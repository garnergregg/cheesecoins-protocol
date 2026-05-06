// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IProjectRegistry
 * @notice Interface for multi-tenant project management
 */
interface IProjectRegistry {
    struct Project {
        uint256 id;
        string name;
        address owner;
        address nftAddress;
        address oracleAddress;
        address yieldPoolAddress;
        uint256 initialDoes;
        uint256 registrationTime;
        uint256 graduationYear;
        bool active;
        bool graduated;
    }

    struct ProjectMetrics {
        uint256 projectId;
        uint256 growthRate;
        uint256 totalStaked;
        uint256 totalYieldDistributed;
        uint256 nftHolders;
        uint256 graduationWeight;
    }

    event ProjectCreated(uint256 indexed projectId, string name, address indexed owner, address nftAddress);

    event ProjectGraduated(uint256 indexed projectId, uint256 weight);

    event ProjectApproved(uint256 indexed projectId);

    event OperatorWalletUpdated(uint256 indexed projectId, address operatorWallet);

    event PayoutsEnabledUpdated(uint256 indexed projectId, bool enabled);

    function createProject(
        string memory name,
        address owner,
        address nftAddress,
        address oracleAddress,
        uint256 initialDoes
    ) external returns (uint256 projectId);

    function getProject(uint256 projectId) external view returns (Project memory);

    function getProjectMetrics(uint256 projectId) external view returns (ProjectMetrics memory);

    function getProjectCount() external view returns (uint256);

    function getGraduationWeight(uint256 projectId) external view returns (uint256);

    function registerYieldPool(uint256 projectId, address yieldPoolAddress) external;

    function approveProject(uint256 projectId) external;

    function getOperatorWallet(uint256 projectId) external view returns (address);

    function isPayoutsEnabled(uint256 projectId) external view returns (bool);
}
