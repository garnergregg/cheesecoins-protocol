// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MerchantRegistry
 * @notice Governance-controlled allowlist of merchants eligible to receive CURD payments
 *         via the MerchantSettlement contract.
 * @dev Phase 4 — Merchant Settlement Rail.
 *      Only governance (owner) may enable or disable merchant addresses.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerchantRegistry is Initializable, OwnableUpgradeable {
    // ============ STATE ============

    /// @notice Returns true if the address is an enabled merchant
    mapping(address => bool) public isMerchant;

    // ============ ERRORS ============

    error ZeroAddress();

    // ============ EVENTS ============

    event MerchantStatusChanged(address indexed merchant, bool enabled);

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize MerchantRegistry
     * @param _owner Contract owner (governance/multisig)
     */
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __Ownable_init();
        _transferOwnership(_owner);
    }

    // ============ GOVERNANCE ============

    /**
     * @notice Enable or disable a merchant address
     * @param merchant Address to update
     * @param enabled  True to enable, false to disable
     */
    function setMerchant(address merchant, bool enabled) external virtual onlyOwner {
        if (merchant == address(0)) revert ZeroAddress();
        isMerchant[merchant] = enabled;
        emit MerchantStatusChanged(merchant, enabled);
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
