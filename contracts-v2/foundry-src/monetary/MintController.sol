// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../core/interfaces/ICheesecoinsCore.sol";
import "../Config.sol";

/**
 * @title MintController
 * @notice DAO-only minting with metric gates (USDC backing + supply cap)
 * @dev No upgrades, no owner besides DAO, no arbitrary parameter setters.
 *
 * Gates (all must pass before minting):
 *   1. msg.sender == dao
 *   2. treasury USDC >= Config.TREASURY_USDC_THRESHOLD (40M USDC)
 *   3. backingBps() >= Config.MIN_BACKING_BPS (75%)
 *   4. totalSupply + amount <= Config.MAX_SUPPLY
 */
contract MintController is ReentrancyGuard {
    // ============ STATE ============

    /// @notice DAO/timelock address — the sole authority to call daoMint
    address public immutable dao;

    /// @notice Core CURD token contract
    ICheesecoinsCore public immutable core;

    /// @notice USDC token contract (6 decimals)
    IERC20 public immutable usdc;

    /// @notice Wallet where USDC treasury balance is held
    address public immutable treasuryUsdcWallet;

    // ============ EVENTS ============

    event Minted(address indexed to, uint256 amount, uint256 backingBps);

    // ============ CONSTRUCTOR ============

    /**
     * @param _dao Timelock/DAO address
     * @param _core CheesecoinsCore contract
     * @param _usdc USDC token contract
     * @param _treasuryUsdcWallet Wallet holding the protocol's USDC
     */
    constructor(address _dao, address _core, address _usdc, address _treasuryUsdcWallet) {
        require(_dao != address(0), "ZERO_ADDRESS");
        require(_core != address(0), "ZERO_ADDRESS");
        require(_usdc != address(0), "ZERO_ADDRESS");
        require(_treasuryUsdcWallet != address(0), "ZERO_ADDRESS");

        dao = _dao;
        core = ICheesecoinsCore(_core);
        usdc = IERC20(_usdc);
        treasuryUsdcWallet = _treasuryUsdcWallet;
    }

    // ============ VIEW ============

    /**
     * @notice Compute the current backing ratio in basis points
     * @dev treasury (6 dec) converted to 18 dec, then (treasury18 * 10_000) / totalSupply
     * @return Backing ratio in basis points (10_000 = 100%)
     */
    function backingBps() public view returns (uint256) {
        uint256 supply = IERC20(address(core)).totalSupply();
        if (supply == 0) return Config.BASIS_POINTS;
        uint256 treasury = usdc.balanceOf(treasuryUsdcWallet);
        uint256 treasury18 = treasury * 1e12; // 6-decimal → 18-decimal
        return (treasury18 * Config.BASIS_POINTS) / supply;
    }

    // ============ MINT ============

    /**
     * @notice Mint new CURD tokens (DAO-only, metric-gated)
     * @param to Recipient address
     * @param amount Amount of CURD to mint (18 decimals)
     * @param reason Human-readable reason string forwarded to core
     */
    function daoMint(address to, uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == dao, "DAO_ONLY");

        uint256 treasury = usdc.balanceOf(treasuryUsdcWallet);
        require(treasury >= Config.TREASURY_USDC_THRESHOLD, "TREASURY_LT_THRESHOLD");

        uint256 bps = backingBps();
        require(bps >= Config.MIN_BACKING_BPS, "BACKING_BELOW_MIN");

        uint256 supply = IERC20(address(core)).totalSupply();
        require(supply + amount <= Config.MAX_SUPPLY, "SUPPLY_CAP_EXCEEDED");

        core.controllerMint(to, amount, reason);

        emit Minted(to, amount, bps);
    }
}
