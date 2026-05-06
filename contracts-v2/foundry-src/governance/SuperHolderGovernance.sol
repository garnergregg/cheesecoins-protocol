// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";
import {MathLibrary} from "../libraries/MathLibrary.sol";
import {IGovernance} from "./interfaces/IGovernance.sol";
import {GovernanceWeighting} from "./GovernanceWeighting.sol";
import {FounderDecentralization} from "./FounderDecentralization.sol";
import {ProtocolTimelock} from "./ProtocolTimelock.sol";
import {SceneTracker} from "../nft/extensions/SceneTracker.sol";
import {IStakingManager} from "../staking/interfaces/IStakingManager.sol";

/**
 * @title ReentrancyGuard
 * @notice Lightweight reentrancy protection
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * @title SuperHolderGovernance
 * @notice Growth-weighted governance with super holder mechanics (complete 100-scene NFT collection).
 * @dev Phase 6B: All passed proposals are executed through ProtocolTimelock, NOT via an
 *      internal queue.  The legacy timelockQueue mapping is permanently disabled — any
 *      attempt to use the old execute() path reverts with InternalQueueDisabled.
 *
 *      New execution flow:
 *        1. propose()           — create proposal (super holders only)
 *        2. vote()              — cast votes during voting period
 *        3. queueToProtocolTimelock(proposalId) — after voting ends + supermajority met,
 *                               calls ProtocolTimelock.schedule() with a deterministic salt
 *        4. executeQueued(proposalId) — after timelock delay elapses, calls
 *                               ProtocolTimelock.execute() and marks proposal done
 *
 *      Guardian cancellation: the guardian multisig holds CANCELLER_ROLE on ProtocolTimelock
 *      and can cancel a queued operation directly on the timelock using the opId stored in
 *      timelockOperationId[proposalId] before executeQueued is called.
 *
 *      Stage gating: queueToProtocolTimelock will revert if this contract does not yet
 *      hold PROPOSER_ROLE on ProtocolTimelock (i.e. before Stage 1 is activated).
 *      This prevents shadow governance from becoming effective before the maturity gate.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract SuperHolderGovernance is IGovernance, ReentrancyGuard {
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;
    using MathLibrary for uint256;

    // ============ Constants ============

    /// @notice CANCELLER_ROLE from OZ TimelockController — used to gate cancelTimelockOperation().
    /// @dev Matches keccak256("CANCELLER_ROLE") in the deployed ProtocolTimelock.
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    // ============ State Variables ============

    /// @notice Governance weighting calculator
    GovernanceWeighting public immutable governanceWeighting;

    /// @notice Founder decentralization contract
    FounderDecentralization public immutable founderDecentralization;

    /// @notice ProtocolTimelock — sole execution authority for passed proposals (Phase 6B).
    ProtocolTimelock public immutable protocolTimelock;

    /// @notice SceneTracker — queried dynamically to determine full-collection ownership.
    SceneTracker public immutable sceneTracker;

    /// @notice StakingManager — queried dynamically to determine per-user project stake.
    IStakingManager public immutable stakingManager;

    /// @notice Project ID scoped to this governance instance.
    uint256 public immutable projectId;

    /// @notice Protocol admin (can cancel proposals; NOT the execution authority)
    address public admin;

    /// @notice Proposal counter
    uint256 public proposalCount;

    /// @notice Mapping of proposal ID to proposal data
    mapping(uint256 => Proposal) public proposals;

    /// @notice Mapping of proposal ID to voter to vote status
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Mapping of proposal ID to voter vote details
    mapping(uint256 => mapping(address => VoteDetails)) public voteDetails;

    /// @notice Accumulator: sum of voting power for all potentially eligible users.
    /// @dev Updated via notifyPotentialVotingPowerChange; snapshotted at proposal creation.
    uint256 public currentPotentialVotes;

    /// @notice Cached voting power per user for accumulator delta calculations.
    mapping(address => uint256) public cachedPotentialVotes;

    /// @notice Cached potential eligibility flag per user (full collection + stake > 0, no age gate).
    mapping(address => bool) public cachedIsPotentiallyEligible;

    /// @notice DEPRECATED — sticky super holder status (Option A: dynamic eligibility).
    /// @dev Do NOT read or write this mapping.  It is kept in storage to preserve the
    ///      upgrade layout of any proxy that inherits from this contract.  Eligibility
    ///      is now determined dynamically via SceneTracker + StakingManager; see
    ///      _isEligible(voter) and immutable sceneTracker / stakingManager / projectId.
    mapping(address => SuperHolderStatus) public superHolders;

    /// @notice DEPRECATED — per-user project ID for super holder status (Option A: dynamic).
    /// @dev Do NOT read or write this mapping.  Kept for upgrade/layout safety only.
    ///      The project ID is now the immutable `projectId` field of this contract.
    mapping(address => uint256) public superHolderProjects;

    /// @notice DEPRECATED — internal timelock queue (Phase 6B: permanently disabled).
    /// @dev Do NOT read or write this mapping.  It is kept in storage to preserve the
    ///      upgrade layout of any proxy that inherits from this contract.  All execution
    ///      is now handled via ProtocolTimelock; see timelockOperationId below.
    ///      Slither flags this as "uninitialized-state" because nothing writes to it.
    ///      That is intentional: as a mapping it is implicitly zero-initialized by the EVM,
    ///      and the only read (getTimelockExecutionTime) correctly returns 0 for all entries.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 => uint256) public timelockQueue;

    /// @notice Maps governance proposalId → ProtocolTimelock operation hash.
    /// @dev Set by queueToProtocolTimelock(); zero means not yet queued.
    ///      Use this ID to cancel the queued op via ProtocolTimelock.cancel(opId).
    mapping(uint256 => bytes32) public timelockOperationId;

    // ============ Structs ============

    struct VoteDetails {
        bool support;
        uint256 weight;
        uint256 timestamp;
    }

    /// @dev DEPRECATED — only retained for storage layout compatibility with the
    ///      deprecated `superHolders` mapping above.  Never populated in new code.
    struct SuperHolderStatus {
        bool isActive;
        uint256 projectId;
        uint256 achievedAt;
        uint256[] nftIds;
    }

    // ============ Events ============

    event ProposalQueued(uint256 indexed proposalId, uint256 executionTime);
    event ProposalCanceled(uint256 indexed proposalId, address indexed canceler);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when a passed proposal is queued in ProtocolTimelock.
    event ProposalQueuedInTimelock(uint256 indexed proposalId, bytes32 indexed timelockOpId);

    /// @notice Emitted when a ProtocolTimelock-queued proposal is executed.
    event ProposalExecutedViaTimelock(uint256 indexed proposalId, bytes32 indexed timelockOpId);

    /// @notice Emitted when cancelTimelockOperation cancels the ProtocolTimelock operation.
    event TimelockOperationCancelled(uint256 indexed proposalId, bytes32 indexed timelockOpId);

    /// @notice Emitted when a user's potential voting power in the accumulator changes.
    event PotentialVotingPowerUpdated(address indexed user, bool eligible, uint256 power, uint256 currentTotal);

    // ============ Errors ============

    error NotSuperHolder();
    error ProposalNotActive();
    error AlreadyVoted();
    error VotingPeriodNotEnded();
    error ProposalNotPassed();
    error TimelockNotExpired();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyCanceled();
    error NotAdmin();
    error InvalidNFTCollection();
    error InsufficientNFTs();

    /// @notice Reverts when becomeSuperHolder is called — this path is permanently deprecated.
    /// @dev Super holder status is now determined dynamically via SceneTracker + StakingManager.
    error SuperHolderClaimDeprecated();

    /// @notice Reverts when caller attempts to use the legacy execute() path.
    /// @dev The internal timelockQueue is permanently disabled in Phase 6B.
    ///      Use queueToProtocolTimelock() + executeQueued() instead.
    error InternalQueueDisabled();

    /// @notice Reverts when queueToProtocolTimelock is called for an already-queued proposal.
    error AlreadyQueued();

    /// @notice Reverts when executeQueued is called before queueToProtocolTimelock.
    error NotQueued();

    /// @notice Reverts when cancelTimelockOperation is called by an address without CANCELLER_ROLE.
    error NotCanceller();

    /// @notice Reverts when the quorum (70% of snapshotPotentialVotes) is not met.
    error QuorumNotMet();

    /// @notice Reverts when snapshotPotentialVotes == 0 at queue time (accumulator not seeded).
    error QuorumUndefined();

    /// @notice Reverts when notifyPotentialVotingPowerChange is called by an unauthorized address.
    error NotAuthorizedNotifier();

    // ============ Modifiers ============

    modifier onlySuperHolder() {
        if (!_isEligible(msg.sender)) {
            revert NotSuperHolder();
        }
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert NotAdmin();
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize super holder governance.
     * @param _governanceWeighting     Governance weighting contract.
     * @param _founderDecentralization Founder decentralization contract.
     * @param _protocolTimelock        ProtocolTimelock — must grant this contract
     *                                 PROPOSER_ROLE before queueToProtocolTimelock works.
     * @param _admin                   Initial admin address (can cancel proposals).
     * @param _sceneTracker            SceneTracker contract for full-collection checks.
     * @param _stakingManager          StakingManager contract for per-user stake queries.
     * @param _projectId               Project ID scoped to this governance instance.
     */
    constructor(
        address _governanceWeighting,
        address _founderDecentralization,
        address _protocolTimelock,
        address _admin,
        address _sceneTracker,
        address _stakingManager,
        uint256 _projectId
    ) {
        _governanceWeighting.requireNonZeroAddress("SuperHolderGov: invalid weighting");
        _founderDecentralization.requireNonZeroAddress("SuperHolderGov: invalid founder");
        _protocolTimelock.requireNonZeroAddress("SuperHolderGov: invalid timelock");
        _admin.requireNonZeroAddress("SuperHolderGov: invalid admin");
        _sceneTracker.requireNonZeroAddress("SuperHolderGov: invalid sceneTracker");
        _stakingManager.requireNonZeroAddress("SuperHolderGov: invalid stakingManager");

        governanceWeighting = GovernanceWeighting(_governanceWeighting);
        founderDecentralization = FounderDecentralization(_founderDecentralization);
        protocolTimelock = ProtocolTimelock(payable(_protocolTimelock));
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        admin = _admin;
        sceneTracker = SceneTracker(_sceneTracker);
        stakingManager = IStakingManager(_stakingManager);
        projectId = _projectId;
    }

    // ============ Super Holder Functions ============

    /**
     * @notice DEPRECATED — super holder status is now determined dynamically.
     * @dev Always reverts. Kept for interface compatibility (IGovernance.becomeSuperHolder).
     *      Eligibility is now checked live via sceneTracker.hasFullCollection() and
     *      stakingManager.getUserProjectStaked().
     *      Storage vars superHolders / superHolderProjects are preserved for upgrade layout
     *      safety but are never written or read.
     */
    function becomeSuperHolder(uint256[] memory) external override nonReentrant {
        revert SuperHolderClaimDeprecated();
    }

    // ============ Governance Functions ============

    /**
     * @notice Create a new governance proposal
     * @param description Proposal description
     * @param target Target contract address
     * @param callData Encoded function call
     * @return proposalId New proposal ID
     * @dev Only super holders can create proposals
     */
    function propose(string memory description, address target, bytes memory callData)
        external
        override
        onlySuperHolder
        returns (uint256 proposalId)
    {
        target.requireNonZeroAddress("SuperHolderGov: invalid target");
        require(bytes(description).length > 0, "SuperHolderGov: empty description");

        proposalCount++;
        proposalId = proposalCount;

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + Config.GOVERNANCE_VOTING_PERIOD;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            target: target,
            callData: callData,
            startTime: startTime,
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false,
            snapshotPotentialVotes: currentPotentialVotes,
            snapshotBlock: uint64(block.number),
            snapshotTime: uint64(block.timestamp)
        });

        emit ProposalCreated(proposalId, msg.sender, description);

        return proposalId;
    }

    /**
     * @notice Vote on a proposal
     * @param proposalId Proposal ID
     * @param support True for yes, false for no
     * @dev Voting power calculated using GovernanceWeighting formula
     */
    function vote(uint256 proposalId, bool support) external override onlySuperHolder nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotActive();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp < proposal.startTime || block.timestamp > proposal.endTime) {
            revert ProposalNotActive();
        }
        if (hasVoted[proposalId][msg.sender]) {
            revert AlreadyVoted();
        }

        // CEI: mark voted before any external call to prevent reentrancy double-vote
        hasVoted[proposalId][msg.sender] = true;

        // Calculate voting power
        // slither-disable-next-line reentrancy-no-eth -- trusted protocol contract + nonReentrant + hasVoted set before call
        uint256 votingPower = getVotingPower(msg.sender);

        // Apply founder multiplier if applicable
        if (founderDecentralization.isFounder(msg.sender)) {
            votingPower = founderDecentralization.calculateFounderAdjustedPower(msg.sender, votingPower);
        }

        // Record vote
        voteDetails[proposalId][msg.sender] =
            VoteDetails({support: support, weight: votingPower, timestamp: block.timestamp});

        // Update proposal vote counts
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(msg.sender, proposalId, support, votingPower);
    }

    /**
     * @notice DISABLED — internal execution path permanently removed in Phase 6B.
     * @dev Always reverts.  Use queueToProtocolTimelock() + executeQueued() instead.
     *
     *      Migration guide:
     *        OLD: execute(proposalId)
     *        NEW: queueToProtocolTimelock(proposalId)  ← after voting period + supermajority
     *             ... wait for ProtocolTimelock delay (Config.TIMELOCK_DELAY) ...
     *             executeQueued(proposalId)
     */
    function execute(uint256) external pure override {
        revert InternalQueueDisabled();
    }

    /**
     * @notice Queue a passed proposal into ProtocolTimelock for time-delayed execution.
     * @dev Callable by anyone after the voting period ends and supermajority is confirmed.
     *      Requires this contract to hold PROPOSER_ROLE on ProtocolTimelock (Stage 1+).
     *      If called before Stage 1 is activated, the call will revert at the timelock.
     *
     *      Deterministic salt: keccak256(abi.encodePacked(address(this), proposalId))
     *      This salt is unique per proposal and ensures the operation ID is predictable
     *      for cancellation via ProtocolTimelock.cancel(timelockOperationId[proposalId]).
     *
     * @param proposalId Governance proposal ID (from propose()).
     */
    function queueToProtocolTimelock(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotActive();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp <= proposal.endTime) revert VotingPeriodNotEnded();

        // Verify supermajority (66%)
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes > 0, "SuperHolderGov: no votes");
        uint256 forPercentage = (proposal.forVotes * 100) / totalVotes;
        if (forPercentage < Config.SUPERMAJORITY_THRESHOLD) revert ProposalNotPassed();

        // Verify quorum (70% of snapshotPotentialVotes at proposal creation)
        if (proposal.snapshotPotentialVotes == 0) revert QuorumUndefined();
        if (totalVotes * 100 < proposal.snapshotPotentialVotes * 70) revert QuorumNotMet();

        // Prevent double-queuing
        if (timelockOperationId[proposalId] != bytes32(0)) revert AlreadyQueued();

        // Deterministic salt: unique per proposalId and per this governance contract address
        bytes32 salt = keccak256(abi.encodePacked(address(this), proposalId));

        // Store operation ID before the external call (checks-effects-interactions)
        bytes32 opId = protocolTimelock.hashOperation(proposal.target, 0, proposal.callData, bytes32(0), salt);
        timelockOperationId[proposalId] = opId;

        // Schedule in ProtocolTimelock — requires this contract to have PROPOSER_ROLE
        protocolTimelock.schedule(
            proposal.target,
            0,
            proposal.callData,
            bytes32(0), // predecessor: none
            salt,
            protocolTimelock.getMinDelay()
        );

        emit ProposalQueuedInTimelock(proposalId, opId);
    }

    /**
     * @notice Execute a previously queued proposal after the ProtocolTimelock delay.
     * @dev Callable by anyone once the timelock delay has elapsed.
     *      If EXECUTOR_ROLE is open (address(0)) on ProtocolTimelock, anyone may call.
     *      If EXECUTOR_ROLE is restricted, this contract or the caller needs the role.
     *
     * @param proposalId Governance proposal ID (from propose()).
     */
    function executeQueued(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotActive();
        if (proposal.canceled) revert ProposalAlreadyCanceled();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (timelockOperationId[proposalId] == bytes32(0)) revert NotQueued();

        bytes32 salt = keccak256(abi.encodePacked(address(this), proposalId));
        bytes32 opId = timelockOperationId[proposalId];

        // Mark executed before external call (checks-effects-interactions)
        proposal.executed = true;

        // Delegate execution to ProtocolTimelock (enforces delay, executor role, etc.)
        protocolTimelock.execute(proposal.target, 0, proposal.callData, bytes32(0), salt);

        emit ProposalExecutedViaTimelock(proposalId, opId);
    }

    /**
     * @notice Cancel a proposal (governance side only).
     * @dev Only admin or proposer can cancel.
     *
     *      IMPORTANT — Timelock side must also be cancelled:
     *      If the proposal has already been queued in ProtocolTimelock
     *      (timelockOperationId[proposalId] != bytes32(0)), cancelling here only
     *      prevents executeQueued() from succeeding.  The pending timelock operation
     *      remains executable after the delay elapses until explicitly cancelled by a
     *      CANCELLER_ROLE holder (typically the guardian multisig):
     *
     *        bytes32 opId = governance.timelockOperationId(proposalId);
     *        protocolTimelock.cancel(opId);
     *
     *      With an open executor (EXECUTOR_ROLE = address(0)), failing to cancel the
     *      timelock op means anyone can call protocolTimelock.execute(...) directly
     *      once the delay elapses and bypass this governance-side cancellation.
     *      With a restricted executor, only credentialed addresses can execute.
     *
     *      Prefer cancelTimelockOperation() for a single call that does both steps atomically
     *      when the caller holds CANCELLER_ROLE on ProtocolTimelock.
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (msg.sender != admin && msg.sender != proposal.proposer) revert NotAdmin();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalAlreadyCanceled();

        // If the proposal is already queued in ProtocolTimelock, cancelProposal alone is
        // insufficient: the timelock op would remain executable by anyone (open executor).
        // Force callers to use cancelTimelockOperation() which atomically cancels both.
        if (timelockOperationId[proposalId] != bytes32(0)) {
            revert AlreadyQueued(); // use cancelTimelockOperation(proposalId) instead
        }

        proposal.canceled = true;
        emit ProposalCanceled(proposalId, msg.sender);
    }

    /**
     * @notice Cancel a proposal and its associated ProtocolTimelock operation in one call.
     * @dev Guarded by ProtocolTimelock CANCELLER_ROLE — only the guardian / security council
     *      can call this.  No new role is introduced; authority is checked directly against
     *      the timelock's own role registry.
     *
     *      This is the recommended "full cancel" path with an open executor (address(0)):
     *        1. Marks the governance proposal canceled (idempotent if already canceled).
     *        2. If timelockOperationId[proposalId] is set AND the operation is still
     *           pending in the timelock, cancels it via protocolTimelock.cancel(opId).
     *
     *      Skips the timelock cancel silently if:
     *        - No timelock operation was scheduled yet (proposal canceled before queueing), or
     *        - Operation was already cancelled or executed (not pending).
     *
     *      Does NOT revert if the proposal was already governance-canceled; this lets
     *      a guardian use this function to cancel the timelock op even if the proposer
     *      already ran cancelProposal() first.
     *
     * @param proposalId Governance proposal ID to cancel.
     */
    function cancelTimelockOperation(uint256 proposalId) external {
        if (!protocolTimelock.hasRole(CANCELLER_ROLE, msg.sender)) revert NotCanceller();

        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotActive();
        if (proposal.executed) revert ProposalAlreadyExecuted();

        // Mark governance proposal canceled (idempotent).
        if (!proposal.canceled) {
            proposal.canceled = true;
            emit ProposalCanceled(proposalId, msg.sender);
        }

        // Cancel the timelock operation if one was scheduled and is still pending.
        bytes32 opId = timelockOperationId[proposalId];
        if (opId != bytes32(0) && protocolTimelock.isOperationPending(opId)) {
            protocolTimelock.cancel(opId);
            emit TimelockOperationCancelled(proposalId, opId);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Potential eligibility: full scene collection AND active project stake (no age gate).
     * @dev Used for accumulator updates (denominator for quorum).
     * @param voter Address to check
     * @return True if voter holds a full collection and has staked > 0 in projectId
     */
    function _isPotentiallyEligible(address voter) internal view returns (bool) {
        return sceneTracker.hasFullCollection(voter) && stakingManager.getUserProjectStaked(voter, projectId) > 0;
    }

    /**
     * @notice Full eligibility: potentially eligible AND stake age >= 24 weeks.
     * @param voter Address to check
     * @return True if voter is potentially eligible and meets the minimum stake age
     */
    function _isEligible(address voter) internal view returns (bool) {
        if (!_isPotentiallyEligible(voter)) return false;
        uint64 stakeStart = stakingManager.userProjectStakeStartAt(voter, projectId);
        if (stakeStart == 0) return false;
        return block.timestamp - uint256(stakeStart) >= 24 weeks;
    }

    /**
     * @notice Get voting power for a user
     * @param voter Voter address
     * @return Voting power (0 if not eligible)
     * @dev Not `view` because calculateVotingPower emits VotingPowerCalculated; matches IGovernance.
     */
    function getVotingPower(address voter) public override returns (uint256) {
        if (!_isEligible(voter)) {
            return 0;
        }

        return governanceWeighting.calculateVotingPower(voter, projectId, true);
    }

    /**
     * @notice Update the potential-votes accumulator for a user.
     * @dev Only callable by sceneTracker or stakingManager.
     *      Does NOT apply stake-age gating — uses _isPotentiallyEligible.
     *      Called by StakingManager on stake/unstake/transfer and by SceneTracker on
     *      full-collection status transitions.
     *      nonReentrant is applied because the call to governanceWeighting.calculateVotingPower
     *      is unavoidable here; nonReentrant prevents cross-function reentry while computing.
     * @param user Address whose potential voting power may have changed.
     */
    function notifyPotentialVotingPowerChange(address user) external nonReentrant {
        if (msg.sender != address(sceneTracker) && msg.sender != address(stakingManager)) {
            revert NotAuthorizedNotifier();
        }

        bool oldEligible = cachedIsPotentiallyEligible[user];
        uint256 oldPower = cachedPotentialVotes[user];

        bool newEligible = _isPotentiallyEligible(user);
        // slither-disable-next-line reentrancy-no-eth -- external weighting call exists; nonReentrant prevents re-entry
        uint256 newPower = newEligible ? governanceWeighting.calculateVotingPower(user, projectId, true) : 0;

        // Update accumulator (remove old, add new)
        if (oldEligible) {
            currentPotentialVotes -= oldPower;
        }
        if (newEligible) currentPotentialVotes += newPower;

        // Update cache
        cachedIsPotentiallyEligible[user] = newEligible;
        cachedPotentialVotes[user] = newPower;

        emit PotentialVotingPowerUpdated(user, newEligible, newPower, currentPotentialVotes);
    }

    /**
     * @notice Get proposal details
     * @param proposalId Proposal ID
     * @return Proposal struct
     */
    function getProposal(uint256 proposalId) external view override returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Get voter info for a proposal
     * @param proposalId Proposal ID
     * @param voter Voter address
     * @return VoterInfo struct
     */
    function getVoterInfo(uint256 proposalId, address voter) external view returns (VoterInfo memory) {
        VoteDetails memory details = voteDetails[proposalId][voter];

        return VoterInfo({
            voter: voter,
            votingPower: details.weight,
            stakedAmount: stakingManager.getUserProjectStaked(voter, projectId),
            projectGrowthRate: governanceWeighting.getProjectGrowthRate(projectId),
            isSuperHolder: _isEligible(voter),
            isFounder: founderDecentralization.isFounder(voter)
        });
    }

    /**
     * @notice Check if proposal has passed supermajority
     * @param proposalId Proposal ID
     * @return True if passed
     */
    function hasPassedSupermajority(uint256 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;

        // slither-disable-next-line incorrect-equality -- sentinel: 0 votes means no participation, not a bucket comparison
        if (totalVotes == 0) return false;

        uint256 forPercentage = (proposal.forVotes * 100) / totalVotes;
        return forPercentage >= Config.SUPERMAJORITY_THRESHOLD;
    }

    /**
     * @notice Get timelock execution time for proposal (legacy; deprecated in Phase 6B).
     * @dev Returns 0 for all proposals since timelockQueue is no longer written.
     *      Use timelockOperationId[proposalId] and query ProtocolTimelock directly
     *      (e.g. protocolTimelock.getTimestamp(opId)) for the execution schedule.
     * @param proposalId Proposal ID
     * @return Always 0 (deprecated field).
     */
    function getTimelockExecutionTime(uint256 proposalId) external view returns (uint256) {
        return timelockQueue[proposalId];
    }

    // ============ Admin Functions ============

    /**
     * @notice Change admin address
     * @param newAdmin New admin address
     */
    function changeAdmin(address newAdmin) external onlyAdmin {
        newAdmin.requireNonZeroAddress("SuperHolderGov: invalid admin");

        address oldAdmin = admin;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        admin = newAdmin;

        emit AdminChanged(oldAdmin, newAdmin);
    }
}
