// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "../core/interfaces/ICheesecoinsCore.sol";
import "./BurnAuthority.sol";

/**
 * @title FiatRedemptionVault
 * @notice Phase-3 soft-peg redemption vault. CSA NFT holders may redeem CURD
 *         for USDC at a sliding rate determined by vault health (A2 model).
 * @dev CURD is transferred directly to BurnAuthority and burned on every redemption.
 *      The vault never retains CURD. All supply contraction is permanent.
 *      Redemption rate declines as the USDC balance depletes relative to the cap.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract FiatRedemptionVault is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ STATE ============

    /// @notice USDC token (6 decimals)
    IERC20Upgradeable public usdc;

    /// @notice CURD token (18 decimals)
    ICheesecoinsCore public curd;

    /// @notice CSA NFT contract
    IERC721Upgradeable public csaNft;

    /// @notice Treasury — may call operational setters and fundVault
    address public treasury;

    /// @notice Centralized burn executor
    BurnAuthority public burnAuthority;

    /// @notice Maximum USDC the vault may hold
    uint256 public usdcCap;

    /// @notice Minimum seconds between redemptions per recipient
    uint256 public cooldownSeconds;

    /// @notice Target USDC per CURD scaled to 1e6 (e.g. 1e6 = 1.00 USDC)
    uint256 public targetUsdcPerCurdE6;

    /// @notice Minimum CURD amount per redemption (0 = no minimum)
    uint256 public minRedeemCurd;

    /// @notice Maximum CURD amount per redemption (0 = no maximum)
    uint256 public maxRedeemCurd;

    /// @notice Last redemption timestamp per recipient address
    mapping(address => uint256) public lastRedeemAt;

    /**
     * @notice A2 sliding-rate step
     * @dev Steps are stored sorted descending by remainingBpsFloor.
     *      First step where remainingBps >= remainingBpsFloor is selected.
     */
    struct RateStep {
        uint16 remainingBpsFloor; // vault balance / cap * 10_000
        uint16 redeemBps; // fraction of targetUsdcPerCurdE6 applied (≤ 10_000)
    }

    RateStep[] private _steps;

    /// @notice Protocol fee in basis points deducted from each redemption payout (e.g. 200 = 2%).
    ///         Fee is routed to treasury; user receives usdcOut minus this amount.
    uint256 public protocolFeeBps;

    /// @notice Maximum USDC redeemable in a rolling 24-hour window (6 decimals). 0 = no cap.
    uint256 public dailyRedemptionCapUsdc;

    /// @notice USDC redeemed in the current 24-hour window (6 decimals)
    uint256 public dailyRedeemedUsdc;

    /// @notice Timestamp when the current daily window started
    uint256 public lastDayReset;

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error NotTreasury();
    error CooldownActive();
    error BelowMinimum();
    error DailyCapExceeded();
    error FeeBpsTooHigh();
    error AboveMaximum();
    error InsufficientUsdcInVault();
    error ExceedsVaultCap();
    error InvalidRateSteps();
    error InvalidMinMax();
    error NoApplicableRateStep();

    // ============ EVENTS ============

    event Redeemed(address indexed recipient, uint256 curdBurned, uint256 usdcOut, uint16 redeemBps);
    event VaultFunded(address indexed funder, uint256 usdcAmount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event BurnAuthorityUpdated(address indexed oldAuthority, address indexed newAuthority);
    event UsdcCapUpdated(uint256 oldCap, uint256 newCap);
    event TargetRateUpdated(uint256 oldRate, uint256 newRate);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event MinMaxRedeemUpdated(uint256 minCurd, uint256 maxCurd);
    event RateStepsUpdated(uint256 stepCount);
    event ProtocolFeeCollected(address indexed treasury, uint256 feeUsdc);
    event DailyRedemptionCapUpdated(uint256 oldCap, uint256 newCap);
    event ProtocolFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    // ============ MODIFIERS ============

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the FiatRedemptionVault
     * @param _usdc               USDC token address (6 decimals)
     * @param _curd               CURD token address (18 decimals)
     * @param _csaNft             CSA NFT contract
     * @param _treasury           Treasury address (operational authority)
     * @param _burnAuthority      BurnAuthority contract
     * @param _usdcCap            Maximum USDC the vault may hold
     * @param _targetUsdcPerCurdE6 Target USDC/CURD rate (1e6 = 1.00 USDC per CURD)
     * @param _owner              Governance owner address
     */
    function initialize(
        address _usdc,
        address _curd,
        address _csaNft,
        address _treasury,
        address _burnAuthority,
        uint256 _usdcCap,
        uint256 _targetUsdcPerCurdE6,
        address _owner
    ) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_curd == address(0)) revert ZeroAddress();
        if (_csaNft == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_burnAuthority == address(0)) revert ZeroAddress();
        if (_targetUsdcPerCurdE6 == 0) revert ZeroAmount();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        usdc = IERC20Upgradeable(_usdc);
        curd = ICheesecoinsCore(_curd);
        csaNft = IERC721Upgradeable(_csaNft);
        treasury = _treasury;
        burnAuthority = BurnAuthority(_burnAuthority);
        usdcCap = _usdcCap;
        targetUsdcPerCurdE6 = _targetUsdcPerCurdE6;
        lastDayReset = block.timestamp;

        _transferOwnership(_owner);
    }

    // ============ REDEMPTION ============

    /**
     * @notice Redeem CURD for USDC at the current A2 sliding rate
     * @dev Caller must be the NFT owner or an approved operator.
     *      Payout always goes to ownerOf(nftId), not necessarily the caller.
     *      CURD is transferred directly to BurnAuthority and immediately burned.
     *      The vault never retains any CURD.
     * @param nftId      CSA NFT token ID
     * @param curdAmount Amount of CURD to redeem (18 decimals)
     */
    // slither-disable-next-line reentrancy-no-eth -- nonReentrant; lastRedeemAt state updated before safeTransferFrom/burn/safeTransfer external calls (CEI)
    function redeem(uint256 nftId, uint256 curdAmount) external nonReentrant whenNotPaused {
        _requireNftAuthorized(nftId);
        address recipient = csaNft.ownerOf(nftId);

        if (curdAmount == 0) revert ZeroAmount();
        if (minRedeemCurd > 0 && curdAmount < minRedeemCurd) revert BelowMinimum();
        if (maxRedeemCurd > 0 && curdAmount > maxRedeemCurd) revert AboveMaximum();
        if (
            cooldownSeconds > 0 && lastRedeemAt[recipient] != 0
                && block.timestamp < lastRedeemAt[recipient] + cooldownSeconds
        ) {
            revert CooldownActive();
        }

        uint256 usdcBalance = usdc.balanceOf(address(this));
        (uint256 usdcOut, uint16 redeemBps) = _computeUsdcOut(curdAmount, usdcBalance);

        if (usdcOut == 0) revert ZeroAmount();
        if (usdcOut > usdcBalance) revert InsufficientUsdcInVault();

        // Compute protocol fee (deducted from usdcOut, routed to treasury)
        uint256 feeUsdc = protocolFeeBps > 0 ? usdcOut * protocolFeeBps / 10_000 : 0;
        uint256 userUsdc = usdcOut - feeUsdc;

        // Daily cap: reset window if needed, then check against gross outflow
        if (block.timestamp >= lastDayReset + 1 days) {
            dailyRedeemedUsdc = 0;
            lastDayReset = block.timestamp;
        }
        if (dailyRedemptionCapUsdc > 0 && dailyRedeemedUsdc + usdcOut > dailyRedemptionCapUsdc) {
            revert DailyCapExceeded();
        }

        // Update state before external calls (CEI pattern)
        lastRedeemAt[recipient] = block.timestamp;
        dailyRedeemedUsdc += usdcOut;

        // Transfer CURD from caller → BurnAuthority, then burn
        IERC20Upgradeable(address(curd)).safeTransferFrom(msg.sender, address(burnAuthority), curdAmount);
        burnAuthority.burn(curdAmount);

        // Send USDC to NFT owner (net of protocol fee)
        usdc.safeTransfer(recipient, userUsdc);

        // Route protocol fee to treasury
        if (feeUsdc > 0) {
            usdc.safeTransfer(treasury, feeUsdc);
            emit ProtocolFeeCollected(treasury, feeUsdc);
        }

        emit Redeemed(recipient, curdAmount, usdcOut, redeemBps);
    }

    // ============ TREASURY (OPERATIONAL) FUNCTIONS ============

    /**
     * @notice Deposit USDC into the vault (treasury only)
     * @dev Vault balance must not exceed usdcCap after funding.
     * @param usdcAmount Amount of USDC to deposit (6 decimals)
     */
    function fundVault(uint256 usdcAmount) external nonReentrant onlyTreasury {
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) + usdcAmount > usdcCap) revert ExceedsVaultCap();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit VaultFunded(msg.sender, usdcAmount);
    }

    /**
     * @notice Update the redemption cooldown period (treasury only)
     * @param _cooldownSeconds New cooldown in seconds (0 = no cooldown)
     */
    function setCooldown(uint256 _cooldownSeconds) external nonReentrant onlyTreasury {
        emit CooldownUpdated(cooldownSeconds, _cooldownSeconds);
        cooldownSeconds = _cooldownSeconds;
    }

    /**
     * @notice Update min and max redemption amounts (treasury only)
     * @param _min Minimum CURD per redemption (0 = no minimum)
     * @param _max Maximum CURD per redemption (0 = no maximum)
     */
    function setMinMaxRedeem(uint256 _min, uint256 _max) external nonReentrant onlyTreasury {
        if (_min > 0 && _max > 0 && _min > _max) revert InvalidMinMax();

        minRedeemCurd = _min;
        maxRedeemCurd = _max;

        emit MinMaxRedeemUpdated(_min, _max);
    }

    /**
     * @notice Update the daily USDC redemption cap (treasury only)
     * @param _capUsdc New 24-hour cap in USDC (6 decimals). 0 = no cap.
     */
    function setDailyRedemptionCap(uint256 _capUsdc) external nonReentrant onlyTreasury {
        emit DailyRedemptionCapUpdated(dailyRedemptionCapUsdc, _capUsdc);
        dailyRedemptionCapUsdc = _capUsdc;
    }

    /**
     * @notice Set the A2 sliding rate steps (treasury only)
     * @dev Steps must be:
     *      - Non-empty
     *      - Sorted strictly descending by remainingBpsFloor
     *      - redeemBps ≤ 10_000
     *      - remainingBpsFloor within [0, 10_000]
     * @param steps Array of RateStep structs
     */
    function setRateSteps(RateStep[] calldata steps) external nonReentrant onlyTreasury {
        _validateRateSteps(steps);

        delete _steps;
        for (uint256 i = 0; i < steps.length; i++) {
            _steps.push(steps[i]);
        }

        emit RateStepsUpdated(steps.length);
    }

    // ============ OWNER (GOVERNANCE) FUNCTIONS ============

    /**
     * @notice Update the treasury address (owner only)
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external nonReentrant onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();

        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /**
     * @notice Update the USDC vault cap (owner only)
     * @param _usdcCap New USDC cap (6 decimals)
     */
    function setUsdcCap(uint256 _usdcCap) external nonReentrant onlyOwner {
        emit UsdcCapUpdated(usdcCap, _usdcCap);
        usdcCap = _usdcCap;
    }

    /**
     * @notice Update the target USDC/CURD exchange rate (owner only)
     * @param _targetUsdcPerCurdE6 New target rate (1e6 = 1.00 USDC per CURD)
     */
    function setTargetUsdcPerCurd(uint256 _targetUsdcPerCurdE6) external nonReentrant onlyOwner {
        if (_targetUsdcPerCurdE6 == 0) revert ZeroAmount();

        emit TargetRateUpdated(targetUsdcPerCurdE6, _targetUsdcPerCurdE6);
        targetUsdcPerCurdE6 = _targetUsdcPerCurdE6;
    }

    /**
     * @notice Update the protocol redemption fee (owner only)
     * @param _feeBps New fee in basis points (e.g. 200 = 2%). Max 1000 (10%).
     */
    function setProtocolFeeBps(uint256 _feeBps) external nonReentrant onlyOwner {
        if (_feeBps > 1_000) revert FeeBpsTooHigh();
        emit ProtocolFeeBpsUpdated(protocolFeeBps, _feeBps);
        protocolFeeBps = _feeBps;
    }

    /**
     * @notice Update the BurnAuthority contract (owner only)
     * @param _burnAuthority New BurnAuthority address
     */
    function setBurnAuthority(address _burnAuthority) external nonReentrant onlyOwner {
        if (_burnAuthority == address(0)) revert ZeroAddress();

        emit BurnAuthorityUpdated(address(burnAuthority), _burnAuthority);
        burnAuthority = BurnAuthority(_burnAuthority);
    }

    /**
     * @notice Pause all redemptions (owner only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause redemptions (owner only)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Return all configured rate steps
     */
    function getRateSteps() external view returns (RateStep[] memory) {
        return _steps;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Require that msg.sender is the NFT owner, the token-approved address,
     *      or an operator approved for all by the NFT owner.
     */
    function _requireNftAuthorized(uint256 nftId) internal view {
        address nftOwner = csaNft.ownerOf(nftId);
        if (
            msg.sender != nftOwner && csaNft.getApproved(nftId) != msg.sender
                && !csaNft.isApprovedForAll(nftOwner, msg.sender)
        ) revert NotAuthorized();
    }

    /**
     * @dev Compute USDC output and the applied redeemBps for a given CURD amount
     *      and current vault USDC balance.
     * @param curdAmount  CURD to redeem (18 decimals)
     * @param usdcBalance Current vault USDC balance (6 decimals)
     * @return usdcOut   USDC to pay out (6 decimals)
     * @return redeemBps The rate step bps applied
     */
    function _computeUsdcOut(uint256 curdAmount, uint256 usdcBalance)
        internal
        view
        returns (uint256 usdcOut, uint16 redeemBps)
    {
        redeemBps = _resolveRedeemBps(usdcBalance);
        // usdcOut = curdAmount * targetUsdcPerCurdE6 / 1e18 * redeemBps / 10_000
        // Divisions combined to minimize rounding loss.
        usdcOut = curdAmount * targetUsdcPerCurdE6 * uint256(redeemBps) / (1e18 * 10_000);
    }

    /**
     * @dev Select the first rate step (highest floor) whose remainingBpsFloor is
     *      satisfied by the current vault health ratio.
     * @param usdcBalance Current vault USDC balance (6 decimals)
     * @return The applicable redeemBps
     */
    function _resolveRedeemBps(uint256 usdcBalance) internal view returns (uint16) {
        if (_steps.length == 0) revert NoApplicableRateStep();
        if (usdcCap == 0) revert NoApplicableRateStep();

        uint256 remainingBps = usdcBalance * 10_000 / usdcCap;

        for (uint256 i = 0; i < _steps.length; i++) {
            if (remainingBps >= uint256(_steps[i].remainingBpsFloor)) {
                return _steps[i].redeemBps;
            }
        }

        revert NoApplicableRateStep();
    }

    /**
     * @dev Validate a rate steps array before storing.
     *      Requirements:
     *      - Non-empty
     *      - Strictly descending remainingBpsFloor
     *      - redeemBps ≤ 10_000
     *      - remainingBpsFloor ≤ 10_000
     */
    function _validateRateSteps(RateStep[] calldata steps) internal pure {
        if (steps.length == 0) revert InvalidRateSteps();

        for (uint256 i = 0; i < steps.length; i++) {
            if (steps[i].redeemBps > 10_000) revert InvalidRateSteps();
            if (steps[i].remainingBpsFloor > 10_000) revert InvalidRateSteps();
            if (i > 0 && steps[i].remainingBpsFloor >= steps[i - 1].remainingBpsFloor) {
                revert InvalidRateSteps();
            }
        }
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
