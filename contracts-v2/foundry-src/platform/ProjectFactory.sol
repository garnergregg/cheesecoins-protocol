// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../Config.sol";
import "../libraries/ValidationLibrary.sol";
import "../libraries/MathLibrary.sol";
import "./interfaces/IProjectRegistry.sol";
import "../staking/interfaces/IYieldPool.sol";
import "../nft/interfaces/INFT.sol";
import "../core/interfaces/ICheesecoinsCore.sol";
import "../nft/TransferHookRouter.sol";

/**
 * @dev NFT class determines which transfer hooks are wired at deployment time.
 *
 *  CAPEX_GROWTH  — Long-term asset financing. Scene-based collection.
 *                  Hooks: SceneTracker (Super Holder eligibility) + StakingManager (yield).
 *
 *  INPUT_COST    — Seasonal operating credit. Certificate-based, renewable each season.
 *                  Hooks: StakingManager only. No governance / Super Holder path.
 *
 *  INNOVATION    — Fixed-term R&D / special project credit. Non-renewable.
 *                  Hooks: StakingManager only. No governance / Super Holder path.
 */
enum NFTClass {
    CAPEX_GROWTH,
    INPUT_COST,
    INNOVATION
}

/**
 * @title ProjectFactory
 * @notice Gas-efficient factory for deploying new agricultural projects
 * @dev Production-grade factory using EIP-1167 minimal proxy pattern
 *
 * Architecture:
 * - Factory pattern: Deploy new project NFTs and yield pools
 * - Clone/Proxy pattern: EIP-1167 minimal proxies for gas efficiency
 * - Template management: Approved NFT implementations (upgradeable)
 * - Automatic registration: Auto-register with ProjectRegistry
 * - Integrated deployment: NFT + YieldPool + Registry in one transaction
 *
 * EIP-1167 Minimal Proxy (Clone) Pattern:
 * - Deploys ultra-lightweight proxy contracts (only 45 bytes of bytecode)
 * - Each proxy delegates all calls to a template implementation
 * - Reduces deployment gas cost by ~10x compared to full contract deployment
 * - Template contracts are deployed once, cloned thousands of times
 * - Perfect for multi-tenant systems with 10K+ identical contract instances
 *
 * Gas Efficiency:
 * - Full NFT deployment: ~2M gas per project
 * - Minimal proxy deployment: ~200K gas per project (10x savings!)
 * - At 10K projects: Save 18B gas = ~$54M at 30 gwei & $3000 ETH
 *
 * Deployment Flow:
 * 1. Admin approves NFT template implementation → approveTemplate()
 * 2. User calls createProject(name, nftTemplate, oracleAddress, initialDoes)
 * 3. Factory clones NFT template using ClonesUpgradeable.clone()
 * 4. Factory clones YieldPool template
 * 5. Factory initializes NFT with project-specific data
 * 6. Factory initializes YieldPool with project ID
 * 7. Factory registers project with ProjectRegistry
 * 8. Factory returns (projectId, nftAddress, yieldPoolAddress)
 *
 * Template Management:
 * - Admin can approve new NFT implementations
 * - Each template has a unique ID for easy selection
 * - Templates must be initialized properly (no constructor, use initialize())
 * - Templates are shared across all projects (never modified after deployment)
 *
 * Security:
 * - ReentrancyGuard on all state-changing operations
 * - Ownable for admin functions (template approval)
 * - Input validation via ValidationLibrary
 * - Safe math operations via MathLibrary
 * - Template whitelist prevents malicious implementations
 * - Clone pattern prevents storage collision (each clone has independent storage)
 *
 * Integration Points:
 * - ProjectRegistry: Registers newly deployed projects
 * - CheesecoinsCore: Links projects to core token contract
 * - NFT Templates: ERC721 implementations with project-specific logic
 * - YieldPool Template: Yield distribution contract template
 * - Frontend: UI for project creation with template selection
 *
 * Scalability:
 * - Supports 10K+ project deployments efficiently
 * - Each project deployment: O(1) operations
 * - Template storage: O(1) lookup via mapping
 * - No iteration over large arrays (gas-efficient at scale)
 *
 * Events:
 * - ProjectDeployed: New project deployed (NFT + YieldPool)
 * - TemplateApproved: New NFT template approved for use
 * - TemplateDeprecated: Template removed from active use
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract ProjectFactory is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;
    using MathLibrary for uint256;
    using ClonesUpgradeable for address;

    // ============ STATE VARIABLES ============

    /// @notice ProjectRegistry contract address
    address public projectRegistry;

    /// @notice CheesecoinsCore contract address
    address public coreContract;

    /// @notice YieldPool template address (for cloning)
    address public yieldPoolTemplate;

    /// @notice Mapping: templateId → NFT template address
    mapping(uint256 => address) public nftTemplates;

    /// @notice Mapping: template address → approved status
    mapping(address => bool) public approvedTemplates;

    /// @notice Next template ID (auto-incrementing)
    uint256 private _nextTemplateId;

    /// @notice Total projects deployed via this factory
    uint256 public totalProjectsDeployed;

    /// @notice Mapping: projectId → deployed NFT address (for tracking)
    mapping(uint256 => address) public deployedNFTs;

    /// @notice Mapping: projectId → deployed YieldPool address (for tracking)
    mapping(uint256 => address) public deployedYieldPools;

    /// @notice SceneTracker hook address wired into Capex project TransferHookRouters.
    /// @dev Set once at initialize(); no mutable admin setter.
    address public sceneTracker;

    /// @notice StakingManager hook address wired into all project TransferHookRouters.
    /// @dev Set once at initialize(); no mutable admin setter.
    address public stakingManager;

    /// @notice Maps templateId → NFTClass for class-aware hook wiring.
    mapping(uint256 => NFTClass) public templateClassOf;

    // ============ EVENTS ============

    /// @notice Emitted when new project is deployed
    event ProjectDeployed(
        uint256 indexed projectId,
        address indexed owner,
        address nftAddress,
        address yieldPoolAddress,
        uint256 templateId
    );

    /// @notice Emitted when NFT template is approved
    event TemplateApproved(uint256 indexed templateId, address indexed templateAddress, string description);

    /// @notice Emitted when template is deprecated
    event TemplateDeprecated(uint256 indexed templateId);

    /// @notice Emitted when YieldPool template is updated
    event YieldPoolTemplateUpdated(address indexed oldTemplate, address indexed newTemplate);

    // ============ ERRORS ============

    error InvalidRegistry();
    error InvalidCoreContract();
    error InvalidTemplate();
    error TemplateNotApproved(uint256 templateId);
    error TemplateAlreadyApproved(address templateAddress);
    error DeploymentFailed();
    error InitializationFailed();
    error RegistrationFailed();

    // ============ CONSTRUCTOR & INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the ProjectFactory
     * @param _owner Contract owner (governance/multisig)
     * @param _projectRegistry ProjectRegistry contract address
     * @param _coreContract CheesecoinsCore contract address
     * @param _yieldPoolTemplate YieldPool template for cloning
     * @param _sceneTracker SceneTracker hook wired into every new project's router
     * @param _stakingManager StakingManager hook wired into every new project's router
     */
    function initialize(
        address _owner,
        address _projectRegistry,
        address _coreContract,
        address _yieldPoolTemplate,
        address _sceneTracker,
        address _stakingManager
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        ValidationLibrary.requireNonZeroAddress(_owner, "ProjectFactory: invalid owner");
        ValidationLibrary.requireNonZeroAddress(_projectRegistry, "ProjectFactory: invalid registry");
        ValidationLibrary.requireNonZeroAddress(_coreContract, "ProjectFactory: invalid core");
        ValidationLibrary.requireNonZeroAddress(_yieldPoolTemplate, "ProjectFactory: invalid template");
        ValidationLibrary.requireNonZeroAddress(_sceneTracker, "ProjectFactory: invalid sceneTracker");
        ValidationLibrary.requireNonZeroAddress(_stakingManager, "ProjectFactory: invalid stakingManager");

        transferOwnership(_owner);
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        projectRegistry = _projectRegistry;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        coreContract = _coreContract;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        yieldPoolTemplate = _yieldPoolTemplate;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress(_sceneTracker) above
        sceneTracker = _sceneTracker;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress(_stakingManager) above
        stakingManager = _stakingManager;
        _nextTemplateId = 1;
    }

    // ============ PROJECT DEPLOYMENT ============

    /**
     * @notice Deploy a new agricultural project (NFT + YieldPool)
     * @param name Project name
     * @param templateId NFT template ID to use
     * @param oracleAddress Oracle address for harvest data
     * @param initialDoes Initial herd size (number of does)
     * @return projectId Unique project ID
     * @return nftAddress Deployed NFT contract address
     * @return yieldPoolAddress Deployed YieldPool contract address
     *
     * @dev Deployment Steps:
     * 1. Validate inputs (template approved, oracle valid, etc.)
     * 2. Clone NFT template using EIP-1167 minimal proxy
     * 3. Clone YieldPool template using EIP-1167 minimal proxy
     * 4. Initialize NFT with project-specific data (owner, name, projectId)
     * 5. Initialize YieldPool with projectId and core contract
     * 6. Register project with ProjectRegistry (createProject)
     * 7. Link YieldPool to project in registry (registerYieldPool)
     * 8. Track deployed contracts in factory state
     * 9. Emit ProjectDeployed event
     *
     * Requirements:
     * - Template must be approved
     * - Oracle address must be non-zero
     * - Initial herd must meet minimum requirements
     * - Caller must have onboarding approval (checked in ProjectRegistry)
     */
    function createProject(string memory name, uint256 templateId, address oracleAddress, uint256 initialDoes)
        external
        nonReentrant
        returns (uint256 projectId, address nftAddress, address yieldPoolAddress)
    {
        // Validate inputs
        require(bytes(name).length > 0, "ProjectFactory: empty name");
        ValidationLibrary.requireNonZeroAddress(oracleAddress, "ProjectFactory: invalid oracle");
        ValidationLibrary.requireNonZeroAmount(initialDoes, "ProjectFactory: invalid initial does");

        // Get NFT template
        address nftTemplate = nftTemplates[templateId];
        if (nftTemplate == address(0)) revert TemplateNotApproved(templateId);
        if (!approvedTemplates[nftTemplate]) revert TemplateNotApproved(templateId);

        // Step 1: Clone NFT contract using EIP-1167 minimal proxy
        nftAddress = _cloneNFTContract(nftTemplate);
        if (nftAddress == address(0)) revert DeploymentFailed();

        // Step 2: Clone YieldPool contract using EIP-1167 minimal proxy
        yieldPoolAddress = _cloneYieldPool();
        if (yieldPoolAddress == address(0)) revert DeploymentFailed();

        // Step 3: Register project with ProjectRegistry (this assigns projectId)
        projectId = _registerProject(name, msg.sender, nftAddress, oracleAddress, initialDoes);

        // Step 4: Initialize NFT contract with project-specific data and wire its transfer-hook
        // router atomically in the same tx.
        _initializeNFT(nftAddress, projectId, name, msg.sender);

        // Step 5: Initialize YieldPool with projectId
        _initializeYieldPool(yieldPoolAddress, projectId);

        // Step 6: Link YieldPool to project in registry
        IProjectRegistry(projectRegistry).registerYieldPool(projectId, yieldPoolAddress);

        // Step 7: Track deployed contracts
        deployedNFTs[projectId] = nftAddress;
        deployedYieldPools[projectId] = yieldPoolAddress;
        totalProjectsDeployed++;

        emit ProjectDeployed(projectId, msg.sender, nftAddress, yieldPoolAddress, templateId);
    }

    /**
     * @notice Batch deploy multiple projects (gas-efficient for initial setup)
     * @param names Array of project names
     * @param templateIds Array of NFT template IDs
     * @param oracleAddresses Array of oracle addresses
     * @param initialDoesArray Array of initial herd sizes
     * @return projectIds Array of project IDs
     * @return nftAddresses Array of NFT contract addresses
     * @return yieldPoolAddresses Array of YieldPool contract addresses
     *
     * @dev Limited to Config.MAX_PROJECTS_PER_TX (50) to prevent gas limit issues
     */
    function batchCreateProjects(
        string[] memory names,
        uint256[] memory templateIds,
        address[] memory oracleAddresses,
        uint256[] memory initialDoesArray
    )
        external
        nonReentrant
        returns (uint256[] memory projectIds, address[] memory nftAddresses, address[] memory yieldPoolAddresses)
    {
        uint256 length = names.length;
        require(length > 0, "ProjectFactory: empty arrays");
        require(length <= Config.MAX_PROJECTS_PER_TX, "ProjectFactory: batch too large");
        ValidationLibrary.requireEqualLength(length, templateIds.length, "ProjectFactory: length mismatch");
        ValidationLibrary.requireEqualLength(length, oracleAddresses.length, "ProjectFactory: length mismatch");
        ValidationLibrary.requireEqualLength(length, initialDoesArray.length, "ProjectFactory: length mismatch");

        projectIds = new uint256[](length);
        nftAddresses = new address[](length);
        yieldPoolAddresses = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            // slither-disable-next-line calls-loop -- bounded by Config.MAX_PROJECTS_PER_TX; governance-gated batch operation
            (projectIds[i], nftAddresses[i], yieldPoolAddresses[i]) =
                this.createProject(names[i], templateIds[i], oracleAddresses[i], initialDoesArray[i]);
        }
    }

    // ============ TEMPLATE MANAGEMENT ============

    /**
     * @notice Approve a new NFT template for use, specifying its NFT class.
     * @param templateAddress NFT template contract address
     * @param description     Human-readable description of template
     * @param nftClass        NFT class (CAPEX_GROWTH, INPUT_COST, or INNOVATION)
     * @return templateId Template ID assigned
     */
    function approveTemplate(address templateAddress, string memory description, NFTClass nftClass)
        external
        onlyOwner
        returns (uint256 templateId)
    {
        templateId = _approveTemplate(templateAddress, description);
        templateClassOf[templateId] = nftClass;
    }

    /**
     * @notice Approve a new NFT template for use (legacy — no class; defaults to CAPEX_GROWTH).
     * @param templateAddress NFT template contract address
     * @param description Human-readable description of template
     * @return templateId Template ID assigned
     *
     * @dev Requirements:
     * - Template must be a valid contract address
     * - Template must not already be approved
     * - Template must implement required interfaces (INFT)
     * - Template must be initialized properly (no constructor logic)
     */
    function approveTemplate(address templateAddress, string memory description)
        external
        onlyOwner
        returns (uint256 templateId)
    {
        templateId = _approveTemplate(templateAddress, description);
        // Defaults to CAPEX_GROWTH (enum value 0) — matches legacy ProjectNFTTemplate behaviour.
    }

    function _approveTemplate(address templateAddress, string memory description)
        internal
        returns (uint256 templateId)
    {
        ValidationLibrary.requireNonZeroAddress(templateAddress, "ProjectFactory: invalid template");
        require(bytes(description).length > 0, "ProjectFactory: empty description");

        if (approvedTemplates[templateAddress]) {
            revert TemplateAlreadyApproved(templateAddress);
        }

        // Lightweight compatibility check: template must have deployed code and expose
        // getProjectId() (part of INFT interface).  A freshly deployed un-initialized
        // clone would return 0; that is acceptable — the factory initializes it.
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(templateAddress)
        }
        if (codeSize == 0) revert InvalidTemplate();

        // Probe getProjectId() — must not revert on the implementation (returns 0 pre-init).
        // slither-disable-next-line low-level-calls -- safe probe via staticcall; reverts if probe fails; template validated
        (bool probeOk,) = templateAddress.staticcall(abi.encodeWithSignature("getProjectId()"));
        if (!probeOk) revert InvalidTemplate();

        // Assign template ID
        templateId = _nextTemplateId++;

        // Store template mapping
        nftTemplates[templateId] = templateAddress;
        approvedTemplates[templateAddress] = true;

        emit TemplateApproved(templateId, templateAddress, description);
    }

    // ============ CLASS-SPECIFIC PROJECT CREATION ============

    /**
     * @notice Deploy a Capex / Growth class project (scene-based, governance-eligible).
     * @param name           Collection name (e.g. "Sunrise Dairy")
     * @param templateId     Approved CapexNFTTemplate templateId
     * @param totalScenes    Number of unique scenes (e.g. 100)
     * @param copiesPerScene Max copies per scene (e.g. 500)
     * @param baseURI        IPFS base URI for metadata
     * @param oracleAddress  Harvest oracle address
     * @return projectId       Assigned project ID
     * @return nftAddress      Deployed NFT clone address
     * @return yieldPoolAddress Deployed YieldPool clone address
     *
     * @dev Hooks wired: [sceneTracker, stakingManager] (full governance path)
     */
    function createCapexProject(
        string memory name,
        uint256 templateId,
        uint16 totalScenes,
        uint256 copiesPerScene,
        string memory baseURI,
        address oracleAddress
    ) external nonReentrant returns (uint256 projectId, address nftAddress, address yieldPoolAddress) {
        require(bytes(name).length > 0, "ProjectFactory: empty name");
        ValidationLibrary.requireNonZeroAddress(oracleAddress, "ProjectFactory: invalid oracle");
        require(totalScenes > 0 && copiesPerScene > 0, "ProjectFactory: invalid scene config");

        address nftTemplate = _validatedTemplate(templateId, NFTClass.CAPEX_GROWTH);

        nftAddress = nftTemplate.clone();
        yieldPoolAddress = yieldPoolTemplate.clone();

        // Register first so projectId is known before NFT init
        projectId = _registerProjectSimple(name, msg.sender, nftAddress, oracleAddress);

        // Initialize CapexNFTTemplate — full signature
        bytes memory initData = abi.encodeWithSignature(
            "initialize(uint256,string,string,uint16,uint256,string,address)",
            projectId,
            name,
            _projectSymbol(projectId),
            totalScenes,
            copiesPerScene,
            baseURI,
            address(this)
        );
        _initializeNFTWithClass(nftAddress, initData, NFTClass.CAPEX_GROWTH);

        _initializeYieldPool(yieldPoolAddress, projectId);
        IProjectRegistry(projectRegistry).registerYieldPool(projectId, yieldPoolAddress);

        deployedNFTs[projectId] = nftAddress;
        deployedYieldPools[projectId] = yieldPoolAddress;
        totalProjectsDeployed++;

        emit ProjectDeployed(projectId, msg.sender, nftAddress, yieldPoolAddress, templateId);
    }

    /**
     * @notice Deploy an Input Cost / Seasonal Credit class project (certificate-based, renewable).
     * @param name               Collection name (e.g. "Green Valley Spring Feed 2026")
     * @param templateId         Approved InputCostNFTTemplate templateId
     * @param maxSupply          Maximum certificates to issue this season
     * @param creditValuePerToken CURD value each certificate represents (18 dec, informational)
     * @param season             Human-readable season label (e.g. "Spring 2026")
     * @param seasonExpiry       Unix timestamp when this season ends
     * @param baseURI            IPFS base URI for metadata
     * @param oracleAddress      Harvest oracle address
     * @return projectId       Assigned project ID
     * @return nftAddress      Deployed NFT clone address
     * @return yieldPoolAddress Deployed YieldPool clone address
     *
     * @dev Hooks wired: [stakingManager] only — no governance path.
     */
    function createInputCostProject(
        string memory name,
        uint256 templateId,
        uint256 maxSupply,
        uint256 creditValuePerToken,
        string memory season,
        uint256 seasonExpiry,
        string memory baseURI,
        address oracleAddress
    ) external nonReentrant returns (uint256 projectId, address nftAddress, address yieldPoolAddress) {
        require(bytes(name).length > 0, "ProjectFactory: empty name");
        ValidationLibrary.requireNonZeroAddress(oracleAddress, "ProjectFactory: invalid oracle");
        require(maxSupply > 0, "ProjectFactory: zero supply");
        require(seasonExpiry > block.timestamp, "ProjectFactory: expiry in past");

        address nftTemplate = _validatedTemplate(templateId, NFTClass.INPUT_COST);

        nftAddress = nftTemplate.clone();
        yieldPoolAddress = yieldPoolTemplate.clone();

        projectId = _registerProjectSimple(name, msg.sender, nftAddress, oracleAddress);

        bytes memory initData = abi.encodeWithSignature(
            "initialize(uint256,string,string,uint256,uint256,string,uint256,string,address)",
            projectId,
            name,
            _projectSymbol(projectId),
            maxSupply,
            creditValuePerToken,
            season,
            seasonExpiry,
            baseURI,
            address(this)
        );
        _initializeNFTWithClass(nftAddress, initData, NFTClass.INPUT_COST);

        _initializeYieldPool(yieldPoolAddress, projectId);
        IProjectRegistry(projectRegistry).registerYieldPool(projectId, yieldPoolAddress);

        deployedNFTs[projectId] = nftAddress;
        deployedYieldPools[projectId] = yieldPoolAddress;
        totalProjectsDeployed++;

        emit ProjectDeployed(projectId, msg.sender, nftAddress, yieldPoolAddress, templateId);
    }

    /**
     * @notice Deploy an Innovation / Special Project class NFT (fixed-term, non-renewable).
     * @param name               Collection name (e.g. "Solar Pilot Q3 2026")
     * @param templateId         Approved InnovationNFTTemplate templateId
     * @param maxSupply          Maximum certificates to issue
     * @param creditValuePerToken CURD value each certificate represents (18 dec, informational)
     * @param projectLabel       Human-readable description of the project
     * @param maturityDate       Unix timestamp when the project term ends (hard, non-renewable)
     * @param baseURI            IPFS base URI for metadata
     * @param oracleAddress      Harvest oracle address
     * @return projectId       Assigned project ID
     * @return nftAddress      Deployed NFT clone address
     * @return yieldPoolAddress Deployed YieldPool clone address
     *
     * @dev Hooks wired: [stakingManager] only — no governance path.
     */
    function createInnovationProject(
        string memory name,
        uint256 templateId,
        uint256 maxSupply,
        uint256 creditValuePerToken,
        string memory projectLabel,
        uint256 maturityDate,
        string memory baseURI,
        address oracleAddress
    ) external nonReentrant returns (uint256 projectId, address nftAddress, address yieldPoolAddress) {
        require(bytes(name).length > 0, "ProjectFactory: empty name");
        ValidationLibrary.requireNonZeroAddress(oracleAddress, "ProjectFactory: invalid oracle");
        require(maxSupply > 0, "ProjectFactory: zero supply");
        require(maturityDate > block.timestamp, "ProjectFactory: maturity in past");

        address nftTemplate = _validatedTemplate(templateId, NFTClass.INNOVATION);

        nftAddress = nftTemplate.clone();
        yieldPoolAddress = yieldPoolTemplate.clone();

        projectId = _registerProjectSimple(name, msg.sender, nftAddress, oracleAddress);

        bytes memory initData = abi.encodeWithSignature(
            "initialize(uint256,string,string,uint256,uint256,string,uint256,string,address)",
            projectId,
            name,
            _projectSymbol(projectId),
            maxSupply,
            creditValuePerToken,
            projectLabel,
            maturityDate,
            baseURI,
            address(this)
        );
        _initializeNFTWithClass(nftAddress, initData, NFTClass.INNOVATION);

        _initializeYieldPool(yieldPoolAddress, projectId);
        IProjectRegistry(projectRegistry).registerYieldPool(projectId, yieldPoolAddress);

        deployedNFTs[projectId] = nftAddress;
        deployedYieldPools[projectId] = yieldPoolAddress;
        totalProjectsDeployed++;

        emit ProjectDeployed(projectId, msg.sender, nftAddress, yieldPoolAddress, templateId);
    }

    /**
     * @notice Deprecate a template (prevent future use)
     * @param templateId Template ID to deprecate
     *
     * @dev Existing projects using this template are not affected
     */
    function deprecateTemplate(uint256 templateId) external onlyOwner {
        address templateAddress = nftTemplates[templateId];
        if (templateAddress == address(0)) revert InvalidTemplate();

        approvedTemplates[templateAddress] = false;

        emit TemplateDeprecated(templateId);
    }

    /**
     * @notice Update YieldPool template
     * @param _yieldPoolTemplate New YieldPool template address
     *
     * @dev Only affects future deployments, existing pools unchanged
     */
    function updateYieldPoolTemplate(address _yieldPoolTemplate) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_yieldPoolTemplate, "ProjectFactory: invalid template");

        address oldTemplate = yieldPoolTemplate;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        yieldPoolTemplate = _yieldPoolTemplate;

        emit YieldPoolTemplateUpdated(oldTemplate, _yieldPoolTemplate);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get NFT template address by ID
     * @param templateId Template ID
     * @return templateAddress NFT template contract address
     */
    function getTemplate(uint256 templateId) external view returns (address templateAddress) {
        return nftTemplates[templateId];
    }

    /**
     * @notice Check if template is approved
     * @param templateAddress Template address to check
     * @return approved True if template is approved
     */
    function isTemplateApproved(address templateAddress) external view returns (bool approved) {
        return approvedTemplates[templateAddress];
    }

    /**
     * @notice Get deployed contracts for a project
     * @param projectId Project ID
     * @return nftAddress NFT contract address
     * @return yieldPoolAddress YieldPool contract address
     */
    function getDeployedContracts(uint256 projectId)
        external
        view
        returns (address nftAddress, address yieldPoolAddress)
    {
        return (deployedNFTs[projectId], deployedYieldPools[projectId]);
    }

    /**
     * @notice Get total number of approved templates
     * @return count Template count
     */
    function getTemplateCount() external view returns (uint256) {
        return _nextTemplateId - 1;
    }

    /**
     * @notice Calculate deployment cost estimate (gas)
     * @return gasEstimate Estimated gas cost for deployment
     *
     * @dev Rough estimate: ~200K gas for minimal proxy deployment
     * Actual cost varies based on initialization complexity
     */
    function estimateDeploymentCost() external pure returns (uint256 gasEstimate) {
        // NFT clone: ~100K gas
        // YieldPool clone: ~100K gas
        // Registry registration: ~50K gas
        // Initialization: ~50K gas
        // Total: ~300K gas (conservative estimate)
        return 300_000;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update ProjectRegistry address
     * @param _projectRegistry New registry address
     */
    function updateProjectRegistry(address _projectRegistry) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_projectRegistry, "ProjectFactory: invalid registry");
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        projectRegistry = _projectRegistry;
    }

    /**
     * @notice Update CheesecoinsCore address
     * @param _coreContract New core contract address
     */
    function updateCoreContract(address _coreContract) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_coreContract, "ProjectFactory: invalid core");
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        coreContract = _coreContract;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Clone NFT contract using EIP-1167 minimal proxy
     * @param template NFT template address
     * @return clone Cloned contract address
     *
     * @dev Uses OpenZeppelin's ClonesUpgradeable library
     * Gas cost: ~45 bytes of bytecode, minimal deployment cost
     */
    function _cloneNFTContract(address template) internal returns (address clone) {
        clone = template.clone();
    }

    /**
     * @notice Clone YieldPool contract using EIP-1167 minimal proxy
     * @return clone Cloned contract address
     */
    function _cloneYieldPool() internal returns (address clone) {
        clone = yieldPoolTemplate.clone();
    }

    /// @dev Returns the validated template address, asserting class matches.
    function _validatedTemplate(uint256 templateId, NFTClass expectedClass)
        internal
        view
        returns (address nftTemplate)
    {
        nftTemplate = nftTemplates[templateId];
        if (nftTemplate == address(0)) revert TemplateNotApproved(templateId);
        if (!approvedTemplates[nftTemplate]) revert TemplateNotApproved(templateId);
        require(templateClassOf[templateId] == expectedClass, "ProjectFactory: class mismatch");
    }

    /// @dev Deterministic symbol for cloned projects.
    function _projectSymbol(uint256 projectId) internal pure returns (string memory) {
        return string(abi.encodePacked("PROJ", Strings.toString(projectId)));
    }

    /// @dev Register without goat-specific initialDoes (used by class-specific creators).
    ///      Passes initialDoes=1 as a harmless non-zero placeholder; registry only needs it
    ///      to be > 0 for internal validation (it is informational, not enforced on-chain).
    function _registerProjectSimple(string memory name, address owner, address nftAddress, address oracleAddress)
        internal
        returns (uint256 projectId)
    {
        try IProjectRegistry(projectRegistry).createProject(name, owner, nftAddress, oracleAddress, 1) returns (
            uint256 id
        ) {
            projectId = id;
        } catch {
            revert RegistrationFailed();
        }
    }

    /**
     * @notice Initialize an NFT clone and wire its TransferHookRouter with class-appropriate hooks.
     * @param nftAddress Freshly cloned NFT contract address
     * @param initData   ABI-encoded initialize() calldata (caller must include address(this) as owner)
     * @param nftClass   NFT class — determines which hooks are wired into the router
     *
     * @dev Hook wiring by class:
     *   CAPEX_GROWTH  → [sceneTracker, stakingManager]  (governance + yield)
     *   INPUT_COST    → [stakingManager]                 (yield only)
     *   INNOVATION    → [stakingManager]                 (yield only)
     *
     *   Ownership of both the router and the NFT is handed to factory.owner() (timelock)
     *   at the end of this call — factory's temporary ownership window is closed atomically.
     */
    function _initializeNFTWithClass(address nftAddress, bytes memory initData, NFTClass nftClass) internal {
        // Step 1: Initialize the NFT clone with factory as temporary owner.
        // slither-disable-next-line low-level-calls -- init of approved template; revert-on-failure
        (bool initOk,) = nftAddress.call(initData);
        if (!initOk) revert InitializationFailed();

        // Step 2: Deploy TransferHookRouter owned by factory.
        TransferHookRouter router = new TransferHookRouter(address(this), nftAddress);

        // Step 3: Wire hooks based on class.
        address[] memory hooks;
        if (nftClass == NFTClass.CAPEX_GROWTH) {
            hooks = new address[](2);
            hooks[0] = sceneTracker;
            hooks[1] = stakingManager;
        } else {
            // INPUT_COST and INNOVATION: StakingManager only.
            hooks = new address[](1);
            hooks[0] = stakingManager;
        }
        router.setHooks(hooks);

        address timelockAuthority = owner();

        // Step 4: Hand router ownership to timelock.
        router.transferOwnership(timelockAuthority);

        // Step 5: Set router as the NFT's transfer hook.
        // slither-disable-next-line low-level-calls -- wiring hook; factory is still NFT owner; revert-on-failure
        (bool hookOk,) = nftAddress.call(abi.encodeWithSignature("setTransferHook(address)", address(router)));
        if (!hookOk) revert InitializationFailed();

        // Step 6: Transfer NFT ownership to timelock. Closes factory's temp ownership window.
        // slither-disable-next-line low-level-calls -- ownership handoff; revert-on-failure
        (bool ownOk,) = nftAddress.call(abi.encodeWithSignature("transferOwnership(address)", timelockAuthority));
        if (!ownOk) revert InitializationFailed();
    }

    /**
     * @notice Register project with ProjectRegistry
     * @param name Project name
     * @param owner Project owner
     * @param nftAddress NFT contract address
     * @param oracleAddress Oracle address
     * @param initialDoes Initial herd size
     * @return projectId Assigned project ID
     */
    function _registerProject(
        string memory name,
        address owner,
        address nftAddress,
        address oracleAddress,
        uint256 initialDoes
    ) internal returns (uint256 projectId) {
        try IProjectRegistry(projectRegistry)
            .createProject(name, owner, nftAddress, oracleAddress, initialDoes) returns (
            uint256 id
        ) {
            projectId = id;
        } catch {
            revert RegistrationFailed();
        }
    }

    /**
     * @notice Initialize NFT contract and wire its TransferHookRouter with canonical hooks,
     *         all in one atomic transaction.
     * @param nftAddress Freshly cloned NFT contract address
     * @param projectId Project ID
     * @param name Project name
     *
     * @dev Six-step atomic sequence — no post-deploy manual config required:
     *
     *   1. Initialize the NFT clone with the factory as temporary owner.
     *      Passing address(this) as owner lets the factory wire the hook before
     *      handing off — the factory is the caller, so no extra privilege is opened.
     *      Symbol is deterministic ("PROJ" + projectId) so no manual input is needed.
     *
     *   2. Deploy a TransferHookRouter owned by the factory (temporary).
     *      Factory ownership lets us call setHooks() without a timelock delay.
     *      The router's nftContract is set to nftAddress at construction (immutable).
     *
     *   3. Wire the canonical hooks in order: [sceneTracker, stakingManager].
     *      Order invariant: SceneTracker must receive beforeNFTTransfer before
     *      StakingManager so scene membership is always recorded before staking gating.
     *
     *   4. Transfer router ownership to factory.owner() (timelock authority).
     *      Future hook changes require timelock governance.
     *
     *   5. Set the router as the NFT's transferHook.
     *      Factory is still the NFT owner at this point, so setTransferHook succeeds.
     *      SceneTracker's NFT-anchored _isAuthorizedCaller() will now accept the router.
     *
     *   6. Transfer NFT ownership to factory.owner() (timelock authority).
     *      Factory's temporary ownership window is closed here — same transaction.
     *
     * Reverts with InitializationFailed() on any failure.
     */
    function _initializeNFT(
        address nftAddress,
        uint256 projectId,
        string memory name,
        address /* projectCreator — intentionally unused; NFT is owned by factory.owner() */
    )
        internal
    {
        // Deterministic symbol: "PROJ" + decimal projectId string (no manual input)
        string memory symbol = string(abi.encodePacked("PROJ", Strings.toString(projectId)));

        address timelockAuthority = owner(); // factory owner = timelock/governance authority

        // Step 1: Initialize the NFT with factory as temporary owner.
        // slither-disable-next-line low-level-calls -- initialization of approved template; revert-on-failure; factory-controlled setup
        (bool initOk,) = nftAddress.call(
            abi.encodeWithSignature("initialize(uint256,string,string,address)", projectId, name, symbol, address(this))
        );
        if (!initOk) revert InitializationFailed();

        // Step 2: Deploy a TransferHookRouter owned by factory (temporary) so we can
        // call setHooks() on it before handing it to the timelock.
        TransferHookRouter router = new TransferHookRouter(address(this), nftAddress);

        // Step 3: Wire the canonical hooks — SceneTracker first, then StakingManager.
        // This order is invariant: scene state is updated before staking gates are checked.
        address[] memory hooks = new address[](2);
        hooks[0] = sceneTracker;
        hooks[1] = stakingManager;
        router.setHooks(hooks);

        // Step 4: Hand router ownership to the timelock authority.
        // Future hook-list changes require governance (timelock) approval.
        router.transferOwnership(timelockAuthority);

        // Step 5: Wire the router as the NFT's transfer hook (factory is still the
        // NFT owner at this point, so setTransferHook succeeds).
        // slither-disable-next-line low-level-calls -- wiring hook during same-tx setup; revert-on-failure; factory still owner
        (bool hookOk,) = nftAddress.call(abi.encodeWithSignature("setTransferHook(address)", address(router)));
        if (!hookOk) revert InitializationFailed();

        // Step 6: Hand off NFT ownership to the timelock authority.
        // Factory's temporary ownership window is closed here — same transaction.
        // slither-disable-next-line low-level-calls -- ownership handoff to timelock authority; revert-on-failure; closes factory window
        (bool ownOk,) = nftAddress.call(abi.encodeWithSignature("transferOwnership(address)", timelockAuthority));
        if (!ownOk) revert InitializationFailed();
    }

    /**
     * @notice Initialize YieldPool with project data
     * @param yieldPoolAddress YieldPool contract address
     * @param projectId Project ID
     *
     * @dev Calls initialize(uint256,address,address,address) on the YieldPool clone.
     *      - projectId:       bound at init, prevents mis-binding to another project
     *      - curdToken:       coreContract (CheesecoinsCore IS the CURD ERC-20)
     *      - cheesecoinsCore: coreContract (authorized depositor)
     *      - owner:           Factory.owner() (timelock authority)
     *      Reverts with InitializationFailed() if the call fails.
     *      Post-init sanity: verifies the pool's projectId matches what we passed.
     */
    function _initializeYieldPool(address yieldPoolAddress, uint256 projectId) internal {
        // coreContract is the CURD ERC-20 token (CheesecoinsCore extends ERC20Upgradeable).
        // Owner is set to factory.owner() (timelock authority), not the project creator.
        // slither-disable-next-line low-level-calls -- init approved pool; revert-on-failure; followed by projectId sanity check
        (bool success,) = yieldPoolAddress.call(
            abi.encodeWithSignature(
                "initialize(uint256,address,address,address)", projectId, coreContract, coreContract, owner()
            )
        );
        if (!success) revert InitializationFailed();

        // Post-init sanity: confirm the pool is bound to the correct project.
        // slither-disable-next-line low-level-calls -- post-init sanity check via staticcall; revert if mismatch
        (bool ok, bytes memory data) = yieldPoolAddress.staticcall(abi.encodeWithSignature("projectId()"));
        if (!ok || abi.decode(data, (uint256)) != projectId) revert InitializationFailed();
    }

    /**
     * @notice Predict address of cloned contract (deterministic)
     * @param template Template address to clone
     * @param salt Salt for deterministic deployment
     * @return predicted Predicted clone address
     *
     * @dev Uses ClonesUpgradeable.predictDeterministicAddress
     * Useful for frontend to pre-compute addresses before deployment
     */
    function predictCloneAddress(address template, bytes32 salt) external view returns (address predicted) {
        return ClonesUpgradeable.predictDeterministicAddress(template, salt, address(this));
    }

    /**
     * @notice Clone contract with deterministic address
     * @param template Template address to clone
     * @param salt Salt for deterministic deployment
     * @return clone Cloned contract address
     *
     * @dev Uses ClonesUpgradeable.cloneDeterministic for CREATE2-style deployment
     * Allows same address across different chains (useful for cross-chain systems)
     */
    function _cloneDeterministic(address template, bytes32 salt) internal returns (address clone) {
        return ClonesUpgradeable.cloneDeterministic(template, salt);
    }
}
