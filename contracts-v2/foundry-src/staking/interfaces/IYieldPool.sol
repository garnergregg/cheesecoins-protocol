// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IYieldPool
 * @notice Interface for per-project yield pool management
 */
interface IYieldPool {
    struct YieldDistribution {
        uint256 projectId;
        uint256 totalYield;
        uint256 nftCount;
        uint256 distributionTime;
        bytes32 merkleRoot;
    }

    event YieldDeposited(uint256 indexed projectId, uint256 amount);

    event YieldDistributed(uint256 indexed projectId, uint256 totalYield, uint256 nftCount, uint256 avgYield);

    function depositYield(uint256 projectId, uint256 amount) external;

    function setMerkleRoot(uint256 projectId, bytes32 root) external;

    function getAvailableYield(uint256 projectId) external view returns (uint256);

    function getDistribution(uint256 projectId, uint256 index) external view returns (YieldDistribution memory);

    function debitYield(uint256 projectId, address recipient, uint256 amount) external;

    function getCurrentMerkleRoot(uint256 projectId) external view returns (bytes32);
}
