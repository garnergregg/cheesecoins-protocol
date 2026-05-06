// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./MerchantRegistryV2.sol";

/**
 * @title MerchantRegistryV3
 * @notice Adds a five-tier supply-chain classification to registered merchants so the
 *         protocol can settle CURD payments across the full agricultural chain
 *         (vendor → producer → processor → distributor → merchant) under a single registry.
 *
 * Tier semantics:
 *   - Merchant     (0) — sells to end consumers (default; backwards-compat for V2 entries)
 *   - Vendor       (1) — sells inputs / raw materials to a producer
 *   - Producer     (2) — turns raw inputs into a primary product (farms)
 *   - Processor    (3) — adds value (cheese plant, abattoir, packaging)
 *   - Distributor  (4) — bulk movement to retailers (wholesalers)
 *
 * Backwards compatibility:
 *   - setMerchant(addr, enabled) is unchanged. Entries set by V2 callers default to
 *     Tier.Merchant (enum value 0), matching the existing semantic of "isMerchant".
 *   - tierOf(addr) returns Tier.Merchant for any address whose tier was never explicitly
 *     set. This is intentional and parallels isMerchant() returning false for unknown
 *     addresses — tier is only meaningful when isMerchant(addr) is also true.
 *   - MerchantSettlement reads only isMerchant() and is unaffected by this upgrade.
 *
 * Storage compatibility (verified via forge inspect against V2):
 *   V2 ends at: __gapV2[49] occupying slots 153–201.
 *   V3 adds:   merchantTier mapping at slot 202, __gapV3[49] at slots 203–251.
 *   No collision with V2 fields, OwnableUpgradeable, or Initializable.
 *
 * Upgrade checklist (two Safe transactions):
 *   1. ProxyAdmin.upgrade(registryProxy, address(implV3))
 *   2. MerchantRegistryV3(registryProxy).initializeV3(addresses[], tiers[])
 *      — pass arrays for any existing merchant whose tier should NOT default to Merchant.
 *      — pass empty arrays if all existing merchants are correctly classified as Merchant.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerchantRegistryV3 is MerchantRegistryV2 {
    // ── Types ──────────────────────────────────────────────────────────────────

    /// @notice Supply-chain tier classification.
    /// @dev Merchant MUST be value 0 so existing V2 entries default correctly.
    enum Tier {
        Merchant, // 0 — default, sells to end consumers
        Vendor, // 1 — sells inputs / raw materials
        Producer, // 2 — primary production (farms)
        Processor, // 3 — value-added (cheese plant, abattoir)
        Distributor // 4 — bulk movement to retailers
    }

    // ── V3 storage (sits after V2's __gapV2[49] — slot 202 onward) ────────────

    /// @notice Tier classification per registered merchant.
    /// @dev Reads default to Tier.Merchant (0) for unset addresses.
    mapping(address => Tier) public merchantTier;

    /// @dev Reserves space for future V3 additions without storage collisions.
    ///      merchantTier (1 slot) + __gapV3[49] = 50 slots total for V3 additions.
    uint256[49] private __gapV3;

    // ── Events ─────────────────────────────────────────────────────────────────

    event MerchantTierSet(address indexed merchant, Tier indexed tier);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error LengthMismatch();
    error NotAMerchant();

    // ── Initialization ─────────────────────────────────────────────────────────

    /**
     * @notice Initialize V3 — optionally migrate existing merchants to non-default tiers.
     * @dev Uses reinitializer(3) — cannot be called again after first V3 init.
     *      Call this immediately after upgrading the proxy to V3 implementation.
     *      Pass empty arrays if all existing merchants should keep the default Tier.Merchant.
     *      Duplicate addresses are last-write-wins.
     * @param merchants Existing merchant addresses to assign a non-default tier.
     * @param tiers     Tier value for each address. MUST be the same length as `merchants`.
     */
    function initializeV3(address[] calldata merchants, Tier[] calldata tiers) external reinitializer(3) {
        if (merchants.length != tiers.length) revert LengthMismatch();

        for (uint256 i = 0; i < merchants.length; i++) {
            address m = merchants[i];
            if (m == address(0)) revert ZeroAddress();
            // Tier may be set even if isMerchant is false at this point — admin must
            // ensure setMerchant(m, true) is also called for the entry to be active.
            merchantTier[m] = tiers[i];
            emit MerchantTierSet(m, tiers[i]);
        }
    }

    // ── Tier setters ───────────────────────────────────────────────────────────

    /**
     * @notice Enable a merchant AND set their tier in one call.
     * @dev Preferred path for new merchant onboarding under V3.
     *      Bypasses the V2 default of Tier.Merchant.
     * @param merchant Address to update.
     * @param enabled  True to enable, false to disable.
     * @param tier     Tier classification to assign.
     */
    function setMerchantWithTier(address merchant, bool enabled, Tier tier) external onlyOwnerOrOperator {
        if (merchant == address(0)) revert ZeroAddress();
        isMerchant[merchant] = enabled;
        merchantTier[merchant] = tier;
        emit MerchantStatusChanged(merchant, enabled);
        emit MerchantTierSet(merchant, tier);
    }

    /**
     * @notice Update tier for an already-enabled merchant.
     * @dev Reverts if the address is not currently registered as a merchant.
     * @param merchant Address to update.
     * @param tier     New tier classification.
     */
    function setTier(address merchant, Tier tier) external onlyOwnerOrOperator {
        if (merchant == address(0)) revert ZeroAddress();
        if (!isMerchant[merchant]) revert NotAMerchant();
        merchantTier[merchant] = tier;
        emit MerchantTierSet(merchant, tier);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the tier of a merchant.
     * @dev Returns Tier.Merchant (0) for any unset address. Only meaningful when
     *      isMerchant(addr) is also true.
     */
    function tierOf(address merchant) external view returns (Tier) {
        return merchantTier[merchant];
    }
}
