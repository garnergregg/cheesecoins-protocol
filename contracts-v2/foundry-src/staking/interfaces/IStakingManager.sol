// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IStakingManager
 * @notice Interface for NFT-only staking engine
 */
interface IStakingManager {
    struct StakingPosition {
        uint256 nftId;
        uint256 amount;
        uint256 lockMonths;
        uint256 startTime;
        uint256 maturityTime;
        uint256 apyMultiplier;
        uint256 accruedYield;
        bool active;
    }

    struct StakingStats {
        uint256 projectId;
        uint256 totalStaked;
        uint256 activeNFTs;
        uint256 communityPercentage;
        bool bonusActive;
    }

    event Staked(
        address indexed user,
        uint256 indexed nftId,
        uint256 indexed projectId,
        uint256 amount,
        uint256 lockMonths,
        uint256 maturityTime
    );

    event Unstaked(address indexed user, uint256 indexed nftId, uint256 amount, uint256 burnAmount, bool earlyUnstake);

    event InsurancePremiumPaid(uint256 indexed projectId, uint256 amount);

    event Community90Achieved(uint256 indexed projectId, uint256 bonusAPY);

    function stake(uint256 nftId, uint256 amount, uint256 lockMonths) external;

    function unstake(uint256 nftId, uint256 amount) external;

    function getStakingPosition(uint256 nftId) external view returns (StakingPosition memory);

    function getStakingStats(uint256 projectId) external view returns (StakingStats memory);

    function calculateAPY(uint256 nftId) external view returns (uint256);

    function payInsurancePremium(uint256 projectId) external;

    function getNFTAddress(uint256 nftId) external view returns (address);

    function isNFTRegistered(uint256 nftId) external view returns (bool);

    function isEligibleForRewards(uint256 nftId) external view returns (bool);

    function getUserProjectStaked(address user, uint256 projectId) external view returns (uint256);

    /// @notice Returns the timestamp when `user` first staked into `projectId` (0 = never staked).
    function userProjectStakeStartAt(address user, uint256 projectId) external view returns (uint64);
}
