// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransitionCalldataBuilder
 * @notice Phase 6A — Pure calldata helper for ProtocolTimelock stage transitions.
 * @dev This contract has NO roles, NO state, and CANNOT execute anything.
 *      It is a read-only utility that assembles the calldata arrays required to call
 *      ProtocolTimelock.scheduleBatch(...) for each governance stage transition.
 *
 *      Usage pattern (caller is a Timelock PROPOSER):
 *
 *        (address[] targets, uint256[] values, bytes[] payloads) =
 *            builder.buildStage0To1Calldata(address(governor));
 *
 *        protocolTimelock.scheduleBatch(
 *            targets, values, payloads,
 *            bytes32(0),        // predecessor: none
 *            STAGE_0_TO_1_SALT, // deterministic salt
 *            protocolTimelock.getMinDelay()
 *        );
 *
 *      Each transition is a single atomic batch so there is no inconsistent
 *      intermediate window between granting and revoking roles.
 *
 * Stage transitions (privileged operations on ProtocolTimelock itself):
 *
 *   Stage 0 → 1 (Year 2 eligible):
 *     - grantRole(PROPOSER_ROLE, governor)
 *     (Founder remains proposer; DAO joins as co-proposer.)
 *
 *   Stage 1 → 2 (Year 3 eligible):
 *     - grantRole(PROPOSER_ROLE, governor)    // idempotent — ensures governor has it
 *     - revokeRole(PROPOSER_ROLE, founder)   // atomic with grant
 *     (DAO becomes sole proposer.)
 *
 *   Stage 2 → 3 (Year 5 eligible):
 *     - revokeRole(CANCELLER_ROLE, oldGuardian)
 *     - grantRole(CANCELLER_ROLE, daoCouncil)
 *     (Guardian rotates to DAO-elected security council.)
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract TransitionCalldataBuilder {
    // ────────────────────────────────────────────────────────────────────────
    // Role constants (keccak256 of OZ TimelockController role names)
    // ────────────────────────────────────────────────────────────────────────

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    // ────────────────────────────────────────────────────────────────────────
    // Deterministic salts — one per transition; must be unique across batches
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Salt for Stage 0 → 1 scheduleBatch call.
    bytes32 public constant STAGE_0_TO_1_SALT = keccak256("CHEESECOINS_STAGE_0_TO_1");

    /// @notice Salt for Stage 1 → 2 scheduleBatch call.
    bytes32 public constant STAGE_1_TO_2_SALT = keccak256("CHEESECOINS_STAGE_1_TO_2");

    /// @notice Salt for Stage 2 → 3 scheduleBatch call.
    bytes32 public constant STAGE_2_TO_3_SALT = keccak256("CHEESECOINS_STAGE_2_TO_3");

    // ────────────────────────────────────────────────────────────────────────
    // Immutable reference
    // ────────────────────────────────────────────────────────────────────────

    /// @notice ProtocolTimelock contract (target of all role management calls).
    address public immutable protocolTimelock;

    // ────────────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @param _protocolTimelock Address of the deployed ProtocolTimelock.
     */
    constructor(address _protocolTimelock) {
        require(_protocolTimelock != address(0), "TCB: zero timelock");
        protocolTimelock = _protocolTimelock;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Stage 0 → 1 : grant DAO governor PROPOSER_ROLE (founder keeps theirs)
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns batch calldata for the Stage 0 → Stage 1 transition.
     * @dev Schedules: grantRole(PROPOSER_ROLE, governor) on the Timelock.
     *      Use STAGE_0_TO_1_SALT as the salt for scheduleBatch.
     * @param governor Address of the SuperHolderGovernance / DAO governor contract.
     * @return targets  Single-element array: [protocolTimelock]
     * @return values   Single-element array: [0]
     * @return payloads Single-element array: [grantRole(PROPOSER_ROLE, governor)]
     */
    function buildStage0To1Calldata(address governor)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        require(governor != address(0), "TCB: zero governor");

        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);

        targets[0] = protocolTimelock;
        values[0] = 0;
        payloads[0] = abi.encodeWithSelector(IAccessControl.grantRole.selector, PROPOSER_ROLE, governor);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Stage 1 → 2 : DAO becomes sole proposer; founder proposer revoked
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns batch calldata for the Stage 1 → Stage 2 transition.
     * @dev Two operations in one atomic batch:
     *      1. grantRole(PROPOSER_ROLE, governor)   — idempotent, ensures governor has it
     *      2. revokeRole(PROPOSER_ROLE, founder)   — atomic with the grant above
     *      Use STAGE_1_TO_2_SALT as the salt for scheduleBatch.
     * @param governor        DAO governor contract address.
     * @param founderProposer Founder multisig address whose PROPOSER_ROLE is revoked.
     * @return targets  Two-element array.
     * @return values   Two-element array (both 0).
     * @return payloads Two-element array.
     */
    function buildStage1To2Calldata(address governor, address founderProposer)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        require(governor != address(0), "TCB: zero governor");
        require(founderProposer != address(0), "TCB: zero founder");

        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);

        targets[0] = protocolTimelock;
        values[0] = 0;
        payloads[0] = abi.encodeWithSelector(IAccessControl.grantRole.selector, PROPOSER_ROLE, governor);

        targets[1] = protocolTimelock;
        values[1] = 0;
        payloads[1] = abi.encodeWithSelector(IAccessControl.revokeRole.selector, PROPOSER_ROLE, founderProposer);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Stage 2 → 3 : rotate guardian CANCELLER_ROLE to DAO security council
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns batch calldata for the Stage 2 → Stage 3 transition.
     * @dev Two operations in one atomic batch:
     *      1. revokeRole(CANCELLER_ROLE, oldGuardian)
     *      2. grantRole(CANCELLER_ROLE, daoCouncil)
     *      Use STAGE_2_TO_3_SALT as the salt for scheduleBatch.
     * @param oldGuardian Existing guardian multisig address.
     * @param daoCouncil  New DAO-elected security council address.
     * @return targets  Two-element array.
     * @return values   Two-element array (both 0).
     * @return payloads Two-element array.
     */
    function buildStage2To3Calldata(address oldGuardian, address daoCouncil)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        require(oldGuardian != address(0), "TCB: zero guardian");
        require(daoCouncil != address(0), "TCB: zero council");

        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);

        targets[0] = protocolTimelock;
        values[0] = 0;
        payloads[0] = abi.encodeWithSelector(IAccessControl.revokeRole.selector, CANCELLER_ROLE, oldGuardian);

        targets[1] = protocolTimelock;
        values[1] = 0;
        payloads[1] = abi.encodeWithSelector(IAccessControl.grantRole.selector, CANCELLER_ROLE, daoCouncil);
    }
}
