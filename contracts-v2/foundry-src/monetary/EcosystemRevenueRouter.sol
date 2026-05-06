// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Config.sol";

/**
 * @title EcosystemRevenueRouter
 * @notice Routes ecosystem revenue: 99% to treasury, 1% accrued for founder (claim-based).
 * @dev Founder share is sunsetted when totalSupply >= MAX_SUPPLY.
 *      No upgrades. No admin knobs. SafeERC20 + ReentrancyGuard throughout.
 */
contract EcosystemRevenueRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ IMMUTABLES ============

    /// @notice CURD core token (used for totalSupply check)
    address public immutable core;

    /// @notice Treasury wallet receiving the bulk of revenue (99%+)
    address public immutable treasury;

    /// @notice Founder address eligible to claim accrued revenue share
    address public immutable founder;

    // ============ STATE ============

    /// @notice Total amount accrued for the founder per token
    mapping(address => uint256) public founderAccrued;

    /// @notice Total amount already claimed by the founder per token
    mapping(address => uint256) public founderClaimed;

    // ============ EVENTS ============

    event Routed(address indexed token, uint256 amount, uint256 founderCut);
    event Claimed(address indexed token, uint256 amount);

    // ============ CONSTRUCTOR ============

    /**
     * @param _core CheesecoinsCore address (for totalSupply sunset check)
     * @param _treasury Treasury wallet address
     * @param _founder Founder address
     */
    constructor(address _core, address _treasury, address _founder) {
        require(_core != address(0), "ZERO_ADDRESS");
        require(_treasury != address(0), "ZERO_ADDRESS");
        require(_founder != address(0), "ZERO_ADDRESS");

        core = _core;
        treasury = _treasury;
        founder = _founder;
    }

    // ============ ROUTE ============

    /**
     * @notice Accept revenue and split between treasury and founder accrual.
     * @param token ERC20 token address of the revenue being routed
     * @param amount Total amount to route (transferred from caller)
     * @dev Founder share is 0 once totalSupply >= MAX_SUPPLY (sunset).
     */
    function route(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 founderCut = 0;
        if (IERC20(core).totalSupply() < Config.MAX_SUPPLY) {
            founderCut = (amount * Config.FOUNDER_REVENUE_BPS) / Config.BASIS_POINTS;
        }

        uint256 treasuryCut = amount - founderCut;

        if (founderCut > 0) {
            founderAccrued[token] += founderCut;
        }

        IERC20(token).safeTransfer(treasury, treasuryCut);

        emit Routed(token, amount, founderCut);
    }

    // ============ CLAIM ============

    /**
     * @notice Founder claims their accrued revenue share for a specific token.
     * @param token ERC20 token address to claim
     */
    function claim(address token) external nonReentrant {
        require(msg.sender == founder, "NOT_FOUNDER");

        uint256 accrued = founderAccrued[token];
        uint256 claimed = founderClaimed[token];
        // Invariant: claimed can never exceed accrued (enforced by incrementing claimed by claimable)
        require(accrued >= claimed, "CLAIMED_GT_ACCRUED");
        uint256 claimable = accrued - claimed;
        require(claimable > 0, "NOTHING_TO_CLAIM");

        founderClaimed[token] = accrued;

        IERC20(token).safeTransfer(founder, claimable);

        emit Claimed(token, claimable);
    }
}
