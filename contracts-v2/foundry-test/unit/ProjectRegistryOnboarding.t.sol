// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ProjectRegistry} from "../../foundry-src/platform/ProjectRegistry.sol";
import {IProjectRegistry} from "../../foundry-src/platform/interfaces/IProjectRegistry.sol";

/// @dev Minimal stub deployed at a non-zero code address, used as yield pool in tests.
contract MockYieldPool {}

/**
 * @title ProjectRegistryOnboardingTest
 * @notice Phase 7 Step 2 staged onboarding exit-criteria tests.
 *
 * Validates:
 *   1. Factory-only creation (random EOA reverts; factory succeeds)
 *   2. Projects start inactive (active == false after createProject)
 *   3. Only owner can approve (non-owner reverts)
 *   4. Approval requires yield pool registered (reverts without pool)
 *   5. Active gating enforced (updateProjectMetrics reverts pre-approval)
 */
contract ProjectRegistryOnboardingTest is Test {
    // ── Actors ───────────────────────────────────────────────────────────────

    address internal deployer = makeAddr("deployer");
    address internal admin = makeAddr("admin"); // registry owner (timelock authority)
    address internal factory = makeAddr("factory"); // designated ProjectFactory
    address internal randomEOA = makeAddr("randomEOA");
    address internal coreContract = makeAddr("core");
    address internal governanceContract = makeAddr("governance");
    address internal projectOwner = makeAddr("projectOwner");
    address internal nftAddress = makeAddr("nftAddress");
    address internal oracleAddress = makeAddr("oracle");
    address internal yieldPoolAddress; // set to address(new MockYieldPool()) in setUp()

    // ── Contract under test ───────────────────────────────────────────────────

    ProjectRegistry internal registry;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 internal constant MIN_DOES = 10;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy a mock yield pool contract so code-size checks pass in happy-path tests
        yieldPoolAddress = address(new MockYieldPool());

        ProxyAdmin proxyAdmin = new ProxyAdmin();

        // Deploy registry proxy without calling initialize (breaks circular dep)
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(new ProjectRegistry()), address(proxyAdmin), "");
        registry = ProjectRegistry(address(registryProxy));

        // Initialize registry: owner=admin, factory=factory (the address above)
        registry.initialize(admin, coreContract, governanceContract, MIN_DOES, factory);

        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Create a project as the factory (succeeds)
    function _createProjectAsFactory() internal returns (uint256 projectId) {
        vm.prank(factory);
        projectId = registry.createProject("Test Farm", projectOwner, nftAddress, oracleAddress, MIN_DOES);
    }

    /// @dev Register yield pool as factory
    function _registerYieldPool(uint256 projectId) internal {
        vm.prank(factory);
        registry.registerYieldPool(projectId, yieldPoolAddress);
    }

    // ── Test 1: Factory-only creation ─────────────────────────────────────────

    /**
     * @notice createProject() reverts when called by a random EOA.
     */
    function test_createProject_revertsForRandomEOA() public {
        vm.prank(randomEOA);
        vm.expectRevert(ProjectRegistry.UnauthorizedCaller.selector);
        registry.createProject("Test Farm", projectOwner, nftAddress, oracleAddress, MIN_DOES);
    }

    /**
     * @notice createProject() reverts when called by the registry owner (non-factory).
     */
    function test_createProject_revertsForOwner() public {
        vm.prank(admin);
        vm.expectRevert(ProjectRegistry.UnauthorizedCaller.selector);
        registry.createProject("Test Farm", projectOwner, nftAddress, oracleAddress, MIN_DOES);
    }

    /**
     * @notice createProject() succeeds when called by the registered factory.
     */
    function test_createProject_succeedsForFactory() public {
        uint256 projectId = _createProjectAsFactory();
        assertEq(projectId, 1, "first project must have ID 1");
        assertEq(registry.getProjectCount(), 1, "project count must be 1");
    }

    // ── Test 2: Projects start inactive ───────────────────────────────────────

    /**
     * @notice After createProject(), the project is inactive (active == false).
     */
    function test_createProject_projectStartsInactive() public {
        uint256 projectId = _createProjectAsFactory();

        IProjectRegistry.Project memory proj = registry.getProject(projectId);
        assertFalse(proj.active, "project must be inactive immediately after creation");
    }

    // ── Test 3: Only owner can approve ────────────────────────────────────────

    /**
     * @notice approveProject() reverts when called by a non-owner (random EOA).
     */
    function test_approveProject_revertsForNonOwner() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(randomEOA);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.approveProject(projectId);
    }

    /**
     * @notice approveProject() reverts when called by the factory (non-owner).
     */
    function test_approveProject_revertsForFactory() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(factory);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.approveProject(projectId);
    }

    /**
     * @notice approveProject() succeeds when called by the registry owner.
     */
    function test_approveProject_succeedsForOwner() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(admin);
        registry.approveProject(projectId);

        IProjectRegistry.Project memory proj = registry.getProject(projectId);
        assertTrue(proj.active, "project must be active after owner approval");
    }

    /**
     * @notice approveProject() reverts if called a second time (already approved).
     */
    function test_approveProject_revertsIfAlreadyApproved() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(admin);
        registry.approveProject(projectId);

        vm.prank(admin);
        vm.expectRevert("ProjectRegistry: already approved");
        registry.approveProject(projectId);
    }

    // ── Test 4: Approval requires yield pool registered ───────────────────────

    /**
     * @notice approveProject() reverts if yieldPoolAddress is not yet set (address(0)).
     */
    function test_approveProject_revertsIfNoYieldPool() public {
        uint256 projectId = _createProjectAsFactory();
        // Do NOT register yield pool

        vm.prank(admin);
        vm.expectRevert("ProjectRegistry: yield pool not registered");
        registry.approveProject(projectId);
    }

    /**
     * @notice After factory registers yield pool, owner can approve successfully.
     */
    function test_approveProject_succeedsAfterYieldPoolRegistered() public {
        uint256 projectId = _createProjectAsFactory();

        // Register yield pool via factory
        _registerYieldPool(projectId);

        // Yield pool is now set but project is still inactive
        IProjectRegistry.Project memory projBefore = registry.getProject(projectId);
        assertEq(projBefore.yieldPoolAddress, yieldPoolAddress, "yield pool must be registered");
        assertFalse(projBefore.active, "project must still be inactive before approval");

        // Owner approves
        vm.prank(admin);
        registry.approveProject(projectId);

        IProjectRegistry.Project memory projAfter = registry.getProject(projectId);
        assertTrue(projAfter.active, "project must be active after approval");
    }

    /**
     * @notice registerYieldPool() reverts when called by a non-factory caller.
     */
    function test_registerYieldPool_revertsForNonFactory() public {
        uint256 projectId = _createProjectAsFactory();

        vm.prank(randomEOA);
        vm.expectRevert(ProjectRegistry.UnauthorizedCaller.selector);
        registry.registerYieldPool(projectId, yieldPoolAddress);
    }

    /**
     * @notice registerYieldPool() reverts when the yield pool address is an EOA (no code).
     */
    function test_registerYieldPool_revertsForEOA() public {
        uint256 projectId = _createProjectAsFactory();

        address eoaAddress = makeAddr("eoaYieldPool"); // no code deployed here
        vm.prank(factory);
        vm.expectRevert("ProjectRegistry: yield pool not a contract");
        registry.registerYieldPool(projectId, eoaAddress);
    }

    // ── Test 5: Active gating enforced ────────────────────────────────────────

    /**
     * @notice updateProjectMetrics() reverts with ProjectInactive before approval.
     */
    function test_updateProjectMetrics_revertsPreApproval() public {
        uint256 projectId = _createProjectAsFactory();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ProjectInactive.selector, projectId));
        registry.updateProjectMetrics(projectId, 110, 1000 ether, 50);
    }

    /**
     * @notice updateProjectMetrics() succeeds after approval.
     */
    function test_updateProjectMetrics_succeedsPostApproval() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(admin);
        registry.approveProject(projectId);

        // Admin (owner) can now update metrics
        vm.prank(admin);
        registry.updateProjectMetrics(projectId, 120, 5000 ether, 100);

        IProjectRegistry.ProjectMetrics memory m = registry.getProjectMetrics(projectId);
        assertEq(m.growthRate, 120, "growth rate must be updated");
        assertEq(m.totalStaked, 5000 ether, "total staked must be updated");
        assertEq(m.nftHolders, 100, "nft holders must be updated");
    }

    /**
     * @notice recordYieldDistribution() reverts with ProjectInactive before approval.
     */
    function test_recordYieldDistribution_revertsPreApproval() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);
        // Project exists and yield pool is registered, but not yet approved (active=false)

        vm.prank(yieldPoolAddress);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ProjectInactive.selector, projectId));
        registry.recordYieldDistribution(projectId, 100 ether);
    }

    /**
     * @notice recordYieldDistribution() succeeds after approval.
     */
    function test_recordYieldDistribution_succeedsPostApproval() public {
        uint256 projectId = _createProjectAsFactory();
        _registerYieldPool(projectId);

        vm.prank(admin);
        registry.approveProject(projectId);

        vm.prank(yieldPoolAddress);
        registry.recordYieldDistribution(projectId, 100 ether);

        IProjectRegistry.ProjectMetrics memory m = registry.getProjectMetrics(projectId);
        assertEq(m.totalYieldDistributed, 100 ether, "yield distributed must be recorded");
    }
}
