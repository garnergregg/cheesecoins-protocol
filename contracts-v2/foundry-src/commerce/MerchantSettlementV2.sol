// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./MerchantSettlement.sol";

/**
 * @title MerchantSettlementV2
 * @notice Adds a delegated operator role so the founder EOA can pause/unpause
 *         the settlement rail without requiring a Gnosis Safe 2-of-2 signature.
 *
 * Access model after upgrade:
 * ┌──────────────────────────┬─────────┬──────────┐
 * │ Function                 │ owner   │ operator │
 * ├──────────────────────────┼─────────┼──────────┤
 * │ pause                    │  ✅     │  ✅      │
 * │ unpause                  │  ✅     │  ✅      │
 * │ setOperator              │  ✅     │  ❌      │
 * │ setRegistry              │  ✅     │  ❌      │
 * │ payMerchant              │ public  │ public   │
 * └──────────────────────────┴─────────┴──────────┘
 *
 * Storage compatibility (verified via forge inspect + cast storage on mainnet):
 *   V1 layout ends at slot 252 (__gap[50] at slots 203–252).
 *   V2 adds `operator` at slot 253 and reserves __gapV2[49] at slots 254–302.
 *   No new parent contracts added — no storage collision risk.
 *
 * Upgrade checklist (two Safe transactions):
 *   1. ProxyAdmin.upgrade(settlementProxy, address(implV2))
 *   2. MerchantSettlementV2(settlementProxy).initializeV2(founderEOA)
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerchantSettlementV2 is MerchantSettlement {
    // ── V2 storage (slot 253+) ─────────────────────────────────────────────────

    /// @notice Delegated operator — can pause/unpause without Safe approval
    address public operator;

    /// @dev Reserves space for future V2 additions.
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
     *      Call immediately after upgrading the proxy to V2 implementation.
     * @param _operator Address that may call pause/unpause without Safe approval.
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
     * @dev onlyOwner — Safe controls who can bypass Safe for emergency pause.
     * @param _operator New operator address. Pass address(0) to remove delegation.
     */
    function setOperator(address _operator) external onlyOwner {
        address prev = operator;
        operator = _operator;
        emit OperatorSet(prev, _operator);
    }

    // ── Overrides ──────────────────────────────────────────────────────────────

    /**
     * @notice Pause the settlement contract (blocks payMerchant).
     * @dev V2: callable by owner OR operator for immediate incident response.
     */
    function pause() external override onlyOwnerOrOperator {
        _pause();
    }

    /**
     * @notice Unpause the settlement contract.
     * @dev V2: callable by owner OR operator.
     */
    function unpause() external override onlyOwnerOrOperator {
        _unpause();
    }

    /**
     * @notice Update the merchant registry address.
     * @dev Stays onlyOwner — registry changes are governance decisions.
     */
    function setRegistry(address _registry) external override onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        address old = address(registry);
        registry = MerchantRegistry(_registry);
        emit RegistryUpdated(old, _registry);
    }
}
