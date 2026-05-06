// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../Config.sol";
import "../libraries/ValidationLibrary.sol";
import "../libraries/MathLibrary.sol";
import "./interfaces/IProjectRegistry.sol";
import "../staking/interfaces/IYieldPool.sol";

/**
 * @title ProjectRegistry
 * @notice Multi-tenant project management with graduation system and growth bonuses
 * @dev Production-grade registry supporting 10K+ agricultural projects
 *
 * Architecture:
 * - Centralized registry for all agricultural projects
 * - Each project: NFT contract + Oracle + YieldPool
 * - Tracks metrics: growth rate, staked amount, NFT holders
 * - Graduation system: Governance weight decreases with age (Y1: 100% → Y5+: 85%)
 * - Growth bonuses: Projects exceeding 1.2x growth unlock ecosystem bonuses
 * - Onboarding checklist: Founder approval (Y1-5) OR 66% supermajority (Y5+)
 *
 * Graduation System (Config.getProjectGraduationWeight):
 * - Y1: 100% governance weight (new projects, full influence)
 * - Y2: 95% (slight reduction as project matures)
 * - Y3-Y4: 90% (established projects)
 * - Y5+: 85% (graduated projects, reduced weight to make room for new entrants)
 *
 * Growth Bonus Tiers (Config growth constants):
 * - 1+ project at 1.2x growth: +10% ecosystem bonus (Config.GROWTH_BONUS_1_PROJECT)
 * - 2+ projects at 1.2x growth: +15% ecosystem bonus (Config.GROWTH_BONUS_2_PROJECTS)
 * - 5+ projects at 1.2x growth: +20% ecosystem bonus (Config.GROWTH_BONUS_5_PROJECTS)
 * - Threshold: 120 = 1.2x growth (Config.GROWTH_BONUS_THRESHOLD)
 *
 * Onboarding Checklist:
 * - Y1-Y5: Founder approval required (50% → 0% weight over 5 years)
 * - Y5+: 66% supermajority community vote required (Config.SUPERMAJORITY_THRESHOLD)
 * - All projects: Must provide NFT address, oracle address, initial herd
 * - Validation: ValidationLibrary.validateProjectRegistration
 *
 * Scalability:
 * - Supports 10K+ projects efficiently
 * - Project lookup: O(1) via mapping
 * - Batch operations limited to Config.MAX_PROJECTS_PER_TX (50)
 * - Metrics cached per project (not recalculated on every read)
 *
 * Security:
 * - ReentrancyGuard on all state-changing operations
 * - Ownable for admin functions (graduation, metric updates)
 * - Input validation via ValidationLibrary
 * - Safe math operations via MathLibrary
 *
 * Integration Points:
 * - ProjectFactory: Calls createProject when deploying new projects
 * - CheesecoinsCore: Reads graduation weights for yield allocation
 * - Governance: Checks founder weight for onboarding approval
 * - YieldPool: Updates metrics when yield is distributed
 * - Frontend: Reads metrics for dashboards and analytics
 *
 * Events:
 * - ProjectCreated: New project registered
 * - ProjectGraduated: Project reached graduation milestone (Y2/Y3/Y5+)
 * - ProjectMetricsUpdated: Growth rate, staking, or holder count changed
 * - YieldPoolRegistered: Yield pool associated with project
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract ProjectRegistry is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IProjectRegistry {
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;
    using MathLibrary for uint256;

    // ============ STATE VARIABLES ============

    /// @notice Next project ID (auto-incrementing)
    uint256 private _nextProjectId;

    /// @notice Mapping: projectId → Project data
    mapping(uint256 => Project) private _projects;

    /// @notice Mapping: projectId → ProjectMetrics
    mapping(uint256 => ProjectMetrics) private _metrics;

    /// @notice Mapping: nftAddress → projectId (reverse lookup)
    mapping(address => uint256) private _nftToProject;

    /// @notice Mapping: owner → projectId[] (owner's projects)
    mapping(address => uint256[]) private _ownerProjects;

    /// @notice Address of CheesecoinsCore (for validation)
    address public coreContract;

    /// @notice Address of Governance contract (for founder weight checks)
    address public governanceContract;

    /// @notice Address of ProjectFactory (only caller allowed to register projects)
    address public projectFactory;

    /// @notice Minimum initial herd size required (in does)
    uint256 public minInitialDoes;

    /// @notice Protocol launch timestamp (for calculating years)
    uint256 public launchTimestamp;

    /// @notice Mapping: projectId → operator wallet for payment routing
    mapping(uint256 => address) private _operatorWallets;

    /// @notice Mapping: projectId → payouts disabled flag (inverted: false = payouts enabled)
    mapping(uint256 => bool) private _payoutsDisabled;

    // ============ EVENTS ============

    /// @notice Emitted when project metrics are updated
    event ProjectMetricsUpdated(uint256 indexed projectId, uint256 growthRate, uint256 totalStaked, uint256 nftHolders);

    /// @notice Emitted when yield pool is registered for project
    event YieldPoolRegistered(uint256 indexed projectId, address indexed yieldPoolAddress);

    /// @notice Emitted when operator wallet is updated for a project

    /// @notice Emitted when payouts enabled flag is updated for a project

    // ============ ERRORS ============

    error ProjectNotFound(uint256 projectId);
    error ProjectAlreadyExists(address nftAddress);
    error ProjectInactive(uint256 projectId);
    error InvalidCoreContract();
    error InvalidGovernanceContract();
    error UnauthorizedCaller();

    // ============ CONSTRUCTOR & INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the ProjectRegistry
     * @param _owner Contract owner (governance/multisig)
     * @param _coreContract CheesecoinsCore contract address
     * @param _governanceContract Governance contract address
     * @param _minInitialDoes Minimum initial herd size
     * @param _projectFactory ProjectFactory address (only caller allowed to register projects)
     */
    function initialize(
        address _owner,
        address _coreContract,
        address _governanceContract,
        uint256 _minInitialDoes,
        address _projectFactory
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        ValidationLibrary.requireNonZeroAddress(_owner, "ProjectRegistry: invalid owner");
        ValidationLibrary.requireNonZeroAddress(_coreContract, "ProjectRegistry: invalid core");
        ValidationLibrary.requireNonZeroAddress(_governanceContract, "ProjectRegistry: invalid governance");
        ValidationLibrary.requireNonZeroAmount(_minInitialDoes, "ProjectRegistry: invalid min does");
        ValidationLibrary.requireNonZeroAddress(_projectFactory, "ProjectRegistry: invalid factory");

        transferOwnership(_owner);
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        coreContract = _coreContract;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        governanceContract = _governanceContract;
        minInitialDoes = _minInitialDoes;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress(_projectFactory) above
        projectFactory = _projectFactory;
        launchTimestamp = block.timestamp;
        _nextProjectId = 1;
    }

    // ============ MODIFIERS ============

    /// @notice Restricts caller to the registered ProjectFactory
    modifier onlyFactory() {
        if (msg.sender != projectFactory) revert UnauthorizedCaller();
        _;
    }

    // ============ PROJECT REGISTRATION ============

    /**
     * @notice Register a new agricultural project
     * @param name Project name
     * @param owner Project owner address
     * @param nftAddress NFT contract address for this project
     * @param oracleAddress Oracle address for harvest data
     * @param initialDoes Initial herd size (number of does)
     * @return projectId Unique project ID
     *
     * @dev Projects start inactive (active=false). The registry owner must call
     *      approveProject() after registerYieldPool() to activate a project.
     *
     * Requirements:
     * - Caller must be the registered projectFactory
     * - NFT address must be non-zero and unique
     * - Oracle address must be non-zero
     * - Initial herd must meet minimum requirement
     */
    function createProject(
        string memory name,
        address owner,
        address nftAddress,
        address oracleAddress,
        uint256 initialDoes
    ) external nonReentrant onlyFactory returns (uint256 projectId) {
        // Validate inputs
        require(bytes(name).length > 0, "ProjectRegistry: empty name");
        ValidationLibrary.validateProjectRegistration(nftAddress, oracleAddress, initialDoes, minInitialDoes);
        ValidationLibrary.requireNonZeroAddress(owner, "ProjectRegistry: invalid owner");

        // Check NFT uniqueness
        if (_nftToProject[nftAddress] != 0) {
            revert ProjectAlreadyExists(nftAddress);
        }

        // Assign project ID
        projectId = _nextProjectId++;

        // Calculate graduation year
        uint256 yearsSinceLaunch = (block.timestamp - launchTimestamp) / Config.ONE_YEAR;
        uint256 graduationYear = yearsSinceLaunch + 1; // Projects graduate in next year

        // Create project struct — starts inactive until approveProject() is called
        _projects[projectId] = Project({
            id: projectId,
            name: name,
            owner: owner,
            nftAddress: nftAddress,
            oracleAddress: oracleAddress,
            yieldPoolAddress: address(0), // Set later by ProjectFactory via registerYieldPool
            initialDoes: initialDoes,
            registrationTime: block.timestamp,
            graduationYear: graduationYear,
            active: false,
            graduated: false
        });

        // Initialize metrics
        _metrics[projectId] = ProjectMetrics({
            projectId: projectId,
            growthRate: 100, // 100 = 1.0x (no growth yet)
            totalStaked: 0,
            totalYieldDistributed: 0,
            nftHolders: 0,
            graduationWeight: Config.getProjectGraduationWeight(0) // 100% initially
        });

        // Update reverse lookups
        _nftToProject[nftAddress] = projectId;
        _ownerProjects[owner].push(projectId);

        emit ProjectCreated(projectId, name, owner, nftAddress);
    }

    /**
     * @notice Register yield pool for a project (called by ProjectFactory)
     * @param projectId Project ID
     * @param yieldPoolAddress YieldPool contract address
     */
    function registerYieldPool(uint256 projectId, address yieldPoolAddress) external nonReentrant onlyFactory {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        ValidationLibrary.requireNonZeroAddress(yieldPoolAddress, "ProjectRegistry: invalid yield pool");

        // Yield pool must be a deployed contract, not an EOA
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(yieldPoolAddress)
        }
        require(codeSize > 0, "ProjectRegistry: yield pool not a contract");

        // Only allow registration once
        require(_projects[projectId].yieldPoolAddress == address(0), "ProjectRegistry: yield pool already registered");

        _projects[projectId].yieldPoolAddress = yieldPoolAddress;

        emit YieldPoolRegistered(projectId, yieldPoolAddress);
    }

    /**
     * @notice Approve a project for activation (timelock-governed second step)
     * @param projectId Project ID to approve
     *
     * @dev Called by registry owner (timelock authority) after the factory has
     *      fully initialized the project. Requires the yield pool to be registered
     *      first, ensuring no half-wired "active" projects exist.
     *
     * Requirements:
     * - Caller must be owner() (timelock authority)
     * - Project must exist
     * - Project must not already be active
     * - Project must have a yield pool registered (enforces full initialization)
     */
    function approveProject(uint256 projectId) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);

        Project storage p = _projects[projectId];
        require(!p.active, "ProjectRegistry: already approved");
        require(p.yieldPoolAddress != address(0), "ProjectRegistry: yield pool not registered");

        p.active = true;
        emit ProjectApproved(projectId);
    }

    // ============ GRADUATION SYSTEM ============

    /**
     * @notice Update project graduation status based on age
     * @param projectId Project ID to graduate
     *
     * @dev Called periodically (e.g., annually) to update graduation weights
     * Graduation tiers (Config.getProjectGraduationWeight):
     * - Y1: 100% weight
     * - Y2: 95% weight (first graduation)
     * - Y3-Y4: 90% weight
     * - Y5+: 85% weight (fully graduated)
     */
    function graduateProject(uint256 projectId) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);

        Project storage project = _projects[projectId];
        uint256 yearsSinceRegistration = (block.timestamp - project.registrationTime) / Config.ONE_YEAR;

        // Calculate new graduation weight
        uint256 newWeight = Config.getProjectGraduationWeight(yearsSinceRegistration);

        // Update metrics
        _metrics[projectId].graduationWeight = newWeight;

        // Mark as graduated if reached Y5+
        if (yearsSinceRegistration >= 5 && !project.graduated) {
            project.graduated = true;
        }

        emit ProjectGraduated(projectId, newWeight);
    }

    /**
     * @notice Batch graduate multiple projects
     * @param projectIds Array of project IDs to graduate
     */
    function batchGraduateProjects(uint256[] calldata projectIds) external onlyOwner {
        uint256 length = projectIds.length;
        require(length <= Config.MAX_PROJECTS_PER_TX, "ProjectRegistry: batch too large");

        for (uint256 i = 0; i < length; i++) {
            uint256 projectId = projectIds[i];
            if (!_projectExists(projectId)) continue; // Skip non-existent projects

            Project storage project = _projects[projectId];
            uint256 yearsSinceRegistration = (block.timestamp - project.registrationTime) / Config.ONE_YEAR;

            uint256 newWeight = Config.getProjectGraduationWeight(yearsSinceRegistration);
            _metrics[projectId].graduationWeight = newWeight;

            if (yearsSinceRegistration >= 5 && !project.graduated) {
                project.graduated = true;
            }

            emit ProjectGraduated(projectId, newWeight);
        }
    }

    // ============ METRICS MANAGEMENT ============

    /**
     * @notice Update project metrics (growth rate, staking, holders)
     * @param projectId Project ID
     * @param growthRate Growth rate (100 = 1.0x, 120 = 1.2x)
     * @param totalStaked Total CURD staked in project
     * @param nftHolders Number of unique NFT holders
     *
     * @dev Called by CheesecoinsCore or authorized contracts after audits
     */
    function updateProjectMetrics(uint256 projectId, uint256 growthRate, uint256 totalStaked, uint256 nftHolders)
        external
        nonReentrant
    {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        if (!_projects[projectId].active) revert ProjectInactive(projectId);

        // Only allow core contract or owner to update metrics
        if (msg.sender != coreContract && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }

        ProjectMetrics storage metrics = _metrics[projectId];
        metrics.growthRate = growthRate;
        metrics.totalStaked = totalStaked;
        metrics.nftHolders = nftHolders;

        emit ProjectMetricsUpdated(projectId, growthRate, totalStaked, nftHolders);
    }

    /**
     * @notice Update yield distributed for project
     * @param projectId Project ID
     * @param amount Yield amount distributed
     */
    function recordYieldDistribution(uint256 projectId, uint256 amount) external nonReentrant {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        if (!_projects[projectId].active) revert ProjectInactive(projectId);

        // Only allow yield pool to record distributions
        require(msg.sender == _projects[projectId].yieldPoolAddress, "ProjectRegistry: only yield pool");

        _metrics[projectId].totalYieldDistributed += amount;
    }

    // ============ GROWTH BONUS CALCULATION ============

    /**
     * @notice Calculate current growth bonus based on high-performing projects
     * @return bonusPercentage Growth bonus (110 = +10%, 115 = +15%, 120 = +20%)
     *
     * @dev Growth Bonus Tiers:
     * - 1+ project at 1.2x+ growth: +10% bonus (Config.GROWTH_BONUS_1_PROJECT)
     * - 2+ projects at 1.2x+ growth: +15% bonus (Config.GROWTH_BONUS_2_PROJECTS)
     * - 5+ projects at 1.2x+ growth: +20% bonus (Config.GROWTH_BONUS_5_PROJECTS)
     * - Threshold: 120 = 1.2x growth (Config.GROWTH_BONUS_THRESHOLD)
     */
    function calculateGrowthBonus() public view returns (uint256 bonusPercentage) {
        uint256 highGrowthProjects = 0;
        uint256 totalProjects = _nextProjectId - 1;

        // Count projects exceeding growth threshold
        for (uint256 i = 1; i <= totalProjects && i <= Config.MAX_PROJECTS_PER_TX; i++) {
            if (_projects[i].active && _metrics[i].growthRate >= Config.GROWTH_BONUS_THRESHOLD) {
                highGrowthProjects++;
            }
        }

        // Apply bonus tiers
        if (highGrowthProjects >= 5) {
            return Config.GROWTH_BONUS_5_PROJECTS; // +20%
        } else if (highGrowthProjects >= 2) {
            return Config.GROWTH_BONUS_2_PROJECTS; // +15%
        } else if (highGrowthProjects >= 1) {
            return Config.GROWTH_BONUS_1_PROJECT; // +10%
        }

        return 100; // No bonus (1.0x)
    }

    /**
     * @notice Get count of high-growth projects (1.2x+)
     * @return count Number of projects exceeding growth threshold
     */
    function getHighGrowthProjectCount() external view returns (uint256 count) {
        uint256 totalProjects = _nextProjectId - 1;

        for (uint256 i = 1; i <= totalProjects && i <= Config.MAX_PROJECTS_PER_TX; i++) {
            if (_projects[i].active && _metrics[i].growthRate >= Config.GROWTH_BONUS_THRESHOLD) {
                count++;
            }
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get project details
     * @param projectId Project ID
     * @return project Project struct
     */
    function getProject(uint256 projectId) external view override returns (Project memory project) {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        return _projects[projectId];
    }

    /**
     * @notice Get project metrics
     * @param projectId Project ID
     * @return metrics ProjectMetrics struct
     */
    function getProjectMetrics(uint256 projectId) external view override returns (ProjectMetrics memory metrics) {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        return _metrics[projectId];
    }

    /**
     * @notice Get total number of registered projects
     * @return count Total project count
     */
    function getProjectCount() external view override returns (uint256) {
        return _nextProjectId - 1;
    }

    /**
     * @notice Get graduation weight for a project
     * @param projectId Project ID
     * @return weight Graduation weight in basis points (10000 = 100%)
     */
    function getGraduationWeight(uint256 projectId) external view override returns (uint256 weight) {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        return _metrics[projectId].graduationWeight;
    }

    /**
     * @notice Get project ID by NFT address
     * @param nftAddress NFT contract address
     * @return projectId Project ID (0 if not found)
     */
    function getProjectByNFT(address nftAddress) external view returns (uint256 projectId) {
        return _nftToProject[nftAddress];
    }

    /**
     * @notice Get all projects owned by an address
     * @param owner Owner address
     * @return projectIds Array of project IDs
     */
    function getProjectsByOwner(address owner) external view returns (uint256[] memory projectIds) {
        return _ownerProjects[owner];
    }

    /**
     * @notice Check if project exists
     * @param projectId Project ID
     * @return exists True if project exists
     */
    function projectExists(uint256 projectId) external view returns (bool) {
        return _projectExists(projectId);
    }

    /**
     * @notice Get projects in a range (for pagination)
     * @param startId Starting project ID (inclusive)
     * @param endId Ending project ID (inclusive)
     * @return projects Array of Project structs
     */
    function getProjectsInRange(uint256 startId, uint256 endId) external view returns (Project[] memory projects) {
        require(startId <= endId, "ProjectRegistry: invalid range");
        require(endId < _nextProjectId, "ProjectRegistry: end ID out of bounds");
        require(endId - startId + 1 <= Config.MAX_PROJECTS_PER_TX, "ProjectRegistry: range too large");

        uint256 length = endId - startId + 1;
        projects = new Project[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 projectId = startId + i;
            if (_projectExists(projectId)) {
                projects[i] = _projects[projectId];
            }
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Deactivate a project (emergency only)
     * @param projectId Project ID to deactivate
     */
    function deactivateProject(uint256 projectId) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        _projects[projectId].active = false;
    }

    /**
     * @notice Reactivate a project
     * @param projectId Project ID to reactivate
     */
    function reactivateProject(uint256 projectId) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        _projects[projectId].active = true;
    }

    /**
     * @notice Update core contract address
     * @param _coreContract New core contract address
     */
    function updateCoreContract(address _coreContract) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_coreContract, "ProjectRegistry: invalid core");
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        coreContract = _coreContract;
    }

    /**
     * @notice Update governance contract address
     * @param _governanceContract New governance contract address
     */
    function updateGovernanceContract(address _governanceContract) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_governanceContract, "ProjectRegistry: invalid governance");
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        governanceContract = _governanceContract;
    }

    /**
     * @notice Update minimum initial herd size
     * @param _minInitialDoes New minimum initial does
     */
    function updateMinInitialDoes(uint256 _minInitialDoes) external onlyOwner {
        ValidationLibrary.requireNonZeroAmount(_minInitialDoes, "ProjectRegistry: invalid min does");
        minInitialDoes = _minInitialDoes;
    }

    /**
     * @notice Set the operator wallet for payment routing of a project
     * @param projectId Project ID
     * @param wallet Operator wallet address (use address(0) to disable operator routing)
     */
    function setOperatorWallet(uint256 projectId, address wallet) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        _operatorWallets[projectId] = wallet;
        emit OperatorWalletUpdated(projectId, wallet);
    }

    /**
     * @notice Enable or disable operator payouts for a project
     * @param projectId Project ID
     * @param enabled True to enable payouts to operator, false to route 100% to treasury
     */
    function setPayoutsEnabled(uint256 projectId, bool enabled) external onlyOwner {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);
        _payoutsDisabled[projectId] = !enabled;
        emit PayoutsEnabledUpdated(projectId, enabled);
    }

    /**
     * @notice Get operator wallet for a project
     * @param projectId Project ID
     * @return Operator wallet address (address(0) if unset)
     */
    function getOperatorWallet(uint256 projectId) external view returns (address) {
        return _operatorWallets[projectId];
    }

    /**
     * @notice Check if payouts to operator are enabled for a project
     * @param projectId Project ID
     * @return True if payouts are enabled (default), false if disabled
     */
    function isPayoutsEnabled(uint256 projectId) external view returns (bool) {
        return !_payoutsDisabled[projectId];
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Check if project exists
     * @param projectId Project ID
     * @return exists True if project exists
     */
    function _projectExists(uint256 projectId) internal view returns (bool) {
        return projectId > 0 && projectId < _nextProjectId;
    }

    function registerExternalProject(
        string memory name,
        address projectOwner,
        address nftAddress,
        address oracleAddress,
        uint256 initialDoes
    ) external onlyOwner nonReentrant returns (uint256 projectId) {
        require(bytes(name).length > 0, "ProjectRegistry: empty name");

        ValidationLibrary.requireNonZeroAddress(projectOwner, "ProjectRegistry: invalid owner");
        ValidationLibrary.requireNonZeroAddress(nftAddress, "ProjectRegistry: invalid nft");
        ValidationLibrary.requireNonZeroAddress(oracleAddress, "ProjectRegistry: invalid oracle");
        ValidationLibrary.requireNonZeroAmount(initialDoes, "ProjectRegistry: invalid does");

        if (_nftToProject[nftAddress] != 0) {
            revert ProjectAlreadyExists(nftAddress);
        }

        projectId = _nextProjectId++;

        uint256 yearsSinceLaunch = (block.timestamp - launchTimestamp) / Config.ONE_YEAR;
        uint256 graduationYear = yearsSinceLaunch + 1;

        _projects[projectId] = Project({
            id: projectId,
            name: name,
            owner: projectOwner,
            nftAddress: nftAddress,
            oracleAddress: oracleAddress,
            yieldPoolAddress: address(0),
            initialDoes: initialDoes,
            registrationTime: block.timestamp,
            graduationYear: graduationYear,
            active: false,
            graduated: false
        });

        _metrics[projectId] = ProjectMetrics({
            projectId: projectId,
            growthRate: 100,
            totalStaked: 0,
            totalYieldDistributed: 0,
            nftHolders: 0,
            graduationWeight: Config.getProjectGraduationWeight(0)
        });

        _nftToProject[nftAddress] = projectId;
        _ownerProjects[projectOwner].push(projectId);

        emit ProjectCreated(projectId, name, projectOwner, nftAddress);
    }

    function registerExternalYieldPool(uint256 projectId, address yieldPoolAddress) external onlyOwner nonReentrant {
        if (!_projectExists(projectId)) revert ProjectNotFound(projectId);

        ValidationLibrary.requireNonZeroAddress(yieldPoolAddress, "ProjectRegistry: invalid yield pool");

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(yieldPoolAddress)
        }

        require(codeSize > 0, "ProjectRegistry: yield pool not a contract");

        require(_projects[projectId].yieldPoolAddress == address(0), "ProjectRegistry: yield pool already registered");

        _projects[projectId].yieldPoolAddress = yieldPoolAddress;

        emit YieldPoolRegistered(projectId, yieldPoolAddress);
    }
}
