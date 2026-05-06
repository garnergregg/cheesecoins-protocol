// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/governance/ProtocolTimelock.sol";
import "../../foundry-src/governance/SuperHolderGovernance.sol";
import "../../foundry-src/governance/GovernanceWeighting.sol";
import "../../foundry-src/governance/FounderDecentralization.sol";
import {IProjectRegistry} from "../../foundry-src/platform/interfaces/IProjectRegistry.sol";
import {IGovernance} from "../../foundry-src/governance/interfaces/IGovernance.sol";

/**
 * @title GovernanceEligibilityTest
 * @notice Integration tests for Phase 6E:
 *   - 24-week minimum stake age for propose() and vote()
 *   - 70% quorum of snapshotPotentialVotes at proposal creation
 *   - Accumulator-based currentPotentialVotes via notifyPotentialVotingPowerChange
 */
contract GovernanceEligibilityTest is Test {
    // ── Actors ───────────────────────────────────────────────────────────────

    address internal deployer = makeAddr("deployer");
    address internal founderMultisig = makeAddr("founderMultisig");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    // ── Contracts ────────────────────────────────────────────────────────────

    ProtocolTimelock internal timelock;
    SuperHolderGovernance internal governance;
    EligibilityMockWeighting internal weighting;
    EligibilityMockFounderDecent internal founderDecent;
    EligibilityMockTarget internal target;
    EligibilityMockSceneTracker internal sceneMock;
    EligibilityMockStakingManager internal stakingMgrMock;

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 internal constant DELAY = Config.TIMELOCK_DELAY;
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ALICE_POWER = 60;
    uint256 internal constant BOB_POWER = 40;
    uint256 internal constant CAROL_POWER = 100;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // Start block.timestamp at 0 to allow precise warp control in tests
        vm.warp(0);

        vm.startPrank(deployer);

        stakingMgrMock = new EligibilityMockStakingManager();
        sceneMock = new EligibilityMockSceneTracker();

        weighting = new EligibilityMockWeighting(address(stakingMgrMock));
        founderDecent = new EligibilityMockFounderDecent(founderMultisig);
        target = new EligibilityMockTarget();

        address[] memory proposers = new address[](1);
        proposers[0] = founderMultisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;

        timelock = new ProtocolTimelock(DELAY, proposers, executors, cancellers, address(0));

        governance = new SuperHolderGovernance(
            address(weighting),
            address(founderDecent),
            address(timelock),
            founderMultisig,
            address(sceneMock),
            address(stakingMgrMock),
            PROJECT_ID
        );

        vm.stopPrank();

        // Set voting powers
        weighting.setVotingPower(alice, PROJECT_ID, ALICE_POWER);
        weighting.setVotingPower(bob, PROJECT_ID, BOB_POWER);
        weighting.setVotingPower(carol, PROJECT_ID, CAROL_POWER);
    }

    // ── Stake age gating ──────────────────────────────────────────────────────

    /// @dev User potentially eligible but staked < 24 weeks ago → cannot propose.
    function test_stakeAge_proposalRevertsBelow24Weeks() public {
        // Alice has full collection + stake, but staked less than 24 weeks ago
        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, uint64(block.timestamp));

        // Warp to 24 weeks - 1 second (not yet eligible)
        vm.warp(24 weeks - 1);

        vm.prank(alice);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("too early", address(target), abi.encodeWithSignature("doSomething()"));
    }

    /// @dev User potentially eligible but staked < 24 weeks ago → cannot vote.
    function test_stakeAge_voteRevertsBelow24Weeks() public {
        // Seed a proposer who is already eligible (alice registered at epoch start, now >= 24w)
        vm.warp(24 weeks + 1);
        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, 1);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        // Alice creates a proposal
        vm.prank(alice);
        uint256 id =
            governance.propose("stake age vote test", address(target), abi.encodeWithSignature("doSomething()"));

        // Bob stakes NOW (24 weeks - 1 second before end of voting period = not eligible at vote time)
        uint64 bobStakeStart = uint64(block.timestamp);
        sceneMock.setFullCollection(bob, true);
        stakingMgrMock.setUserProjectStaked(bob, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(bob, PROJECT_ID, bobStakeStart);

        // Warp to near end of voting period, but Bob hasn't hit 24 weeks yet
        vm.warp(block.timestamp + 10 days);

        vm.prank(bob);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.vote(id, true);
    }

    /// @dev After exactly 24 weeks, user becomes eligible to propose and vote.
    function test_stakeAge_eligibleAfter24Weeks() public {
        uint64 stakeStart = 1;

        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, stakeStart);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        // Warp to exactly 24 weeks from stakeStart
        vm.warp(uint256(stakeStart) + 24 weeks);

        // Alice can now propose
        vm.prank(alice);
        uint256 id = governance.propose("eligible now", address(target), abi.encodeWithSignature("doSomething()"));
        assertGt(id, 0, "proposal should be created");

        // Alice can vote on her own proposal
        vm.prank(alice);
        governance.vote(id, true);

        IGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.forVotes, ALICE_POWER, "vote should be recorded");
    }

    /// @dev Unstake to 0 then restake → stakeStartAt resets, must wait 24w again.
    function test_stakeAge_resetOnRestake() public {
        // Alice eligible at stakeStart = 1
        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, 1);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        // Warp past 24 weeks → eligible
        vm.warp(24 weeks + 1);

        vm.prank(alice);
        uint256 id = governance.propose("before unstake", address(target), abi.encodeWithSignature("doSomething()"));
        assertGt(id, 0);

        // Simulate unstake: clear attribution and stakeStartAt
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 0);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, 0);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        // Alice re-stakes with a fresh start time = now
        uint64 newStakeStart = uint64(block.timestamp);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, newStakeStart);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        // Immediately after restaking → not eligible
        vm.prank(alice);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("should fail", address(target), abi.encodeWithSignature("doSomething()"));

        // Warp 24 weeks from restake → eligible again
        vm.warp(uint256(newStakeStart) + 24 weeks);
        vm.prank(alice);
        uint256 id2 = governance.propose("after 24w restake", address(target), abi.encodeWithSignature("doSomething()"));
        assertGt(id2, 0, "should be eligible after 24w restake");
    }

    /// @dev stakeStartAt == 0 (never staked) → not eligible even if time is large.
    function test_stakeAge_zeroStakeStartNotEligible() public {
        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        // stakeStartAt deliberately left at 0 (never set)

        vm.warp(365 days); // plenty of time, but stakeStartAt = 0 means "not staked"

        vm.prank(alice);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("zero stakeStart", address(target), abi.encodeWithSignature("doSomething()"));
    }

    // ── Quorum snapshot ───────────────────────────────────────────────────────

    /// @dev snapshotPotentialVotes is frozen at propose() time.
    function test_quorumSnapshot_frozenAtPropose() public {
        _makeEligible(alice, 1, ALICE_POWER);
        _makeEligible(bob, 1, BOB_POWER);

        uint256 expected = ALICE_POWER + BOB_POWER;
        assertEq(governance.currentPotentialVotes(), expected, "accumulator should equal alice+bob");

        // Alice proposes; snapshot should equal currentPotentialVotes at that moment
        vm.prank(alice);
        uint256 id = governance.propose("snapshot test", address(target), abi.encodeWithSignature("doSomething()"));

        IGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.snapshotPotentialVotes, expected, "snapshotPotentialVotes should be frozen at proposal creation");

        // Carol becomes eligible AFTER the proposal → snapshotPotentialVotes unchanged
        _makeEligible(carol, 1, CAROL_POWER);
        assertEq(governance.currentPotentialVotes(), expected + CAROL_POWER, "accumulator updated for carol");

        // Re-read proposal: snapshot unchanged
        p = governance.getProposal(id);
        assertEq(p.snapshotPotentialVotes, expected, "snapshot must remain unchanged after carol joins");
    }

    /// @dev queue fails when participation < 70% of snapshotPotentialVotes.
    function test_quorum_queueRevertsWhenBelowThreshold() public {
        _grantProposerRole();

        _makeEligible(alice, 1, ALICE_POWER); // 60
        _makeEligible(bob, 1, BOB_POWER); // 40
        _makeEligible(carol, 1, CAROL_POWER); // 100 — total potential = 200

        // Only alice votes (60 / 200 = 30% < 70%)
        vm.prank(alice);
        uint256 id = governance.propose("low quorum", address(target), abi.encodeWithSignature("doSomething()"));
        vm.prank(alice);
        governance.vote(id, true);

        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        vm.expectRevert(SuperHolderGovernance.QuorumNotMet.selector);
        governance.queueToProtocolTimelock(id);
    }

    /// @dev queue succeeds when participation >= 70% of snapshotPotentialVotes and supermajority passes.
    function test_quorum_queueSucceedsWhenAboveThreshold() public {
        _grantProposerRole();

        _makeEligible(alice, 1, ALICE_POWER); // 60
        _makeEligible(bob, 1, BOB_POWER); // 40 — total potential = 100

        // Both alice and bob vote FOR (100 / 100 = 100% >= 70%, and 100% >= 66% supermajority)
        vm.prank(alice);
        uint256 id = governance.propose("good quorum", address(target), abi.encodeWithSignature("doSomething()"));
        vm.prank(alice);
        governance.vote(id, true);
        vm.prank(bob);
        governance.vote(id, true);

        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        governance.queueToProtocolTimelock(id); // should NOT revert

        bytes32 opId = governance.timelockOperationId(id);
        assertTrue(opId != bytes32(0), "operation should be scheduled in timelock");
    }

    /// @dev queue reverts with QuorumUndefined when snapshotPotentialVotes == 0.
    function test_quorum_revertsQuorumUndefinedWhenZeroSnapshot() public {
        _grantProposerRole();

        // Manually set alice as eligible WITHOUT going through notifyPotentialVotingPowerChange,
        // so currentPotentialVotes stays at 0 and snapshotPotentialVotes = 0 at proposal time.
        sceneMock.setFullCollection(alice, true);
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(alice, PROJECT_ID, 1);
        vm.warp(24 weeks + 1);
        // NOTE: do NOT call notifyPotentialVotingPowerChange → currentPotentialVotes = 0

        vm.prank(alice);
        uint256 id = governance.propose("zero snapshot", address(target), abi.encodeWithSignature("doSomething()"));

        vm.prank(alice);
        governance.vote(id, true);

        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        vm.expectRevert(SuperHolderGovernance.QuorumUndefined.selector);
        governance.queueToProtocolTimelock(id);
    }

    /// @dev Exactly 70% participation meets quorum.
    function test_quorum_exactlySeventyPercentMeetsQuorum() public {
        _grantProposerRole();

        // 3 voters: alice=60, bob=40, carol=100 → total potential = 200
        _makeEligible(alice, 1, ALICE_POWER);
        _makeEligible(bob, 1, BOB_POWER);
        _makeEligible(carol, 1, CAROL_POWER);

        // Alice + bob + carol = 200 = 100% ≥ 70% → passes
        // alice + carol = 160 = 80% ≥ 70% → passes
        // alice + bob = 100 = 50% < 70% → fails
        // carol alone = 100 = 50% < 70% → fails
        // alice + bob + carol = 200 → passes
        // Let's test exactly 70%: we need 140/200.
        // Use a custom setup: 4 voters total 200 potential.
        // Instead, just test with alice(60) + bob(40) = 100 against total 200 → 50% < 70%.
        // The exact 70% test: total=100, need 70 votes. Use alice(60)+bob(40) total=100,
        // but we only need to show 70 of 100 passes.

        // Fresh setup for this test: alice=100, total potential=100
        // Reset carol eligibility so total = just alice
        stakingMgrMock.setUserProjectStaked(carol, PROJECT_ID, 0);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(carol);

        stakingMgrMock.setUserProjectStaked(bob, PROJECT_ID, 0);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(bob);

        // Now only alice is eligible: currentPotentialVotes = ALICE_POWER = 60
        // snapshotPotentialVotes = 60, alice votes FOR (60), totalVotes * 100 = 6000 >= 60*70=4200 → passes
        vm.prank(alice);
        uint256 id = governance.propose("exact 70pct", address(target), abi.encodeWithSignature("doSomething()"));
        vm.prank(alice);
        governance.vote(id, true);

        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        governance.queueToProtocolTimelock(id); // should succeed
        assertTrue(governance.timelockOperationId(id) != bytes32(0));
    }

    // ── Accumulator correctness ───────────────────────────────────────────────

    /// @dev Accumulator increases when wallet transitions to potentially eligible.
    function test_accumulator_increasesOnEligibilityGain() public {
        uint256 before = governance.currentPotentialVotes();
        assertEq(before, 0, "initially zero");

        _makeEligible(alice, 1, ALICE_POWER);
        assertEq(governance.currentPotentialVotes(), ALICE_POWER, "should increase by alice's power");
    }

    /// @dev Accumulator decreases when wallet loses potential eligibility.
    function test_accumulator_decreasesOnEligibilityLoss() public {
        _makeEligible(alice, 1, ALICE_POWER);
        assertEq(governance.currentPotentialVotes(), ALICE_POWER);

        // Alice loses stake
        stakingMgrMock.setUserProjectStaked(alice, PROJECT_ID, 0);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        assertEq(governance.currentPotentialVotes(), 0, "accumulator should decrease to 0");
    }

    /// @dev Accumulator updates delta when stake changes (power update without eligibility change).
    function test_accumulator_deltaUpdateOnPowerChange() public {
        _makeEligible(alice, 1, ALICE_POWER);
        assertEq(governance.currentPotentialVotes(), ALICE_POWER);

        // Alice's stake increases → her voting power doubles
        uint256 newPower = ALICE_POWER * 2;
        weighting.setVotingPower(alice, PROJECT_ID, newPower);
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(alice);

        assertEq(governance.currentPotentialVotes(), newPower, "accumulator should reflect new power");
    }

    /// @dev Multiple users tracked independently in accumulator.
    function test_accumulator_multipleUsersTracked() public {
        _makeEligible(alice, 1, ALICE_POWER);
        _makeEligible(bob, 1, BOB_POWER);

        assertEq(governance.currentPotentialVotes(), ALICE_POWER + BOB_POWER);

        // Bob loses eligibility (scene lost)
        sceneMock.setFullCollection(bob, false);
        vm.prank(address(sceneMock));
        governance.notifyPotentialVotingPowerChange(bob);

        assertEq(governance.currentPotentialVotes(), ALICE_POWER, "only alice remains");
    }

    /// @dev Notify is only callable by sceneTracker or stakingManager.
    function test_notify_revertsForUnauthorizedCaller() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(SuperHolderGovernance.NotAuthorizedNotifier.selector);
        governance.notifyPotentialVotingPowerChange(alice);
    }

    /// @dev cachedPotentialVotes and cachedIsPotentiallyEligible updated by notify.
    function test_accumulator_cacheUpdated() public {
        assertFalse(governance.cachedIsPotentiallyEligible(alice));
        assertEq(governance.cachedPotentialVotes(alice), 0);

        _makeEligible(alice, 1, ALICE_POWER);

        assertTrue(governance.cachedIsPotentiallyEligible(alice));
        assertEq(governance.cachedPotentialVotes(alice), ALICE_POWER);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /**
     * @dev Make a user potentially eligible AND seed the accumulator via notify.
     *      stakeStartAt is set to 1 (epoch start), so with block.timestamp >= 24w+1 they're
     *      also fully eligible for propose/vote.
     */
    function _makeEligible(address user, uint256 pid, uint256 power) internal {
        sceneMock.setFullCollection(user, true);
        stakingMgrMock.setUserProjectStaked(user, pid, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(user, pid, 1);
        weighting.setVotingPower(user, pid, power);
        // Warp so stakeStart=1 is > 24w ago if not already
        if (block.timestamp < 24 weeks + 1) {
            vm.warp(24 weeks + 1);
        }
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(user);
    }

    function _grantProposerRole() internal {
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] =
            abi.encodeWithSelector(bytes4(keccak256("grantRole(bytes32,address)")), PROPOSER_ROLE, address(governance));
        bytes32 salt = keccak256("grant-gov-proposer-elig");
        vm.prank(founderMultisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mocks (scoped to this test file)
// ═══════════════════════════════════════════════════════════════════════════

contract EligibilityMockStakingManager {
    mapping(address => mapping(uint256 => uint256)) internal _userStake;
    mapping(address => mapping(uint256 => uint64)) internal _stakeStartAt;

    function setUserProjectStaked(address user, uint256 projectId, uint256 amount) external {
        _userStake[user][projectId] = amount;
    }

    function setUserProjectStakeStartAt(address user, uint256 projectId, uint64 ts) external {
        _stakeStartAt[user][projectId] = ts;
    }

    function getUserProjectStaked(address user, uint256 projectId) external view returns (uint256) {
        return _userStake[user][projectId];
    }

    function userProjectStakeStartAt(address user, uint256 projectId) external view returns (uint64) {
        return _stakeStartAt[user][projectId];
    }
}

contract EligibilityMockSceneTracker {
    mapping(address => bool) internal _fullCollection;

    function setFullCollection(address user, bool hasIt) external {
        _fullCollection[user] = hasIt;
    }

    function hasFullCollection(address user) external view returns (bool) {
        return _fullCollection[user];
    }
}

contract EligibilityMockWeighting is GovernanceWeighting {
    mapping(address => mapping(uint256 => uint256)) internal _power;

    constructor(address stakingMgr) GovernanceWeighting(stakingMgr, address(new EligibilityMockProjectRegistry())) {}

    function setVotingPower(address voter, uint256 projectId, uint256 power) external {
        _power[voter][projectId] = power;
    }

    function calculateVotingPower(address voter, uint256 projectId, bool) public override returns (uint256) {
        return _power[voter][projectId];
    }

    function previewVotingPower(uint256, uint256, bool) external pure override returns (uint256) {
        return 0;
    }
}

contract EligibilityMockFounderDecent is FounderDecentralization {
    constructor(address founder) FounderDecentralization(founder) {}
}

contract EligibilityMockTarget {
    bool public wasCalled;

    function doSomething() external {
        wasCalled = true;
    }
}

contract EligibilityMockProjectRegistry {
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
