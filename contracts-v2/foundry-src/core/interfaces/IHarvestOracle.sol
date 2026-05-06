// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IHarvestOracle
 * @notice Interface for herd production data feeds
 */
interface IHarvestOracle {
    struct HerdData {
        uint256 projectId;
        uint256 totalDoes;
        uint256 productionValue; // USD value in 8 decimals
        uint256 timestamp;
        bool verified;
    }

    event HerdDataUpdated(uint256 indexed projectId, uint256 totalDoes, uint256 productionValue);

    function updateHerdData(uint256 projectId, uint256 totalDoes, uint256 productionValue) external;

    function getHerdData(uint256 projectId) external view returns (HerdData memory);

    function isDataFresh(uint256 projectId) external view returns (bool);

    function getLatestProductionValue(uint256 projectId) external view returns (uint256);
}
