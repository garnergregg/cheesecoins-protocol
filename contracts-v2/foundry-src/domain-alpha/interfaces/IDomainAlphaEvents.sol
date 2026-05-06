// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IDomainAlphaEvents
 * @notice Interface for Domain Alpha social bot events
 */
interface IDomainAlphaEvents {
    // NFT Events
    event NFTMinted(
        uint256 indexed projectId, uint256 indexed nftId, uint16 sceneNumber, address indexed user, uint256 timestamp
    );

    // Staking Events
    event StakingCreated(
        uint256 indexed nftId, uint256 indexed projectId, uint256 amount, uint256 lockMonths, address indexed user
    );

    // Yield Events
    event YieldDistributed(uint256 indexed projectId, uint256 totalValue, uint256 nftCount, uint256 avgYield);

    // Governance Events
    event SuperHolderCreated(address indexed user, uint256 indexed projectId, uint256 votingPower);

    // Project Events
    event ProjectRegistered(uint256 indexed projectId, string name, string ownerName, uint256 initialDoes);

    // Audit Events
    event HarvestAuditCompleted(
        uint256 indexed projectId, uint256 actualGrowth, uint256 projectedGrowth, uint256 value
    );

    // Milestone Events
    event Community90PercentAchieved(uint256 indexed projectId, uint256 bonusAPY);

    // Marketplace Events
    event NFTTransferredWithStaking(
        uint256 indexed nftId, address indexed seller, address indexed buyer, uint256 stakedAmount
    );

    // Decentralization Events
    event FounderDecentralization(uint256 yearRemaining, uint256 currentWeight);

    // Growth Bonus Events
    event GrowthBonusTriggered(uint256 projectCount, uint256 bonusPercent);

    // Function declarations
    function emitNFTTransferredWithStaking(uint256 nftId, address seller, address buyer, uint256 stakedAmount) external;
}
