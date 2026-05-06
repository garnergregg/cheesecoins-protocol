// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/core/CheesecoinsCore.sol";
import "../../foundry-src/Config.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title MockCurdUsdPriceFeed
 * @notice Configurable mock price feed for unit testing
 */
contract MockCurdUsdPriceFeed {
    int256 private _price;
    bool private _isStale;

    constructor(int256 price_, bool isStale_) {
        _price = price_;
        _isStale = isStale_;
    }

    function viewLatestPrice() external view returns (int256 price, bool isStale) {
        return (_price, _isStale);
    }

    function setPrice(int256 price_, bool isStale_) external {
        _price = price_;
        _isStale = isStale_;
    }
}

/**
 * @title CheesecoinsCoreTest
 * @notice Comprehensive test suite for CheesecoinsCore contract
 * @dev Tests tokenomics, security, access control, and upgrade safety
 */
contract CheesecoinsCoreTest is Test {
    CheesecoinsCore public implementation;
    CheesecoinsCore public core;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public proxy;
    MockCurdUsdPriceFeed public mockFeed;

    address public owner;
    address public treasuryEcosystem;
    address public treasuryFarmers;
    address public treasuryMarketing;
    address public treasuryReserve;
    address public auditor;
    address public minter;
    address public user1;
    address public user2;

    event ProjectRegistered(uint256 indexed projectId, address nftAddress, uint256 initialDoes);
    event Mint(address indexed to, uint256 amount, uint256 indexed projectId, string reason);
    event Burn(address indexed from, uint256 amount, string reason);
    event AuditCompleted(
        uint256 indexed projectId, uint256 actualValue, uint256 actualDoes, uint256 growthRate, bool targetsMet
    );

    function setUp() public {
        // Setup addresses
        owner = address(this);
        treasuryEcosystem = makeAddr("treasuryEcosystem");
        treasuryFarmers = makeAddr("treasuryFarmers");
        treasuryMarketing = makeAddr("treasuryMarketing");
        treasuryReserve = makeAddr("treasuryReserve");
        auditor = makeAddr("auditor");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock price feed at peg ($1.00 = 1e8 in 8-decimal format)
        mockFeed = new MockCurdUsdPriceFeed(int256(Config.PEG_PRICE), false);

        // Deploy implementation
        implementation = new CheesecoinsCore();

        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();

        // founderVestingWallet placeholder (non-zero address required)
        address founderVestingWallet = makeAddr("founderVestingWallet");

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
            founderVestingWallet
        );

        proxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        // Get proxy as CheesecoinsCore
        core = CheesecoinsCore(address(proxy));
    }

    // ============ INITIALIZATION TESTS ============

    function testInitialization() public {
        assertEq(core.name(), "Cheesecoins CURD");
        assertEq(core.symbol(), "CURD");
        assertEq(core.decimals(), 18);
        assertEq(core.totalSupply(), Config.INITIAL_SUPPLY);
        assertEq(core.balanceOf(treasuryEcosystem), Config.TREASURY_ALLOCATION);
        assertEq(core.treasuryEcosystem(), treasuryEcosystem);
        assertEq(core.treasuryFarmers(), treasuryFarmers);
        assertEq(core.treasuryMarketing(), treasuryMarketing);
        assertEq(core.treasuryReserve(), treasuryReserve);
        assertEq(core.authorizedAuditor(), auditor);
        assertEq(core.authorizedMinter(), minter);
    }

    function testCannotReinitialize() public {
        vm.expectRevert();
        core.initialize(
            treasuryEcosystem,
            treasuryFarmers,
            treasuryMarketing,
            treasuryReserve,
            auditor,
            minter,
            address(mockFeed),
            makeAddr("founderVestingWallet")
        );
    }

    function testInitialMintToEcosystemTreasury() public {
        assertEq(
            core.balanceOf(treasuryEcosystem), Config.TREASURY_ALLOCATION, "180M should be minted to ecosystem treasury"
        );
    }

    // ============ MAX SUPPLY ENFORCEMENT TESTS ============

    function testCannotExceedMaxSupply() public {
        assertEq(core.authorizedMinter(), minter, "minter mismatch");

        uint256 initialSupply = core.totalSupply();
        uint256 maxSupply = Config.MAX_SUPPLY;
        uint256 excessAmount = maxSupply - initialSupply + 1;

        // controllerMint enforces MAX_SUPPLY; overflow reverts with SUPPLY_CAP_EXCEEDED
        vm.prank(minter);
        vm.expectRevert("SUPPLY_CAP_EXCEEDED");
        core.controllerMint(treasuryEcosystem, excessAmount, "exceed test");

        // Supply should be unchanged (revert)
        assertLe(core.totalSupply(), maxSupply, "Total supply must not exceed MAX_SUPPLY");
    }

    function testMaxSupplyInvariant() public {
        assertLe(core.totalSupply(), Config.MAX_SUPPLY, "Total supply must never exceed MAX_SUPPLY");
    }

    // ============ ANNUAL MINT CAP TESTS ============

    function testAnnualMintCap() public {
        // Legacy mint path is permanently disabled under Stage 0 policy
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(1000 * 10 ** 18, "");

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(2000 * 10 ** 18, "");
    }

    function testAnnualMintCapResets() public {
        // Legacy mint path is permanently disabled under Stage 0 policy
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(1000 * 10 ** 18, "");
    }

    function testCurrentYearMintedTracking() public {
        // Legacy mint path is permanently disabled under Stage 0 policy
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(1000 * 10 ** 18, "");

        // currentYearMinted stays 0 since mint path is disabled
        (uint256 minted,,) = core.getAnnualMintStats();
        assertEq(minted, 0, "currentYearMinted stays 0 when mint path is disabled");
    }

    // ============ PRODUCTION GROWTH MINTING TESTS ============

    function testMintRequiresProductionGrowth() public {
        uint256 currentProduction = core.totalProductionValue();

        // Body never runs — MINT_PATH_DISABLED fires first (path is disabled before input checks)
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(currentProduction, "");
    }

    function testMintProportionalToProductionGrowth() public {
        uint256 productionGrowth = 5000 * 10 ** 18;
        uint256 newProductionValue = core.totalProductionValue() + productionGrowth;

        // Legacy mint path disabled — production-proportional minting no longer active
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(newProductionValue, "");
    }

    function testNoUnderflowInProductionCalculation() public {
        uint256 initialProduction = 10000 * 10 ** 18;

        // Both calls hit MINT_PATH_DISABLED before any arithmetic
        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(initialProduction, "");

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(initialProduction - 1000 * 10 ** 18, "");
    }

    // ============ ACCESS CONTROL TESTS ============

    function testOnlyOwnerCanRegisterProjects() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");

        vm.prank(user1);
        vm.expectRevert();
        core.registerProject(nft, oracle, 100);
    }

    function testOnlyMinterCanMint() public {
        vm.prank(user1);
        vm.expectRevert("CheesecoinsCore: caller not minter");
        core.mintNewCURDForEcosystemGrowth(1000 * 10 ** 18, "");
    }

    function testOnlyAuditorCanAudit() public {
        // Register a project first
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 projectId = core.registerProject(nft, oracle, 100);

        // Fast forward to allow audit
        vm.warp(block.timestamp + Config.MIN_AUDIT_INTERVAL);

        vm.prank(user1);
        vm.expectRevert("CheesecoinsCore: caller not auditor");
        core.performAnnualAudit(projectId, 1000 * 10 ** 18, 100, "");
    }

    function testOwnerCanUpdateAuditor() public {
        address newAuditor = makeAddr("newAuditor");
        core.setAuthorizedAuditor(newAuditor);
        assertEq(core.authorizedAuditor(), newAuditor);
    }

    function testOwnerCanUpdateMinter() public {
        address newMinter = makeAddr("newMinter");
        core.setAuthorizedMinter(newMinter);
        assertEq(core.authorizedMinter(), newMinter);
    }

    function testNonOwnerCannotUpdateAuditor() public {
        address newAuditor = makeAddr("newAuditor");
        vm.prank(user1);
        vm.expectRevert();
        core.setAuthorizedAuditor(newAuditor);
    }

    function testNonOwnerCannotUpdateMinter() public {
        address newMinter = makeAddr("newMinter");
        vm.prank(user1);
        vm.expectRevert();
        core.setAuthorizedMinter(newMinter);
    }

    // ============ AUDIT TESTS ============

    function testAuditIntervalEnforced() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 projectId = core.registerProject(nft, oracle, 100);

        // Try to audit immediately - should fail
        vm.prank(auditor);
        vm.expectRevert("CheesecoinsCore: audit too soon");
        core.performAnnualAudit(projectId, 1000 * 10 ** 18, 100, "");
    }

    function testAuditAfterMinInterval() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 projectId = core.registerProject(nft, oracle, 100);

        // Fast forward past minimum interval
        vm.warp(block.timestamp + Config.MIN_AUDIT_INTERVAL);

        vm.prank(auditor);
        core.performAnnualAudit(projectId, 100000 * 10 ** 18, 120, "");

        // Should succeed
    }

    function testAuditPenaltyWhenTargetsNotMet() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 projectId = core.registerProject(nft, oracle, 100);

        vm.warp(block.timestamp + Config.MIN_AUDIT_INTERVAL);

        uint256 initialBalance = core.balanceOf(treasuryEcosystem);

        // Perform audit with values below expected
        vm.prank(auditor);
        core.performAnnualAudit(projectId, 1 * 10 ** 18, 50, "");

        // Check that penalty was applied (balance should be lower due to burn)
        uint256 finalBalance = core.balanceOf(treasuryEcosystem);
        assertLe(finalBalance, initialBalance, "Penalty should reduce treasury balance");
    }

    function testAuditRewardWhenTargetsExceeded() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 projectId = core.registerProject(nft, oracle, 100);

        vm.warp(block.timestamp + Config.MIN_AUDIT_INTERVAL + Config.ONE_YEAR);

        uint256 initialSupply = core.totalSupply();

        // Perform audit with exceptional growth
        vm.prank(auditor);
        core.performAnnualAudit(projectId, 500000 * 10 ** 18, 150, "");

        // Under Stage 0, project.totalMinted = 0 (legacy path disabled), so audit reward = 0
        assertEq(core.totalSupply(), initialSupply, "No audit reward minted under Stage 0");
    }

    // ============ BURN TESTS ============

    function testUserCanBurnOwnTokens() public {
        // Transfer some tokens to user1
        vm.prank(treasuryEcosystem);
        core.transfer(user1, 1000 * 10 ** 18);

        uint256 burnAmount = 500 * 10 ** 18;
        uint256 initialBalance = core.balanceOf(user1);
        uint256 initialSupply = core.totalSupply();

        vm.prank(user1);
        core.burn(burnAmount);

        assertEq(core.balanceOf(user1), initialBalance - burnAmount);
        assertEq(core.totalSupply(), initialSupply - burnAmount);
    }

    function testBurnFromWithAllowance() public {
        // Transfer some tokens to user1
        vm.prank(treasuryEcosystem);
        core.transfer(user1, 1000 * 10 ** 18);

        uint256 burnAmount = 500 * 10 ** 18;

        // User1 approves user2 to burn
        vm.prank(user1);
        core.approve(user2, burnAmount);

        uint256 initialSupply = core.totalSupply();

        // User2 burns from user1
        vm.prank(user2);
        core.burnFrom(user1, burnAmount);

        assertEq(core.totalSupply(), initialSupply - burnAmount);
        assertEq(core.balanceOf(user1), 500 * 10 ** 18);
    }

    function testCannotBurnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("CheesecoinsCore: zero burn amount");
        core.burn(0);
    }

    // ============ BURN RATE SCHEDULE TESTS ============

    function testBurnRateProgression() public {
        // Get deployment time to calculate years properly
        uint256 deployTime = core.deploymentTime();

        // Year 0 - at deployment
        vm.warp(deployTime);
        assertEq(core.getCurrentBurnRate(), 0);

        // Year 1 - exactly 1 year after deployment
        vm.warp(deployTime + Config.ONE_YEAR);
        assertEq(core.getCurrentBurnRate(), 1 * 10 ** 18);

        // Year 2 - exactly 2 years after deployment
        vm.warp(deployTime + 2 * Config.ONE_YEAR);
        assertEq(core.getCurrentBurnRate(), 2 * 10 ** 18);

        // Year 3 - exactly 3 years after deployment
        vm.warp(deployTime + 3 * Config.ONE_YEAR);
        assertEq(core.getCurrentBurnRate(), 3 * 10 ** 18);

        // Year 4+ - exactly 4 years after deployment
        vm.warp(deployTime + 4 * Config.ONE_YEAR);
        assertEq(core.getCurrentBurnRate(), 4 * 10 ** 18);
    }

    // ============ PROJECT REGISTRATION TESTS ============

    function testRegisterProject() public {
        address nft = makeAddr("nft");
        address oracle = makeAddr("oracle");
        uint256 initialDoes = 100;

        vm.expectEmit(true, true, false, true);
        emit ProjectRegistered(1, nft, initialDoes);

        uint256 projectId = core.registerProject(nft, oracle, initialDoes);

        assertEq(projectId, 1);
        assertEq(core.getProjectCount(), 1);

        ICheesecoinsCore.ProjectData memory project = core.getProject(projectId);
        assertEq(project.nftAddress, nft);
        assertEq(project.oracleAddress, oracle);
        assertEq(project.initialDoes, initialDoes);
        assertEq(project.currentDoes, initialDoes);
        assertTrue(project.active);
    }

    function testCannotRegisterProjectWithZeroAddress() public {
        vm.expectRevert();
        core.registerProject(address(0), makeAddr("oracle"), 100);
    }

    function testCannotRegisterProjectWithZeroDoes() public {
        vm.expectRevert();
        core.registerProject(makeAddr("nft"), makeAddr("oracle"), 0);
    }

    function testProjectCountIncreases() public {
        assertEq(core.getProjectCount(), 0);

        core.registerProject(makeAddr("nft1"), makeAddr("oracle1"), 100);
        assertEq(core.getProjectCount(), 1);

        core.registerProject(makeAddr("nft2"), makeAddr("oracle2"), 200);
        assertEq(core.getProjectCount(), 2);
    }

    // ============ DEFLATIONARY METRICS TESTS ============

    function testDeflatoryTrajectoryTracking() public {
        uint256 mintAmount = 30_000 * 1e18;

        vm.prank(minter);
        core.controllerMint(treasuryEcosystem, mintAmount, "test");

        (uint256 productionValue, uint256 tokenSupply, uint256 ratio) = core.getDeflatoryTrajectory();

        // Under Stage 0, totalProductionValue is never updated (legacy path disabled)
        assertEq(productionValue, 0, "productionValue stays 0 under Stage 0");
        assertEq(tokenSupply, Config.INITIAL_SUPPLY + mintAmount);
        assertEq(ratio, 0, "ratio = 0 when productionValue = 0");
    }

    // ============ ORACLE PRICE CONVERSION TESTS ============

    function testPriceFeedStoredOnInitialize() public {
        assertEq(core.curdUsdPriceFeed(), address(mockFeed), "price feed should be stored");
    }

    /// @notice Legacy path disabled — price oracle is no longer used in mint conversion
    function testMintConversionAtOneDollar() public {
        uint256 productionGrowth = 1000 * 1e18;
        uint256 newProductionValue = core.totalProductionValue() + productionGrowth;

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(newProductionValue, "");
    }

    /// @notice Legacy path disabled — price oracle is no longer used in mint conversion
    function testMintConversionAtTwoDollars() public {
        mockFeed.setPrice(2e8, false);

        uint256 productionGrowth = 1000 * 1e18;
        uint256 newProductionValue = core.totalProductionValue() + productionGrowth;

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(newProductionValue, "");
    }

    /// @notice Legacy path disabled — price oracle is no longer used in mint conversion
    function testMintConversionAtHalfDollar() public {
        mockFeed.setPrice(5e7, false);

        uint256 productionGrowth = 1000 * 1e18;
        uint256 newProductionValue = core.totalProductionValue() + productionGrowth;

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(newProductionValue, "");

        assertLe(core.totalSupply(), Config.MAX_SUPPLY, "supply must not exceed max");
    }

    /// @notice Legacy path disabled — reverts with MINT_PATH_DISABLED before oracle check
    function testMintRevertsOnInvalidPrice() public {
        mockFeed.setPrice(0, false);

        uint256 productionGrowth = 1000 * 1e18;
        uint256 newProductionValue = core.totalProductionValue() + productionGrowth;

        vm.prank(minter);
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(newProductionValue, "");
    }
}
