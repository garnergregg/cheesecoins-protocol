// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ICheesecoinsCore
 * @notice Interface for the core CURD token contract
 */
interface ICheesecoinsCore {
    // ============ EVENTS ============

    event ProjectRegistered(uint256 indexed projectId, address nftAddress, uint256 initialDoes);
    event Mint(address indexed to, uint256 amount, uint256 indexed projectId, string reason);
    event Burn(address indexed from, uint256 amount, string reason);
    event AuthorizedAuditorUpdated(address indexed oldAuditor, address indexed newAuditor);
    event AuthorizedMinterUpdated(address indexed oldMinter, address indexed newMinter);
    event AuditCompleted(
        uint256 indexed projectId, uint256 actualValue, uint256 actualDoes, uint256 growthRate, bool targetsMet
    );
    event YieldAllocation(uint256 indexed projectId, uint256 amount, uint256 timestamp);
    event DeflatoryTrajectoryUpdated(uint256 productionValue, uint256 tokenSupply, uint256 ratio);
    event TreasuryAddressesUpdated(address ecosystem, address farmers, address marketing, address reserve);

    // ============ STRUCTS ============

    struct ProjectData {
        uint256 id;
        address nftAddress;
        address oracleAddress;
        uint256 initialDoes;
        uint256 currentDoes;
        uint256 registrationTime;
        uint256 lastAuditTime;
        uint256 totalMinted;
        bool active;
    }

    struct AuditResult {
        uint256 projectId;
        uint256 actualValue;
        uint256 actualDoes;
        uint256 expectedValue;
        uint256 growthRate;
        uint256 timestamp;
        bool targetsMet;
    }

    // ============ PROJECT MANAGEMENT ============

    function registerProject(address nftAddress, address oracleAddress, uint256 initialDoes)
        external
        returns (uint256 projectId);

    function getProject(uint256 projectId) external view returns (ProjectData memory);

    function getProjectCount() external view returns (uint256);

    // ============ MINTING & BURNING ============

    function mintNewCURDForEcosystemGrowth(uint256 newProductionValue, bytes memory proof)
        external
        returns (uint256 mintedAmount);

    function controllerMint(address to, uint256 amount, string calldata reason) external;

    function burn(uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;

    // ============ AUDIT FUNCTIONS ============

    function performAnnualAudit(uint256 projectId, uint256 actualValue, uint256 actualDoes, bytes memory proof)
        external
        returns (AuditResult memory);

    function calculateProjectGrowthRate(uint256 projectId) external view returns (uint256);

    // ============ DEFLATIONARY MECHANICS ============

    function getDeflatoryTrajectory()
        external
        view
        returns (uint256 productionValue, uint256 tokenSupply, uint256 ratio);

    function getCurrentBurnRate() external view returns (uint256);

    // ============ TREASURY ============

    function allocateTreasuryFunds(address recipient, uint256 amount, uint8 category) external;

    function fundYieldPool(address yieldPool, uint256 pid, uint256 amount, uint8 category) external;
}
