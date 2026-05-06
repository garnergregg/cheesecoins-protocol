// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title ITrancheStakingManager
/// @notice Interface for Phase-3 tranche-based NFT-keyed CURD staking
interface ITrancheStakingManager {
    // ============ STRUCTS ============

    /// @notice Represents a single staking tranche created by one stake() call
    struct Tranche {
        uint256 principal;
        uint256 startTime;
        uint256 maturityTime;
        uint32 aprBps;
        bool closed;
    }

    // ============ EVENTS ============

    event TrancheStaked(
        uint256 indexed nftId,
        uint256 indexed trancheId,
        address indexed caller,
        uint256 principal,
        uint32 aprBps,
        uint256 maturityTime
    );
    event TrancheClaimed(
        uint256 indexed nftId, uint256 indexed trancheId, address indexed recipient, uint256 principal, uint256 yield
    );
    event TrancheBroken(uint256 indexed nftId, uint256 indexed trancheId, address indexed recipient, uint256 principal);
    event RewardsFunded(address indexed funder, uint256 amount);
    event AprModelUpdated(address indexed oldModel, address indexed newModel);
    event BaseAprBpsUpdated(uint32 oldBps, uint32 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ FUNCTIONS ============

    function initialize(address curdToken, address csaNft, address treasury, uint32 baseAprBps, address aprModel)
        external;

    function stake(uint256 nftId, uint256 amount) external returns (uint256 trancheId);

    function claimMatured(uint256 nftId, uint256[] calldata trancheIds) external;

    function breakEarly(uint256 nftId, uint256[] calldata trancheIds) external;

    function fundRewards(uint256 amount) external;

    function setAprModel(address newModel) external;

    function setBaseAprBps(uint32 newBps) external;

    function setTreasury(address newTreasury) external;

    function trancheCount(uint256 nftId) external view returns (uint256);

    function getTranche(uint256 nftId, uint256 trancheId) external view returns (Tranche memory);

    function activePrincipal(uint256 nftId) external view returns (uint256);

    function previewYield(uint256 nftId, uint256 trancheId) external view returns (uint256);

    function isMatured(uint256 nftId, uint256 trancheId) external view returns (bool);
}
