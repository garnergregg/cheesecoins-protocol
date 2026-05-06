// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Config} from "../../foundry-src/Config.sol";
import {ProjectFactory} from "../../foundry-src/platform/ProjectFactory.sol";
import {ProjectRegistry} from "../../foundry-src/platform/ProjectRegistry.sol";
import {IProjectRegistry} from "../../foundry-src/platform/interfaces/IProjectRegistry.sol";
import {ProjectNFTTemplate} from "../../foundry-src/nft/ProjectNFTTemplate.sol";
import {TransferHookRouter} from "../../foundry-src/nft/TransferHookRouter.sol";
import {INFTTransferHook} from "../../foundry-src/nft/interfaces/INFTTransferHook.sol";
import {SceneTracker} from "../../foundry-src/nft/extensions/SceneTracker.sol";
import {YieldPool} from "../../foundry-src/staking/YieldPool.sol";
import {StakingManager} from "../../foundry-src/staking/StakingManager.sol";
import {ProtocolTimelock} from "../../foundry-src/governance/ProtocolTimelock.sol";
import {SuperHolderGovernance} from "../../foundry-src/governance/SuperHolderGovernance.sol";
import {GovernanceWeighting} from "../../foundry-src/governance/GovernanceWeighting.sol";
import {FounderDecentralization} from "../../foundry-src/governance/FounderDecentralization.sol";
import {IGovernance} from "../../foundry-src/governance/interfaces/IGovernance.sol";

// ============ MOCKS ============

/// @dev Minimal ERC20 mock that acts as both curdToken and cheesecoinsCore.
contract MockCore {}

contract P7MockWeighting is GovernanceWeighting {
    mapping(address => mapping(uint256 => uint256)) internal _power;

    constructor(address stakingMgr, address registry_) GovernanceWeighting(stakingMgr, registry_) {}

    function setVotingPower(address voter, uint256 pid, uint256 power) external {
        _power[voter][pid] = power;
    }

    function calculateVotingPower(address voter, uint256 pid, bool) public override returns (uint256) {
        return _power[voter][pid];
    }

    function previewVotingPower(uint256, uint256, bool) external pure override returns (uint256) {
        return 0;
    }
}

contract P7MockFounderDecent is FounderDecentralization {
    constructor(address founder) FounderDecentralization(founder) {}
}

contract P7MockStakingManager {
    mapping(address => mapping(uint256 => uint256)) internal _stake;
    mapping(address => mapping(uint256 => uint64)) internal _startAt;

    function setStake(address user, uint256 pid, uint256 amount) external {
        _stake[user][pid] = amount;
    }

    function setStartAt(address user, uint256 pid, uint64 ts) external {
        _startAt[user][pid] = ts;
    }

    function getUserProjectStaked(address user, uint256 pid) external view returns (uint256) {
        return _stake[user][pid];
    }

    function userProjectStakeStartAt(address user, uint256 pid) external view returns (uint64) {
        return _startAt[user][pid];
    }
}

contract P7MockSceneTracker {
    mapping(address => bool) internal _full;

    function setFullCollection(address user, bool val) external {
        _full[user] = val;
    }

    function hasFullCollection(address user) external view returns (bool) {
        return _full[user];
    }
}

contract P7MockProjectRegistry {
    function getProjectCount() external pure returns (uint256) {
        return 0;
    }

    function getProjectMetrics(uint256) external pure returns (IProjectRegistry.ProjectMetrics memory) {
        return IProjectRegistry.ProjectMetrics({
            projectId: 1,
            growthRate: 100,
            totalStaked: 0,
            totalYieldDistributed: 0,
            nftHolders: 0,
            graduationWeight: 10000
        });
    }
}

/// @dev Governance target that records execution.
contract P7MockTarget {
    bool public wasCalled;

    function doSomething() external {
        wasCalled = true;
    }
}

/**
 * @dev Minimal INFTTransferHook adapter used as the factory's sceneTracker and
 *      stakingManager hook slots.  Just records calls; no actual logic required
 *      for Phase 7 factory wiring tests.  Separate from P7MockSceneTracker which
 *      only serves the governance full-collection check.
 */
contract P7MockHookAdapter is INFTTransferHook {
    function beforeNFTTransfer(uint256, address, address) external pure override returns (bool) {
        return true;
    }

    function afterNFTTransfer(uint256, address, address) external override {}
}

// ============ PHASE 7 INTEGRATION TEST ============

/**
 * @title ProjectFactoryPhase7Test
 * @notice Phase 7 Step 1 exit-criteria test.
 *
 * Lifecycle covered:
 *   deploy → approveTemplate → createProject → (NFT/pool assertions) →
 *   mint → (governance) propose → queue → execute
 *
 * PR3 acceptance criteria:
 *   ✔ Factory deploys & initialises YieldPool clone in same tx
 *   ✔ YieldPool is one-shot initialised
 *   ✔ YieldPool is bound to projectId
 *   ✔ Any state mutation before init reverts
 *   ✔ pool.owner() == factory.owner()
 */
contract ProjectFactoryPhase7Test is Test {
    // ── Actors ───────────────────────────────────────────────────────────────

    address internal deployer = makeAddr("deployer");
    address internal admin = makeAddr("admin"); // factory/registry owner
    address internal founderMultisig = makeAddr("founderMultisig");
    address internal guardian = makeAddr("guardian");
    address internal user = makeAddr("user");
    address internal superHolder1 = makeAddr("superHolder1");
    address internal superHolder2 = makeAddr("superHolder2");
    address internal oracle = makeAddr("oracle");

    // ── Contracts ─────────────────────────────────────────────────────────────

    ProxyAdmin internal proxyAdmin;
    MockCore internal core;
    ProjectRegistry internal registry;
    ProjectFactory internal factory;
    ProjectNFTTemplate internal nftImpl;
    YieldPool internal poolImpl;

    // Hook adapters wired into every project's TransferHookRouter by the factory.
    // Separate from the governance mocks (sceneMock, stakingMgr) which only serve
    // voting-power checks.
    P7MockHookAdapter internal hookSceneTracker;
    P7MockHookAdapter internal hookStakingMgr;

    // Governance
    ProtocolTimelock internal timelock;
    SuperHolderGovernance internal governance;
    P7MockWeighting internal weighting;
    P7MockFounderDecent internal founderDecent;
    P7MockStakingManager internal stakingMgr;
    P7MockSceneTracker internal sceneMock;
    P7MockTarget internal target;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 internal constant TIMELOCK_DELAY = Config.TIMELOCK_DELAY;
    uint256 internal constant PROJECT_ID = 1; // first project is always 1

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // Block time must be >= 24 weeks for governance eligibility
        vm.warp(24 weeks + 1);

        vm.startPrank(deployer);
        proxyAdmin = new ProxyAdmin();
        core = new MockCore();
        nftImpl = new ProjectNFTTemplate();
        poolImpl = new YieldPool();
        hookSceneTracker = new P7MockHookAdapter();
        hookStakingMgr = new P7MockHookAdapter();

        // ── Deploy ProjectRegistry proxy WITHOUT calling initialize ────────
        // This breaks the circular dependency: we need the factory address to
        // initialize the registry, but the factory needs the registry address.
        // Solution: deploy registry proxy first (no init), then factory proxy
        // (with registry address), then finally initialize registry with factory address.
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(new ProjectRegistry()), address(proxyAdmin), "");
        registry = ProjectRegistry(address(registryProxy));

        // ── Deploy ProjectFactory via proxy (owner = `admin`) ─────────────
        bytes memory factoryInit = abi.encodeWithSelector(
            ProjectFactory.initialize.selector,
            admin,
            address(registry),
            address(core),
            address(poolImpl),
            address(hookSceneTracker),
            address(hookStakingMgr)
        );
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(address(new ProjectFactory()), address(proxyAdmin), factoryInit);
        factory = ProjectFactory(address(factoryProxy));

        // ── Now initialize registry with factory address known ────────────
        registry.initialize(
            admin,
            address(core),
            admin, // governanceContract placeholder (not used in creation path)
            10, // minInitialDoes
            address(factory)
        );
        vm.stopPrank();

        // ── Deploy Governance stack ────────────────────────────────────────
        vm.startPrank(deployer);

        stakingMgr = new P7MockStakingManager();
        sceneMock = new P7MockSceneTracker();
        weighting = new P7MockWeighting(address(stakingMgr), address(new P7MockProjectRegistry()));
        founderDecent = new P7MockFounderDecent(founderMultisig);
        target = new P7MockTarget();

        address[] memory proposers = new address[](1);
        proposers[0] = founderMultisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;

        timelock = new ProtocolTimelock(TIMELOCK_DELAY, proposers, executors, cancellers, address(0));

        governance = new SuperHolderGovernance(
            address(weighting),
            address(founderDecent),
            address(timelock),
            founderMultisig,
            address(sceneMock),
            address(stakingMgr),
            PROJECT_ID
        );

        vm.stopPrank();

        // ── Approve NFT template (admin = factory owner) ──────────────────
        vm.prank(admin);
        factory.approveTemplate(address(nftImpl), "ProjectNFT v1");

        // ── Wire super holders for governance ─────────────────────────────
        _registerSuperHolder(superHolder1, PROJECT_ID, 60);
        _registerSuperHolder(superHolder2, PROJECT_ID, 40);
    }

    // ── Core PR3 tests ────────────────────────────────────────────────────────

    /**
     * @notice Test 1: createProject initialises a YieldPool bound to the correct projectId.
     */
    function test_createProject_initializesYieldPoolBoundToProject() public {
        vm.prank(user);
        (uint256 pid, address nftAddr, address poolAddr) = factory.createProject("Goat Farm Alpha", 1, oracle, 10);

        YieldPool pool = YieldPool(poolAddr);

        // Pool must be bound to the correct projectId
        assertEq(pool.projectId(), pid, "pool.projectId must equal the assigned project ID");
        assertEq(pid, PROJECT_ID, "first project must have ID 1");

        // Re-initialization must revert (one-shot guard)
        vm.expectRevert(); // ALREADY_INITIALIZED via OZ initializer modifier
        pool.initialize(pid, address(core), address(core), user);
    }

    /**
     * @notice Test 2: An un-initialized YieldPool clone reverts on any mutation.
     */
    function test_yieldPool_revertsIfNotInitialized() public {
        // Clone the pool template without calling initialize
        address rawClone = ClonesUpgradeable.clone(address(poolImpl));
        YieldPool uninit = YieldPool(rawClone);

        vm.expectRevert(YieldPool.NotInitialized.selector);
        uninit.depositYield(1, 100);
    }

    /**
     * @notice Blocker-2 fix validation: YieldPool operations must reject a project ID
     *         that differs from the bound projectId (onlyBoundProject enforcement).
     */
    function test_yieldPool_depositYield_rejectsWrongProjectId() public {
        vm.prank(user);
        (uint256 pid,, address poolAddr) = factory.createProject("Goat Farm Bound", 1, oracle, 10);

        YieldPool pool = YieldPool(poolAddr);

        // Confirm the pool is bound to the expected ID
        assertEq(pool.projectId(), pid, "pool must be bound to the factory-assigned projectId");

        // A deposit for a different project ID must revert
        uint256 wrongId = pid + 1;
        vm.expectRevert(YieldPool.InvalidProjectId.selector);
        pool.depositYield(wrongId, 100);
    }

    /**
     * @notice Test 3: pool.owner() == factory.owner() after createProject.
     */
    function test_factory_poolOwner_is_factoryOwner() public {
        vm.prank(user);
        (,, address poolAddr) = factory.createProject("Goat Farm Beta", 1, oracle, 10);

        YieldPool pool = YieldPool(poolAddr);
        assertEq(pool.owner(), factory.owner(), "pool.owner must equal factory.owner()");
        assertEq(pool.owner(), admin, "factory.owner() must be admin");
    }

    // ── NFT initialization tests ──────────────────────────────────────────────

    /**
     * @notice NFT is initialized: projectId, deterministic symbol, owner = factory.owner(),
     *         transferHook wired to a router, and router has canonical hooks pre-set.
     */
    function test_createProject_initializesNFT() public {
        string memory projectName = "Goat Farm Gamma";
        vm.prank(user);
        (uint256 pid, address nftAddr,) = factory.createProject(projectName, 1, oracle, 10);

        ProjectNFTTemplate nft = ProjectNFTTemplate(nftAddr);

        assertEq(nft.getProjectId(), pid, "NFT.getProjectId must match assigned projectId");
        assertEq(nft.name(), projectName, "NFT name must match project name");

        // Deterministic symbol: "PROJ" + decimal projectId
        string memory expectedSymbol = string(abi.encodePacked("PROJ", _uintToStr(pid)));
        assertEq(nft.symbol(), expectedSymbol, "NFT symbol must be deterministic PROJ+id");

        // NFT owner must be factory.owner() (admin), not the project creator (user)
        assertEq(nft.owner(), admin, "NFT.owner must be factory.owner() (timelock authority)");
        assertTrue(nft.owner() != user, "NFT.owner must NOT be the project creator");

        // transferHook must be wired — canonical source is nft.transferHook()
        address routerAddr = address(nft.transferHook());
        assertTrue(routerAddr != address(0), "NFT.transferHook must be set after createProject");

        TransferHookRouter router = TransferHookRouter(routerAddr);

        // Router must be bound to this NFT
        assertEq(router.nftContract(), nftAddr, "router.nftContract must equal nftAddr");

        // Router must be owned by factory.owner() (timelock authority), not factory itself
        assertEq(router.owner(), admin, "router.owner must be factory.owner()");
        assertTrue(router.owner() != address(factory), "router must NOT still be owned by factory");

        // Router must have exactly the 2 canonical hooks pre-wired (no post-deploy config needed)
        address[] memory hooks = router.getHooks();
        assertEq(hooks.length, 2, "router must have exactly 2 hooks wired");
        assertEq(hooks[0], factory.sceneTracker(), "hooks[0] must be factory.sceneTracker");
        assertEq(hooks[1], factory.stakingManager(), "hooks[1] must be factory.stakingManager");
    }

    /**
     * @notice Re-initialization of NFT clone reverts.
     */
    function test_reinitNFT_reverts() public {
        vm.prank(user);
        (uint256 pid, address nftAddr,) = factory.createProject("Goat Farm Delta", 1, oracle, 10);

        ProjectNFTTemplate nft = ProjectNFTTemplate(nftAddr);

        vm.expectRevert(); // AlreadyInitialized or OZ initializer guard
        nft.initialize(pid, "Hack", "HACK", user);
    }

    // ── Template approval guard ───────────────────────────────────────────────

    /**
     * @notice approveTemplate rejects an address with no deployed code.
     */
    function test_approveTemplate_rejectsNonContract() public {
        address nonContract = makeAddr("nonContract");
        vm.prank(admin);
        vm.expectRevert(ProjectFactory.InvalidTemplate.selector);
        factory.approveTemplate(nonContract, "bad template");
    }

    /**
     * @notice approveTemplate rejects a contract that lacks getProjectId().
     */
    function test_approveTemplate_rejectsIncompatibleContract() public {
        // Deploy a contract without getProjectId()
        address incompatible = address(new MockCore());
        vm.prank(admin);
        vm.expectRevert(ProjectFactory.InvalidTemplate.selector);
        factory.approveTemplate(incompatible, "incompatible");
    }

    // ── Mint path ─────────────────────────────────────────────────────────────

    /**
     * @notice Mint works after the factory has fully initialized the NFT.
     */
    function test_mint_succeedsAfterProjectCreation() public {
        vm.prank(user);
        (, address nftAddr,) = factory.createProject("Goat Farm Epsilon", 1, oracle, 10);

        ProjectNFTTemplate nft = ProjectNFTTemplate(nftAddr);

        // Admin (factory.owner() = NFT owner) authorises a minter
        address minter = makeAddr("minter");
        vm.prank(admin);
        nft.setAuthorizedMinter(minter, true);

        // Minter mints scene 1 to user
        vm.prank(minter);
        uint256 tokenId = nft.mint(user, 1);

        assertEq(nft.ownerOf(tokenId), user, "minted token must belong to user");
        assertEq(nft.getSceneNumber(tokenId), 1, "scene number must be 1");
    }

    /**
     * @notice Real-hooks integration test: replaces mock hook adapters with the real
     *         SceneTracker and StakingManager contracts, then mints and transfers through
     *         the router to prove no revert occurs and real hook state is updated correctly.
     *
     * @dev Rationale (addresses problem-statement merge-gate item 2):
     *      The factory is initialised with P7MockHookAdapter no-ops as sceneTracker and
     *      stakingManager.  This test swaps those out (via router.setHooks, which the
     *      timelock-authority admin can call) and exercises the full NFT→Router→RealHooks
     *      path so production behaviour is not masked by silent no-ops.
     *
     * Production staking hook identification:
     *   - StakingManager.sol IS the production staking hook (implements INFTTransferHook).
     *   - TrancheStakingManager does NOT implement INFTTransferHook.
     *   - Factory wires it: ProjectFactory.stakingManager → router.setHooks([sceneTracker, stakingManager]).
     *
     * StakingManager.beforeNFTTransfer on transfer of a non-staked token:
     *   - from != address(0), so mint early-return doesn't fire.
     *   - stakingPositions[nftId].active == false → returns true at line 596 immediately.
     *   - Never reaches ITransferHookRouter(msg.sender).nftContract() at line 602.
     *   - Therefore: no initialize() needed; no onlyInitialized guard on this path.
     *
     * StakingManager.afterNFTTransfer: pure no-op {}.
     *
     * _beforeTokenTransfers (ProjectNFTTemplate) only calls beforeNFTTransfer when
     *   from != address(0) — so mints do NOT call StakingManager.beforeNFTTransfer.
     * _afterTokenTransfers always calls afterNFTTransfer (mint + transfer).
     */
    function test_realHooks_mintAndTransferDoNotRevert() public {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");

        // ── Create project (factory wires mock adapters as router hooks) ──────
        vm.prank(user);
        (, address nftAddr,) = factory.createProject("Real Hooks Farm", 1, oracle, 10);

        ProjectNFTTemplate nft = ProjectNFTTemplate(nftAddr);
        TransferHookRouter router = TransferHookRouter(address(nft.transferHook()));

        // ── Deploy real SceneTracker bound to this NFT ────────────────────────
        // admin is the owner; nftAddr anchors the authorization check.
        SceneTracker realScene = new SceneTracker(admin, nftAddr);

        // ── Deploy real StakingManager implementation ─────────────────────────
        // No initialize() needed for the hook path used in this test:
        //   - beforeNFTTransfer exits at line 596 (position.active == false) for non-staked tokens.
        //   - afterNFTTransfer is a pure no-op.
        StakingManager realStaking = new StakingManager();

        // ── Admin replaces mock hooks with real contracts ─────────────────────
        // admin == factory.owner() == router.owner(), so this is the correct authority.
        address[] memory realHooks = new address[](2);
        realHooks[0] = address(realScene); // SceneTracker first (canonical order)
        realHooks[1] = address(realStaking); // StakingManager second
        vm.prank(admin);
        router.setHooks(realHooks);

        // ── Authorize a minter (admin is the NFT owner) ───────────────────────
        address authorizedMinter = makeAddr("realMinter");
        vm.prank(admin);
        nft.setAuthorizedMinter(authorizedMinter, true);

        // ── MINT: scene 5 to userA — must NOT revert ──────────────────────────
        // _beforeTokenTransfers skips hook on mint (from == address(0)).
        // _afterTokenTransfers calls router.afterNFTTransfer → SceneTracker credits scene 5 to userA.
        vm.prank(authorizedMinter);
        uint256 tokenId = nft.mint(userA, 5);

        // Verify mint assertions
        assertEq(nft.ownerOf(tokenId), userA, "minted token must belong to userA");
        assertEq(nft.getSceneNumber(tokenId), 5, "scene number must be 5");
        assertEq(realScene.userSceneCounts(userA, 5), 1, "SceneTracker must credit userA with scene 5 after mint");
        assertEq(realScene.userSceneCounts(userB, 5), 0, "userB must have 0 scene 5 credits before transfer");

        // ── TRANSFER: userA → userB — must NOT revert ─────────────────────────
        // _beforeTokenTransfers fires beforeNFTTransfer:
        //   router → SceneTracker.beforeNFTTransfer: authorized (router == nft.transferHook()), returns true.
        //   router → StakingManager.beforeNFTTransfer: position.active == false → returns true.
        // ERC721A performs the transfer.
        // _afterTokenTransfers fires afterNFTTransfer:
        //   router → SceneTracker.afterNFTTransfer: authorized, removes scene 5 from userA, adds to userB.
        //   router → StakingManager.afterNFTTransfer: no-op.
        vm.prank(userA);
        nft.transferFrom(userA, userB, tokenId);

        // Verify transfer assertions
        assertEq(nft.ownerOf(tokenId), userB, "token must belong to userB after transfer");
        assertEq(realScene.userSceneCounts(userA, 5), 0, "SceneTracker must decrement userA scene 5 count");
        assertEq(realScene.userSceneCounts(userB, 5), 1, "SceneTracker must credit userB with scene 5 after transfer");
    }

    // ── Governance lifecycle: propose → queue → execute via ProtocolTimelock ───

    /**
     * @notice Full governance lifecycle: propose, vote, queue, execute.
     *         Proves ProtocolTimelock is the exclusive execution path.
     */
    function test_governance_proposeQueueExecute_viaTimelock() public {
        // Grant governance PROPOSER_ROLE on timelock
        _grantProposerRoleToGovernance();

        // Propose
        vm.prank(superHolder1);
        uint256 proposalId =
            governance.propose("Phase 7 proposal", address(target), abi.encodeWithSignature("doSomething()"));

        // Vote (supermajority: superHolder1 + superHolder2)
        vm.prank(superHolder1);
        governance.vote(proposalId, true);
        vm.prank(superHolder2);
        governance.vote(proposalId, true);

        // Advance past voting period
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);

        // Queue to ProtocolTimelock
        governance.queueToProtocolTimelock(proposalId);
        bytes32 opId = governance.timelockOperationId(proposalId);
        assertTrue(timelock.isOperationPending(opId), "operation must be pending in timelock");

        // Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execute
        governance.executeQueued(proposalId);
        assertTrue(target.wasCalled(), "target.doSomething() must have been called");

        IGovernance.Proposal memory p = governance.getProposal(proposalId);
        assertTrue(p.executed, "proposal must be marked executed");

        // Legacy execute() path is permanently disabled
        vm.expectRevert(SuperHolderGovernance.InternalQueueDisabled.selector);
        governance.execute(proposalId);
    }

    // ── Deployed addresses are non-zero ───────────────────────────────────────

    function test_deployedAddresses_nonZero() public {
        vm.prank(user);
        (uint256 pid, address nftAddr, address poolAddr) = factory.createProject("Goat Farm Zeta", 1, oracle, 10);

        assertTrue(pid != 0, "projectId must be non-zero");
        assertTrue(nftAddr != address(0), "nftAddress must be non-zero");
        assertTrue(poolAddr != address(0), "yieldPoolAddress must be non-zero");

        // Factory tracks them
        (address trackedNFT, address trackedPool) = factory.getDeployedContracts(pid);
        assertEq(trackedNFT, nftAddr);
        assertEq(trackedPool, poolAddr);

        // Registry has them linked
        IProjectRegistry.Project memory proj = registry.getProject(pid);
        assertEq(proj.nftAddress, nftAddr);
        assertEq(proj.yieldPoolAddress, poolAddr);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _grantProposerRoleToGovernance() internal {
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(IAccessControl.grantRole.selector, PROPOSER_ROLE, address(governance));

        bytes32 salt = keccak256("grant-gov-proposer-p7");
        // Cache getMinDelay() BEFORE vm.prank: inline external calls in argument position
        // consume the prank before scheduleBatch is reached (Solidity evaluates args L→R).
        uint256 minDelay = timelock.getMinDelay();
        vm.prank(founderMultisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, minDelay);
        vm.warp(block.timestamp + minDelay + 1);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governance)));
    }

    function _registerSuperHolder(address holder, uint256 pid, uint256 power) internal {
        weighting.setVotingPower(holder, pid, power);
        sceneMock.setFullCollection(holder, true);
        stakingMgr.setStake(holder, pid, 100 ether);
        stakingMgr.setStartAt(holder, pid, 1); // start at epoch 1, now >= 24 weeks
        vm.prank(address(stakingMgr));
        governance.notifyPotentialVotingPowerChange(holder);
    }

    /// @dev Simple uint-to-decimal-string helper for test assertions.
    function _uintToStr(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 temp = n;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (n != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(n % 10)));
            n /= 10;
        }
        return string(buffer);
    }
}
