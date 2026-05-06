// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CurdDirectSale
 * @notice CURD token sale for USDC. Price and limits are owner-configurable.
 *         Bridges the gap before the Uniswap CURD/USDC pool is seeded.
 *         No KYC required — fully permissionless.
 *
 * @dev Upgradeable via OpenZeppelin Transparent Proxy pattern.
 *      ProxyAdmin should be owned by the Founder EOA (Ledger).
 *
 *      USDC  = 6 decimals
 *      CURD  = 18 decimals
 *
 *      Price modes:
 *        - Manual (default): owner sets priceUsdcPerCurd (USDC 6-decimal units per 1 CURD)
 *        - Oracle: when oracle != address(0), price is pulled from IPrice(oracle).getPrice()
 *          which must return USDC per CURD in 6-decimal units.
 *          Call setOracle(address(0)) to revert to manual mode.
 *
 *      Lifecycle:
 *        - Phase 1 (now):      manual price 1:1, min 1 USDC, max 100,000 USDC
 *        - Phase 2 (Uniswap):  call setOracle(uniswapTwapOracle) — price becomes market-driven
 *        - Wind-down:          pause() then recoverCurd(treasury, curdReserve())
 *
 * @custom:security-contact security@cheesecoins.io
 */

interface IPrice {
    /// @notice Returns current CURD price in USDC (6 decimals). e.g. 1e6 = $1.00
    function getPrice() external view returns (uint256);
}

contract CurdDirectSale is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ── State ─────────────────────────────────────────────────────────────────

    IERC20 public usdc;
    IERC20 public curd;
    address public treasury;

    /// @notice Minimum USDC purchase (6 dec). Default: 1 USDC.
    uint256 public minPurchaseUsdc;

    /// @notice Maximum USDC purchase (6 dec). Default: 100,000 USDC.
    uint256 public maxPurchaseUsdc;

    /// @notice Manual price: USDC per 1 CURD (6 dec). e.g. 1e6 = $1.00/CURD.
    ///         Ignored when oracle is set.
    uint256 public priceUsdcPerCurd;

    /// @notice Optional price oracle. When non-zero, overrides priceUsdcPerCurd.
    ///         Pass address(0) to setOracle() to revert to manual price mode.
    address public oracle;

    uint256 public totalUsdcRaised;
    uint256 public totalCurdSold;

    // ── Errors ────────────────────────────────────────────────────────────────

    error BelowMinimum(uint256 sent, uint256 minimum);
    error AboveMaximum(uint256 sent, uint256 maximum);
    error InsufficientCurdReserve(uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPrice();
    error InvalidMinMax();

    // ── Events ────────────────────────────────────────────────────────────────

    event CurdPurchased(address indexed buyer, uint256 usdcIn, uint256 curdOut, uint256 price);
    event PriceUpdated(uint256 newPriceUsdcPerCurd);
    event OracleUpdated(address indexed newOracle);
    event LimitsUpdated(uint256 newMin, uint256 newMax);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event CurdRecovered(address indexed to, uint256 amount);
    event UsdcRecovered(address indexed to, uint256 amount);

    // ── Constructor (disables initializers on implementation) ─────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ───────────────────────────────────────────────────────────

    /**
     * @notice Initialize the proxy.
     * @param _usdc        USDC token (6 dec) — Arbitrum One: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
     * @param _curd        CURD token (18 dec)
     * @param _treasury    Receives USDC proceeds
     * @param initialOwner Founder EOA / Ledger
     */
    function initialize(address _usdc, address _curd, address _treasury, address initialOwner) external initializer {
        if (_usdc == address(0) || _curd == address(0) || _treasury == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        usdc = IERC20(_usdc);
        curd = IERC20(_curd);
        treasury = _treasury;

        minPurchaseUsdc = 1e6; // 1 USDC
        maxPurchaseUsdc = 100_000e6; // 100,000 USDC
        priceUsdcPerCurd = 1e6; // $1.00 per CURD

        _transferOwnership(initialOwner);
    }

    // ── Purchase ──────────────────────────────────────────────────────────────

    /**
     * @notice Buy CURD with USDC. No KYC. No account required.
     * @param usdcAmount USDC to spend (6 decimals).
     */
    function buy(uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount < minPurchaseUsdc) revert BelowMinimum(usdcAmount, minPurchaseUsdc);
        if (usdcAmount > maxPurchaseUsdc) revert AboveMaximum(usdcAmount, maxPurchaseUsdc);

        uint256 price = _currentPrice();
        if (price == 0) revert InvalidPrice();

        // usdcAmount (6 dec) / price (6 dec) * 1e18 = curdAmount (18 dec)
        uint256 curdAmount = (usdcAmount * 1e18) / price;

        uint256 reserve = curd.balanceOf(address(this));
        if (reserve < curdAmount) revert InsufficientCurdReserve(curdAmount, reserve);

        // CEI: update state before external calls
        totalUsdcRaised += usdcAmount;
        totalCurdSold += curdAmount;

        usdc.safeTransferFrom(msg.sender, treasury, usdcAmount);
        curd.safeTransfer(msg.sender, curdAmount);

        emit CurdPurchased(msg.sender, usdcAmount, curdAmount, price);
    }

    // ── View ──────────────────────────────────────────────────────────────────

    /// @notice CURD tokens available for purchase right now.
    function curdReserve() external view returns (uint256) {
        return curd.balanceOf(address(this));
    }

    /// @notice Current effective price: USDC per 1 CURD (6 decimals).
    function currentPrice() external view returns (uint256) {
        return _currentPrice();
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _currentPrice() internal view returns (uint256) {
        if (oracle != address(0)) {
            return IPrice(oracle).getPrice();
        }
        return priceUsdcPerCurd;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update manual price. Only active when oracle == address(0).
    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        priceUsdcPerCurd = newPrice;
        emit PriceUpdated(newPrice);
    }

    /// @notice Set price oracle. Pass address(0) to revert to manual price.
    function setOracle(address newOracle) external onlyOwner {
        // address(0) is valid — it disables oracle mode and reverts to manual price
        oracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    /// @notice Update purchase limits.
    function setLimits(uint256 newMin, uint256 newMax) external onlyOwner {
        if (newMin == 0 || newMax == 0 || newMin > newMax) revert InvalidMinMax();
        minPurchaseUsdc = newMin;
        maxPurchaseUsdc = newMax;
        emit LimitsUpdated(newMin, newMax);
    }

    /// @notice Update treasury address.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Recover unsold CURD — use when winding down or rebalancing.
    function recoverCurd(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit CurdRecovered(to, amount);
        curd.safeTransfer(to, amount);
    }

    /// @notice Recover USDC sent directly to this contract (edge case only).
    function recoverUsdc(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit UsdcRecovered(to, amount);
        usdc.safeTransfer(to, amount);
    }
}
