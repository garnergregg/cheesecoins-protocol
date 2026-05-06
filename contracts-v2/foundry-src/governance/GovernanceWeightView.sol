// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {GovernanceWeighting} from "./GovernanceWeighting.sol";
import {FounderDecentralization} from "./FounderDecentralization.sol";
import {IStakingManager} from "../staking/interfaces/IStakingManager.sol";

/// @dev Read-only slice of SceneTracker needed for full-collection check.
interface ISceneTrackerFullSet {
    function hasFullCollection(address user) external view returns (bool);
}

/**
 * @title GovernanceWeightView
 * @notice Phase 6B — Read-only view wrapper over the existing voting-weight formula.
 * @dev Computes voting power WITHOUT emitting events and WITHOUT writing state,
 *      making it safe to call from view contexts (front-ends, MaturityOracle, etc.)
 *      while remaining byte-for-byte equivalent to the formula used inside
 *      SuperHolderGovernance.vote() and GovernanceWeighting.calculateVotingPower().
 *
 * Formula (same as legacy):
 *   if !sceneTracker.hasFullCollection(voter) → 0
 *   else:
 *     staked  = stakingManager.getUserProjectStaked(voter, projectId)
 *     power   = governanceWeighting.previewVotingPower(staked, projectId, isSuperHolder)
 *     if voter is founder:
 *       power = founderDecentralization.calculateFounderAdjustedPower(voter, power)
 *
 * This contract has NO state, NO events, and NO admin functions.
 * All references are immutable; the address set at construction is permanent.
 *
 * Audit note on rounding:
 *   previewVotingPower delegates to MathLibrary.ln which uses a fixed-point
 *   approximation.  Any test comparing GovernanceWeightView output to
 *   GovernanceWeighting.calculateVotingPower output must allow for ±1 wei
 *   rounding tolerance arising from event-vs-no-event code path differences.
 *   In practice both functions call the same MathLibrary.ln, so output is
 *   identical when the staking stats have not changed between the two calls.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract GovernanceWeightView {
    // ============ IMMUTABLES ============

    /// @notice SceneTracker for full-collection / super-holder check.
    ISceneTrackerFullSet public immutable sceneTracker;

    /// @notice GovernanceWeighting for the core ln(stake) × growthRate formula.
    GovernanceWeighting public immutable governanceWeighting;

    /// @notice FounderDecentralization for founder weight adjustment.
    FounderDecentralization public immutable founderDecentralization;

    // ============ ERRORS ============

    error ZeroAddress();

    // ============ CONSTRUCTOR ============

    /**
     * @param _sceneTracker          SceneTracker contract address.
     * @param _governanceWeighting   GovernanceWeighting contract address.
     * @param _founderDecentralization FounderDecentralization contract address.
     */
    constructor(address _sceneTracker, address _governanceWeighting, address _founderDecentralization) {
        if (_sceneTracker == address(0)) revert ZeroAddress();
        if (_governanceWeighting == address(0)) revert ZeroAddress();
        if (_founderDecentralization == address(0)) revert ZeroAddress();

        sceneTracker = ISceneTrackerFullSet(_sceneTracker);
        governanceWeighting = GovernanceWeighting(_governanceWeighting);
        founderDecentralization = FounderDecentralization(_founderDecentralization);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns the current voting power for `voter` in `projectId`.
     * @dev View-only — no state changes, no events.
     *      Returns 0 if the voter does not hold a full collection (not a super holder).
     *      This is the read-only equivalent of SuperHolderGovernance.getVotingPower().
     * @param voter     Address to query.
     * @param projectId NFT project ID for the staking component.
     * @return power    Voting power (0 if not a super holder).
     */
    function getVotingPower(address voter, uint256 projectId) external view returns (uint256 power) {
        // Step 1: super holder gate (SceneTracker bitmask — no custody, no loops)
        bool voterIsSuperHolder = sceneTracker.hasFullCollection(voter);
        if (!voterIsSuperHolder) {
            return 0;
        }

        // Step 2: per-wallet staked amount for the project
        IStakingManager sm = governanceWeighting.stakingManager();
        uint256 stakedAmount = sm.getUserProjectStaked(voter, projectId);

        // Step 3: core formula via previewVotingPower (view, no events)
        power = governanceWeighting.previewVotingPower(stakedAmount, projectId, voterIsSuperHolder);

        // Step 4: apply founder decay adjustment if applicable
        if (power > 0 && founderDecentralization.isFounder(voter)) {
            power = founderDecentralization.calculateFounderAdjustedPower(voter, power);
        }
    }

    /**
     * @notice Returns whether `voter` is a super holder according to SceneTracker.
     * @dev Convenience wrapper over sceneTracker.hasFullCollection.
     */
    function isSuperHolder(address voter) external view returns (bool) {
        return sceneTracker.hasFullCollection(voter);
    }
}
