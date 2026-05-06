// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IHedgeModule.sol";

// ============ INLINE INTERFACES ============

/**
 * @dev Minimal Uniswap v3 pool interface — only observe() and token accessors required.
 */
interface IUniswapV3PoolTwap {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title StabilityCoordinator
 * @notice Phase-3 treasury-controlled stabilization coordinator.
 *         The treasury calls stabilize() when it judges CURD to be below peg.
 *         This contract validates the deviation via a Uniswap v3 TWAP and, if
 *         the price is sufficiently below the target, delegates the buyback to
 *         HedgeModule.
 *
 * @dev Upgrade-safe: Initializable + OwnableUpgradeable + ReentrancyGuardUpgradeable
 *      + PausableUpgradeable.
 *
 *      TWAP math: Uses a minimal inline TickMath (getSqrtRatioAtTick) and an
 *      integer price formula.  Assumes CURD (18 dec) / USDC (6 dec) pool.
 *      Price is computed as priceE6 = (sqrtPriceX96 * 1e9 / 2^96)^2 when CURD
 *      is token0, or 1e36 / that value when USDC is token0.
 *
 *      Soft peg: no hard USD guarantee.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract StabilityCoordinator is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // ============ CONSTANTS ============

    uint256 private constant Q96 = 2 ** 96;

    // ============ STATE ============

    /// @notice Treasury — only address that may call stabilize()
    address public treasury;

    /// @notice HedgeModule — receives buyback execution calls
    IHedgeModule public hedgeModule;

    /// @notice Uniswap v3 CURD/USDC pool used for TWAP price measurement
    address public pool;

    /// @notice Whether CURD is token0 in the pool (determined at initialize from pool.token0())
    bool public curdIsToken0;

    /// @notice Target price of CURD in USDC, scaled by 1e6 (e.g. 1e6 = $1.00)
    uint256 public targetPriceE6;

    /// @notice Deviation threshold in basis points (e.g. 400 = 4%)
    /// Buyback is gated: only executes when priceE6 < targetPriceE6 * (10_000 - epsilonBps) / 10_000
    uint256 public epsilonBps;

    /// @notice TWAP window in seconds (e.g. 3600 = 1 hour)
    uint32 public twapWindow;

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error NotTreasury();
    error PriceAboveThreshold(uint256 priceE6, uint256 thresholdE6);
    error InvalidEpsilon();
    error InvalidTwapWindow();
    error InvalidPoolTokens(address token0, address token1, address curd);

    // ============ EVENTS ============

    event StabilizeAttempt(uint256 priceE6, uint256 thresholdE6, uint256 usdcAmount);
    event StabilizeExecuted(uint256 priceE6, uint256 usdcIn, uint256 curdBurned);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event HedgeModuleUpdated(address indexed oldModule, address indexed newModule);
    event PoolUpdated(address indexed oldPool, address indexed newPool, bool curdIsToken0);
    event TargetPriceUpdated(uint256 oldTarget, uint256 newTarget);
    event EpsilonUpdated(uint256 oldEpsilon, uint256 newEpsilon);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);

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
     * @notice Initialize StabilityCoordinator
     * @param _treasury      Treasury address (only caller for stabilize)
     * @param _hedgeModule   HedgeModule contract
     * @param _pool          Uniswap v3 CURD/USDC pool address
     * @param _curd          CURD token address (used to determine token ordering)
     * @param _targetPriceE6 Target CURD price in USDC (1e6 = $1.00)
     * @param _epsilonBps    Deviation threshold in bps (e.g. 400 = 4%)
     * @param _twapWindow    TWAP window in seconds (e.g. 3600)
     * @param _owner         Governance owner address
     */
    function initialize(
        address _treasury,
        address _hedgeModule,
        address _pool,
        address _curd,
        uint256 _targetPriceE6,
        uint256 _epsilonBps,
        uint32 _twapWindow,
        address _owner
    ) external initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_hedgeModule == address(0)) revert ZeroAddress();
        if (_pool == address(0)) revert ZeroAddress();
        if (_curd == address(0)) revert ZeroAddress();
        if (_targetPriceE6 == 0) revert ZeroAmount();
        if (_epsilonBps > 10_000) revert InvalidEpsilon();
        if (_twapWindow == 0) revert InvalidTwapWindow();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        treasury = _treasury;
        hedgeModule = IHedgeModule(_hedgeModule);
        pool = _pool;
        targetPriceE6 = _targetPriceE6;
        epsilonBps = _epsilonBps;
        twapWindow = _twapWindow;

        // Determine token ordering by querying both pool tokens; revert if CURD is neither.
        address t0 = IUniswapV3PoolTwap(_pool).token0();
        address t1 = IUniswapV3PoolTwap(_pool).token1();
        if (t0 == _curd) {
            curdIsToken0 = true;
        } else if (t1 == _curd) {
            curdIsToken0 = false;
        } else {
            revert InvalidPoolTokens(t0, t1, _curd);
        }

        _transferOwnership(_owner);
    }

    // ============ STABILIZE ============

    /**
     * @notice Trigger a buyback if CURD is sufficiently below peg
     * @dev Only the treasury may call this. The TWAP price is fetched from the
     *      Uniswap v3 pool and compared against the threshold.
     *      Reverts if the current price is at or above the threshold (no deviation).
     * @param usdcAmount  USDC to spend on buyback (passed through to HedgeModule)
     * @param minCurdOut  Minimum CURD to receive (slippage guard)
     * @param deadline    Swap deadline timestamp
     */
    function stabilize(uint256 usdcAmount, uint256 minCurdOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        onlyTreasury
    {
        if (usdcAmount == 0) revert ZeroAmount();

        uint256 priceE6 = _getTwapPriceE6();
        uint256 thresholdE6 = targetPriceE6 * (10_000 - epsilonBps) / 10_000;

        emit StabilizeAttempt(priceE6, thresholdE6, usdcAmount);

        if (priceE6 >= thresholdE6) revert PriceAboveThreshold(priceE6, thresholdE6);

        uint256 curdBurned = hedgeModule.executeBuyback(usdcAmount, minCurdOut, deadline);

        emit StabilizeExecuted(priceE6, usdcAmount, curdBurned);
    }

    // ============ OWNER SETTERS ============

    /**
     * @notice Update the treasury address (owner only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /**
     * @notice Update the HedgeModule (owner only)
     */
    function setHedgeModule(address _hedgeModule) external onlyOwner {
        if (_hedgeModule == address(0)) revert ZeroAddress();
        emit HedgeModuleUpdated(address(hedgeModule), _hedgeModule);
        hedgeModule = IHedgeModule(_hedgeModule);
    }

    /**
     * @notice Update the Uniswap v3 pool (owner only)
     *         Also re-derives curdIsToken0 from the new pool.
     * @param _pool New pool address
     * @param _curd CURD token address (used to determine ordering in the new pool)
     */
    function setPool(address _pool, address _curd) external onlyOwner {
        if (_pool == address(0)) revert ZeroAddress();
        if (_curd == address(0)) revert ZeroAddress();

        address t0 = IUniswapV3PoolTwap(_pool).token0();
        address t1 = IUniswapV3PoolTwap(_pool).token1();
        bool _curdIsToken0 = false;
        if (t0 == _curd) {
            _curdIsToken0 = true;
        } else if (t1 == _curd) {
            _curdIsToken0 = false;
        } else {
            revert InvalidPoolTokens(t0, t1, _curd);
        }

        emit PoolUpdated(pool, _pool, _curdIsToken0);
        pool = _pool;
        curdIsToken0 = _curdIsToken0;
    }

    /**
     * @notice Update the target CURD price (owner only)
     * @param _targetPriceE6 New target (1e6 = $1.00)
     */
    function setTargetPrice(uint256 _targetPriceE6) external onlyOwner {
        if (_targetPriceE6 == 0) revert ZeroAmount();
        emit TargetPriceUpdated(targetPriceE6, _targetPriceE6);
        targetPriceE6 = _targetPriceE6;
    }

    /**
     * @notice Update the deviation threshold (owner only)
     * @param _epsilonBps New threshold in bps (≤ 10_000)
     */
    function setEpsilon(uint256 _epsilonBps) external onlyOwner {
        if (_epsilonBps > 10_000) revert InvalidEpsilon();
        emit EpsilonUpdated(epsilonBps, _epsilonBps);
        epsilonBps = _epsilonBps;
    }

    /**
     * @notice Update the TWAP window (owner only)
     * @param _twapWindow New window in seconds (> 0)
     */
    function setTwapWindow(uint32 _twapWindow) external onlyOwner {
        if (_twapWindow == 0) revert InvalidTwapWindow();
        emit TwapWindowUpdated(twapWindow, _twapWindow);
        twapWindow = _twapWindow;
    }

    /**
     * @notice Pause stabilize calls (owner only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause stabilize calls (owner only)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ INTERNAL: TWAP PRICE ============

    /**
     * @dev Fetch the Uniswap v3 TWAP price for CURD expressed in USDC, scaled to 1e6.
     *      Steps:
     *        1. Call pool.observe() with [twapWindow, 0] to get tick cumulatives.
     *        2. Compute average tick over the window.
     *        3. Derive sqrtPriceX96 from tick using inline TickMath.
     *        4. Convert sqrtPriceX96 to priceE6 adjusting for CURD(18)/USDC(6) decimals.
     *
     * @return priceE6  CURD price in USDC scaled by 1e6 (1e6 = $1.00)
     */
    function _getTwapPriceE6() internal view returns (uint256 priceE6) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow; // older timestamp
        secondsAgos[1] = 0; // now

        // Bind both return values; secondsPerLiquidityCumulativeX128s is not needed for tick-based TWAP
        // slither-disable-next-line unused-local
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            IUniswapV3PoolTwap(pool).observe(secondsAgos);

        // Average tick over the window (Uniswap OracleLibrary rounding)
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 tick = int24(tickCumulativesDelta / int56(int256(uint256(twapWindow))));
        // Round toward negative infinity for negative tick (match Uniswap OracleLibrary)
        if (tickCumulativesDelta < 0 && tickCumulativesDelta % int56(int256(uint256(twapWindow))) != 0) {
            tick--;
        }

        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(tick);
        priceE6 = _sqrtPriceX96ToPriceE6(sqrtPriceX96);
    }

    /**
     * @dev Convert sqrtPriceX96 to priceE6 (CURD price in USDC scaled by 1e6).
     *      Uses the formula:
     *        mid = sqrtPriceX96 * 1e9 / 2^96
     *        priceE6 = mid^2          (when CURD is token0, USDC is token1)
     *                = 1e36 / mid^2  (when USDC is token0, CURD is token1)
     */
    function _sqrtPriceX96ToPriceE6(uint160 sqrtPriceX96) internal view returns (uint256 priceE6) {
        // mid = sqrt(price) * 1e9 — scaled so that (mid)^2 = priceE6 for CURD=token0 case
        // Use Math.mulDiv to perform the multiplication before division (precision-preserving)
        uint256 mid = Math.mulDiv(uint256(sqrtPriceX96), 1e9, Q96);
        uint256 midSq = mid * mid;

        if (curdIsToken0) {
            // priceE6 = (sqrtPriceX96 / 2^96)^2 * 1e18  = mid^2
            priceE6 = midSq;
        } else {
            // priceE6 = 1 / rawPrice * 1e6 = 1e36 / mid^2
            priceE6 = midSq == 0 ? type(uint256).max : (1e36 / midSq);
        }
    }

    // ============ INTERNAL: INLINE TICKMATH ============

    /**
     * @dev Compute sqrtPriceX96 from a tick using Uniswap v3 TickMath algorithm.
     *      Directly ported from Uniswap v3-core TickMath.getSqrtRatioAtTick.
     *      Constants encode the precomputed values for 1.0001^(2^i) at each bit position.
     *
     * @dev NOTE: Slither flags divide-before-multiply inside this function because it
     *      contains sequential `>> 128` (division) followed by `* constant` (multiplication).
     *      This is intentional Uniswap V3 reference math — changing the operation order
     *      would break precision.  This is NOT a real divide-before-multiply vulnerability.
     */
    // slither-disable-start divide-before-multiply
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "Tick out of range");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
    // slither-disable-end divide-before-multiply

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
