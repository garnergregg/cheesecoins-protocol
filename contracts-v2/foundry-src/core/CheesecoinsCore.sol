// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../Config.sol";
import "../libraries/MathLibrary.sol";
import "../libraries/ValidationLibrary.sol";
import "./interfaces/ICheesecoinsCore.sol";
import "../staking/interfaces/IYieldPool.sol";

/**
 * @notice Minimal interface for the CURD/USD price feed used by CheesecoinsCore
 * @dev price is in 8 decimals (Chainlink USD standard); isStale indicates fallback peg
 */
interface ICurdUsdPriceFeed {
    function viewLatestPrice() external view returns (int256 price, bool isStale);
}

/**
 * @title CheesecoinsCore
 * @notice Core CURD token (Cheesecoins USD-pegged) contract for the ecosystem
 * @dev Implements production-based minting with deflationary mechanics
 *
 * Key Features:
 * - ERC20 with Permit (gasless approvals)
 * - Production-based minting with 2% annual cap
 * - Project registration and management
 * - Annual audit mechanism with growth tracking
 * - Deflationary burn mechanics (Y1→Y10 ramping)
 * - Treasury allocation (40/30/20/10 split)
 * - Comprehensive access control and reentrancy protection
 */
contract CheesecoinsCore is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ICheesecoinsCore
{
    using MathLibrary for uint256;
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;

    // ============ STATE VARIABLES ============

    /// @notice Contract deployment timestamp
    uint256 public deploymentTime;

    /// @notice Total number of registered projects
    uint256 public projectCount;

    /// @notice Mapping of project ID to project data
    mapping(uint256 => ProjectData) public projects;

    /// @notice Mapping of project ID to audit history
    mapping(uint256 => AuditResult[]) public projectAudits;

    /// @notice Total production value across all projects (for deflationary tracking)
    uint256 public totalProductionValue;

    /// @notice Annual minting tracker (resets each year)
    uint256 public currentYearMinted;
    uint256 public lastMintResetTime;
    uint256 public yearStartSupply; // Supply at the start of current mint year

    /// @notice Treasury addresses
    address public treasuryEcosystem;
    address public treasuryFarmers;
    address public treasuryMarketing;
    address public treasuryReserve;

    /// @notice Authorized auditor address
    address public authorizedAuditor;

    /// @notice Authorized minter address (for ecosystem growth)
    address public authorizedMinter;

    /// @notice CURD/USD price feed used for mint conversion (8-decimal oracle)
    address public curdUsdPriceFeed;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserved storage slots to allow adding new state variables without shifting existing ones
     * @dev 49 slots reserved (curdUsdPriceFeed uses 1 slot from the original 50)
     */
    uint256[49] private __gap;

    // ============ MODIFIERS ============

    modifier onlyAuditor() {
        require(msg.sender == authorizedAuditor, "CheesecoinsCore: caller not auditor");
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == authorizedMinter, "CheesecoinsCore: caller not minter");
        _;
    }

    modifier projectExists(uint256 projectId) {
        require(projectId > 0 && projectId <= projectCount, "CheesecoinsCore: invalid project ID");
        require(projects[projectId].active, "CheesecoinsCore: project not active");
        _;
    }

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _treasuryEcosystem Ecosystem development treasury address
     * @param _treasuryFarmers Farmer support treasury address
     * @param _treasuryMarketing Marketing treasury address
     * @param _treasuryReserve Emergency reserve treasury address
     * @param _authorizedAuditor Address authorized to perform audits
     * @param _authorizedMinter Address authorized to mint new tokens
     * @param _curdUsdPriceFeed CURD/USD price feed contract address (8-decimal oracle)
     * @param _founderVestingWallet Address of the founder vesting wallet (receives 20M CURD)
     */
    function initialize(
        address _treasuryEcosystem,
        address _treasuryFarmers,
        address _treasuryMarketing,
        address _treasuryReserve,
        address _authorizedAuditor,
        address _authorizedMinter,
        address _curdUsdPriceFeed,
        address _founderVestingWallet
    ) public initializer {
        __ERC20_init("Cheesecoins CURD", "CURD");
        __ERC20Permit_init("Cheesecoins CURD");
        __Ownable_init();
        __ReentrancyGuard_init();

        // Validate treasury addresses
        ValidationLibrary.requireNonZeroAddress(_treasuryEcosystem, "CheesecoinsCore: invalid ecosystem treasury");
        ValidationLibrary.requireNonZeroAddress(_treasuryFarmers, "CheesecoinsCore: invalid farmers treasury");
        ValidationLibrary.requireNonZeroAddress(_treasuryMarketing, "CheesecoinsCore: invalid marketing treasury");
        ValidationLibrary.requireNonZeroAddress(_treasuryReserve, "CheesecoinsCore: invalid reserve treasury");
        ValidationLibrary.requireNonZeroAddress(_authorizedAuditor, "CheesecoinsCore: invalid auditor");
        ValidationLibrary.requireNonZeroAddress(_authorizedMinter, "CheesecoinsCore: invalid minter");

        // Validate price feed: must be a non-zero contract address
        ValidationLibrary.requireNonZeroAddress(_curdUsdPriceFeed, "CheesecoinsCore: invalid price feed");
        require(_curdUsdPriceFeed.code.length > 0, "CheesecoinsCore: price feed not a contract");

        ValidationLibrary.requireNonZeroAddress(_founderVestingWallet, "CheesecoinsCore: invalid vesting wallet");

        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryEcosystem = _treasuryEcosystem;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryFarmers = _treasuryFarmers;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryMarketing = _treasuryMarketing;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryReserve = _treasuryReserve;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        authorizedAuditor = _authorizedAuditor;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        authorizedMinter = _authorizedMinter;
        curdUsdPriceFeed = _curdUsdPriceFeed;

        deploymentTime = block.timestamp;
        lastMintResetTime = block.timestamp;
        totalProductionValue = 0; // Explicit initialization; updated via authorizedAuditor setter when production data is available

        // Genesis mint split: 180M to treasury ecosystem, 20M to founder vesting wallet
        _mint(_treasuryEcosystem, Config.TREASURY_ALLOCATION);
        _mint(_founderVestingWallet, Config.FOUNDER_ALLOCATION);

        // Set year start supply after initial mint
        yearStartSupply = totalSupply();
    }

    // ============ PROJECT MANAGEMENT ============

    /**
     * @notice Register a new cheese production project
     * @param nftAddress Address of the project's NFT collection
     * @param oracleAddress Address of the production data oracle
     * @param initialDoes Initial number of dairy animals in the project
     * @return projectId Unique identifier for the registered project
     */
    function registerProject(address nftAddress, address oracleAddress, uint256 initialDoes)
        external
        override
        onlyOwner
        returns (uint256 projectId)
    {
        // Validate inputs
        ValidationLibrary.validateProjectRegistration(
            nftAddress,
            oracleAddress,
            initialDoes,
            1 // minimum 1 doe to start
        );

        projectCount++;
        projectId = projectCount;

        projects[projectId] = ProjectData({
            id: projectId,
            nftAddress: nftAddress,
            oracleAddress: oracleAddress,
            initialDoes: initialDoes,
            currentDoes: initialDoes,
            registrationTime: block.timestamp,
            lastAuditTime: block.timestamp,
            totalMinted: 0,
            active: true
        });

        emit ProjectRegistered(projectId, nftAddress, initialDoes);
    }

    /**
     * @notice Get project data
     * @param projectId Project identifier
     * @return Project data struct
     */
    function getProject(uint256 projectId) external view override returns (ProjectData memory) {
        require(projectId > 0 && projectId <= projectCount, "CheesecoinsCore: invalid project ID");
        return projects[projectId];
    }

    /**
     * @notice Get total number of registered projects
     * @return Total project count
     */
    function getProjectCount() external view override returns (uint256) {
        return projectCount;
    }

    // ============ MINTING & BURNING ============

    /**
     * @dev Reset annual mint counter if a year has passed
     * @notice This function checks if it's time to reset the annual mint tracking
     * and updates yearStartSupply to the current supply
     */
    function _resetAnnualMintIfNeeded() internal {
        if (block.timestamp >= lastMintResetTime + Config.ONE_YEAR) {
            currentYearMinted = 0;
            lastMintResetTime = block.timestamp;
            yearStartSupply = totalSupply();
        }
    }

    /**
     * @notice Permanently disabled under Stage 0 monetary enforcement.
     * @dev All minting must flow through MintController → controllerMint.
     *      This legacy annual-cap path is disabled to enforce a single mint surface.
     * @param newProductionValue Ignored — mint path is disabled.
     * @param proof Ignored — mint path is disabled.
     * @return Always reverts; return type preserved for ABI/interface compatibility.
     */
    function mintNewCURDForEcosystemGrowth(uint256 newProductionValue, bytes memory proof)
        external
        override
        onlyMinter
        nonReentrant
        returns (uint256)
    {
        // Stage 0: legacy mint path permanently disabled.
        newProductionValue;
        proof;
        revert("MINT_PATH_DISABLED");
    }

    /**
     * @notice Burn tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external override {
        ValidationLibrary.requireNonZeroAmount(amount, "CheesecoinsCore: zero burn amount");
        _burn(msg.sender, amount);
        emit Burn(msg.sender, amount, "User burn");
    }

    /**
     * @notice Burn tokens from another account (requires allowance)
     * @param account Account to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address account, uint256 amount) external override {
        ValidationLibrary.requireNonZeroAddress(account, "CheesecoinsCore: burn from zero address");
        ValidationLibrary.requireNonZeroAmount(amount, "CheesecoinsCore: zero burn amount");

        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);

        emit Burn(account, amount, "Burn from");
    }

    /**
     * @notice Mint tokens via the authorized controller (MintController)
     * @param to Recipient address
     * @param amount Amount to mint
     * @param reason Human-readable reason for the mint
     * @dev Only callable by the authorizedMinter (MintController). Enforces MAX_SUPPLY.
     */
    function controllerMint(address to, uint256 amount, string calldata reason)
        external
        override
        onlyMinter
        nonReentrant
    {
        ValidationLibrary.requireNonZeroAddress(to, "CheesecoinsCore: mint to zero address");
        ValidationLibrary.requireNonZeroAmount(amount, "CheesecoinsCore: zero mint amount");
        require(totalSupply() + amount <= Config.MAX_SUPPLY, "SUPPLY_CAP_EXCEEDED");

        _resetAnnualMintIfNeeded();
        currentYearMinted += amount;

        _mint(to, amount);
        emit Mint(to, amount, 0, reason);
    }

    // ============ AUDIT FUNCTIONS ============

    /**
     * @notice Perform annual audit on a project
     * @param projectId Project identifier
     * @param actualValue Actual production value achieved
     * @param actualDoes Actual number of dairy animals
     * @param proof Audit verification proof
     * @return Audit result with growth rate and target assessment
     */
    function performAnnualAudit(uint256 projectId, uint256 actualValue, uint256 actualDoes, bytes memory proof)
        external
        override
        onlyAuditor
        projectExists(projectId)
        nonReentrant
        returns (AuditResult memory)
    {
        ProjectData storage project = projects[projectId];

        // Check minimum audit interval
        require(block.timestamp >= project.lastAuditTime + Config.MIN_AUDIT_INTERVAL, "CheesecoinsCore: audit too soon");

        // Calculate expected value based on initial allocation
        uint256 yearsSinceRegistration = (block.timestamp - project.registrationTime) / Config.ONE_YEAR;
        // Note: Using simplified production multiplier - should match oracle data model
        uint256 productionValuePerDoe = 1000 * 1e18; // 1000 units per doe baseline
        uint256 expectedValue = project.initialDoes * productionValuePerDoe;

        // Calculate growth rate using CAGR
        uint256 growthRate = yearsSinceRegistration > 0
            ? MathLibrary.calculateCAGR(project.initialDoes, actualDoes, yearsSinceRegistration)
            : 100; // No growth in first partial year

        // Determine if targets were met (simplified: actual >= expected)
        bool targetsMet = actualValue >= expectedValue && actualDoes >= project.initialDoes;

        // Create audit result
        AuditResult memory result = AuditResult({
            projectId: projectId,
            actualValue: actualValue,
            actualDoes: actualDoes,
            expectedValue: expectedValue,
            growthRate: growthRate,
            timestamp: block.timestamp,
            targetsMet: targetsMet
        });

        // Store audit result
        projectAudits[projectId].push(result);

        // Update project state
        project.currentDoes = actualDoes;
        project.lastAuditTime = block.timestamp;

        // Handle penalties or rewards
        if (!targetsMet) {
            _applyAuditPenalty(projectId, project);
        } else if (growthRate > Config.GROWTH_BONUS_THRESHOLD) {
            _applyAuditReward(project);
        }

        emit AuditCompleted(projectId, actualValue, actualDoes, growthRate, targetsMet);

        return result;
    }

    /**
     * @notice Calculate current growth rate for a project
     * @param projectId Project identifier
     * @return Growth rate as percentage (100 = 1.0x)
     */
    function calculateProjectGrowthRate(uint256 projectId)
        external
        view
        override
        projectExists(projectId)
        returns (uint256)
    {
        ProjectData storage project = projects[projectId];
        uint256 yearsSinceRegistration = (block.timestamp - project.registrationTime) / Config.ONE_YEAR;

        // slither-disable-next-line incorrect-equality -- yearsSinceRegistration == 0 means first year; sentinel not a bucket
        if (yearsSinceRegistration == 0) return 100;

        return MathLibrary.calculateCAGR(project.initialDoes, project.currentDoes, yearsSinceRegistration);
    }

    /**
     * @dev Apply penalty for missing audit targets
     */
    function _applyAuditPenalty(uint256 projectId, ProjectData storage project) private {
        // Burn 5% of project's allocated tokens (simplified: from ecosystem treasury)
        uint256 penaltyAmount = (project.totalMinted * Config.AUDIT_MISS_PENALTY_PERCENT) / 100;

        if (penaltyAmount > 0 && balanceOf(treasuryEcosystem) >= penaltyAmount) {
            _burn(treasuryEcosystem, penaltyAmount);
            emit Burn(treasuryEcosystem, penaltyAmount, "Audit penalty");
        }
    }

    /**
     * @dev Apply reward for exceeding audit targets
     */
    function _applyAuditReward(ProjectData storage project) private {
        // Check if we need to reset annual mint counter
        _resetAnnualMintIfNeeded();

        // Calculate maximum allowed mint for this year (2% of year start supply)
        uint256 maxAnnualMint = (yearStartSupply * Config.ANNUAL_MINT_CAP_PERCENT) / 100;
        uint256 remainingCapacity = maxAnnualMint > currentYearMinted ? maxAnnualMint - currentYearMinted : 0;

        // Reward: unlock additional 10% allocation (simplified: mint to ecosystem)
        uint256 rewardAmount = (project.totalMinted * Config.AUDIT_EXCEED_REWARD_PERCENT) / 100;

        // Cap reward to remaining annual capacity
        if (rewardAmount > remainingCapacity) {
            rewardAmount = remainingCapacity;
        }

        if (rewardAmount > 0 && totalSupply() + rewardAmount <= Config.MAX_SUPPLY) {
            currentYearMinted += rewardAmount;
            project.totalMinted += rewardAmount;
            _mint(treasuryEcosystem, rewardAmount);
            emit Mint(treasuryEcosystem, rewardAmount, project.id, "Audit reward");
            emit YieldAllocation(project.id, rewardAmount, block.timestamp);
        }
    }

    // ============ DEFLATIONARY MECHANICS ============

    /**
     * @notice Get current deflationary trajectory metrics
     * @return productionValue Total production value
     * @return tokenSupply Current token supply
     * @return ratio Production-to-supply ratio (in basis points)
     */
    function getDeflatoryTrajectory()
        external
        view
        override
        returns (uint256 productionValue, uint256 tokenSupply, uint256 ratio)
    {
        return (totalProductionValue, totalSupply(), _calculateRatio());
    }

    /**
     * @notice Get current burn rate based on years since deployment
     * @return Burn rate in tokens per unstaked CURD
     */
    function getCurrentBurnRate() external view override returns (uint256) {
        uint256 yearsSinceDeployment = (block.timestamp - deploymentTime) / Config.ONE_YEAR;
        return Config.getBurnRateForYear(yearsSinceDeployment);
    }

    /**
     * @dev Calculate production-to-supply ratio
     */
    function _calculateRatio() private view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (totalProductionValue * Config.BASIS_POINTS) / supply;
    }

    // ============ TREASURY MANAGEMENT ============

    /**
     * @notice Allocate treasury funds to specific category
     * @param recipient Recipient address
     * @param amount Amount to allocate
     * @param category Treasury category (0=Ecosystem, 1=Farmers, 2=Marketing, 3=Reserve)
     * @dev Emits YieldAllocation with projectId=0 to indicate treasury operation
     */
    function allocateTreasuryFunds(address recipient, uint256 amount, uint8 category)
        external
        override
        onlyOwner
        nonReentrant
    {
        ValidationLibrary.requireNonZeroAddress(recipient, "CheesecoinsCore: invalid recipient");
        ValidationLibrary.requireNonZeroAmount(amount, "CheesecoinsCore: zero amount");
        require(category <= 3, "CheesecoinsCore: invalid category");

        address treasury;

        if (category == 0) {
            treasury = treasuryEcosystem;
        } else if (category == 1) {
            treasury = treasuryFarmers;
        } else if (category == 2) {
            treasury = treasuryMarketing;
        } else {
            treasury = treasuryReserve;
        }

        require(balanceOf(treasury) >= amount, "CheesecoinsCore: insufficient treasury balance");

        _transfer(treasury, recipient, amount);
        // Note: projectId=0 indicates treasury operations (not project-specific)
        emit YieldAllocation(0, amount, block.timestamp);
    }

    // ============ YIELD POOL FUNDING ============

    /**
     * @notice Fund a YieldPool from treasury so stakers earn yield.
     * @param yieldPool Address of the YieldPool proxy to fund.
     * @param pid       Project ID bound to the pool (use type(uint256).max for BootstrapYieldPool).
     * @param amount    CURD amount (18 decimals) to deposit.
     * @param category  Treasury source: 0=Ecosystem, 1=Farmers, 2=Marketing, 3=Reserve.
     *
     * Flow:
     *   1. Pull `amount` CURD from the selected treasury into this contract.
     *   2. Approve the pool to pull via transferFrom (required by YieldPool.depositYield).
     *   3. Call depositYield — pool pulls the tokens and credits the balance.
     *
     * Security:
     *   - onlyOwner (Gnosis Safe) — prevents unauthorized treasury drain.
     *   - nonReentrant — prevents reentry through the external pool call.
     *   - Balance check before transfer — explicit rather than relying on ERC20 revert.
     */
    function fundYieldPool(address yieldPool, uint256 pid, uint256 amount, uint8 category)
        external
        onlyOwner
        nonReentrant
    {
        ValidationLibrary.requireNonZeroAddress(yieldPool, "CheesecoinsCore: invalid pool");
        ValidationLibrary.requireNonZeroAmount(amount, "CheesecoinsCore: zero amount");
        require(category <= 3, "CheesecoinsCore: invalid category");

        address src;
        if (category == 0) src = treasuryEcosystem;
        else if (category == 1) src = treasuryFarmers;
        else if (category == 2) src = treasuryMarketing;
        else src = treasuryReserve;

        require(balanceOf(src) >= amount, "CheesecoinsCore: insufficient treasury balance");

        // Pull from treasury into this contract (no allowance needed — internal ERC20 op)
        _transfer(src, address(this), amount);

        // Approve yieldPool to pull via transferFrom inside depositYield
        _approve(address(this), yieldPool, amount);

        // depositYield calls safeTransferFrom(address(this), pool, amount) — uses the approval above
        IYieldPool(yieldPool).depositYield(pid, amount);

        emit YieldAllocation(pid, amount, block.timestamp);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update authorized auditor
     * @param newAuditor New auditor address
     */
    function setAuthorizedAuditor(address newAuditor) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(newAuditor, "CheesecoinsCore: invalid auditor");
        address old = authorizedAuditor;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        authorizedAuditor = newAuditor;
        emit AuthorizedAuditorUpdated(old, newAuditor);
    }

    /**
     * @notice Update authorized minter
     * @param newMinter New minter address
     */
    function setAuthorizedMinter(address newMinter) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(newMinter, "CheesecoinsCore: invalid minter");
        address old = authorizedMinter;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        authorizedMinter = newMinter;
        emit AuthorizedMinterUpdated(old, newMinter);
    }

    /**
     * @notice Update treasury addresses
     */
    function updateTreasuryAddresses(address _ecosystem, address _farmers, address _marketing, address _reserve)
        external
        onlyOwner
    {
        ValidationLibrary.requireNonZeroAddress(_ecosystem, "CheesecoinsCore: invalid ecosystem");
        ValidationLibrary.requireNonZeroAddress(_farmers, "CheesecoinsCore: invalid farmers");
        ValidationLibrary.requireNonZeroAddress(_marketing, "CheesecoinsCore: invalid marketing");
        ValidationLibrary.requireNonZeroAddress(_reserve, "CheesecoinsCore: invalid reserve");

        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryEcosystem = _ecosystem;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryFarmers = _farmers;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryMarketing = _marketing;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        treasuryReserve = _reserve;

        emit TreasuryAddressesUpdated(_ecosystem, _farmers, _marketing, _reserve);
    }

    /**
     * @notice Deactivate a project
     * @param projectId Project to deactivate
     */
    function deactivateProject(uint256 projectId) external onlyOwner projectExists(projectId) {
        projects[projectId].active = false;
    }

    /**
     * @notice Reactivate a previously deactivated project
     * @param projectId Project to reactivate
     */
    function reactivateProject(uint256 projectId) external onlyOwner {
        require(projectId > 0 && projectId <= projectCount, "CheesecoinsCore: invalid project ID");
        require(!projects[projectId].active, "CheesecoinsCore: project already active");
        projects[projectId].active = true;
    }

    /**
     * @notice Get audit history for a project
     * @param projectId Project identifier
     * @return Array of audit results
     */
    function getProjectAudits(uint256 projectId) external view returns (AuditResult[] memory) {
        return projectAudits[projectId];
    }

    /**
     * @notice Get current year's minting statistics
     * @return minted Amount minted this year
     * @return capacity Maximum annual capacity
     * @return remaining Remaining mint capacity
     */
    function getAnnualMintStats() external view returns (uint256 minted, uint256 capacity, uint256 remaining) {
        // Apply reset logic without writing state so view reflects true current position
        uint256 effectiveMinted = currentYearMinted;
        uint256 effectiveYearStartSupply = yearStartSupply;
        if (block.timestamp >= lastMintResetTime + Config.ONE_YEAR) {
            effectiveMinted = 0;
            effectiveYearStartSupply = totalSupply();
        }
        uint256 maxAnnualMint = (effectiveYearStartSupply * Config.ANNUAL_MINT_CAP_PERCENT) / 100;
        uint256 remainingCapacity = maxAnnualMint > effectiveMinted ? maxAnnualMint - effectiveMinted : 0;

        return (effectiveMinted, maxAnnualMint, remainingCapacity);
    }
}
