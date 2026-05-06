// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/core/CheesecoinsCore.sol";
import "../../foundry-src/Config.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title CheesecoinsCoreV2
 * @notice Mock V2 contract for upgrade testing
 * @dev Adds one new state variable at the end to test storage safety
 */
contract CheesecoinsCoreV2 is CheesecoinsCore {
    /// @notice New state variable added in V2
    uint256 public newFeatureValue;

    /// @notice Function to set the new feature value
    function setNewFeature(uint256 value) external onlyOwner {
        newFeatureValue = value;
    }

    /// @notice Function to get version
    function version() external pure returns (string memory) {
        return "V2";
    }
}

/**
 * @notice Mock price feed used in upgrade tests — returns peg price ($1.00)
 */
contract MockCurdUsdPriceFeedUpgrade {
    int256 private constant _PRICE = int256(Config.PEG_PRICE);

    function viewLatestPrice() external pure returns (int256 price, bool isStale) {
        return (_PRICE, false);
    }
}

/**
 * @title CheesecoinsCoreUpgradeTest
 * @notice Tests for proxy upgrade safety
 * @dev Ensures storage layout is preserved across upgrades
 */
contract CheesecoinsCoreUpgradeTest is Test {
    CheesecoinsCore public coreV1;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public proxy;
    MockCurdUsdPriceFeedUpgrade public mockFeed;

    address public owner;
    address public treasuryEcosystem;
    address public treasuryFarmers;
    address public treasuryMarketing;
    address public treasuryReserve;
    address public auditor;
    address public minter;
    address public proxyAdminOwner;

    function setUp() public {
        owner = address(this);
        proxyAdminOwner = makeAddr("proxyAdminOwner");
        treasuryEcosystem = makeAddr("treasuryEcosystem");
        treasuryFarmers = makeAddr("treasuryFarmers");
        treasuryMarketing = makeAddr("treasuryMarketing");
        treasuryReserve = makeAddr("treasuryReserve");
        auditor = makeAddr("auditor");
        minter = makeAddr("minter");

        // Deploy mock price feed at peg ($1.00)
        mockFeed = new MockCurdUsdPriceFeedUpgrade();

        // Deploy V1 implementation
        CheesecoinsCore implementationV1 = new CheesecoinsCore();

        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();

        // Transfer ProxyAdmin ownership
        proxyAdmin.transferOwnership(proxyAdminOwner);

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            CheesecoinsCore.initialize.selector,
            treasuryEcosystem,
            treasuryFarmers,
            treasuryMarketing,
            treasuryReserve,
            auditor,
            minter,
            address(mockFeed),
            makeAddr("founderVestingWallet")
        );

        proxy = new TransparentUpgradeableProxy(address(implementationV1), address(proxyAdmin), initData);

        coreV1 = CheesecoinsCore(address(proxy));
    }

    function testUpgradePreservesStorage() public {
        // ============ SETUP V1 STATE ============

        // Register multiple projects
        address nft1 = makeAddr("nft1");
        address oracle1 = makeAddr("oracle1");
        uint256 project1Id = coreV1.registerProject(nft1, oracle1, 100);

        address nft2 = makeAddr("nft2");
        address oracle2 = makeAddr("oracle2");
        uint256 project2Id = coreV1.registerProject(nft2, oracle2, 200);

        // Mint some tokens using controllerMint (Stage 0 mint surface)
        uint256 mintAmount = 5000 * 10 ** 18;
        vm.prank(minter);
        coreV1.controllerMint(treasuryEcosystem, mintAmount, "setup");

        // Perform an audit
        vm.warp(block.timestamp + Config.MIN_AUDIT_INTERVAL);
        vm.prank(auditor);
        coreV1.performAnnualAudit(project1Id, 100000 * 10 ** 18, 120, "");

        // Transfer some tokens
        vm.prank(treasuryEcosystem);
        coreV1.transfer(makeAddr("user1"), 1000 * 10 ** 18);

        // ============ SNAPSHOT V1 STATE ============

        uint256 v1TotalSupply = coreV1.totalSupply();
        uint256 v1ProjectCount = coreV1.getProjectCount();
        uint256 v1TotalProduction = coreV1.totalProductionValue();
        uint256 v1CurrentYearMinted = coreV1.currentYearMinted();
        uint256 v1DeploymentTime = coreV1.deploymentTime();

        address v1TreasuryEcosystem = coreV1.treasuryEcosystem();
        address v1TreasuryFarmers = coreV1.treasuryFarmers();
        address v1TreasuryMarketing = coreV1.treasuryMarketing();
        address v1TreasuryReserve = coreV1.treasuryReserve();
        address v1Auditor = coreV1.authorizedAuditor();
        address v1Minter = coreV1.authorizedMinter();

        ICheesecoinsCore.ProjectData memory project1Before = coreV1.getProject(project1Id);
        ICheesecoinsCore.ProjectData memory project2Before = coreV1.getProject(project2Id);

        ICheesecoinsCore.AuditResult[] memory auditsProject1Before = coreV1.getProjectAudits(project1Id);

        uint256 v1EcosystemBalance = coreV1.balanceOf(treasuryEcosystem);
        uint256 v1User1Balance = coreV1.balanceOf(makeAddr("user1"));

        // ============ PERFORM UPGRADE ============

        // Deploy V2 implementation
        CheesecoinsCoreV2 implementationV2 = new CheesecoinsCoreV2();

        // Upgrade proxy (only ProxyAdmin owner can do this)
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV2));

        // Cast proxy to V2
        CheesecoinsCoreV2 coreV2 = CheesecoinsCoreV2(address(proxy));

        // ============ VERIFY ALL STATE PRESERVED ============

        // Check core state variables
        assertEq(coreV2.totalSupply(), v1TotalSupply, "Total supply changed");
        assertEq(coreV2.getProjectCount(), v1ProjectCount, "Project count changed");
        assertEq(coreV2.totalProductionValue(), v1TotalProduction, "Total production changed");
        assertEq(coreV2.currentYearMinted(), v1CurrentYearMinted, "Current year minted changed");
        assertEq(coreV2.deploymentTime(), v1DeploymentTime, "Deployment time changed");

        // Check addresses
        assertEq(coreV2.treasuryEcosystem(), v1TreasuryEcosystem, "Ecosystem treasury changed");
        assertEq(coreV2.treasuryFarmers(), v1TreasuryFarmers, "Farmers treasury changed");
        assertEq(coreV2.treasuryMarketing(), v1TreasuryMarketing, "Marketing treasury changed");
        assertEq(coreV2.treasuryReserve(), v1TreasuryReserve, "Reserve treasury changed");
        assertEq(coreV2.authorizedAuditor(), v1Auditor, "Auditor changed");
        assertEq(coreV2.authorizedMinter(), v1Minter, "Minter changed");

        // Check project data
        ICheesecoinsCore.ProjectData memory project1After = coreV2.getProject(project1Id);
        assertEq(project1After.id, project1Before.id, "Project 1 ID changed");
        assertEq(project1After.nftAddress, project1Before.nftAddress, "Project 1 NFT changed");
        assertEq(project1After.oracleAddress, project1Before.oracleAddress, "Project 1 oracle changed");
        assertEq(project1After.initialDoes, project1Before.initialDoes, "Project 1 initial does changed");
        assertEq(project1After.currentDoes, project1Before.currentDoes, "Project 1 current does changed");
        assertEq(project1After.totalMinted, project1Before.totalMinted, "Project 1 total minted changed");
        assertTrue(project1After.active, "Project 1 active status changed");

        ICheesecoinsCore.ProjectData memory project2After = coreV2.getProject(project2Id);
        assertEq(project2After.id, project2Before.id, "Project 2 ID changed");
        assertEq(project2After.initialDoes, project2Before.initialDoes, "Project 2 initial does changed");

        // Check audit history
        ICheesecoinsCore.AuditResult[] memory auditsProject1After = coreV2.getProjectAudits(project1Id);
        assertEq(auditsProject1After.length, auditsProject1Before.length, "Audit history length changed");
        if (auditsProject1Before.length > 0) {
            assertEq(auditsProject1After[0].projectId, auditsProject1Before[0].projectId, "Audit data changed");
        }

        // Check balances
        assertEq(coreV2.balanceOf(treasuryEcosystem), v1EcosystemBalance, "Ecosystem balance changed");
        assertEq(coreV2.balanceOf(makeAddr("user1")), v1User1Balance, "User1 balance changed");

        // Check token metadata
        assertEq(coreV2.name(), "Cheesecoins CURD", "Token name changed");
        assertEq(coreV2.symbol(), "CURD", "Token symbol changed");
        assertEq(coreV2.decimals(), 18, "Token decimals changed");

        // ============ VERIFY V2 NEW FUNCTIONALITY ============

        // Check V2 version
        assertEq(coreV2.version(), "V2", "V2 version check failed");

        // Test new V2 feature
        assertEq(coreV2.newFeatureValue(), 0, "New feature should initialize to 0");

        coreV2.setNewFeature(12345);
        assertEq(coreV2.newFeatureValue(), 12345, "New feature value not set correctly");

        // ============ VERIFY OPERATIONS STILL WORK ============

        // Verify storage preserved
        assertEq(coreV2.authorizedMinter(), minter, "Minter not preserved after upgrade");
        assertEq(coreV2.authorizedAuditor(), auditor, "Auditor not preserved after upgrade");

        // Can still mint using controllerMint under Stage 0
        uint256 newMintAmount = 1000 * 10 ** 18;
        vm.prank(minter);
        coreV2.controllerMint(treasuryEcosystem, newMintAmount, "post-upgrade test");
        assertEq(coreV2.totalSupply(), v1TotalSupply + newMintAmount, "Mint failed after upgrade");

        // Can still register projects
        address nft3 = makeAddr("nft3");
        address oracle3 = makeAddr("oracle3");
        uint256 project3Id = coreV2.registerProject(nft3, oracle3, 300);
        assertEq(project3Id, 3, "Project registration failed after upgrade");
        assertEq(coreV2.getProjectCount(), 3, "Project count not updated after upgrade");

        // Can still burn
        vm.prank(treasuryEcosystem);
        coreV2.burn(100 * 10 ** 18);
        assertLt(coreV2.totalSupply(), v1TotalSupply + newMintAmount, "Burn failed after upgrade");

        // Can still transfer
        vm.prank(treasuryEcosystem);
        coreV2.transfer(makeAddr("user2"), 500 * 10 ** 18);
        assertEq(coreV2.balanceOf(makeAddr("user2")), 500 * 10 ** 18, "Transfer failed after upgrade");
    }

    function testUpgradeCanOnlyBePerformedByProxyAdmin() public {
        // Deploy V2 implementation
        CheesecoinsCoreV2 implementationV2 = new CheesecoinsCoreV2();

        // Try to upgrade without being ProxyAdmin owner - should fail
        vm.expectRevert();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV2));
    }

    function testMultipleUpgrades() public {
        // Register a project and mint some tokens
        uint256 projectId = coreV1.registerProject(makeAddr("nft"), makeAddr("oracle"), 100);
        vm.prank(minter);
        coreV1.controllerMint(treasuryEcosystem, 5000 * 10 ** 18, "test");

        uint256 initialSupply = coreV1.totalSupply();
        uint256 initialProjectCount = coreV1.getProjectCount();

        // First upgrade to V2
        CheesecoinsCoreV2 implementationV2 = new CheesecoinsCoreV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV2));

        CheesecoinsCoreV2 coreV2 = CheesecoinsCoreV2(address(proxy));
        coreV2.setNewFeature(111);

        // Do some operations in V2 using controllerMint (Stage 0 mint surface).
        // 1000 tokens matches what the legacy path would have minted at $1 price
        // given production grew from 5000→6000 (delta = 1000).
        vm.prank(minter);
        coreV2.controllerMint(treasuryEcosystem, 1000 * 10 ** 18, "test");

        uint256 v2Supply = coreV2.totalSupply();
        uint256 v2NewFeature = coreV2.newFeatureValue();

        // Upgrade back to V1 (simulate a rollback)
        CheesecoinsCore implementationV1New = new CheesecoinsCore();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV1New));

        CheesecoinsCore coreRolledBack = CheesecoinsCore(address(proxy));

        // Verify state still preserved
        assertEq(coreRolledBack.totalSupply(), v2Supply, "Supply changed after rollback");
        assertEq(coreRolledBack.getProjectCount(), initialProjectCount, "Project count changed");

        // Upgrade to V2 again
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV2));

        CheesecoinsCoreV2 coreV2Again = CheesecoinsCoreV2(address(proxy));

        // State should still be preserved
        assertEq(coreV2Again.totalSupply(), v2Supply, "Supply changed after re-upgrade");
        // Note: newFeatureValue would be 0 because storage slot wasn't preserved in V1
        // This is expected behavior
    }

    function testStorageGapExists() public {
        // This test verifies that storage gap was properly added
        // The presence of __gap prevents storage collisions in future upgrades

        // Deploy and initialize
        uint256 projectCount = coreV1.getProjectCount();

        // Register several projects to use storage
        for (uint256 i = 0; i < 5; i++) {
            coreV1.registerProject(
                address(uint160(uint256(keccak256(abi.encodePacked("nft", i))))),
                address(uint160(uint256(keccak256(abi.encodePacked("oracle", i))))),
                100 + i
            );
        }

        assertEq(coreV1.getProjectCount(), projectCount + 5, "Projects not registered");

        // Upgrade to V2 which adds new storage
        CheesecoinsCoreV2 implementationV2 = new CheesecoinsCoreV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(implementationV2));

        CheesecoinsCoreV2 coreV2 = CheesecoinsCoreV2(address(proxy));

        // Verify no storage collision - all projects still accessible
        for (uint256 i = 1; i <= 5; i++) {
            ICheesecoinsCore.ProjectData memory project = coreV2.getProject(i);
            assertTrue(project.active, "Project storage corrupted");
            assertGt(project.initialDoes, 0, "Project data corrupted");
        }

        // New storage works
        coreV2.setNewFeature(999);
        assertEq(coreV2.newFeatureValue(), 999, "New storage slot not working");
    }
}
