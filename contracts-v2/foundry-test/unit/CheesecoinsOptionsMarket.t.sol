// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../foundry-src/stability/CheesecoinsOptionsMarket.sol";

// ============ MOCKS ============

contract MockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @dev Minimal Pyth mock. Call setPrice() to control what the market reads.
 *      Mimics getPriceNoOlderThan by reverting if price is stale.
 */
contract MockPyth {
    struct StoredPrice {
        int64  price;
        int32  expo;
        uint   publishTime;
    }

    mapping(bytes32 => StoredPrice) internal _prices;

    function setPrice(bytes32 feedId, int64 price, int32 expo, uint publishTime) external {
        _prices[feedId] = StoredPrice(price, expo, publishTime);
    }

    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (IPyth.Price memory) {
        StoredPrice memory s = _prices[id];
        require(block.timestamp - s.publishTime <= age, "StalePrice");
        return IPyth.Price({ price: s.price, conf: 0, expo: s.expo, publishTime: s.publishTime });
    }

    function getPriceUnsafe(bytes32 id) external view returns (IPyth.Price memory) {
        StoredPrice memory s = _prices[id];
        return IPyth.Price({ price: s.price, conf: 0, expo: s.expo, publishTime: s.publishTime });
    }
}

/**
 * @dev Minimal CommodityPriceOracle mock. Mirrors the real oracle's getPrice / isDoubleStale
 *      behaviour without bounds enforcement so tests can drive arbitrary scenarios.
 */
contract MockCommodityPriceOracle {
    struct Stored {
        uint256 price;       // CURD-wei
        uint256 publishTime;
    }
    mapping(uint256 => Stored)  internal _prices;
    mapping(uint256 => uint256) public stalenessWindow; // per market — set in tests

    bool public shouldRevert; // toggle to simulate broken oracle

    function setPrice(uint256 marketId, uint256 price, uint256 publishTime) external {
        _prices[marketId] = Stored(price, publishTime);
    }

    function setStaleness(uint256 marketId, uint256 windowSecs) external {
        stalenessWindow[marketId] = windowSecs;
    }

    function setShouldRevert(bool v) external { shouldRevert = v; }

    function getPrice(uint256 marketId) external view returns (uint256, uint256, bool) {
        if (shouldRevert) revert("oracle broken");
        Stored memory s = _prices[marketId];
        uint256 win = stalenessWindow[marketId];
        bool fresh = s.publishTime > 0 && win > 0 && (block.timestamp - s.publishTime) <= win;
        return (s.price, s.publishTime, fresh);
    }

    function isDoubleStale(uint256 marketId) external view returns (bool) {
        if (shouldRevert) revert("oracle broken");
        Stored memory s = _prices[marketId];
        uint256 win = stalenessWindow[marketId];
        if (s.publishTime == 0) return true;
        if (win == 0) return true;
        return (block.timestamp - s.publishTime) > (win * 2);
    }
}

// ============ TEST CONTRACT ============

contract OptionsMarketTest is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address owner    = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address writer   = makeAddr("writer");
    address buyer    = makeAddr("buyer");
    address keeper   = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    // ── Contracts ─────────────────────────────────────────────────────────────
    MockCURD  curd;
    MockPyth  mockPyth;
    MockCommodityPriceOracle commodityOracle;
    CheesecoinsOptionsMarket market;
    ProxyAdmin admin;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant WAD     = 1e18;
    uint256 constant CORN    = 1; // MARKET_CORN — routes through commodityOracle by default
    uint256 constant USD_CAD = 8; // MARKET_USD_CAD — routes through Pyth (commodityOracle == 0)

    // Pyth feed ID for CORN (same bytes32 as configured in contract)
    bytes32 constant CORN_FEED    = 0xdca56b6f3f4a335a2f4e3b7b3338794710d1aa5779bdeb40059ead4b0854328b;
    bytes32 constant USD_CAD_FEED = 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;

    // Option params
    // Strike $4.50/bu — expo -8, so rawPrice = 4.50 * 1e8 = 450_000_000
    uint256 constant STRIKE  = 4_500_000_000_000_000_000; // $4.50 in CURD-wei
    int64   constant STRIKE_RAW = 450_000_000;            // Pyth raw (expo -8)
    int32   constant EXPO    = -8;
    uint256 constant LOT     = 100;
    uint256 constant PREMIUM = 50 * WAD;
    uint256 constant COLLAT  = STRIKE * LOT; // 450 CURD

    // Staleness window for the commodity oracle in tests — matches MAX_AGE_CME (80h)
    uint256 constant ORACLE_STALENESS = 288_000;

    // Settlement prices within 10% of strike for realistic scenarios
    // $4.10 in the money: raw = 410_000_000
    int64   constant PRICE_BELOW_RAW = 410_000_000;
    uint256 constant PRICE_BELOW_WAD = 4_100_000_000_000_000_000;
    // $4.90 out of the money: raw = 490_000_000
    int64   constant PRICE_ABOVE_RAW = 490_000_000;

    function setUp() public {
        curd            = new MockCURD();
        mockPyth        = new MockPyth();
        commodityOracle = new MockCommodityPriceOracle();
        admin           = new ProxyAdmin();

        // Configure the mock oracle's staleness window for every commodity market 1-7
        for (uint256 i = 1; i <= 7; i++) {
            commodityOracle.setStaleness(i, ORACLE_STALENESS);
        }

        CheesecoinsOptionsMarket impl = new CheesecoinsOptionsMarket();
        market = CheesecoinsOptionsMarket(
            address(new TransparentUpgradeableProxy(
                address(impl),
                address(admin),
                abi.encodeCall(
                    CheesecoinsOptionsMarket.initialize,
                    (owner, address(curd), address(mockPyth), treasury, address(commodityOracle))
                )
            ))
        );

        curd.mint(writer, 10_000 * WAD);
        curd.mint(buyer,  10_000 * WAD);
        vm.prank(writer); curd.approve(address(market), type(uint256).max);
        vm.prank(buyer);  curd.approve(address(market), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// CORN routes through commodityOracle — set price in CURD-wei directly.
    /// Converts (rawPyth, expo=-8) → CURD-wei for test parity with old signature.
    function _setOraclePrice(int64 raw, uint publishTime) internal {
        uint256 wadPrice = uint256(int256(raw)) * 1e10; // expo -8 → multiply by 1e(18-8)
        commodityOracle.setPrice(CORN, wadPrice, publishTime);
    }

    function _setOracleWadPrice(uint256 wadPrice, uint publishTime) internal {
        commodityOracle.setPrice(CORN, wadPrice, publishTime);
    }

    function _writeOption() internal returns (uint256 id) {
        uint256 expiry = block.timestamp + 7 days;
        vm.prank(writer);
        id = market.writeOption(CORN, STRIKE, LOT, PREMIUM, expiry);
    }

    function _writeAndBuy() internal returns (uint256 id) {
        id = _writeOption();
        vm.prank(buyer);
        market.buyOption(id);
    }

    function _expiry(uint256 id) internal view returns (uint256) {
        (,,,,,uint256 e,,,) = market.options(id);
        return e;
    }

    // ============ writeOption ============

    function test_writeOption_locksCollateral() public {
        uint256 before = curd.balanceOf(writer);
        uint256 id = _writeOption();
        assertEq(curd.balanceOf(writer), before - COLLAT);
        assertEq(curd.balanceOf(address(market)), COLLAT);
        (address w,,,,,,,,CheesecoinsOptionsMarket.OptionState state) = market.options(id);
        assertEq(w, writer);
        assertEq(uint8(state), uint8(CheesecoinsOptionsMarket.OptionState.Open));
    }

    function test_writeOption_revertZeroStrike() public {
        vm.prank(writer);
        vm.expectRevert(CheesecoinsOptionsMarket.InvalidParams.selector);
        market.writeOption(CORN, 0, LOT, PREMIUM, block.timestamp + 1 days);
    }

    function test_writeOption_revertPastExpiry() public {
        vm.prank(writer);
        vm.expectRevert(CheesecoinsOptionsMarket.InvalidExpiry.selector);
        market.writeOption(CORN, STRIKE, LOT, PREMIUM, block.timestamp);
    }

    function test_writeOption_revertInactiveMarket() public {
        vm.prank(owner);
        market.setMarketConfig(CORN, CORN_FEED, 288_000, false, address(commodityOracle));
        vm.prank(writer);
        vm.expectRevert(CheesecoinsOptionsMarket.MarketNotActive.selector);
        market.writeOption(CORN, STRIKE, LOT, PREMIUM, block.timestamp + 1 days);
    }

    // ============ buyOption ============

    function test_buyOption_splitsPremium10_90() public {
        uint256 id = _writeOption();
        uint256 tBefore = curd.balanceOf(treasury);
        uint256 wBefore = curd.balanceOf(writer);

        vm.prank(buyer);
        market.buyOption(id);

        uint256 fee       = (PREMIUM * 1_000) / 10_000;
        uint256 writerCut = PREMIUM - fee;
        assertEq(curd.balanceOf(treasury), tBefore + fee);
        assertEq(curd.balanceOf(writer),   wBefore + writerCut);
    }

    function test_buyOption_setsBuyerState() public {
        uint256 id = _writeAndBuy();
        (,address b,,,,,,,CheesecoinsOptionsMarket.OptionState state) = market.options(id);
        assertEq(b, buyer);
        assertEq(uint8(state), uint8(CheesecoinsOptionsMarket.OptionState.Sold));
    }

    function test_buyOption_revertAlreadySold() public {
        uint256 id = _writeAndBuy();
        vm.expectRevert(CheesecoinsOptionsMarket.OptionNotOpen.selector);
        vm.prank(makeAddr("buyer2"));
        market.buyOption(id);
    }

    function test_buyOption_revertExpired() public {
        uint256 id = _writeOption();
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(CheesecoinsOptionsMarket.OptionExpired.selector);
        vm.prank(buyer);
        market.buyOption(id);
    }

    // ============ exercise ============

    function test_exercise_inTheMoney() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);
        vm.warp(exp);
        _setOraclePrice(PRICE_BELOW_RAW, block.timestamp);

        uint256 bBefore = curd.balanceOf(buyer);
        uint256 wBefore = curd.balanceOf(writer);

        vm.prank(buyer);
        market.exercise(id);

        uint256 payout = (STRIKE - PRICE_BELOW_WAD) * LOT;
        assertEq(curd.balanceOf(buyer),  bBefore + payout);
        assertEq(curd.balanceOf(writer), wBefore + (COLLAT - payout));
    }

    function test_exercise_outOfMoney_writerGetsAll() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);
        vm.warp(exp);
        _setOraclePrice(PRICE_ABOVE_RAW, block.timestamp);

        uint256 wBefore = curd.balanceOf(writer);
        vm.prank(buyer);
        market.exercise(id);

        assertEq(curd.balanceOf(writer), wBefore + COLLAT);
    }

    function test_exercise_revertBeforeExpiry() public {
        uint256 id = _writeAndBuy();
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        vm.expectRevert(CheesecoinsOptionsMarket.NotExpiredYet.selector);
        vm.prank(buyer);
        market.exercise(id);
    }

    function test_exercise_revertStaleOracle() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);
        // Set price at option creation but don't update at expiry
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        // Warp past expiry AND past the 80h maxAge window
        vm.warp(exp + 290_000);
        vm.expectRevert(CheesecoinsOptionsMarket.OracleStale.selector);
        vm.prank(buyer);
        market.exercise(id);
    }

    function test_exercise_revertNotBuyer() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);
        vm.warp(exp);
        _setOraclePrice(PRICE_BELOW_RAW, block.timestamp);
        vm.expectRevert(CheesecoinsOptionsMarket.NotBuyer.selector);
        vm.prank(stranger);
        market.exercise(id);
    }

    // ── Pyth price conversion (_pythToWad) — exercised via USD/CAD market ─────

    /// Helper: write an option on USD/CAD (Pyth-routed) and immediately buy it
    function _writeAndBuyUsdCad(uint256 strike, uint256 expirySecs) internal returns (uint256 id) {
        vm.prank(writer);
        id = market.writeOption(USD_CAD, strike, LOT, PREMIUM, expirySecs);
        vm.prank(buyer);
        market.buyOption(id);
    }

    function test_exercise_priceConversion_expo_neg8() public {
        // Strike $1.40 USD/CAD, settlement $1.30 → in the money
        uint256 strike = 1_400_000_000_000_000_000; // $1.40 in CURD-wei
        uint256 settle = 1_300_000_000_000_000_000; // $1.30 in CURD-wei
        uint256 expirySecs = block.timestamp + 1 days;

        uint256 id = _writeAndBuyUsdCad(strike, expirySecs);
        vm.warp(expirySecs);
        // Pyth raw 130_000_000, expo -8 → $1.30
        mockPyth.setPrice(USD_CAD_FEED, 130_000_000, -8, block.timestamp);

        uint256 bBefore = curd.balanceOf(buyer);
        vm.prank(buyer);
        market.exercise(id);

        uint256 expected = (strike - settle) * LOT;
        assertEq(curd.balanceOf(buyer), bBefore + expected);
    }

    function test_exercise_priceConversion_expo_neg5() public {
        // Same $1.30 settle, different expo: raw 130_000, expo -5
        uint256 strike = 1_400_000_000_000_000_000;
        uint256 settle = 1_300_000_000_000_000_000;
        uint256 expirySecs = block.timestamp + 1 days;

        uint256 id = _writeAndBuyUsdCad(strike, expirySecs);
        vm.warp(expirySecs);
        mockPyth.setPrice(USD_CAD_FEED, 130_000, -5, block.timestamp);

        uint256 bBefore = curd.balanceOf(buyer);
        vm.prank(buyer);
        market.exercise(id);

        uint256 expected = (strike - settle) * LOT;
        assertEq(curd.balanceOf(buyer), bBefore + expected);
    }

    // ============ releaseStale ============

    function test_releaseStale_writerGetsCollateral() public {
        // Set a real publish time so the feed isn't publishTime==0
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id = _writeAndBuy();

        // Advance past 2× maxAge (160h + 1s)
        vm.warp(block.timestamp + 576_001);

        uint256 wBefore = curd.balanceOf(writer);
        vm.prank(keeper);
        market.releaseStale(id);

        assertEq(curd.balanceOf(writer), wBefore + COLLAT);
        (,,,,,,,,CheesecoinsOptionsMarket.OptionState state) = market.options(id);
        assertEq(uint8(state), uint8(CheesecoinsOptionsMarket.OptionState.Released));
    }

    function test_releaseStale_buyerReceivesNothing() public {
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id = _writeAndBuy();
        uint256 buyerAfterBuy = curd.balanceOf(buyer);

        vm.warp(block.timestamp + 576_001);
        vm.prank(keeper);
        market.releaseStale(id);

        assertEq(curd.balanceOf(buyer), buyerAfterBuy);
    }

    function test_releaseStale_revertNotDoubleStale() public {
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id = _writeAndBuy();

        // Only 83h — past 80h maxAge but not 160h
        vm.warp(block.timestamp + 300_000);
        vm.expectRevert(CheesecoinsOptionsMarket.NotDoubleStale.selector);
        vm.prank(keeper);
        market.releaseStale(id);
    }

    function test_releaseStale_revertNotSold() public {
        uint256 id = _writeOption(); // Open, not sold
        vm.warp(block.timestamp + 576_001);
        vm.expectRevert(CheesecoinsOptionsMarket.OptionNotSold.selector);
        vm.prank(keeper);
        market.releaseStale(id);
    }

    // ============ batchRelease ============

    function test_batchRelease_multipleOptions() public {
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id1 = _writeAndBuy();
        uint256 id2 = _writeAndBuy();
        uint256 id3 = _writeAndBuy();
        vm.warp(block.timestamp + 576_001);

        uint256 wBefore = curd.balanceOf(writer);
        uint256[] memory ids = new uint256[](3);
        ids[0] = id1; ids[1] = id2; ids[2] = id3;

        vm.prank(keeper);
        market.batchRelease(ids);

        assertEq(curd.balanceOf(writer), wBefore + COLLAT * 3);
    }

    function test_batchRelease_revertDuplicate() public {
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id = _writeAndBuy();
        vm.warp(block.timestamp + 576_001);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id; ids[1] = id;
        vm.expectRevert(CheesecoinsOptionsMarket.DuplicateOptionId.selector);
        market.batchRelease(ids);
    }

    function test_batchRelease_revertOverLimit() public {
        uint256[] memory ids = new uint256[](51);
        vm.expectRevert(CheesecoinsOptionsMarket.BatchLimitExceeded.selector);
        market.batchRelease(ids);
    }

    // ============ cancelOption ============

    function test_cancel_returnsCollateral() public {
        uint256 id = _writeOption();
        uint256 wBefore = curd.balanceOf(writer);

        vm.prank(writer);
        market.cancelOption(id);

        assertEq(curd.balanceOf(writer), wBefore + COLLAT);
    }

    function test_cancel_revertIfSold() public {
        uint256 id = _writeAndBuy();
        vm.expectRevert(CheesecoinsOptionsMarket.OptionNotOpen.selector);
        vm.prank(writer);
        market.cancelOption(id);
    }

    function test_cancel_revertNotWriter() public {
        uint256 id = _writeOption();
        vm.expectRevert(CheesecoinsOptionsMarket.NotWriter.selector);
        vm.prank(stranger);
        market.cancelOption(id);
    }

    // ============ mutual exclusion ============

    function test_cannotExerciseAfterRelease() public {
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);

        vm.warp(exp + 576_001);
        vm.prank(keeper);
        market.releaseStale(id);

        _setOraclePrice(PRICE_BELOW_RAW, block.timestamp);
        vm.expectRevert(CheesecoinsOptionsMarket.OptionNotSold.selector);
        vm.prank(buyer);
        market.exercise(id);
    }

    function test_cannotReleaseAfterExercise() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);

        vm.warp(exp);
        _setOraclePrice(PRICE_BELOW_RAW, block.timestamp);
        vm.prank(buyer);
        market.exercise(id);

        vm.warp(block.timestamp + 576_001);
        vm.expectRevert(CheesecoinsOptionsMarket.OptionNotSold.selector);
        vm.prank(keeper);
        market.releaseStale(id);
    }

    // ============ governance ============

    function test_setTreasury_onlyOwner() public {
        vm.prank(owner);
        market.setTreasury(makeAddr("newTreasury"));
        assertEq(market.treasury(), makeAddr("newTreasury"));
    }

    function test_setTreasury_revertStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        market.setTreasury(makeAddr("newTreasury"));
    }

    function test_setMarketConfig_onlyOwner() public {
        vm.prank(owner);
        market.setMarketConfig(CORN, CORN_FEED, 172_800, true, address(commodityOracle));
        (, uint256 maxAge,,) = market.markets(CORN);
        assertEq(maxAge, 172_800);
    }

    function test_setMarketConfig_revertStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        market.setMarketConfig(CORN, CORN_FEED, 288_000, true, address(commodityOracle));
    }

    function test_pause_blocksWrite() public {
        vm.prank(owner);
        market.pause();
        vm.prank(writer);
        vm.expectRevert("Pausable: paused");
        market.writeOption(CORN, STRIKE, LOT, PREMIUM, block.timestamp + 1 days);
    }

    // ============ default market config ============

    function test_defaultMarkets_configured() public view {
        // All 8 markets should be active with correct feed IDs
        for (uint256 i = 1; i <= 8; i++) {
            (bytes32 feedId, uint256 maxAge, bool active,) = market.markets(i);
            assertTrue(active,       "market should be active");
            assertTrue(feedId != 0,  "feedId should be set");
            assertTrue(maxAge > 0,   "maxAge should be set");
        }
    }

    function test_usdCadMarket_hasFxMaxAge() public view {
        (, uint256 maxAge,,) = market.markets(USD_CAD);
        assertEq(maxAge, 7_200); // 2h — FX is nearly 24/7
    }

    function test_cmeMarkets_have80hMaxAge() public view {
        (, uint256 maxAge,,) = market.markets(CORN);
        assertEq(maxAge, 288_000); // 80h
    }

    // ============ oracle routing ============

    function test_routing_cornUsesCommodityOracle() public view {
        (,,, address oracleAddr) = market.markets(CORN);
        assertEq(oracleAddr, address(commodityOracle));
    }

    function test_routing_usdCadUsesPyth() public view {
        (,,, address oracleAddr) = market.markets(USD_CAD);
        assertEq(oracleAddr, address(0));
    }

    function test_routing_dualPath_oneTransaction() public {
        // CORN exercise via commodity oracle, USD_CAD exercise via Pyth — both succeed
        uint256 cornStrike = STRIKE;             // $4.50
        uint256 cornSettle = PRICE_BELOW_WAD;    // $4.10
        uint256 fxStrike   = 1_400_000_000_000_000_000; // $1.40
        uint256 fxSettle   = 1_300_000_000_000_000_000; // $1.30

        uint256 cornId = _writeAndBuy(); // CORN
        uint256 fxExpiry = block.timestamp + 1 days;
        uint256 fxId = _writeAndBuyUsdCad(fxStrike, fxExpiry);

        // Advance to after both expiries
        uint256 cornExpiry = _expiry(cornId);
        uint256 latest = cornExpiry > fxExpiry ? cornExpiry : fxExpiry;
        vm.warp(latest);

        _setOracleWadPrice(cornSettle, block.timestamp);
        mockPyth.setPrice(USD_CAD_FEED, 130_000_000, -8, block.timestamp);

        uint256 bBefore = curd.balanceOf(buyer);
        vm.prank(buyer); market.exercise(cornId);
        vm.prank(buyer); market.exercise(fxId);

        uint256 cornPayout = (cornStrike - cornSettle) * LOT;
        uint256 fxPayout   = (fxStrike   - fxSettle)   * LOT;
        assertEq(curd.balanceOf(buyer), bBefore + cornPayout + fxPayout);
    }

    function test_routing_brokenOracleRevertsOracleStale() public {
        uint256 id  = _writeAndBuy();
        uint256 exp = _expiry(id);
        vm.warp(exp);
        commodityOracle.setShouldRevert(true);
        vm.expectRevert(CheesecoinsOptionsMarket.OracleStale.selector);
        vm.prank(buyer);
        market.exercise(id);
    }

    function test_routing_brokenOracleAllowsRelease() public {
        // A reverting oracle should be treated as double-stale so writers can recover
        _setOraclePrice(STRIKE_RAW, block.timestamp);
        uint256 id = _writeAndBuy();
        commodityOracle.setShouldRevert(true);
        vm.warp(block.timestamp + 1 days);

        uint256 wBefore = curd.balanceOf(writer);
        vm.prank(keeper);
        market.releaseStale(id);

        assertEq(curd.balanceOf(writer), wBefore + COLLAT);
    }
}
