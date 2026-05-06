// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/governance/ProtocolTimelock.sol";

/**
 * @title ProtocolTimelockTest
 * @notice Unit tests for ProtocolTimelock (Phase 5 governance timelock).
 */
contract ProtocolTimelockTest is Test {
    // ── Actors ──────────────────────────────────────────────────────────────
    address public deployer = makeAddr("deployer");
    address public proposer = makeAddr("proposer");
    address public executor = makeAddr("executor");
    address public guardian = makeAddr("guardian"); // explicit CANCELLER_ROLE holder
    address public stranger = makeAddr("stranger");
    address public target = makeAddr("target");

    // ── Constants ───────────────────────────────────────────────────────────
    uint256 public constant VALID_DELAY = Config.TIMELOCK_DELAY; // 2 days
    uint256 public constant SHORT_DELAY = Config.TIMELOCK_DELAY - 1; // below minimum

    // ── Contract under test ─────────────────────────────────────────────────
    ProtocolTimelock public timelock;

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _makeProposers(address addr) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = addr;
    }

    function _makeExecutors(address addr) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = addr;
    }

    function _makeCancellers(address addr) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = addr;
    }

    function _emptyCancellers() internal pure returns (address[] memory arr) {
        arr = new address[](0);
    }

    function setUp() public {
        vm.prank(deployer);
        // guardian is wired as an explicit canceller; admin=address(0) → self-governed
        timelock = new ProtocolTimelock(
            VALID_DELAY, _makeProposers(proposer), _makeExecutors(executor), _makeCancellers(guardian), address(0)
        );
    }

    // ── Deployment ──────────────────────────────────────────────────────────

    function test_deploy_setsCorrectMinDelay() public {
        assertEq(timelock.getMinDelay(), VALID_DELAY);
    }

    function test_deploy_rejectsDelayBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(ProtocolTimelock.DelayBelowMinimum.selector, SHORT_DELAY, VALID_DELAY));
        new ProtocolTimelock(
            SHORT_DELAY, _makeProposers(proposer), _makeExecutors(executor), _emptyCancellers(), address(0)
        );
    }

    function test_deploy_rejectsEmptyProposers() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(ProtocolTimelock.EmptyProposers.selector);
        new ProtocolTimelock(VALID_DELAY, empty, _makeExecutors(executor), _emptyCancellers(), address(0));
    }

    function test_deploy_emitsProtocolTimelockDeployed() public {
        address[] memory proposers = _makeProposers(proposer);
        address[] memory executors = _makeExecutors(executor);
        address[] memory cancellers = _makeCancellers(guardian);
        vm.expectEmit(false, false, false, true);
        emit ProtocolTimelock.ProtocolTimelockDeployed(VALID_DELAY, 1, 1, 1);
        new ProtocolTimelock(VALID_DELAY, proposers, executors, cancellers, address(0));
    }

    function test_deploy_emitsProtocolTimelockDeployed_noCancellers() public {
        address[] memory proposers = _makeProposers(proposer);
        address[] memory executors = _makeExecutors(executor);
        vm.expectEmit(false, false, false, true);
        emit ProtocolTimelock.ProtocolTimelockDeployed(VALID_DELAY, 1, 1, 0);
        new ProtocolTimelock(VALID_DELAY, proposers, executors, _emptyCancellers(), address(0));
    }

    // ── Minimum delay constant ───────────────────────────────────────────────

    function test_minProtocolDelay_equalsConfigTimelockDelay() public {
        assertEq(ProtocolTimelock(timelock).MIN_PROTOCOL_DELAY(), Config.TIMELOCK_DELAY);
    }

    // ── Role assignment ──────────────────────────────────────────────────────

    function test_proposer_hasProposerRole() public {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
    }

    function test_proposer_hasDefaultCancellerRole() public {
        // OZ TimelockController grants CANCELLER_ROLE to every proposer by default.
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
    }

    function test_guardian_hasCancellerRole() public {
        // Guardian is explicitly granted CANCELLER_ROLE via the cancellers[] constructor arg.
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
    }

    function test_guardian_lacksProposerRole() public {
        // Guardian can cancel but cannot propose new operations.
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
    }

    function test_executor_hasExecutorRole() public {
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor));
    }

    function test_stranger_lacksProposerRole() public {
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), stranger));
    }

    function test_stranger_lacksExecutorRole() public {
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), stranger));
    }

    function test_stranger_lacksCancellerRole() public {
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), stranger));
    }

    // ── Scheduling ───────────────────────────────────────────────────────────

    function test_schedule_revertsForNonProposer() public {
        vm.prank(stranger);
        vm.expectRevert();
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("salt"), VALID_DELAY);
    }

    function test_schedule_revertsForGuardian() public {
        // Guardian holds only CANCELLER_ROLE, not PROPOSER_ROLE.
        vm.prank(guardian);
        vm.expectRevert();
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("salt-g"), VALID_DELAY);
    }

    function test_schedule_succeeds_forProposer() public {
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("salt1"), VALID_DELAY);
        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("salt1"));
        assertTrue(timelock.isOperationPending(id));
    }

    // ── Execution ─────────────────────────────────────────────────────────────

    function test_execute_revertsBeforeDelay() public {
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("exec1"), VALID_DELAY);

        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("exec1"));
        assertTrue(timelock.isOperationPending(id));

        // Warp to just before ready
        vm.warp(block.timestamp + VALID_DELAY - 1);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(target, 0, bytes(""), bytes32(0), bytes32("exec1"));
    }

    function test_execute_succeeds_afterDelay() public {
        // Schedule a no-op call to target (EOA)
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("exec2"), VALID_DELAY);

        vm.warp(block.timestamp + VALID_DELAY);

        vm.prank(executor);
        timelock.execute(target, 0, bytes(""), bytes32(0), bytes32("exec2"));

        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("exec2"));
        assertTrue(timelock.isOperationDone(id));
    }

    // ── Cancellation ──────────────────────────────────────────────────────────

    function test_cancel_revertsForNonCanceller() public {
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("cancel1"), VALID_DELAY);
        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("cancel1"));

        vm.prank(stranger);
        vm.expectRevert();
        timelock.cancel(id);
    }

    function test_cancel_succeeds_forGuardian() public {
        // Guardian holds explicit CANCELLER_ROLE but no PROPOSER_ROLE.
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("cancel-g"), VALID_DELAY);
        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("cancel-g"));

        vm.prank(guardian);
        timelock.cancel(id);

        assertFalse(timelock.isOperationPending(id));
    }

    function test_cancel_succeeds_forProposer() public {
        // Proposers also hold CANCELLER_ROLE by OZ default (separate from guardian).
        vm.prank(proposer);
        timelock.schedule(target, 0, bytes(""), bytes32(0), bytes32("cancel2"), VALID_DELAY);
        bytes32 id = timelock.hashOperation(target, 0, bytes(""), bytes32(0), bytes32("cancel2"));

        vm.prank(proposer);
        timelock.cancel(id);

        assertFalse(timelock.isOperationPending(id));
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_deploy_rejectsDelayBelowMinimum(uint256 badDelay) public {
        badDelay = bound(badDelay, 0, VALID_DELAY - 1);
        vm.expectRevert();
        new ProtocolTimelock(
            badDelay, _makeProposers(proposer), _makeExecutors(executor), _emptyCancellers(), address(0)
        );
    }

    function testFuzz_deploy_acceptsDelayAtOrAboveMinimum(uint256 goodDelay) public {
        goodDelay = bound(goodDelay, VALID_DELAY, 365 days);
        ProtocolTimelock tl = new ProtocolTimelock(
            goodDelay, _makeProposers(proposer), _makeExecutors(executor), _emptyCancellers(), address(0)
        );
        assertEq(tl.getMinDelay(), goodDelay);
    }
}
