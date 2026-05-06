// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./MerchantRegistry.sol";

/**
 * @title MerchantRegistryV2
 * @notice Adds a delegated operator role so the founder EOA can onboard merchants
 *         without requiring a Gnosis Safe 2-of-2 signature for every call.
 *
 * Access model after upgrade:
 * ┌──────────────────────────┬─────────┬──────────┐
 * │ Function                 │ owner   │ operator │
 * ├──────────────────────────┼─────────┼──────────┤
 * │ setMerchant              │  ✅     │  ✅      │
 * │ setOperator              │  ✅     │  ❌      │
 * │ transferOwnership        │  ✅     │  ❌      │
 * └──────────────────────────┴─────────┴──────────┘
 *
 * Storage compatibility:
 *   V1 storage ends at: Initializable(1) + _owner(1) + isMerchant(1) + __gap[50].
 *   V2 adds `operator` and `__gapV2[49]` AFTER V1's layout — no collision.
 *
 * Upgrade checklist (two Safe transactions):
 *   1. ProxyAdmin.upgrade(registryProxy, address(implV2))
 *   2. MerchantRegistryV2(registryProxy).initializeV2(founderEOA)
 *      — sets operator to founder EOA so day-to-day onboarding bypasses Safe
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerchantRegistryV2 is MerchantRegistry {
    // ── V2 storage (sits after V1's __gap[50]) ─────────────────────────────────

    /// @notice Delegated operator — can onboard/offboard merchants without Safe
    address public operator;

    /// @dev Reserves space for future V2 additions without storage collisions.
    ///      operator (1 slot) + __gapV2[49] = 50 slots total for V2 additions.
    uint256[49] private __gapV2;

    // ── Events ─────────────────────────────────────────────────────────────────

    event OperatorSet(address indexed previous, address indexed next);

    // ── Errors ──────────────────────────────────────────────────────────────────

    error NotAuthorized();

    // ── Modifiers ──────────────────────────────────────────────────────────────

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorized();
        _;
    }

    // ── Initialization ─────────────────────────────────────────────────────────

    /**
     * @notice Initialize V2 — sets the delegated operator.
     * @dev Uses reinitializer(2) — cannot be called again after first V2 init.
     *      Call this immediately after upgrading the proxy to V2 implementation.
     * @param _operator Address that may call setMerchant without Safe approval.
     *                  Recommend: founder EOA. Set to address(0) to disable delegation.
     */
    function initializeV2(address _operator) external reinitializer(2) {
        address prev = operator;
        operator = _operator;
        emit OperatorSet(prev, _operator);
    }

    // ── Owner-only admin ───────────────────────────────────────────────────────

    /**
     * @notice Update the delegated operator.
     * @dev onlyOwner — Safe controls who can bypass Safe for merchant ops.
     * @param _operator New operator address. Pass address(0) to remove delegation.
     */
    function setOperator(address _operator) external onlyOwner {
        address prev = operator;
        operator = _operator;
        emit OperatorSet(prev, _operator);
    }

    // ── Override setMerchant ───────────────────────────────────────────────────

    /**
     * @notice Enable or disable a merchant address.
     * @dev V2: callable by owner OR operator.
     */
    function setMerchant(address merchant, bool enabled) external override onlyOwnerOrOperator {
        if (merchant == address(0)) revert ZeroAddress();
        isMerchant[merchant] = enabled;
        emit MerchantStatusChanged(merchant, enabled);
    }
}
