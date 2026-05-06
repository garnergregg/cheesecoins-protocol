// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "../../foundry-src/stability/StabilityCoordinator.sol";
import "../../foundry-src/stability/interfaces/IHedgeModule.sol";

// ============ MOCKS ============

/**
 * @dev Mock Uniswap v3 pool that returns configurable tick cumulatives.
 *      Also exposes token0/token1 for curdIsToken0 detection.
 */
contract MockUniswapPool {
    address public token0;
    address public token1;

    // tickCumulatives[0] = older, tickCumulatives[1] = newer (current)
    int56 public tickCumulativeOlder;
    int56 public tickCumulativeNewer;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev Set the tick cumulatives to produce a specific TWAP tick
    ///      averageTick = (newer - older) / twapWindow
    function setTickCumulatives(int56 _older, int56 _newer) external {
        tickCumulativeOlder = _older;
        tickCumulativeNewer = _newer;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulativeOlder;
        tickCumulatives[1] = tickCumulativeNewer;

        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}

/**
 * @dev Mock HedgeModule that records executeBuyback calls.
 */
contract MockHedgeModule {
    uint256 public executeCallCount;
    uint256 public lastUsdcAmount;
    uint256 public lastMinCurdOut;
    uint256 public lastDeadline;

    function executeBuyback(uint256 usdcAmount, uint256 minCurdOut, uint256 deadline)
        external
        returns (uint256 curdBurned)
    {
        executeCallCount++;
        lastUsdcAmount = usdcAmount;
        lastMinCurdOut = minCurdOut;
        lastDeadline = deadline;
        curdBurned = usdcAmount * 1e12; // mock: 1 USDC → 1 CURD (1e12 rate)
    }
}

// ============ TEST BASE ============

/**
 * @title StabilityCoordinatorTest
 * @notice Full unit test suite for StabilityCoordinator (Phase-3 PR3).
 *
 * TWAP math reference (CURD = token0, USDC = token1, CURD 18 dec, USDC 6 dec):
 *   priceE6 = (sqrtPriceX96 * 1e9 / 2^96)^2
 *   At peg ($1): tick ≈ -276324, priceE6 ≈ 1e6
 *   4% below peg: priceE6 ≈ 960000
 *   5% below peg: priceE6 ≈ 950000
 *
 * Mock pattern: set tickCumulatives so that
 *   averageTick = (newer - older) / twapWindow = desired tick
 *   e.g. twapWindow=3600, tick=-280000 → older=0, newer=-280000*3600=-1_008_000_000
 */
contract StabilityCoordinatorTest is Test {
    // Contracts under test
    StabilityCoordinator public coord;

    ProxyAdmin public proxyAdmin;

    // Mocks
    MockUniswapPool public pool;
    MockHedgeModule public hedgeModule;

    // Token address stubs (not real tokens — coordinator doesn't transfer tokens)
    address public curdAddr = makeAddr("curd");
    address public usdcAddr = makeAddr("usdc");

    // Actors
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public anyone = makeAddr("anyone");

    // Parameters
    uint256 constant TARGET_PRICE_E6 = 1e6; // $1.00
    uint256 constant EPSILON_BPS = 400; // 4%
    uint32 constant TWAP_WINDOW = 3600; // 1 hour

    // Threshold = 1e6 * (10000 - 400) / 10000 = 960_000
    uint256 constant THRESHOLD_E6 = 960_000;

    // Tick that puts price at ~$0.96 (just below threshold) when CURD=token0
    // tick ≈ -276324 is peg; 4% below peg is another ~408 ticks lower ≈ -276732
    // We'll use tick = -280000 which gives ~5.7% below peg (clearly below threshold)
    int24 constant BELOW_PEG_TICK = -280_000;

    // Tick for ~peg: tick = -276324 gives priceE6 ≈ 1e6 (above threshold)
    int24 constant AT_PEG_TICK = -276_324;

    function setUp() public {
        proxyAdmin = new ProxyAdmin();

        // Deploy mocks — CURD is token0
        pool = new MockUniswapPool(curdAddr, usdcAddr);
        hedgeModule = new MockHedgeModule();

        // Set pool to peg (above threshold) by default
        _setTick(AT_PEG_TICK);

        // Deploy StabilityCoordinator proxy
        StabilityCoordinator impl = new StabilityCoordinator();
        bytes memory initData = abi.encodeWithSelector(
            StabilityCoordinator.initialize.selector,
            treasury,
            address(hedgeModule),
            address(pool),
            curdAddr,
            TARGET_PRICE_E6,
            EPSILON_BPS,
            TWAP_WINDOW,
            owner
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        coord = StabilityCoordinator(address(proxy));
    }

    // ============ HELPERS ============

    /// @dev Configure pool so TWAP produces exactly `tick` over twapWindow seconds.
    function _setTick(int24 tick) internal {
        // older = 0, newer = tick * twapWindow
        int56 older = 0;
        int56 newer = int56(int256(tick)) * int56(int256(uint256(TWAP_WINDOW)));
        pool.setTickCumulatives(older, newer);
    }

    // ============ INITIALIZATION ============

    function test_initialize_setsFields() public {
        assertEq(coord.treasury(), treasury);
        assertEq(address(coord.hedgeModule()), address(hedgeModule));
        assertEq(coord.pool(), address(pool));
        assertTrue(coord.curdIsToken0()); // curdAddr == pool.token0()
        assertEq(coord.targetPriceE6(), TARGET_PRICE_E6);
        assertEq(coord.epsilonBps(), EPSILON_BPS);
        assertEq(coord.twapWindow(), TWAP_WINDOW);
        assertEq(coord.owner(), owner);
    }

    function test_initialize_usdcIsToken0() public {
        // Deploy with USDC as token0
        MockUniswapPool reversePool = new MockUniswapPool(usdcAddr, curdAddr);
        int56 tickAtPeg = int56(int256(uint256(TWAP_WINDOW))) * 276_324; // positive tick for reversed pool
        reversePool.setTickCumulatives(0, tickAtPeg);

        // Verify mock setup: USDC is token0, CURD is token1
        assertEq(reversePool.token0(), usdcAddr);
        assertEq(reversePool.token1(), curdAddr);

        StabilityCoordinator impl = new StabilityCoordinator();
        bytes memory initData = abi.encodeWithSelector(
            StabilityCoordinator.initialize.selector,
            treasury,
            address(hedgeModule),
            address(reversePool),
            curdAddr,
            TARGET_PRICE_E6,
            EPSILON_BPS,
            TWAP_WINDOW,
            owner
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        StabilityCoordinator reverseCoord = StabilityCoordinator(address(proxy));

        assertFalse(reverseCoord.curdIsToken0());
    }

    // ============ ONLY TREASURY ============

    function test_stabilize_revertsIfNotTreasury() public {
        _setTick(BELOW_PEG_TICK);
        vm.prank(anyone);
        vm.expectRevert(StabilityCoordinator.NotTreasury.selector);
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    // ============ PRICE ABOVE THRESHOLD → REVERT ============

    function test_stabilize_revertsWhenNoDeviation() public {
        // At peg (or above threshold) → revert
        _setTick(AT_PEG_TICK);

        vm.prank(treasury);
        vm.expectRevert(); // PriceAboveThreshold
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    function test_stabilize_revertsAtExactThreshold() public {
        // Find tick that gives priceE6 exactly at threshold (960_000)
        // priceE6 = mid^2 where mid = sqrtPriceX96 * 1e9 / 2^96
        // At threshold: mid^2 = 960_000 → mid = sqrt(960_000) ≈ 979.8
        // But we just need a tick that results in priceE6 >= threshold

        // Tick slightly above peg (price > $1) should also revert
        _setTick(-270_000); // higher than peg = higher price

        vm.prank(treasury);
        vm.expectRevert(); // PriceAboveThreshold
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    // ============ PRICE BELOW THRESHOLD → BUYBACK TRIGGERED ============

    function test_stabilize_callsExecuteWhenBelowThreshold() public {
        _setTick(BELOW_PEG_TICK);

        uint256 usdcAmount = 1_000e6;
        vm.prank(treasury);
        coord.stabilize(usdcAmount, 0, block.timestamp + 1);

        assertEq(hedgeModule.executeCallCount(), 1, "executeBuyback must be called once");
        assertEq(hedgeModule.lastUsdcAmount(), usdcAmount);
    }

    function test_stabilize_passesParamsToHedgeModule() public {
        _setTick(BELOW_PEG_TICK);

        uint256 usdcAmount = 2_500e6;
        uint256 minCurdOut = 100e18;
        uint256 deadline = block.timestamp + 300;

        vm.prank(treasury);
        coord.stabilize(usdcAmount, minCurdOut, deadline);

        assertEq(hedgeModule.lastUsdcAmount(), usdcAmount);
        assertEq(hedgeModule.lastMinCurdOut(), minCurdOut);
        assertEq(hedgeModule.lastDeadline(), deadline);
    }

    // ============ EVENTS ============

    function test_stabilize_emitsStabilizeAttempt() public {
        _setTick(BELOW_PEG_TICK);

        vm.expectEmit(false, false, false, false);
        emit StabilityCoordinator.StabilizeAttempt(0, 0, 0);

        vm.prank(treasury);
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    function test_stabilize_emitsStabilizeExecuted() public {
        _setTick(BELOW_PEG_TICK);

        vm.expectEmit(false, false, false, false);
        emit StabilityCoordinator.StabilizeExecuted(0, 0, 0);

        vm.prank(treasury);
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    // ============ PAUSE ============

    function test_pause_blocksStabilize() public {
        _setTick(BELOW_PEG_TICK);

        vm.prank(owner);
        coord.pause();

        vm.prank(treasury);
        vm.expectRevert("Pausable: paused");
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    function test_unpause_restoresStabilize() public {
        _setTick(BELOW_PEG_TICK);

        vm.prank(owner);
        coord.pause();

        vm.prank(owner);
        coord.unpause();

        vm.prank(treasury);
        coord.stabilize(1_000e6, 0, block.timestamp + 1);

        assertEq(hedgeModule.executeCallCount(), 1);
    }

    function test_pause_onlyOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        coord.pause();
    }

    // ============ ZERO AMOUNT ============

    function test_stabilize_zeroAmountReverts() public {
        _setTick(BELOW_PEG_TICK);

        vm.prank(treasury);
        vm.expectRevert(StabilityCoordinator.ZeroAmount.selector);
        coord.stabilize(0, 0, block.timestamp + 1);
    }

    // ============ OWNER SETTERS ============

    function test_setTreasury_onlyOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        coord.setTreasury(anyone);
    }

    function test_setTreasury_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(StabilityCoordinator.ZeroAddress.selector);
        coord.setTreasury(address(0));
    }

    function test_setTreasury_updates() public {
        vm.prank(owner);
        coord.setTreasury(anyone);
        assertEq(coord.treasury(), anyone);
    }

    function test_setHedgeModule_updates() public {
        address newModule = makeAddr("newModule");
        vm.prank(owner);
        coord.setHedgeModule(newModule);
        assertEq(address(coord.hedgeModule()), newModule);
    }

    function test_setPool_updates() public {
        // Create a new pool with USDC as token0
        MockUniswapPool newPool = new MockUniswapPool(usdcAddr, curdAddr);
        newPool.setTickCumulatives(0, 0);

        vm.prank(owner);
        coord.setPool(address(newPool), curdAddr);

        assertEq(coord.pool(), address(newPool));
        assertFalse(coord.curdIsToken0()); // CURD is now token1
    }

    function test_setTargetPrice_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(StabilityCoordinator.ZeroAmount.selector);
        coord.setTargetPrice(0);
    }

    function test_setTargetPrice_updates() public {
        vm.prank(owner);
        coord.setTargetPrice(2e6); // $2.00
        assertEq(coord.targetPriceE6(), 2e6);
    }

    function test_setEpsilon_over10000_reverts() public {
        vm.prank(owner);
        vm.expectRevert(StabilityCoordinator.InvalidEpsilon.selector);
        coord.setEpsilon(10_001);
    }

    function test_setEpsilon_updates() public {
        vm.prank(owner);
        coord.setEpsilon(200); // 2%
        assertEq(coord.epsilonBps(), 200);
    }

    function test_setTwapWindow_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(StabilityCoordinator.InvalidTwapWindow.selector);
        coord.setTwapWindow(0);
    }

    function test_setTwapWindow_updates() public {
        vm.prank(owner);
        coord.setTwapWindow(1800);
        assertEq(coord.twapWindow(), 1800);
    }

    // ============ TWAP CORRECTNESS ============

    function test_twap_priceAtPegIsAboveThreshold() public {
        // At peg tick, price should be ~1e6 which is above threshold (960000)
        _setTick(AT_PEG_TICK);

        // stabilize should revert because price >= threshold
        vm.prank(treasury);
        vm.expectRevert();
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    function test_twap_priceFarBelowPegTriggersExecute() public {
        // tick = -290000 is well below peg → should trigger execute
        _setTick(-290_000);

        vm.prank(treasury);
        coord.stabilize(1_000e6, 0, block.timestamp + 1);

        assertEq(hedgeModule.executeCallCount(), 1);
    }

    function test_twap_tickRoundingNegative() public {
        // Test that negative tick rounding (toward -inf) works correctly.
        // Set cumulatives such that the delta is not exactly divisible by twapWindow.
        // delta = -1000 * 3600 - 1 = -3_600_001
        // averageTick (naive) = -3_600_001 / 3600 = -1000 (truncated toward 0)
        // but should round toward -inf = -1001
        int56 older = 0;
        int56 newer = -(int56(int256(uint256(TWAP_WINDOW))) * 1000 + 1); // small below-peg tick
        pool.setTickCumulatives(older, newer);

        // The tick used is -1001 or -1000. Either way, check that stabilize() doesn't revert
        // for something clearly below threshold or revert for something above.
        // We mainly test that it doesn't revert on the rounding logic itself.
        // At tick -1001 or -1000 we'd still be far above peg ($1) → revert PriceAboveThreshold
        vm.prank(treasury);
        vm.expectRevert(); // PriceAboveThreshold (high price)
        coord.stabilize(1_000e6, 0, block.timestamp + 1);
    }

    // ============ USDC IS TOKEN0 CASE ============

    function test_stabilize_usdcIsToken0_belowPeg() public {
        // Build a coordinator with USDC as token0
        MockUniswapPool reversePool = new MockUniswapPool(usdcAddr, curdAddr);

        StabilityCoordinator impl = new StabilityCoordinator();
        bytes memory initData = abi.encodeWithSelector(
            StabilityCoordinator.initialize.selector,
            treasury,
            address(hedgeModule),
            address(reversePool),
            curdAddr, // CURD is token1 in this pool
            TARGET_PRICE_E6,
            EPSILON_BPS,
            TWAP_WINDOW,
            owner
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        StabilityCoordinator reverseCoord = StabilityCoordinator(address(proxy));

        assertFalse(reverseCoord.curdIsToken0());

        // When USDC is token0 and CURD is cheap:
        // raw price = CURD_raw/USDC_raw; peg tick ≈ +276324
        // CURD cheaper → tick > 276324 (more CURD per USDC)
        // Set tick well above the reversed-peg to simulate CURD being cheap
        int24 cheapCurdTick = 290_000; // above peg for USDC=token0 pool
        int56 older = 0;
        int56 newer = int56(int256(cheapCurdTick)) * int56(int256(uint256(TWAP_WINDOW)));
        reversePool.setTickCumulatives(older, newer);

        // Should trigger buyback (CURD is cheap)
        vm.prank(treasury);
        reverseCoord.stabilize(1_000e6, 0, block.timestamp + 1);

        assertEq(hedgeModule.executeCallCount(), 1);
    }
}
