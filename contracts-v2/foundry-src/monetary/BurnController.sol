// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../core/interfaces/ICheesecoinsCore.sol";
import "../Config.sol";

/**
 * @title BurnController
 * @notice DAO-only metric-aware burns: burns are allowed only when backing < MIN_BACKING_BPS
 * @dev Burns from treasuryTokenHolder using burnFrom (requires prior allowance from that wallet).
 */
contract BurnController is ReentrancyGuard {
    // ============ STATE ============

    /// @notice DAO/timelock address — the sole authority to call daoBurn
    address public immutable dao;

    /// @notice Core CURD token contract
    ICheesecoinsCore public immutable core;

    /// @notice USDC token contract (6 decimals)
    IERC20 public immutable usdc;

    /// @notice Wallet holding the protocol's USDC
    address public immutable treasuryUsdcWallet;

    /// @notice Wallet holding CURD tokens to be burned (must approve this contract)
    address public immutable treasuryTokenHolder;

    // ============ EVENTS ============

    event Burned(uint256 amount, uint256 backingBps);

    // ============ CONSTRUCTOR ============

    /**
     * @param _dao Timelock/DAO address
     * @param _core CheesecoinsCore contract
     * @param _usdc USDC token contract
     * @param _treasuryUsdcWallet Wallet holding the protocol's USDC
     * @param _treasuryTokenHolder Wallet holding CURD whose tokens will be burned
     */
    constructor(address _dao, address _core, address _usdc, address _treasuryUsdcWallet, address _treasuryTokenHolder) {
        require(_dao != address(0), "ZERO_ADDRESS");
        require(_core != address(0), "ZERO_ADDRESS");
        require(_usdc != address(0), "ZERO_ADDRESS");
        require(_treasuryUsdcWallet != address(0), "ZERO_ADDRESS");
        require(_treasuryTokenHolder != address(0), "ZERO_ADDRESS");

        dao = _dao;
        core = ICheesecoinsCore(_core);
        usdc = IERC20(_usdc);
        treasuryUsdcWallet = _treasuryUsdcWallet;
        treasuryTokenHolder = _treasuryTokenHolder;
    }

    // ============ VIEW ============

    /**
     * @notice Compute the current backing ratio in basis points
     * @return Backing ratio (10_000 = 100%)
     */
    function backingBps() public view returns (uint256) {
        uint256 supply = IERC20(address(core)).totalSupply();
        if (supply == 0) return Config.BASIS_POINTS;
        uint256 treasury = usdc.balanceOf(treasuryUsdcWallet);
        uint256 treasury18 = treasury * 1e12;
        return (treasury18 * Config.BASIS_POINTS) / supply;
    }

    // ============ BURN ============

    /**
     * @notice Burn CURD from the treasury token holder (DAO-only, backing must be < floor)
     * @param amount Amount of CURD to burn (18 decimals)
     * @param reason Audit/reason string for off-chain logging (not emitted; stored in calldata)
     * @dev The treasury token holder must have approved this contract at least `amount` CURD.
     */
    function daoBurn(uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == dao, "DAO_ONLY");

        uint256 bps = backingBps();
        require(bps < Config.MIN_BACKING_BPS, "BACKING_HEALTHY");

        core.burnFrom(treasuryTokenHolder, amount);

        emit Burned(amount, bps);
    }
}
