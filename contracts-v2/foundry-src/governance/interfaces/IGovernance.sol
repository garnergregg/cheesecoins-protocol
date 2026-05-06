// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IGovernance
 * @notice Interface for growth-weighted governance system
 */
interface IGovernance {
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        address target;
        bytes callData;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        /// @notice Snapshot of currentPotentialVotes at proposal creation time (used for quorum).
        uint256 snapshotPotentialVotes;
        /// @notice Block number at proposal creation time.
        uint64 snapshotBlock;
        /// @notice Timestamp at proposal creation time.
        uint64 snapshotTime;
    }

    struct VoterInfo {
        address voter;
        uint256 votingPower;
        uint256 stakedAmount;
        uint256 projectGrowthRate;
        bool isSuperHolder;
        bool isFounder;
    }

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description);

    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 weight);

    event ProposalExecuted(uint256 indexed proposalId);

    event SuperHolderCreated(address indexed user, uint256 indexed projectId, uint256 votingPower);

    event FounderWeightUpdated(uint256 year, uint256 newWeight);

    function propose(string memory description, address target, bytes memory callData)
        external
        returns (uint256 proposalId);

    function vote(uint256 proposalId, bool support) external;

    function execute(uint256 proposalId) external;

    function getVotingPower(address voter) external returns (uint256);

    function getProposal(uint256 proposalId) external view returns (Proposal memory);

    /// @notice DEPRECATED — always reverts with SuperHolderClaimDeprecated().
    /// @dev Kept for interface compatibility.  Super holder eligibility is now
    ///      determined dynamically via SceneTracker.hasFullCollection() and
    ///      StakingManager.getUserProjectStaked(); no claim transaction required.
    function becomeSuperHolder(uint256[] memory nftIds) external;
}
