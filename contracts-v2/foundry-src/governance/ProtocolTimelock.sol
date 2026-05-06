// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import {Config} from "../Config.sol";

/**
 * @title ProtocolTimelock
 * @notice Phase 5 — Governance-controlled timelock for protocol upgrades and critical operations.
 * @dev Wraps OpenZeppelin TimelockController with Cheesecoins-specific minimum-delay enforcement.
 *
 * Role summary:
 *   TIMELOCK_ADMIN_ROLE — Manages the timelock's own role configuration.  Passing address(0)
 *                         as `admin` makes the contract self-governed: the only way to change
 *                         roles after deployment is to schedule the change through the timelock
 *                         itself (subject to the delay).  This is the recommended production
 *                         setting — bake ALL required roles into the constructor call.
 *   PROPOSER_ROLE       — Can schedule operations (multisig / governance contract).
 *                         Note: OZ TimelockController also grants CANCELLER_ROLE to every
 *                         proposer by default.
 *   EXECUTOR_ROLE       — Can execute matured operations; pass address(0) to allow open
 *                         execution by anyone once the delay has elapsed.
 *   CANCELLER_ROLE      — Can cancel pending operations.  Granted to all proposers by OZ
 *                         default AND to every address in the explicit `cancellers` array
 *                         (e.g. a guardian / security council multisig).
 *
 * Bootstrap sequence (recommended production deployment):
 *   1. Determine: proposersMultisig, guardianMultisig, operationalMultisig.
 *   2. Deploy:
 *        new ProtocolTimelock(
 *            Config.TIMELOCK_DELAY,
 *            [proposersMultisig],
 *            [address(0)],          // open execution
 *            [guardianMultisig],    // guardian gets CANCELLER_ROLE
 *            address(0)             // no extra admin: self-governed immediately
 *        )
 *   3. Upgrade MerchantRegistry proxy to MerchantRegistryV2 impl.
 *   4. Call MerchantRegistryV2.initializeV2(
 *            admin    = address(ProtocolTimelock),
 *            guardian = guardianMultisig,
 *            operator = operationalMultisig
 *        )
 *   5. Upgrade MerchantSettlement proxy to MerchantSettlementV2 impl and repeat step 4.
 *   6. Transfer ProxyAdmin ownership to the ProtocolTimelock (or to a separate
 *        upgrade-controller multisig that is itself a proposer on the timelock).
 *   7. Optionally: call OwnableUpgradeable.transferOwnership(address(ProtocolTimelock))
 *        on each V2 proxy so the Ownable owner tracks governance.
 *
 * Threat model mitigations:
 *   - Governance takeover: minimum delay >= Config.TIMELOCK_DELAY (2 days) prevents same-block
 *     manipulation; only PROPOSER_ROLE addresses can schedule operations.
 *   - Key compromise: CANCELLER_ROLE (guardian) can cancel malicious pending operations
 *     before execution; with admin=address(0) a compromised proposer key cannot silently
 *     grant itself new roles without also going through the delay.
 *   - Timelock bypass: all state-changing protocol operations must be routed through this
 *     contract; granting EXECUTOR_ROLE to address(0) relies purely on delay.
 *   - Role escalation: with admin=address(0) the contract is its own admin; role grants
 *     also require timelock delay.
 *
 * Scope (Phase 5 only):
 *   IN  — Upgrade authority for MerchantRegistry and MerchantSettlement proxies.
 *   IN  — Role management for MerchantRegistryV2 and MerchantSettlementV2.
 *   OUT — Tokenomics, fee logic, burn logic, economic layer parameters (no changes).
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract ProtocolTimelock is TimelockController {
    /// @notice Minimum allowed delay enforced on top of TimelockController's own floor.
    uint256 public constant MIN_PROTOCOL_DELAY = Config.TIMELOCK_DELAY; // 2 days

    // ============ EVENTS ============

    /// @notice Emitted when the timelock is deployed with initial configuration.
    event ProtocolTimelockDeployed(
        uint256 minDelay, uint256 proposerCount, uint256 executorCount, uint256 cancellerCount
    );

    // ============ ERRORS ============

    error DelayBelowMinimum(uint256 provided, uint256 minimum);
    error EmptyProposers();
    error ZeroCanceller();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Deploy the ProtocolTimelock.
     * @param minDelay    Minimum delay before operations can be executed.
     *                    Must be >= Config.TIMELOCK_DELAY (2 days).
     * @param proposers   Addresses that may schedule operations (multisig / governance).
     *                    Must contain at least one address.
     *                    OZ also grants CANCELLER_ROLE to every proposer by default.
     * @param executors   Addresses that may execute matured operations.
     *                    Pass [address(0)] to allow open execution by anyone.
     * @param cancellers  Additional addresses granted CANCELLER_ROLE (e.g. guardian /
     *                    security council).  These addresses can cancel malicious pending
     *                    operations without being able to propose new ones.
     *                    Pass an empty array if no extra cancellers are needed.
     * @param admin       Optional extra admin address granted TIMELOCK_ADMIN_ROLE.
     *                    Pass address(0) to make the timelock self-governed immediately —
     *                    all role changes after deployment will require going through the
     *                    timelock delay.  Recommended for production (pass all roles above).
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address[] memory cancellers,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        if (minDelay < MIN_PROTOCOL_DELAY) {
            revert DelayBelowMinimum(minDelay, MIN_PROTOCOL_DELAY);
        }
        if (proposers.length == 0) {
            revert EmptyProposers();
        }

        // Grant CANCELLER_ROLE to explicit guardian / security-council addresses.
        // (OZ already grants it to every proposer; this extends cancellation rights
        // to a dedicated guardian without giving them proposal authority.)
        for (uint256 i = 0; i < cancellers.length; i++) {
            if (cancellers[i] == address(0)) revert ZeroCanceller();
            _grantRole(CANCELLER_ROLE, cancellers[i]);
        }

        emit ProtocolTimelockDeployed(minDelay, proposers.length, executors.length, cancellers.length);
    }

    /**
     * @notice Validate that a proposed delay reduction does not go below MIN_PROTOCOL_DELAY.
     * @dev OZ TimelockController.updateDelay is external with private _minDelay — it cannot
     *      be overridden to enforce our floor at the Solidity level without duplicating OZ internals.
     *
     *      Mainnet mitigations (layered defense):
     *        1. Any call to updateDelay must be scheduled as a timelock operation (subject to
     *           the CURRENT 2-day delay before it can execute).
     *        2. On mainnet, scheduling requires SuperHolderGovernance PROPOSER_ROLE (Stage 1+),
     *           which requires 66% supermajority + 70% quorum + 24-week stake age.
     *        3. The guardian multisig holds CANCELLER_ROLE and has the full delay window to
     *           cancel any malicious updateDelay proposal before it executes.
     *        4. All proposers and operations are visible on-chain immediately upon scheduling.
     *
     *      OPERATIONAL REQUIREMENT: Never schedule or execute a governance proposal that calls
     *      updateDelay(newDelay) with newDelay < Config.TIMELOCK_DELAY (2 days) on mainnet.
     *      Sepolia testing with reduced delay is intentional and acceptable.
     *
     * @param newDelay The proposed new delay — call reverts if below MIN_PROTOCOL_DELAY.
     */
    function validateDelayUpdate(uint256 newDelay) external pure {
        if (newDelay < MIN_PROTOCOL_DELAY) {
            revert DelayBelowMinimum(newDelay, MIN_PROTOCOL_DELAY);
        }
    }
}
