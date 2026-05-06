// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "../Config.sol";
import "../libraries/ValidationLibrary.sol";
import "../libraries/MathLibrary.sol";
import "./interfaces/IStakingManager.sol";
import "../nft/interfaces/INFT.sol";
import "../nft/interfaces/INFTTransferHook.sol";
import "./interfaces/IYieldPool.sol";
import "../core/interfaces/ICheesecoinsCore.sol";

/// @dev Minimal router interface used by beforeNFTTransfer to identify the originating NFT collection
interface ITransferHookRouter {
    function nftContract() external view returns (address);
}

/// @dev Minimal interface for notifying governance of potential voting power changes.
interface ISuperHolderGovernance {
    function notifyPotentialVotingPowerChange(address user) external;
}

/**
 * @title StakingManager
 * @notice NFT-only staking engine with maturity tiers and seasonal multipliers
 * @dev Production-grade implementation with comprehensive security and validation
 *
 * Key Features:
 * - NFT-gated staking: Minimum 100 CURD per NFT required (Config.MIN_STAKE_PER_NFT)
 * - Maturity tiers: 1Y/2Y/3Y/5Y+ with progressive APY multipliers (1.0x → 2.0x)
 * - Community bonus: +25% APY when 90% of project NFTs are staked (dynamic on/off)
 * - Seasonal multipliers: Spring/Summer/Fall/Winter yield adjustments
 * - Insurance premium: 2% annual fee tracking (integration point for insurance system)
 * - Early unstake: principal returned 100%, rewards forfeited (no burn, no treasury penalty)
 * - Position tracking: Full staking history per NFT with accrued yield
 *
 * Design Decisions:
 * - NFT registration required before staking (owner must call registerNFT/batchRegisterNFTs)
 * - Community bonus is dynamic: activates at 90% threshold, deactivates if drops below
 * - Yield calculation is tracked but not automatically distributed (integration with YieldPool)
 * - Insurance premium is tracked as an event (integration point for premium collection)
 * - Early unstake burns from staked balance (requires contract to hold tokens)
 *
 * Integration Points:
 * - CheesecoinsCore (ICheesecoinsCore): CURD token with burn capability
 * - NFT contracts (INFT): Project NFTs with ownership verification
 * - YieldPool (IYieldPool): Yield distribution mechanism (tracking only in MVP)
 * - Treasury: Receives early unstake penalties
 *
 * Security:
 * - ReentrancyGuard on all state-changing functions
 * - NFT ownership verification before operations
 * - SafeERC20 for all token transfers
 * - Comprehensive input validation via ValidationLibrary
 * - Safe math operations via MathLibrary
 * - Emergency pause mechanism
 * - Custom errors for gas efficiency
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract StakingManager is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IStakingManager,
    INFTTransferHook
{
    using MathLibrary for uint256;
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ STATE VARIABLES ============

    /// @notice Core CURD token contract
    ICheesecoinsCore public curdToken;

    /// @notice Yield pool for distribution
    IYieldPool public yieldPool;

    /// @notice Treasury address for fees and penalties
    address public treasury;

    /// @notice Mapping of NFT ID to staking position
    mapping(uint256 => StakingPosition) public stakingPositions;

    /// @notice Mapping of project ID to staking statistics
    mapping(uint256 => StakingStats) public stakingStats;

    /// @notice Mapping of project ID to total NFT count (for community bonus)
    mapping(uint256 => uint256) public projectNFTCount;

    /// @notice Mapping of NFT address to project ID
    mapping(address => uint256) public nftToProject;

    /// @notice Mapping of NFT ID to NFT contract address
    mapping(uint256 => address) public nftIdToAddress;

    /// @notice Last insurance premium payment timestamp per project
    mapping(uint256 => uint256) public lastInsurancePayment;

    /// @notice Emergency pause flag
    bool public paused;

    /// @notice Base APY rate (in basis points, e.g., 1000 = 10%)
    uint256 public baseAPY;

    /// @notice Contract deployment timestamp for seasonal calculations
    uint256 public deploymentTime;

    /// @notice Per-wallet per-project staked amount for governance voting weight.
    /// @dev Updated on stake, unstake, and NFT transfer (via beforeNFTTransfer hook).
    ///
    ///      Governance integrity trade-off (Phase 6C Step 2):
    ///      When the hook is missed on a transfer (e.g., registered after some positions
    ///      were already staked), both this mapping and the unstake decrement use a
    ///      "clamp-to-zero" guard rather than reverting.
    ///
    ///      Consequence: if accounting desyncs the wallet retains inflated (or loses) voting
    ///      weight temporarily, but stake/unstake operations are never bricked.
    ///
    ///      This is the right policy for Phase 6C mid-build.  If governance must guarantee
    ///      "weight is never overstated," switch to a reverting decrement and provide an
    ///      admin repair function (syncUserProjectStaked) in a later phase.
    mapping(address => mapping(uint256 => uint256)) public userProjectStaked;

    /// @notice Timestamp when a wallet first obtained >0 attributed stake for a project.
    /// @dev Set to block.timestamp when attribution transitions 0→>0; cleared to 0 on >0→0.
    ///      Used by SuperHolderGovernance to gate proposals/votes behind a 24-week minimum age.
    mapping(address => mapping(uint256 => uint64)) public userProjectStakeStartAt;

    /// @notice Address of the SuperHolderGovernance contract to notify on attribution changes.
    /// @dev Set by owner via setGovernanceNotifier. Calls notifyPotentialVotingPowerChange.
    address public governanceNotifier;

    // ============ ERRORS ============

    error Paused();
    error NotNFTOwner();
    error InsufficientStake();
    error InvalidLockPeriod();
    error NoActivePosition();
    error InsufficientStakedAmount();
    error StillLocked();
    error InvalidNFT();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyStaked();
    error InsurancePremiumAlreadyPaid();
    error ActiveStakeOnBurn();

    // ============ EVENTS (admin setter changes) ============

    /// @notice Emitted when the base APY rate is updated
    event BaseAPYUpdated(uint256 oldAPY, uint256 newAPY);
    /// @notice Emitted when the treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    /// @notice Emitted on emergency withdrawal for monitoring
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);

    // ============ MODIFIERS ============

    /**
     * @notice Ensures contract is not paused
     */
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /**
     * @notice Validates NFT ownership
     * @param nftId NFT token ID
     */
    modifier onlyNFTOwner(uint256 nftId) {
        address nftAddress = nftIdToAddress[nftId];
        if (nftAddress == address(0)) revert InvalidNFT();
        if (IERC721Upgradeable(nftAddress).ownerOf(nftId) != msg.sender) revert NotNFTOwner();
        _;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the staking manager
     * @param _curdToken Core CURD token address
     * @param _yieldPool Yield pool address
     * @param _treasury Treasury address
     * @param _baseAPY Base APY rate in basis points (e.g., 1000 = 10%)
     */
    function initialize(address _curdToken, address _yieldPool, address _treasury, uint256 _baseAPY)
        external
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();

        if (_curdToken == address(0)) revert ZeroAddress();
        if (_yieldPool == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        curdToken = ICheesecoinsCore(_curdToken);
        yieldPool = IYieldPool(_yieldPool);
        treasury = _treasury;
        baseAPY = _baseAPY;
        deploymentTime = block.timestamp;
    }

    // ============ STAKING OPERATIONS ============

    /**
     * @notice Stake CURD tokens with NFT requirement
     * @param nftId NFT token ID to associate with stake
     * @param amount Amount of CURD to stake
     * @param lockMonths Lock period in months (12, 24, 36, or 60+)
     * @dev Requires:
     * - Caller owns the NFT
     * - Amount >= MIN_STAKE_PER_NFT (100 CURD)
     * - Valid lock period
     * - NFT not currently staked
     * - NFT must be registered via registerNFT first
     */
    // slither-disable-next-line reentrancy-no-eth -- nonReentrant; all position state written before safeTransferFrom and governanceNotifier call (CEI)
    function stake(uint256 nftId, uint256 amount, uint256 lockMonths)
        external
        override
        nonReentrant
        whenNotPaused
        onlyNFTOwner(nftId)
    {
        // Validate staking parameters
        if (amount < Config.MIN_STAKE_PER_NFT) revert InsufficientStake();
        _validateLockPeriod(lockMonths);

        // Check if NFT already has active position
        StakingPosition storage position = stakingPositions[nftId];
        if (position.active) revert AlreadyStaked();

        // Get NFT project information — use registry mapping, not NFT self-report.
        // NFT.getProjectId() is unreliable if the NFT was deployed with the wrong constant.
        address nftAddress = nftIdToAddress[nftId];
        uint256 projectId = nftToProject[nftAddress];
        if (projectId == 0) revert InvalidNFT();

        // Calculate maturity time and APY multiplier
        uint256 maturityTime = block.timestamp + (lockMonths * Config.ONE_MONTH);
        uint256 apyMultiplier = _getAPYMultiplier(lockMonths);

        // CEI: write all state (effects) before the external token transfer (interaction)
        // Create staking position
        position.nftId = nftId;
        position.amount = amount;
        position.lockMonths = lockMonths;
        position.startTime = block.timestamp;
        position.maturityTime = maturityTime;
        position.apyMultiplier = apyMultiplier;
        position.accruedYield = 0;
        position.active = true;

        // Update project statistics
        StakingStats storage stats = stakingStats[projectId];
        stats.projectId = projectId;
        stats.totalStaked += amount;
        stats.activeNFTs += 1;

        // Update per-wallet stake attribution for governance voting weight
        uint256 prevStaked = userProjectStaked[msg.sender][projectId];
        userProjectStaked[msg.sender][projectId] = prevStaked + amount;

        // Set stake start time when transitioning from 0 → >0 attribution
        if (prevStaked == 0) {
            userProjectStakeStartAt[msg.sender][projectId] = uint64(block.timestamp);
        }

        // Update community percentage (handles bonus activation)
        _updateCommunityPercentage(projectId);

        emit Staked(msg.sender, nftId, projectId, amount, lockMonths, maturityTime);

        // Interactions last (CEI): pull tokens then notify governance
        IERC20Upgradeable(address(curdToken)).safeTransferFrom(msg.sender, address(this), amount);

        // Notify governance of potential voting power change (CEI: external call last)
        if (governanceNotifier != address(0)) {
            ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(msg.sender);
        }
    }

    /**
     * @notice Unstake CURD tokens (full or partial)
     * @param nftId NFT token ID
     * @param amount Amount to unstake (0 = full unstake)
     * @dev Early unstake penalty:
     * - Before maturity: 50% burned, 50% to treasury
     * - After maturity: No penalty, full amount + yield returned
     */
    // slither-disable-next-line reentrancy-no-eth -- nonReentrant; all position and stats state written before burn/transfer/governanceNotifier call (CEI)
    function unstake(uint256 nftId, uint256 amount) external override nonReentrant whenNotPaused onlyNFTOwner(nftId) {
        StakingPosition storage position = stakingPositions[nftId];

        if (!position.active) revert NoActivePosition();
        if (amount == 0) {
            amount = position.amount;
        }
        if (amount > position.amount) revert InsufficientStakedAmount();

        // Get project information — use registry mapping only. Never fall back to NFT self-report;
        // NubiansNorthNFT hardcodes PROJECT_ID = 1 which is the abandoned test project.
        address nftAddress = nftIdToAddress[nftId];
        uint256 projectId = nftToProject[nftAddress];
        if (projectId == 0) revert InvalidNFT();

        // Update per-wallet stake attribution for governance voting weight.
        // Clamp to zero rather than revert so unstake is never bricked if accounting
        // desynced (e.g., hook missed on a transfer before registration).
        // See userProjectStaked @dev for the full governance-integrity trade-off.
        uint256 currentStaked = userProjectStaked[msg.sender][projectId];
        userProjectStaked[msg.sender][projectId] = currentStaked >= amount ? currentStaked - amount : 0;

        // Clear stake start time when attribution reaches 0
        if (userProjectStaked[msg.sender][projectId] == 0) {
            userProjectStakeStartAt[msg.sender][projectId] = 0;
        }

        bool isEarlyUnstake = block.timestamp < position.maturityTime;
        uint256 burnAmount = 0;
        uint256 treasuryAmount = 0;
        uint256 returnAmount = amount;
        uint256 yieldAmount = 0;

        // Compute amounts before any state modifications (reads position state unchanged)
        if (isEarlyUnstake) {
            // Early unstake: principal always returns to holder.
            // Rewards are forfeited by not accruing / not distributing them.
            burnAmount = 0;
            treasuryAmount = 0;
            yieldAmount = 0;
        } else {
            // Mature unstake: calculate yield while position state is still intact.
            // Yield distribution happens via YieldPool's separate mechanism;
            // StakingManager tracks accrued yield but doesn't mint it directly.
            yieldAmount = _calculateYield(nftId);
        }

        // CEI: update all state (effects) before external calls (interactions)
        // Update accrued yield for mature unstake
        if (!isEarlyUnstake) {
            position.accruedYield += yieldAmount;
        }

        // Update position
        position.amount -= amount;
        if (position.amount == 0) {
            position.active = false;
        }

        // Update project statistics
        StakingStats storage stats = stakingStats[projectId];
        stats.totalStaked -= amount;
        if (position.amount == 0) {
            stats.activeNFTs -= 1;
        }

        // Update community percentage
        _updateCommunityPercentage(projectId);

        emit Unstaked(msg.sender, nftId, returnAmount, burnAmount, isEarlyUnstake);

        // Interactions last (CEI): principal always returns to the holder.
        // Early unstake forfeits rewards only; it does not slash principal.
        IERC20Upgradeable(address(curdToken)).safeTransfer(msg.sender, returnAmount);

        // Notify governance of potential voting power change (CEI: external call last)
        if (governanceNotifier != address(0)) {
            ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(msg.sender);
        }
    }

    // ============ INSURANCE PREMIUM ============

    /**
     * @notice Pay insurance premium for project (2% annual)
     * @param projectId Project ID
     * @dev Anyone can trigger, premium deducted from staked funds
     * - Collects 2% annual premium from total staked amount
     * - Premium sent to treasury for insurance coverage
     * - Can be called once per year per project
     * - Premium is virtual deduction from staked amount (tracked, not physically moved)
     *
     * Note: In production, this should integrate with a proper insurance fund mechanism
     * that either mints new tokens for premiums or has a dedicated reserve.
     */
    function payInsurancePremium(uint256 projectId) external override nonReentrant whenNotPaused {
        uint256 lastPayment = lastInsurancePayment[projectId];

        // Require at least 1 year since last payment
        if (block.timestamp < lastPayment + Config.ONE_YEAR) {
            revert InsurancePremiumAlreadyPaid();
        }

        StakingStats storage stats = stakingStats[projectId];
        if (stats.totalStaked == 0) revert ZeroAmount();

        // Calculate 2% annual premium
        uint256 premiumAmount = stats.totalStaked.mulDiv(Config.INSURANCE_PREMIUM_PERCENT, 100);

        // Update payment timestamp
        lastInsurancePayment[projectId] = block.timestamp;

        // Note: In a production system, this premium should be:
        // 1. Minted from treasury/insurance fund
        // 2. Or deducted from staking positions proportionally
        // 3. Or paid from a separate insurance reserve
        // For now, this tracks the premium amount that should be collected

        emit InsurancePremiumPaid(projectId, premiumAmount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get staking position for NFT
     * @param nftId NFT token ID
     * @return Staking position details
     */
    function getStakingPosition(uint256 nftId) external view override returns (StakingPosition memory) {
        return stakingPositions[nftId];
    }

    /**
     * @notice Get staking statistics for project
     * @param projectId Project ID
     * @return Staking statistics
     */
    function getStakingStats(uint256 projectId) external view override returns (StakingStats memory) {
        return stakingStats[projectId];
    }

    /**
     * @notice Calculate current APY for NFT position
     * @param nftId NFT token ID
     * @return Total APY in basis points (including all bonuses)
     * @dev APY calculation:
     * - Base APY (set by owner)
     * - × Maturity multiplier (1.0x → 2.0x)
     * - × Seasonal multiplier (0.5x → 2.0x)
     * - + Community bonus (25% if 90% target met)
     */
    function calculateAPY(uint256 nftId) external view override returns (uint256) {
        return _calculateAPY(nftId);
    }

    /**
     * @notice Get NFT contract address for a given NFT ID
     * @param nftId NFT token ID
     * @return NFT contract address
     */
    function getNFTAddress(uint256 nftId) external view returns (address) {
        return nftIdToAddress[nftId];
    }

    /**
     * @notice Check if NFT is registered for staking
     * @param nftId NFT token ID
     * @return True if NFT is registered
     */
    function isNFTRegistered(uint256 nftId) external view returns (bool) {
        return nftIdToAddress[nftId] != address(0);
    }

    /**
     * @notice Check if an NFT position is eligible for rewards
     * @param nftId NFT token ID
     * @return True if position is active and staked amount >= Config.MIN_STAKE_PER_NFT
     * @dev stake() enforces the minimum at creation time; this guard becomes meaningful
     *      if a partial unstake drops the remaining balance below the threshold.
     *      Used by the off-chain Merkle snapshot builder and optionally by on-chain callers.
     */
    function isEligibleForRewards(uint256 nftId) public view override returns (bool) {
        StakingPosition storage position = stakingPositions[nftId];
        return position.active && position.amount >= Config.MIN_STAKE_PER_NFT;
    }

    /**
     * @notice Get per-wallet staked amount for a project
     * @param user Wallet address
     * @param projectId Project ID
     * @return Amount of CURD staked by `user` in `projectId`
     */
    function getUserProjectStaked(address user, uint256 projectId) external view override returns (uint256) {
        return userProjectStaked[user][projectId];
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Register NFT with staking manager
     * @param nftAddress NFT contract address
     * @param nftId NFT token ID
     * @param projectId Project ID
     * @param totalNFTs Total NFT count for project (only needed first time)
     * @dev This function must be called before an NFT can be staked
     * - Associates NFT ID with its contract address
     * - Updates total NFT count for community bonus calculation
     */
    function registerNFT(address nftAddress, uint256 nftId, uint256 projectId, uint256 totalNFTs) external onlyOwner {
        if (nftAddress == address(0)) revert ZeroAddress();

        // Register NFT ID to address mapping
        nftIdToAddress[nftId] = nftAddress;

        // Register NFT contract to project only if not already set.
        // Never overwrite silently — staked positions rely on this mapping for attribution.
        if (nftToProject[nftAddress] == 0) {
            nftToProject[nftAddress] = projectId;
        }

        // Update total NFT count (if provided)
        if (totalNFTs > 0 && projectNFTCount[projectId] == 0) {
            projectNFTCount[projectId] = totalNFTs;
        }
    }

    /**
     * @notice Batch register multiple NFTs
     * @param nftAddress NFT contract address
     * @param nftIds Array of NFT token IDs
     * @param projectId Project ID
     * @param totalNFTs Total NFT count for project
     * @dev More efficient for registering many NFTs at once
     */
    function batchRegisterNFTs(address nftAddress, uint256[] calldata nftIds, uint256 projectId, uint256 totalNFTs)
        external
        onlyOwner
    {
        if (nftAddress == address(0)) revert ZeroAddress();

        // Register NFT contract to project only if not already set.
        if (nftToProject[nftAddress] == 0) {
            nftToProject[nftAddress] = projectId;
        }

        // Register all NFT IDs
        for (uint256 i = 0; i < nftIds.length; i++) {
            nftIdToAddress[nftIds[i]] = nftAddress;
        }

        // Update total NFT count (if provided)
        if (totalNFTs > 0 && projectNFTCount[projectId] == 0) {
            projectNFTCount[projectId] = totalNFTs;
        }
    }

    /**
     * @notice Update base APY rate
     * @param newBaseAPY New base APY in basis points
     */
    function setBaseAPY(uint256 newBaseAPY) external onlyOwner {
        uint256 old = baseAPY;
        baseAPY = newBaseAPY;
        emit BaseAPYUpdated(old, newBaseAPY);
    }

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @notice Set the governance notifier address.
     * @param _gov SuperHolderGovernance contract address.
     */
    function setGovernanceNotifier(address _gov) external onlyOwner {
        if (_gov == address(0)) revert ZeroAddress();
        governanceNotifier = _gov;
    }

    /**
     * @notice Pause/unpause contract
     * @param _paused Pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    // ============ INFTTransferHook ============

    /**
     * @notice Move stake attribution when the associated NFT transfers.
     * @dev Implements Phase 6C Step 2 "stake follows NFT."
     *      All accounting happens here (before) to satisfy "before external effects."
     *
     *      The NFT collection address is resolved via the caller (router) rather
     *      than passed in the hook signature:
     *        nftAddr = ITransferHookRouter(msg.sender).nftContract()
     *
     * @param nftId Token ID being transferred
     * @param from Previous owner (address(0) on mint)
     * @param to New owner (address(0) on burn)
     * @return True always; reverts if a burn is attempted on an NFT with an active stake
     */
    function beforeNFTTransfer(uint256 nftId, address from, address to) external override returns (bool) {
        // Mint: auto-register token if collection is already known, then return (no stake to move)
        if (from == address(0)) {
            address mintedNftAddr = ITransferHookRouter(msg.sender).nftContract();
            if (nftToProject[mintedNftAddr] != 0 && nftIdToAddress[nftId] == address(0)) {
                nftIdToAddress[nftId] = mintedNftAddr;
            }
            return true;
        }

        StakingPosition storage position = stakingPositions[nftId];
        if (!position.active) return true;

        // Burn with active stake is disallowed
        if (to == address(0)) revert ActiveStakeOnBurn();

        // Resolve NFT collection via the router that is calling us
        address nftAddr = ITransferHookRouter(msg.sender).nftContract();

        // Resolve project ID from registry mapping only. Never fall back to NFT self-report.
        uint256 projectId = nftToProject[nftAddr];
        if (projectId == 0) revert InvalidNFT();

        // Move stake attribution from old owner to new owner.
        // Clamp to zero rather than revert so transfers are never bricked if accounting
        // desynced (e.g., hook registered after position was already staked).
        // See userProjectStaked @dev for the full governance-integrity trade-off.
        uint256 fromStaked = userProjectStaked[from][projectId];
        uint256 toStakedBefore = userProjectStaked[to][projectId];
        userProjectStaked[from][projectId] = fromStaked >= position.amount ? fromStaked - position.amount : 0;
        userProjectStaked[to][projectId] = toStakedBefore + position.amount;

        // Update stakeStartAt for both wallets:
        // - from: clear if attribution reaches 0
        // - to: set to now only if transitioning from 0 → >0 (fresh stake-age clock for new holder)
        if (userProjectStaked[from][projectId] == 0) {
            userProjectStakeStartAt[from][projectId] = 0;
        }
        if (toStakedBefore == 0) {
            // to had 0 attribution before this transfer; start their clock now
            userProjectStakeStartAt[to][projectId] = uint64(block.timestamp);
        }

        // Notify governance for both wallets after final attribution values are applied
        if (governanceNotifier != address(0)) {
            ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(from);
            ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(to);
        }

        return true;
    }

    /**
     * @notice After-hook: auto-register NFTs on mint.
     * @dev NubiansNorthNFT skips beforeNFTTransfer on mint (from == address(0)), so
     *      registration must happen here instead. Transfers and burns are no-ops.
     */
    function afterNFTTransfer(uint256 nftId, address from, address to) external override {
        // Only act on mints
        if (from != address(0)) return;
        (to); // silence unused warning
        address mintedNftAddr = ITransferHookRouter(msg.sender).nftContract();
        if (nftToProject[mintedNftAddr] != 0 && nftIdToAddress[nftId] == address(0)) {
            nftIdToAddress[nftId] = mintedNftAddr;
        }
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Calculate APY with all multipliers
     * @param nftId NFT token ID
     * @return Total APY in basis points
     */
    function _calculateAPY(uint256 nftId) internal view returns (uint256) {
        StakingPosition storage position = stakingPositions[nftId];
        if (!position.active) return 0;

        // Get project ID for community bonus check — use registry mapping only.
        address nftAddress = nftIdToAddress[nftId];
        uint256 projectId = nftToProject[nftAddress];
        if (projectId == 0) revert InvalidNFT();
        StakingStats storage stats = stakingStats[projectId];

        // Start with base APY
        uint256 apy = baseAPY;

        // Apply maturity multiplier
        apy = apy.mulDiv(position.apyMultiplier, 100);

        // Apply seasonal multiplier
        uint256 seasonalMultiplier = _getSeasonalMultiplier();
        apy = apy.mulDiv(seasonalMultiplier, 100);

        // Apply community bonus (additive bonus on final APY)
        // Note: This is +25% of the adjusted APY, not base APY
        if (stats.bonusActive) {
            apy += apy.mulDiv(Config.COMMUNITY_90_PERCENT_BONUS, 100);
        }

        return apy;
    }

    /**
     * @notice Calculate accrued yield for position
     * @param nftId NFT token ID
     * @return Yield amount
     */
    function _calculateYield(uint256 nftId) internal view returns (uint256) {
        StakingPosition storage position = stakingPositions[nftId];
        if (!position.active) return 0;

        uint256 timeStaked = block.timestamp - position.startTime;
        uint256 apy = _calculateAPY(nftId);

        // Calculate yield: (amount * APY * time) / (100% * 1 year)
        uint256 yield = position.amount.mulDiv(apy, Config.BASIS_POINTS).mulDiv(timeStaked, Config.ONE_YEAR);

        return yield;
    }

    /**
     * @notice Get APY multiplier for lock period
     * @param lockMonths Lock period in months
     * @return Multiplier (100 = 1.0x, 200 = 2.0x)
     */
    function _getAPYMultiplier(uint256 lockMonths) internal pure returns (uint256) {
        if (lockMonths >= Config.LOCK_5_YEAR_MONTHS) {
            return Config.MATURITY_5Y_APY; // 2.0x
        } else if (lockMonths >= Config.LOCK_3_YEAR_MONTHS) {
            return Config.MATURITY_3Y_APY; // 1.5x
        } else if (lockMonths >= Config.LOCK_2_YEAR_MONTHS) {
            return Config.MATURITY_2Y_APY; // 1.25x
        } else if (lockMonths >= Config.LOCK_1_YEAR_MONTHS) {
            return Config.MATURITY_1Y_APY; // 1.0x
        }
        revert InvalidLockPeriod();
    }

    /**
     * @notice Get seasonal yield multiplier
     * @return Multiplier (100 = 1.0x)
     * @dev Deterministic calendar logic based on months since deployment (NOT a PRNG).
     *      The modulo is calendar arithmetic to determine the season; it is not used for
     *      randomness or security.  Seasonal schedule:
     * - Spring (Mar-May): 150% (high milk production)
     * - Summer (Jun-Aug): 150% (high milk production)
     * - Fall (Sep-Nov): 100% (moderate production)
     * - Winter (Dec-Feb): 50% (low production)
     *
     * Note: This assumes deploymentTime represents a reference point for seasonal calculation.
     * The seasonal cycle repeats every 12 months from deployment.
     * For calendar-based seasons, deploymentTime should be set to a January 1st reference.
     */
    // slither-disable-next-line weak-prng
    function _getSeasonalMultiplier() internal view returns (uint256) {
        uint256 monthsSinceDeployment = (block.timestamp - deploymentTime) / Config.ONE_MONTH;
        uint256 currentMonth = (monthsSinceDeployment % 12) + 1; // 1-12

        if (currentMonth >= 3 && currentMonth <= 8) {
            // Spring + Summer: Mar-Aug
            return Config.MILK_SPRING_SUMMER; // 150
        } else if (currentMonth >= 9 && currentMonth <= 11) {
            // Fall: Sep-Nov
            return Config.MILK_FALL; // 100
        } else {
            // Winter: Dec-Feb
            return Config.MILK_WINTER; // 50
        }
    }

    /**
     * @notice Validate lock period
     * @param lockMonths Lock period in months
     */
    function _validateLockPeriod(uint256 lockMonths) internal pure {
        if (lockMonths < Config.LOCK_1_YEAR_MONTHS) revert InvalidLockPeriod();
        // No upper limit, but minimum is 1 year
    }

    /**
     * @notice Update community percentage for project
     * @param projectId Project ID
     */
    function _updateCommunityPercentage(uint256 projectId) internal {
        StakingStats storage stats = stakingStats[projectId];
        uint256 totalNFTs = projectNFTCount[projectId];

        if (totalNFTs > 0) {
            stats.communityPercentage = stats.activeNFTs.mulDiv(100, totalNFTs);

            // Update bonus active status based on current percentage
            if (stats.communityPercentage >= Config.COMMUNITY_90_PERCENT_TARGET) {
                if (!stats.bonusActive) {
                    stats.bonusActive = true;
                    emit Community90Achieved(projectId, Config.COMMUNITY_90_PERCENT_BONUS);
                }
            } else {
                stats.bonusActive = false;
            }
        }
    }

    /**
     * @notice Emergency withdrawal function (owner only)
     * @param token Token address
     * @param amount Amount to withdraw
     * @dev Only callable by owner in emergency situations
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        emit EmergencyWithdrawal(token, amount, owner());
        IERC20Upgradeable(token).safeTransfer(owner(), amount);
    }
}
