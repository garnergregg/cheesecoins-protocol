// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/governance/ProtocolTimelock.sol";
import "../../foundry-src/governance/SuperHolderGovernance.sol";
import "../../foundry-src/governance/GovernanceWeighting.sol";
import "../../foundry-src/governance/FounderDecentralization.sol";
import {IProjectRegistry} from "../../foundry-src/platform/interfaces/IProjectRegistry.sol";
import {IGovernance} from "../../foundry-src/governance/interfaces/IGovernance.sol";

/**
 * @title GovernanceTimelockRoutingTest
 * @notice Integration tests for Phase 6B: SuperHolderGovernance routing execution
 *         through ProtocolTimelock (not the deprecated internal timelockQueue).
 *
 * Scenario covered:
 *   1. propose()                         → proposal created
 *   2. dynamic eligibility + vote()      → supermajority reached
 *   3. queueToProtocolTimelock()         → operation scheduled in ProtocolTimelock
 *   4. executeQueued() before delay      → reverts (TimelockController not ready)
 *   5. vm.warp(delay)                    → delay elapses
 *   6. executeQueued()                   → target called, proposal marked executed
 *   7. execute() (legacy)                → always reverts InternalQueueDisabled
 *   8. Guardian cancellation             → guardian cancels via ProtocolTimelock directly
 */
contract GovernanceTimelockRoutingTest is Test {
    // ── Actors ───────────────────────────────────────────────────────────────

    address internal deployer = makeAddr("deployer");
    address internal founderMultisig = makeAddr("founderMultisig");
    address internal guardian = makeAddr("guardian");
    address internal superHolder1 = makeAddr("superHolder1");
    address internal superHolder2 = makeAddr("superHolder2");
    address internal anyone = makeAddr("anyone");

    // ── Contracts ────────────────────────────────────────────────────────────

    ProtocolTimelock internal timelock;
    SuperHolderGovernance internal governance;
    MockGovernanceWeighting internal weighting;
    MockFounderDecentralization internal founderDecent;
    MockTarget internal target;
    MockSceneTracker internal sceneMock;
    MockStakingManager internal stakingMgrMock;

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 internal constant DELAY = Config.TIMELOCK_DELAY; // 2 days

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // Start at a block.timestamp that is >= 24 weeks so that stakeStartAt = 1 passes eligibility.
        vm.warp(24 weeks + 1);

        vm.startPrank(deployer);

        // Deploy shared mocks (single instances used by both weighting and governance)
        stakingMgrMock = new MockStakingManager();
        sceneMock = new MockSceneTracker();

        // Deploy mock dependencies
        weighting = new MockGovernanceWeighting(address(stakingMgrMock));
        founderDecent = new MockFounderDecentralization(founderMultisig);
        target = new MockTarget();

        // Deploy ProtocolTimelock: founderMultisig is initial proposer, guardian is canceller
        address[] memory proposers = new address[](1);
        proposers[0] = founderMultisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;

        timelock = new ProtocolTimelock(DELAY, proposers, executors, cancellers, address(0));

        // Deploy SuperHolderGovernance with ProtocolTimelock reference and dynamic deps
        governance = new SuperHolderGovernance(
            address(weighting),
            address(founderDecent),
            address(timelock),
            founderMultisig,
            address(sceneMock),
            address(stakingMgrMock),
            1 // projectId
        );

        vm.stopPrank();

        // Wire super holders (mock: both are eligible)
        weighting.setVotingPower(superHolder1, 1, 60); // 60 votes
        weighting.setVotingPower(superHolder2, 1, 40); // 40 votes

        // Register them as super holders in governance
        _registerSuperHolder(superHolder1, 1);
        _registerSuperHolder(superHolder2, 1);
    }

    // ── execute() is permanently disabled ────────────────────────────────────

    function test_legacyExecute_alwaysReverts() public {
        vm.expectRevert(SuperHolderGovernance.InternalQueueDisabled.selector);
        governance.execute(1);
    }

    // ── propose ───────────────────────────────────────────────────────────────

    function test_propose_succeeds() public {
        uint256 id = _createProposal();
        IGovernance.Proposal memory p = governance.getProposal(id);
        assertEq(p.id, id);
        assertEq(p.target, address(target));
        assertFalse(p.executed);
        assertFalse(p.canceled);
    }

    // ── queueToProtocolTimelock ───────────────────────────────────────────────

    function test_queueToProtocolTimelock_revertsBeforeVotingEnds() public {
        uint256 id = _createAndVote();
        // voting period not yet over
        vm.expectRevert(SuperHolderGovernance.VotingPeriodNotEnded.selector);
        governance.queueToProtocolTimelock(id);
    }

    function test_queueToProtocolTimelock_revertsIfNoProposerRole() public {
        // governance doesn't hold PROPOSER_ROLE yet (Stage 0)
        uint256 id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        // The call will revert inside TimelockController with AccessControl error
        vm.expectRevert();
        governance.queueToProtocolTimelock(id);
    }

    function test_queueToProtocolTimelock_succeedsAfterProposerRoleGranted() public {
        _grantProposerRoleToGovernance();

        uint256 id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);

        governance.queueToProtocolTimelock(id);

        bytes32 opId = governance.timelockOperationId(id);
        assertTrue(opId != bytes32(0));
        assertTrue(timelock.isOperationPending(opId));
    }

    function test_queueToProtocolTimelock_revertsIfAlreadyQueued() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        governance.queueToProtocolTimelock(id);

        vm.expectRevert(SuperHolderGovernance.AlreadyQueued.selector);
        governance.queueToProtocolTimelock(id);
    }

    function test_queueToProtocolTimelock_revertsIfSupermajorityNotMet() public {
        _grantProposerRoleToGovernance();

        // Create proposal and vote AGAINST
        uint256 id = _createProposal();
        vm.prank(superHolder1);
        governance.vote(id, false); // against
        vm.prank(superHolder2);
        governance.vote(id, false); // against

        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        vm.expectRevert(SuperHolderGovernance.ProposalNotPassed.selector);
        governance.queueToProtocolTimelock(id);
    }

    // ── executeQueued ─────────────────────────────────────────────────────────

    function test_executeQueued_revertsIfNotQueued() public {
        uint256 id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        vm.expectRevert(SuperHolderGovernance.NotQueued.selector);
        governance.executeQueued(id);
    }

    function test_executeQueued_revertsBeforeDelay() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        // Immediately after queuing — delay not elapsed
        vm.expectRevert(); // TimelockController: operation is not ready
        governance.executeQueued(id);
    }

    function test_executeQueued_succeedsAfterDelay() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        // Warp past timelock delay
        vm.warp(block.timestamp + DELAY + 1);

        governance.executeQueued(id);

        // Target function was called
        assertTrue(target.wasCalled());

        // Proposal marked executed
        IGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.executed);
    }

    function test_executeQueued_revertsIfAlreadyExecuted() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();
        vm.warp(block.timestamp + DELAY + 1);
        governance.executeQueued(id);

        vm.expectRevert(SuperHolderGovernance.ProposalAlreadyExecuted.selector);
        governance.executeQueued(id);
    }

    // ── Guardian cancellation ─────────────────────────────────────────────────

    function test_guardian_canCancelQueuedOperation() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        bytes32 opId = governance.timelockOperationId(id);
        assertTrue(timelock.isOperationPending(opId));

        // Guardian cancels directly on the timelock
        vm.prank(guardian);
        timelock.cancel(opId);

        assertFalse(timelock.isOperationPending(opId));
        // executeQueued now reverts because op was cancelled at timelock level
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(); // TimelockController: operation is not ready
        governance.executeQueued(id);
    }

    // ── cancelProposal + timelock op separation ───────────────────────────────

    function test_cancelProposal_revertsAlreadyQueued() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        bytes32 opId = governance.timelockOperationId(id);
        assertTrue(timelock.isOperationPending(opId), "op should be pending");

        // cancelProposal is blocked once the proposal is queued in the timelock —
        // caller must use cancelTimelockOperation() which atomically cancels both.
        vm.prank(founderMultisig);
        vm.expectRevert(SuperHolderGovernance.AlreadyQueued.selector);
        governance.cancelProposal(id);

        // Timelock op is unchanged — still pending
        assertTrue(timelock.isOperationPending(opId), "timelock op still pending after blocked cancel");
    }

    function test_guardian_cancelTimelockOp_atomicCancel() public {
        _grantProposerRoleToGovernance();
        _grantCancellerRoleToGovernance();
        uint256 id = _createVoteAndQueue();
        bytes32 opId = governance.timelockOperationId(id);

        // Guardian uses cancelTimelockOperation — atomically cancels both the governance
        // proposal and the timelock operation in a single call.
        vm.prank(guardian);
        governance.cancelTimelockOperation(id);

        IGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.canceled, "governance proposal canceled");
        assertFalse(timelock.isOperationPending(opId), "timelock op cancelled");
    }

    // ── cancelTimelockOperation (one-step guardian cancel) ────────────────────

    function test_cancelTimelockOperation_cancelsBothAtOnce() public {
        _grantProposerRoleToGovernance();
        _grantCancellerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        bytes32 opId = governance.timelockOperationId(id);
        assertTrue(timelock.isOperationPending(opId), "op should be pending before cancel");

        // Guardian calls the one-step canceller — marks proposal canceled AND cancels timelock op
        vm.expectEmit(true, true, false, false, address(governance));
        emit SuperHolderGovernance.TimelockOperationCancelled(id, opId);
        vm.prank(guardian);
        governance.cancelTimelockOperation(id);

        // Governance proposal is now canceled
        IGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.canceled, "proposal should be canceled");

        // Timelock op is also gone
        assertFalse(timelock.isOperationPending(opId), "timelock op should be cancelled");

        // executeQueued reverts
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(SuperHolderGovernance.ProposalAlreadyCanceled.selector);
        governance.executeQueued(id);
    }

    function test_cancelTimelockOperation_idempotentOnDoubleCall() public {
        _grantProposerRoleToGovernance();
        _grantCancellerRoleToGovernance();
        uint256 id = _createVoteAndQueue();
        bytes32 opId = governance.timelockOperationId(id);

        // First call cancels both the governance proposal and the timelock op.
        vm.prank(guardian);
        governance.cancelTimelockOperation(id);
        assertFalse(timelock.isOperationPending(opId), "timelock op cancelled after first call");

        // Second call is idempotent — proposal already canceled, timelock op already gone.
        vm.prank(guardian);
        governance.cancelTimelockOperation(id);

        IGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.canceled, "proposal still canceled");
        assertFalse(timelock.isOperationPending(opId), "timelock op still not pending");
    }

    function test_cancelTimelockOperation_noTimelockOpScheduled() public {
        // Proposal created and voted but not yet queued to timelock
        uint256 id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        // timelockOperationId is still bytes32(0)
        assertEq(governance.timelockOperationId(id), bytes32(0));

        // cancelTimelockOperation still works — cancels governance side, skips timelock cancel
        vm.prank(guardian);
        governance.cancelTimelockOperation(id);

        IGovernance.Proposal memory p = governance.getProposal(id);
        assertTrue(p.canceled, "proposal canceled");
    }

    function test_cancelTimelockOperation_revertsForNonCanceller() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();

        // stranger has no CANCELLER_ROLE on the timelock
        vm.prank(anyone);
        vm.expectRevert(SuperHolderGovernance.NotCanceller.selector);
        governance.cancelTimelockOperation(id);
    }

    function test_cancelTimelockOperation_revertsForAlreadyExecuted() public {
        _grantProposerRoleToGovernance();
        uint256 id = _createVoteAndQueue();
        vm.warp(block.timestamp + DELAY + 1);
        governance.executeQueued(id);

        vm.prank(guardian);
        vm.expectRevert(SuperHolderGovernance.ProposalAlreadyExecuted.selector);
        governance.cancelTimelockOperation(id);
    }

    // ── Deterministic salt uniqueness ─────────────────────────────────────────

    function test_deterministicSalt_uniquePerProposal() public {
        _grantProposerRoleToGovernance();

        uint256 id1 = _createVoteAndQueue();
        // Create a second proposal with a different calldata
        uint256 id2 = _createProposalWithCalldata(abi.encodeWithSignature("secondCall()"));
        vm.prank(superHolder1);
        governance.vote(id2, true);
        vm.prank(superHolder2);
        governance.vote(id2, true);
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        governance.queueToProtocolTimelock(id2);

        bytes32 opId1 = governance.timelockOperationId(id1);
        bytes32 opId2 = governance.timelockOperationId(id2);
        assertTrue(opId1 != opId2, "operation IDs must be unique per proposal");
    }

    // ── Dynamic eligibility regression tests ─────────────────────────────────

    /// @dev Scene loss immediately revokes eligibility: after losing full collection,
    ///      any subsequent propose/vote reverts with NotSuperHolder.
    function test_sceneLoss_revokesEligibilityImmediately() public {
        address voter = makeAddr("voterA");
        weighting.setVotingPower(voter, 1, 50);
        sceneMock.setFullCollection(voter, true);
        stakingMgrMock.setUserProjectStaked(voter, 1, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(voter, 1, 1);

        // voter can propose and vote while eligible
        vm.prank(voter);
        uint256 id = governance.propose("scene loss test", address(target), abi.encodeWithSignature("doSomething()"));
        vm.prank(voter);
        governance.vote(id, true);

        // Now voter loses full collection (sells/transfers a scene NFT)
        sceneMock.setFullCollection(voter, false);

        // Create a new proposal to try voting on
        vm.prank(superHolder1);
        uint256 id2 = governance.propose("another proposal", address(target), abi.encodeWithSignature("doSomething()"));

        // Voter is no longer eligible — propose and vote both revert
        vm.prank(voter);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.vote(id2, true);

        vm.prank(voter);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("should fail", address(target), abi.encodeWithSignature("doSomething()"));
    }

    /// @dev Clearing a user's stake removes their eligibility immediately.
    function test_stakeTransfer_movesEligibility() public {
        address holderA = makeAddr("holderA");
        address holderB = makeAddr("holderB");

        weighting.setVotingPower(holderA, 1, 50);
        weighting.setVotingPower(holderB, 1, 50);

        // holderA is eligible, holderB is not yet eligible
        sceneMock.setFullCollection(holderA, true);
        stakingMgrMock.setUserProjectStaked(holderA, 1, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(holderA, 1, 1);

        vm.prank(superHolder1);
        uint256 id =
            governance.propose("stake transfer test", address(target), abi.encodeWithSignature("doSomething()"));

        // holderA can vote
        vm.prank(holderA);
        governance.vote(id, true);

        // Simulate NFT-gated stake moving from A to B: A unstakes, B stakes
        stakingMgrMock.setUserProjectStaked(holderA, 1, 0);
        sceneMock.setFullCollection(holderB, true);
        stakingMgrMock.setUserProjectStaked(holderB, 1, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(holderB, 1, 1);

        vm.prank(superHolder1);
        uint256 id2 =
            governance.propose("post-transfer proposal", address(target), abi.encodeWithSignature("doSomething()"));

        // holderA can no longer vote or propose
        vm.prank(holderA);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.vote(id2, true);

        vm.prank(holderA);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("A should fail", address(target), abi.encodeWithSignature("doSomething()"));

        // holderB (now staked + full collection) can vote and propose
        vm.prank(holderB);
        governance.vote(id2, true);

        vm.prank(holderB);
        governance.propose("B should succeed", address(target), abi.encodeWithSignature("doSomething()"));
    }

    /// @dev Selling one scene after casting a vote blocks all subsequent voting/proposing.
    function test_sellingScene_blocksSubsequentVoting() public {
        address voter = makeAddr("voterC");
        weighting.setVotingPower(voter, 1, 50);
        sceneMock.setFullCollection(voter, true);
        stakingMgrMock.setUserProjectStaked(voter, 1, 100 ether);
        stakingMgrMock.setUserProjectStakeStartAt(voter, 1, 1);

        vm.prank(voter);
        uint256 id = governance.propose("sell scene test", address(target), abi.encodeWithSignature("doSomething()"));

        // voter casts one vote successfully
        vm.prank(voter);
        governance.vote(id, true);

        // voter sells one scene NFT — no longer holds full collection
        sceneMock.setFullCollection(voter, false);

        // Next vote on any proposal reverts
        vm.prank(superHolder1);
        uint256 id2 = governance.propose("second proposal", address(target), abi.encodeWithSignature("doSomething()"));

        vm.prank(voter);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.vote(id2, true);

        // Propose also reverts
        vm.prank(voter);
        vm.expectRevert(SuperHolderGovernance.NotSuperHolder.selector);
        governance.propose("should fail", address(target), abi.encodeWithSignature("doSomething()"));
    }

    /// @dev becomeSuperHolder always reverts with SuperHolderClaimDeprecated.
    function test_becomeSuperHolder_alwaysReverts() public {
        uint256[] memory ids = new uint256[](Config.SUPER_HOLDER_REQUIRED_SCENES);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = i + 1;
        }
        vm.expectRevert(SuperHolderGovernance.SuperHolderClaimDeprecated.selector);
        governance.becomeSuperHolder(ids);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _grantCancellerRoleToGovernance() internal {
        // Founder schedules + executes a self-timelocked grantRole for CANCELLER_ROLE.
        // Required so that governance.cancelTimelockOperation() can call timelock.cancel()
        // (msg.sender seen by the timelock is address(governance), which needs CANCELLER_ROLE).
        bytes32 CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(IAccessControl.grantRole.selector, CANCELLER_ROLE, address(governance));

        bytes32 salt = keccak256("grant-gov-canceller");

        vm.prank(founderMultisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertTrue(timelock.hasRole(CANCELLER_ROLE, address(governance)));
    }

    function _grantProposerRoleToGovernance() internal {
        // Founder schedules + executes a self-timelocked grantRole
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(IAccessControl.grantRole.selector, PROPOSER_ROLE, address(governance));

        bytes32 salt = keccak256("grant-gov-proposer");

        vm.prank(founderMultisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governance)));
    }

    function _registerSuperHolder(address holder, uint256 projectId_) internal {
        // Set dynamic eligibility: full collection + staked > 0 in the shared mocks.
        // becomeSuperHolder is deprecated and always reverts; eligibility is checked live.
        sceneMock.setFullCollection(holder, true);
        stakingMgrMock.setUserProjectStaked(holder, projectId_, 100 ether);
        // stakeStartAt = 1 (epoch start); since block.timestamp >= 24 weeks + 1, the age check passes.
        stakingMgrMock.setUserProjectStakeStartAt(holder, projectId_, 1);
        // Seed the accumulator so snapshotPotentialVotes > 0 when proposals are created.
        vm.prank(address(stakingMgrMock));
        governance.notifyPotentialVotingPowerChange(holder);
    }

    function _createProposal() internal returns (uint256 id) {
        return _createProposalWithCalldata(abi.encodeWithSignature("doSomething()"));
    }

    function _createProposalWithCalldata(bytes memory data) internal returns (uint256 id) {
        vm.prank(superHolder1);
        id = governance.propose("test proposal", address(target), data);
    }

    function _createAndVote() internal returns (uint256 id) {
        id = _createProposal();
        vm.prank(superHolder1);
        governance.vote(id, true);
        vm.prank(superHolder2);
        governance.vote(id, true);
    }

    function _createVoteAndQueue() internal returns (uint256 id) {
        id = _createAndVote();
        vm.warp(block.timestamp + Config.GOVERNANCE_VOTING_PERIOD + 1);
        governance.queueToProtocolTimelock(id);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mocks
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Returns configurable voting power; no state mutations (avoids event side-effects)
contract MockGovernanceWeighting is GovernanceWeighting {
    mapping(address => mapping(uint256 => uint256)) internal _power;

    /// @dev Accept an external staking manager so the same instance can be shared with governance.
    constructor(address stakingMgr) GovernanceWeighting(stakingMgr, address(new MockProjectRegistry())) {}

    function setVotingPower(address voter, uint256 projectId, uint256 power) external {
        _power[voter][projectId] = power;
    }

    function calculateVotingPower(address voter, uint256 projectId, bool) public override returns (uint256) {
        return _power[voter][projectId];
    }

    function previewVotingPower(uint256, uint256, bool) external pure override returns (uint256) {
        return 0; // not used in these tests
    }
}

contract MockFounderDecentralization is FounderDecentralization {
    constructor(address founder) FounderDecentralization(founder) {}
}

contract MockTarget {
    bool public wasCalled;

    function doSomething() external {
        wasCalled = true;
    }

    function secondCall() external {}
}

contract MockStakingManager {
    // Minimal stub — GovernanceWeighting constructor only stores the address.
    // getUserProjectStaked is used both by GovernanceWeighting (via calculateVotingPower)
    // and by SuperHolderGovernance._isEligible.
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

contract MockSceneTracker {
    // Minimal stub implementing the hasFullCollection function that
    // SuperHolderGovernance._isEligible calls on the SceneTracker type.
    mapping(address => bool) internal _fullCollection;

    function setFullCollection(address user, bool hasIt) external {
        _fullCollection[user] = hasIt;
    }

    function hasFullCollection(address user) external view returns (bool) {
        return _fullCollection[user];
    }
}

contract MockProjectRegistry {
    // Minimal stub
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
