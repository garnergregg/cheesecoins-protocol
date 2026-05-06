// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/governance/MaturityOracle.sol";

/**
 * @title MaturityOracleTest
 * @notice Unit tests for MaturityOracle (Phase 6A on-chain maturity gate).
 */
contract MaturityOracleTest is Test {
    // ── Mock contracts ───────────────────────────────────────────────────────

    MockSceneTracker internal mockTracker;
    MockSettlement internal mockSettlement;
    MockVault internal mockVault;
    MockUsdc internal mockUsdc;

    // ── Actors ───────────────────────────────────────────────────────────────

    address internal admin = makeAddr("admin");

    // ── Oracle under test ────────────────────────────────────────────────────

    MaturityOracle internal oracle;

    // ── Default thresholds ───────────────────────────────────────────────────

    uint256 internal constant RESERVE_FLOOR = 500_000e6; // 500k USDC
    uint256 internal constant Y2_HOLDER_MIN = 40;
    uint256 internal constant Y3_HOLDER_MIN = 80;
    uint256 internal constant Y5_HOLDER_MIN = 200;
    uint256 internal constant Y3_MULT = 12500; // 1.25×
    uint256 internal constant Y5_MULT = 15000; // 1.50×

    uint256 internal T0;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        mockUsdc = new MockUsdc();
        mockVault = new MockVault(address(mockUsdc));
        mockTracker = new MockSceneTracker();
        mockSettlement = new MockSettlement();

        T0 = block.timestamp;

        oracle = new MaturityOracle(
            T0,
            address(mockTracker),
            address(mockSettlement),
            address(mockVault),
            admin,
            RESERVE_FLOOR,
            Y2_HOLDER_MIN,
            Y3_HOLDER_MIN,
            Y5_HOLDER_MIN,
            Y3_MULT,
            Y5_MULT
        );
    }

    // ── Constructor / immutables ──────────────────────────────────────────────

    function test_constructor_storesImmutables() public view {
        assertEq(oracle.T0(), T0);
        assertEq(address(oracle.sceneTracker()), address(mockTracker));
        assertEq(address(oracle.settlement()), address(mockSettlement));
        assertEq(address(oracle.fiatRedemptionVault()), address(mockVault));
        assertEq(oracle.admin(), admin);
        assertEq(oracle.reserveFloor(), RESERVE_FLOOR);
        assertEq(oracle.year2HolderMin(), Y2_HOLDER_MIN);
        assertEq(oracle.year3HolderMin(), Y3_HOLDER_MIN);
        assertEq(oracle.year5HolderMin(), Y5_HOLDER_MIN);
        assertEq(oracle.year3ReserveMultiplierBps(), Y3_MULT);
        assertEq(oracle.year5ReserveMultiplierBps(), Y5_MULT);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        address ok = address(mockTracker);
        vm.expectRevert(MaturityOracle.ZeroAddress.selector);
        new MaturityOracle(T0, address(0), ok, ok, admin, 0, 0, 0, 0, 10000, 10000);

        vm.expectRevert(MaturityOracle.ZeroAddress.selector);
        new MaturityOracle(T0, ok, address(0), ok, admin, 0, 0, 0, 0, 10000, 10000);

        vm.expectRevert(MaturityOracle.ZeroAddress.selector);
        new MaturityOracle(T0, ok, ok, address(0), admin, 0, 0, 0, 0, 10000, 10000);

        vm.expectRevert(MaturityOracle.ZeroAddress.selector);
        new MaturityOracle(T0, ok, ok, ok, address(0), 0, 0, 0, 0, 10000, 10000);
    }

    // ── isYear2Eligible — time gate ───────────────────────────────────────────

    function test_year2_falseBeforeTimeGate() public {
        _setAllConditions(true, true, true);
        assertFalse(oracle.isYear2Eligible()); // not 2 years yet
    }

    function test_year2_trueAfterAllConditionsMet() public {
        _setAllConditions(true, true, true);
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertTrue(oracle.isYear2Eligible());
    }

    function test_year2_falseWhenHolderCountInsufficient() public {
        mockTracker.setCount(Y2_HOLDER_MIN - 1);
        mockVault.setBalance(RESERVE_FLOOR);
        // never paused
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertFalse(oracle.isYear2Eligible());
    }

    function test_year2_falseWhenReserveBelowFloor() public {
        mockTracker.setCount(Y2_HOLDER_MIN);
        mockVault.setBalance(RESERVE_FLOOR - 1);
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertFalse(oracle.isYear2Eligible());
    }

    function test_year2_falseWhenRecentPause() public {
        mockTracker.setCount(Y2_HOLDER_MIN);
        mockVault.setBalance(RESERVE_FLOOR);
        // Pause happened 1 day ago — within INCIDENT_FREE_WINDOW
        uint256 pauseTime = T0 + 2 * Config.ONE_YEAR - 1 days;
        mockSettlement.setLastPauseTimestamp(pauseTime);
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertFalse(oracle.isYear2Eligible());
    }

    function test_year2_trueWhenPauseOldEnough() public {
        _setAllConditions(true, true, true);
        // Pause was more than INCIDENT_FREE_WINDOW ago
        uint256 pauseTime = T0 + 2 * Config.ONE_YEAR - oracle.INCIDENT_FREE_WINDOW() - 1;
        mockSettlement.setLastPauseTimestamp(pauseTime);
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertTrue(oracle.isYear2Eligible());
    }

    function test_year2_trueWhenNeverPaused() public {
        _setAllConditions(true, true, true);
        mockSettlement.setLastPauseTimestamp(0); // never paused
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertTrue(oracle.isYear2Eligible());
    }

    // ── isYear3Eligible ───────────────────────────────────────────────────────

    function test_year3_falseWhenYear2EligibleButNot3() public {
        mockTracker.setCount(Y3_HOLDER_MIN);
        mockVault.setBalance((RESERVE_FLOOR * Y3_MULT) / 10000 + 1);
        vm.warp(T0 + 2 * Config.ONE_YEAR); // only 2 years
        assertFalse(oracle.isYear3Eligible());
    }

    function test_year3_trueAfterAllConditionsMet() public {
        mockTracker.setCount(Y3_HOLDER_MIN);
        mockVault.setBalance((RESERVE_FLOOR * Y3_MULT) / 10000);
        vm.warp(T0 + 3 * Config.ONE_YEAR);
        assertTrue(oracle.isYear3Eligible());
    }

    function test_year3_falseWhenReserveBelowMultipliedFloor() public {
        mockTracker.setCount(Y3_HOLDER_MIN);
        mockVault.setBalance((RESERVE_FLOOR * Y3_MULT) / 10000 - 1);
        vm.warp(T0 + 3 * Config.ONE_YEAR);
        assertFalse(oracle.isYear3Eligible());
    }

    // ── isYear5Eligible ───────────────────────────────────────────────────────

    function test_year5_falseBeforeYear5() public {
        mockTracker.setCount(Y5_HOLDER_MIN);
        mockVault.setBalance((RESERVE_FLOOR * Y5_MULT) / 10000);
        vm.warp(T0 + 4 * Config.ONE_YEAR + 364 days);
        assertFalse(oracle.isYear5Eligible());
    }

    function test_year5_trueAfterAllConditionsMet() public {
        mockTracker.setCount(Y5_HOLDER_MIN);
        mockVault.setBalance((RESERVE_FLOOR * Y5_MULT) / 10000);
        vm.warp(T0 + 5 * Config.ONE_YEAR);
        assertTrue(oracle.isYear5Eligible());
    }

    // ── reserve floor zero edge case ─────────────────────────────────────────

    function test_reserveFloorZero_reserveAlwaysMet() public {
        vm.prank(admin);
        oracle.setThresholds(0, Y2_HOLDER_MIN, Y3_HOLDER_MIN, Y5_HOLDER_MIN, Y3_MULT, Y5_MULT);

        mockTracker.setCount(Y2_HOLDER_MIN);
        mockVault.setBalance(0); // empty vault
        vm.warp(T0 + 2 * Config.ONE_YEAR);
        assertTrue(oracle.isYear2Eligible());
    }

    // ── Admin: setThresholds ──────────────────────────────────────────────────

    function test_setThresholds_updatesValues() public {
        vm.prank(admin);
        oracle.setThresholds(1e6, 50, 100, 250, 13000, 16000);

        assertEq(oracle.reserveFloor(), 1e6);
        assertEq(oracle.year2HolderMin(), 50);
        assertEq(oracle.year3HolderMin(), 100);
        assertEq(oracle.year5HolderMin(), 250);
        assertEq(oracle.year3ReserveMultiplierBps(), 13000);
        assertEq(oracle.year5ReserveMultiplierBps(), 16000);
    }

    function test_setThresholds_revertsForNonAdmin() public {
        vm.expectRevert(MaturityOracle.NotAdmin.selector);
        oracle.setThresholds(0, 0, 0, 0, 0, 0);
    }

    // ── Admin: setAdmin ───────────────────────────────────────────────────────

    function test_setAdmin_updatesAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        oracle.setAdmin(newAdmin);
        assertEq(oracle.admin(), newAdmin);
    }

    function test_setAdmin_revertsForNonAdmin() public {
        vm.expectRevert(MaturityOracle.NotAdmin.selector);
        oracle.setAdmin(makeAddr("x"));
    }

    function test_setAdmin_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(MaturityOracle.ZeroAddress.selector);
        oracle.setAdmin(address(0));
    }

    // ── vaultUsdcBalance ──────────────────────────────────────────────────────

    function test_vaultUsdcBalance_returnsCorrectBalance() public {
        mockVault.setBalance(1_000_000e6);
        assertEq(oracle.vaultUsdcBalance(), 1_000_000e6);
    }

    // ── Fuzz: time gate ───────────────────────────────────────────────────────

    function testFuzz_year2_timeGate(uint256 offset) public {
        offset = bound(offset, 0, 2 * Config.ONE_YEAR - 1);
        _setAllConditions(true, true, true);
        vm.warp(T0 + offset);
        assertFalse(oracle.isYear2Eligible());
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _setAllConditions(bool holders, bool reserve, bool noIncident) internal {
        if (holders) mockTracker.setCount(Y2_HOLDER_MIN);
        if (reserve) mockVault.setBalance(RESERVE_FLOOR);
        if (noIncident) mockSettlement.setLastPauseTimestamp(0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mock contracts
// ═══════════════════════════════════════════════════════════════════════════

contract MockUsdc {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}

contract MockVault {
    MockUsdc internal _usdc;

    constructor(address u) {
        _usdc = MockUsdc(u);
    }

    function usdc() external view returns (address) {
        return address(_usdc);
    }

    function setBalance(uint256 amount) external {
        _usdc.setBalance(address(this), amount);
    }
}

contract MockSceneTracker {
    uint256 internal _count;

    function superHolderCount() external view returns (uint256) {
        return _count;
    }

    function setCount(uint256 c) external {
        _count = c;
    }
}

contract MockSettlement {
    uint256 internal _lastPauseTimestamp;

    function lastPauseTimestamp() external view returns (uint256) {
        return _lastPauseTimestamp;
    }

    function setLastPauseTimestamp(uint256 ts) external {
        _lastPauseTimestamp = ts;
    }
}
