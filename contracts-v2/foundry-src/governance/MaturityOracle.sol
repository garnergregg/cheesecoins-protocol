// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Config} from "../Config.sol";

// ─── Minimal interfaces ────────────────────────────────────────────────────

/// @dev Read-only slice of SceneTracker needed for eligibility checks.
interface ISceneTrackerView {
    /// @notice Number of wallets currently holding a full 100-scene collection.
    function superHolderCount() external view returns (uint256);
}

/// @dev Read-only slice of MerchantSettlementV2 needed for incident-proxy metric.
interface ISettlementV2View {
    /// @notice Unix timestamp of the most recent pause; 0 if never paused.
    function lastPauseTimestamp() external view returns (uint256);
}

/// @dev Read-only slice of FiatRedemptionVault needed for reserve-floor check.
interface IFiatRedemptionVaultView {
    /// @notice USDC token held by the vault (IERC20Upgradeable compatible address).
    function usdc() external view returns (address);
}

/// @dev Minimal ERC20 view for balance query.
interface IERC20View {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title MaturityOracle
 * @notice Phase 6A — On-chain maturity gate for governance stage transitions.
 * @dev Provides three boolean eligibility functions used by TransitionCalldataBuilder
 *      and SuperHolderGovernance when gating stage transitions.
 *
 * All metrics are verifiable purely on-chain:
 *   1. Elapsed time since T0 (block.timestamp arithmetic)
 *   2. superHolderCount from SceneTracker (bitmask tracking, no custody)
 *   3. lastPauseTimestamp from MerchantSettlementV2 (on-chain incident proxy)
 *   4. USDC vault balance >= reserveFloor (on-chain ERC20 balance check)
 *
 * Metrics intentionally excluded (unverifiable on-chain without trusted reporter):
 *   - governance participation rate
 *   - "no critical incidents" (beyond the settlement pause proxy)
 *   - volume-based metrics (no on-chain volume tracker yet)
 *
 * Year 2 eligibility requires ALL of:
 *   a) block.timestamp >= T0 + 2 * ONE_YEAR
 *   b) sceneTracker.superHolderCount() >= year2HolderMin (default: 40)
 *   c) vault USDC balance >= reserveFloor
 *   d) settlement never paused OR lastPauseTimestamp <= now - INCIDENT_FREE_WINDOW (180 days)
 *
 * Year 3 and Year 5 follow the same pattern with stricter thresholds.
 *
 * Thresholds are set at construction and updatable by the `admin` address.
 * In production, admin should be the ProtocolTimelock — any threshold change
 * then requires a timelocked governance proposal.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MaturityOracle {
    // ============ CONSTANTS ============

    /// @notice Minimum incident-free window (no pause) required for eligibility.
    uint256 public constant INCIDENT_FREE_WINDOW = 180 days;

    // ============ IMMUTABLES ============

    /// @notice Protocol genesis timestamp (T0).
    uint256 public immutable T0;

    /// @notice SceneTracker contract — source of superHolderCount.
    ISceneTrackerView public immutable sceneTracker;

    /// @notice MerchantSettlementV2 contract — source of lastPauseTimestamp.
    ISettlementV2View public immutable settlement;

    /// @notice FiatRedemptionVault contract — source of USDC balance.
    IFiatRedemptionVaultView public immutable fiatRedemptionVault;

    // ============ STATE (admin-updatable thresholds) ============

    /// @notice Address allowed to update eligibility thresholds.
    /// @dev Recommend setting to ProtocolTimelock post-deployment.
    address public admin;

    /// @notice Minimum USDC (6 decimals) the FiatRedemptionVault must hold.
    uint256 public reserveFloor;

    /// @notice Minimum super holder count required for Year 2 eligibility.
    uint256 public year2HolderMin;

    /// @notice Minimum super holder count required for Year 3 eligibility.
    uint256 public year3HolderMin;

    /// @notice Minimum super holder count required for Year 5 eligibility.
    uint256 public year5HolderMin;

    /// @notice Reserve floor multiplier for Year 3 (basis points; 12500 = 1.25×).
    uint256 public year3ReserveMultiplierBps;

    /// @notice Reserve floor multiplier for Year 5 (basis points; 15000 = 1.50×).
    uint256 public year5ReserveMultiplierBps;

    // ============ EVENTS ============

    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event ThresholdsUpdated(
        uint256 reserveFloor,
        uint256 year2HolderMin,
        uint256 year3HolderMin,
        uint256 year5HolderMin,
        uint256 year3ReserveMultiplierBps,
        uint256 year5ReserveMultiplierBps
    );

    // ============ ERRORS ============

    error ZeroAddress();
    error NotAdmin();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Deploy the MaturityOracle.
     * @param _T0                         Protocol genesis timestamp (e.g. MaturityOracle deploy time).
     * @param _sceneTracker               SceneTracker contract address.
     * @param _settlement                 MerchantSettlementV2 proxy address.
     * @param _fiatRedemptionVault        FiatRedemptionVault proxy address.
     * @param _admin                      Initial admin (recommend ProtocolTimelock).
     * @param _reserveFloor               Minimum USDC vault balance (6 decimals).
     * @param _year2HolderMin             Min super holders for Year 2 (default: 40).
     * @param _year3HolderMin             Min super holders for Year 3 (default: 80).
     * @param _year5HolderMin             Min super holders for Year 5 (default: 200).
     * @param _year3ReserveMultiplierBps  Year 3 reserve multiplier in bps (default: 12500 = 1.25×).
     * @param _year5ReserveMultiplierBps  Year 5 reserve multiplier in bps (default: 15000 = 1.50×).
     */
    constructor(
        uint256 _T0,
        address _sceneTracker,
        address _settlement,
        address _fiatRedemptionVault,
        address _admin,
        uint256 _reserveFloor,
        uint256 _year2HolderMin,
        uint256 _year3HolderMin,
        uint256 _year5HolderMin,
        uint256 _year3ReserveMultiplierBps,
        uint256 _year5ReserveMultiplierBps
    ) {
        if (_sceneTracker == address(0)) revert ZeroAddress();
        if (_settlement == address(0)) revert ZeroAddress();
        if (_fiatRedemptionVault == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        T0 = _T0;
        sceneTracker = ISceneTrackerView(_sceneTracker);
        settlement = ISettlementV2View(_settlement);
        fiatRedemptionVault = IFiatRedemptionVaultView(_fiatRedemptionVault);
        admin = _admin;

        reserveFloor = _reserveFloor;
        year2HolderMin = _year2HolderMin;
        year3HolderMin = _year3HolderMin;
        year5HolderMin = _year5HolderMin;
        year3ReserveMultiplierBps = _year3ReserveMultiplierBps;
        year5ReserveMultiplierBps = _year5ReserveMultiplierBps;
    }

    // ============ ELIGIBILITY FUNCTIONS ============

    /**
     * @notice Returns true when all Year 2 eligibility conditions are met.
     * @dev Required for Stage 0 → Stage 1 (grant SuperHoldersGovernance PROPOSER_ROLE).
     *
     * Conditions:
     *   a) block.timestamp >= T0 + 2 years
     *   b) sceneTracker.superHolderCount() >= year2HolderMin
     *   c) USDC vault balance >= reserveFloor
     *   d) settlement never paused OR last pause >= INCIDENT_FREE_WINDOW ago
     */
    function isYear2Eligible() external view returns (bool) {
        return _timeElapsed(2) && _holderCountMet(year2HolderMin) && _reserveMet(10000) && _incidentFreeMet();
    }

    /**
     * @notice Returns true when all Year 3 eligibility conditions are met.
     * @dev Required for Stage 1 → Stage 2 (revoke founder PROPOSER_ROLE).
     *
     * Conditions:
     *   a) block.timestamp >= T0 + 3 years
     *   b) sceneTracker.superHolderCount() >= year3HolderMin
     *   c) USDC vault balance >= reserveFloor * year3ReserveMultiplierBps / 10000
     *   d) last pause >= INCIDENT_FREE_WINDOW ago
     */
    function isYear3Eligible() external view returns (bool) {
        return _timeElapsed(3) && _holderCountMet(year3HolderMin) && _reserveMet(year3ReserveMultiplierBps)
            && _incidentFreeMet();
    }

    /**
     * @notice Returns true when all Year 5 eligibility conditions are met.
     * @dev Required for Stage 2 → Stage 3 (rotate guardian to DAO security council).
     *
     * Conditions:
     *   a) block.timestamp >= T0 + 5 years
     *   b) sceneTracker.superHolderCount() >= year5HolderMin
     *   c) USDC vault balance >= reserveFloor * year5ReserveMultiplierBps / 10000
     *   d) last pause >= INCIDENT_FREE_WINDOW ago
     */
    function isYear5Eligible() external view returns (bool) {
        return _timeElapsed(5) && _holderCountMet(year5HolderMin) && _reserveMet(year5ReserveMultiplierBps)
            && _incidentFreeMet();
    }

    // ============ VIEW HELPERS ============

    /**
     * @notice Returns the current USDC balance of FiatRedemptionVault (6 decimals).
     * @dev Reads usdc() from the vault (public state var → getter) then balanceOf.
     */
    function vaultUsdcBalance() public view returns (uint256) {
        address usdcToken = fiatRedemptionVault.usdc();
        return IERC20View(usdcToken).balanceOf(address(fiatRedemptionVault));
    }

    /**
     * @notice Seconds elapsed since T0.
     */
    function elapsedSinceT0() external view returns (uint256) {
        if (block.timestamp <= T0) return 0;
        return block.timestamp - T0;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update eligibility thresholds.
     * @dev Only callable by admin (recommended: ProtocolTimelock, so changes require timelock delay).
     */
    function setThresholds(
        uint256 _reserveFloor,
        uint256 _year2HolderMin,
        uint256 _year3HolderMin,
        uint256 _year5HolderMin,
        uint256 _year3ReserveMultiplierBps,
        uint256 _year5ReserveMultiplierBps
    ) external {
        if (msg.sender != admin) revert NotAdmin();

        reserveFloor = _reserveFloor;
        year2HolderMin = _year2HolderMin;
        year3HolderMin = _year3HolderMin;
        year5HolderMin = _year5HolderMin;
        year3ReserveMultiplierBps = _year3ReserveMultiplierBps;
        year5ReserveMultiplierBps = _year5ReserveMultiplierBps;

        emit ThresholdsUpdated(
            _reserveFloor,
            _year2HolderMin,
            _year3HolderMin,
            _year5HolderMin,
            _year3ReserveMultiplierBps,
            _year5ReserveMultiplierBps
        );
    }

    /**
     * @notice Transfer admin to a new address.
     * @dev Recommend: call via timelock to set admin = address(protocolTimelock).
     */
    function setAdmin(address _admin) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_admin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, _admin);
        admin = _admin;
    }

    // ============ INTERNAL ============

    /// @dev True if `numYears` full Config.ONE_YEAR periods have elapsed since T0.
    function _timeElapsed(uint256 numYears) internal view returns (bool) {
        return block.timestamp >= T0 + numYears * Config.ONE_YEAR;
    }

    /// @dev True if super holder count meets the required minimum.
    function _holderCountMet(uint256 minRequired) internal view returns (bool) {
        return sceneTracker.superHolderCount() >= minRequired;
    }

    /// @dev True if vault USDC balance >= reserveFloor * multiplierBps / 10000.
    ///      multiplierBps = 10000 → floor; 12500 → 1.25× floor; etc.
    function _reserveMet(uint256 multiplierBps) internal view returns (bool) {
        if (reserveFloor == 0) return true;
        uint256 required = (reserveFloor * multiplierBps) / 10000;
        return vaultUsdcBalance() >= required;
    }

    /// @dev True if settlement has never been paused OR was last paused >= INCIDENT_FREE_WINDOW ago.
    function _incidentFreeMet() internal view returns (bool) {
        uint256 lastPause = settlement.lastPauseTimestamp();
        if (lastPause == 0) return true; // never paused
        return block.timestamp >= lastPause + INCIDENT_FREE_WINDOW;
    }
}
