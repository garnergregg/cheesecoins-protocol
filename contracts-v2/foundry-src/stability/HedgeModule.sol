// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../core/interfaces/ICheesecoinsCore.sol";
import "./BurnAuthority.sol";
import "./interfaces/IHedgeModule.sol";

// ============ INLINE INTERFACE ============

/**
 * @dev Minimal Uniswap v3 SwapRouter interface — only exactInputSingle is required.
 */
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/**
 * @title HedgeModule
 * @notice Phase-3 buyback module. Treasury pre-funds this contract with USDC.
 *         When triggered by the StabilityCoordinator, it swaps USDC for CURD on
 *         Uniswap v3 and permanently burns the acquired CURD via BurnAuthority.
 *
 * @dev Upgrade-safe: uses Initializable + OwnableUpgradeable + ReentrancyGuardUpgradeable.
 *      Access model:
 *        - onlyCoordinator  : executeBuyback (operational triggers)
 *        - onlyOwner        : governance setters (limits, addresses)
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract HedgeModule is IHedgeModule, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ STATE ============

    /// @notice USDC token (6 decimals) — used for buyback spending
    IERC20Upgradeable public usdc;

    /// @notice CURD token (18 decimals) — acquired and burned
    ICheesecoinsCore public curd;

    /// @notice Treasury — receives no funds; is the governance beneficiary
    address public treasury;

    /// @notice BurnAuthority contract — CURD is burned through this contract
    BurnAuthority public burnAuthority;

    /// @notice StabilityCoordinator — only address allowed to call executeBuyback
    address public coordinator;

    /// @notice Uniswap v3 SwapRouter
    ISwapRouter public swapRouter;

    /// @notice Uniswap v3 fee tier for the USDC/CURD pool (e.g. 500, 3000, 10000)
    uint24 public poolFee;

    // ---- Rate limits ----

    /// @notice Minimum seconds between consecutive executions
    uint256 public cooldownSeconds;

    /// @notice Maximum USDC allowed per single execution (6 decimals)
    uint256 public maxUsdcPerExecution;

    /// @notice Maximum USDC that may be spent in a rolling 24-hour window (6 decimals)
    uint256 public dailyBudget;

    /// @notice USDC spent in the current 24-hour window (6 decimals)
    uint256 public dailySpent;

    /// @notice Timestamp of the most recent executeBuyback call
    uint256 public lastExecutionTimestamp;

    /// @notice Timestamp when the current daily budget window started
    uint256 public lastBudgetReset;

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error NotCoordinator();
    error CooldownActive();
    error ExceedsMaxPerExecution();
    error DailyBudgetExceeded();

    // ============ EVENTS ============

    /// @notice Emitted when the coordinator address is updated
    event CoordinatorUpdated(address indexed oldCoordinator, address indexed newCoordinator);

    // ============ MODIFIERS ============

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize HedgeModule
     * @param _usdc              USDC token address (6 decimals)
     * @param _curd              CURD token address (18 decimals)
     * @param _burnAuthority     BurnAuthority contract
     * @param _treasury          Treasury address
     * @param _coordinator       StabilityCoordinator address
     * @param _router            Uniswap v3 SwapRouter address
     * @param _poolFee           Uniswap v3 pool fee tier
     * @param _cooldownSeconds   Minimum seconds between executions
     * @param _maxUsdcPerExec    Maximum USDC per single execution (6 decimals)
     * @param _dailyBudget       Maximum USDC per 24-hour window (6 decimals)
     * @param _owner             Governance owner address
     */
    function initialize(
        address _usdc,
        address _curd,
        address _burnAuthority,
        address _treasury,
        address _coordinator,
        address _router,
        uint24 _poolFee,
        uint256 _cooldownSeconds,
        uint256 _maxUsdcPerExec,
        uint256 _dailyBudget,
        address _owner
    ) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_curd == address(0)) revert ZeroAddress();
        if (_burnAuthority == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_coordinator == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();

        usdc = IERC20Upgradeable(_usdc);
        curd = ICheesecoinsCore(_curd);
        burnAuthority = BurnAuthority(_burnAuthority);
        treasury = _treasury;
        coordinator = _coordinator;
        swapRouter = ISwapRouter(_router);
        poolFee = _poolFee;
        cooldownSeconds = _cooldownSeconds;
        maxUsdcPerExecution = _maxUsdcPerExec;
        dailyBudget = _dailyBudget;
        lastBudgetReset = block.timestamp;

        _transferOwnership(_owner);
    }

    // ============ CORE: BUYBACK ============

    /**
     * @inheritdoc IHedgeModule
     * @dev Enforces cooldown, per-execution cap, and daily budget before swapping.
     *      CURD acquired is transferred to BurnAuthority and immediately burned.
     *      HedgeModule must already hold at least `usdcAmount` USDC (prefunded by treasury).
     */
    function executeBuyback(uint256 usdcAmount, uint256 minCurdOut, uint256 deadline)
        external
        override
        onlyCoordinator
        nonReentrant
        returns (uint256 curdBurned)
    {
        if (usdcAmount == 0) revert ZeroAmount();

        // ---- Cooldown ----
        if (cooldownSeconds > 0 && lastExecutionTimestamp != 0) {
            if (block.timestamp < lastExecutionTimestamp + cooldownSeconds) revert CooldownActive();
        }

        // ---- Per-execution cap ----
        if (maxUsdcPerExecution > 0 && usdcAmount > maxUsdcPerExecution) revert ExceedsMaxPerExecution();

        // ---- Daily budget with 1-day reset ----
        if (block.timestamp >= lastBudgetReset + 1 days) {
            dailySpent = 0;
            lastBudgetReset = block.timestamp;
        }
        if (dailyBudget > 0 && dailySpent + usdcAmount > dailyBudget) revert DailyBudgetExceeded();

        // Update rate-limit state before external calls
        dailySpent += usdcAmount;
        lastExecutionTimestamp = block.timestamp;

        // ---- Swap USDC → CURD via Uniswap v3 ----
        // Reset allowance to 0 first; required for USDC-style tokens that disallow
        // non-zero → non-zero allowance changes (e.g. USDC on mainnet).
        usdc.safeApprove(address(swapRouter), 0);
        usdc.safeApprove(address(swapRouter), usdcAmount);

        uint256 curdOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(curd),
                fee: poolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: usdcAmount,
                amountOutMinimum: minCurdOut,
                sqrtPriceLimitX96: 0
            })
        );

        // ---- Burn acquired CURD via BurnAuthority ----
        IERC20Upgradeable(address(curd)).safeTransfer(address(burnAuthority), curdOut);
        burnAuthority.burn(curdOut);

        curdBurned = curdOut;
        uint256 remaining = dailyBudget > dailySpent ? dailyBudget - dailySpent : 0;
        emit BuybackExecuted(usdcAmount, curdOut, block.timestamp, remaining);
    }

    // ============ OWNER SETTERS ============

    /**
     * @notice Update the StabilityCoordinator address (owner only)
     */
    function setCoordinator(address _coordinator) external onlyOwner {
        if (_coordinator == address(0)) revert ZeroAddress();
        address old = coordinator;
        coordinator = _coordinator;
        emit CoordinatorUpdated(old, _coordinator);
    }

    /**
     * @notice Update the treasury address (owner only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /**
     * @notice Update BurnAuthority (owner only)
     */
    function setBurnAuthority(address _burnAuthority) external onlyOwner {
        if (_burnAuthority == address(0)) revert ZeroAddress();
        burnAuthority = BurnAuthority(_burnAuthority);
    }

    /**
     * @notice Update the Uniswap v3 SwapRouter (owner only)
     */
    function setSwapRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        swapRouter = ISwapRouter(_router);
    }

    /**
     * @notice Update the Uniswap v3 pool fee tier (owner only)
     */
    function setPoolFee(uint24 _poolFee) external onlyOwner {
        poolFee = _poolFee;
    }

    /**
     * @notice Update the cooldown period (owner only)
     * @param _cooldownSeconds New cooldown in seconds (0 = no cooldown)
     */
    function setCooldown(uint256 _cooldownSeconds) external onlyOwner {
        cooldownSeconds = _cooldownSeconds;
    }

    /**
     * @notice Update the per-execution USDC cap (owner only)
     * @param _maxUsdcPerExec New per-execution cap (0 = no cap)
     */
    function setMaxUsdcPerExecution(uint256 _maxUsdcPerExec) external onlyOwner {
        maxUsdcPerExecution = _maxUsdcPerExec;
    }

    /**
     * @notice Update the 24-hour USDC budget (owner only)
     * @param _dailyBudget New daily budget (0 = no limit)
     */
    function setDailyBudget(uint256 _dailyBudget) external onlyOwner {
        dailyBudget = _dailyBudget;
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
