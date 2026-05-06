// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../core/interfaces/ICheesecoinsCore.sol";
import "./MerchantRegistry.sol";

/**
 * @title MerchantSettlement
 * @notice Phase 4 — Merchant Settlement Rail.
 *         Payers transfer CURD directly to allowlisted merchants through this contract,
 *         which emits a canonical MerchantPayment receipt event.
 *
 * @dev NO BURN. Merchant receives the full payment amount.
 *      This contract never holds CURD — all transfers flow payer → merchant atomically.
 *      Merchants must be enabled in MerchantRegistry before receiving payments.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerchantSettlement is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ STATE ============

    /// @notice CURD token (18 decimals)
    ICheesecoinsCore public curd;

    /// @notice Merchant allowlist registry
    MerchantRegistry public registry;

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error NotAMerchant(address merchant);

    // ============ EVENTS ============

    /**
     * @notice Emitted on every successful merchant payment
     * @param payer     Address that sent the CURD
     * @param merchant  Address that received the CURD
     * @param amount    Amount of CURD transferred (18 decimals)
     * @param ref Off-chain payment reference
     */
    event MerchantPayment(address indexed payer, address indexed merchant, uint256 amount, bytes32 indexed ref);

    /// @notice Emitted when the merchant registry address is updated
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize MerchantSettlement
     * @param _curd     CURD token address
     * @param _registry MerchantRegistry address
     * @param _owner    Contract owner (governance/multisig)
     */
    function initialize(address _curd, address _registry, address _owner) external initializer {
        if (_curd == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        curd = ICheesecoinsCore(_curd);
        registry = MerchantRegistry(_registry);

        _transferOwnership(_owner);
    }

    // ============ PAYMENT ============

    /**
     * @notice Pay a merchant with CURD
     * @param merchant  Recipient — must be enabled in MerchantRegistry
     * @param amount    Amount of CURD to transfer (must be > 0)
     * @param ref Off-chain payment reference (emitted in event only)
     *
     * @dev CURD flows directly payer → merchant via transferFrom.
     *      This contract never holds CURD.
     */
    function payMerchant(address merchant, uint256 amount, bytes32 ref) external nonReentrant whenNotPaused {
        if (!registry.isMerchant(merchant)) revert NotAMerchant(merchant);
        if (amount == 0) revert ZeroAmount();

        IERC20Upgradeable(address(curd)).safeTransferFrom(msg.sender, merchant, amount);

        emit MerchantPayment(msg.sender, merchant, amount, ref);
    }

    // ============ ADMIN ============

    /// @notice Pause the settlement contract (blocks payMerchant)
    function pause() external virtual onlyOwner {
        _pause();
    }

    /// @notice Unpause the settlement contract
    function unpause() external virtual onlyOwner {
        _unpause();
    }

    /**
     * @notice Update the merchant registry address
     * @param _registry New MerchantRegistry address
     */
    function setRegistry(address _registry) external virtual onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        address old = address(registry);
        registry = MerchantRegistry(_registry);
        emit RegistryUpdated(old, _registry);
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
