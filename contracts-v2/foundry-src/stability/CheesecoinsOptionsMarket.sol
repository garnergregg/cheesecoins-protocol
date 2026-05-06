// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

// ── Minimal Pyth interface (no external dependency) ───────────────────────────
// Full SDK: https://github.com/pyth-network/pyth-sdk-solidity
interface IPyth {
    struct Price {
        int64  price;       // raw price — multiply by 10^expo for actual USD value
        uint64 conf;        // confidence interval (same scale)
        int32  expo;        // exponent (usually negative, e.g. -8 means price / 1e8)
        uint   publishTime; // unix timestamp of last on-chain update
    }
    // Reverts with PythErrors.StalePrice if price is older than `age` seconds
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory);
    // Returns last known price regardless of age — used for staleness checks
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

// ── CommodityPriceOracle interface (governance-published prices) ──────────────
// Used for markets where Pyth has no live feed (CME/ICE/NYMEX commodities).
// Prices already in CURD-wei (1e18 == $1.00) — no conversion needed.
interface ICommodityPriceOracle {
    function getPrice(uint256 marketId) external view returns (uint256 price, uint256 publishTime, bool fresh);
    function isDoubleStale(uint256 marketId) external view returns (bool);
}

/**
 * @title CheesecoinsOptionsMarket
 * @notice Permissionless European put options exchange for agricultural commodities,
 *         energy, and FX. Per-market oracle routing:
 *           - commodityOracle != address(0) → CommodityPriceOracle (governance-published)
 *                                              Used for CME/ICE/NYMEX commodities where
 *                                              Pyth has no live feed.
 *           - commodityOracle == address(0) → Pyth Network on-chain
 *                                              Used for FX (USD/CAD) where Pyth is live.
 *
 * ── Markets (oracle routing as of April 2026) ────────────────────────────────
 *   Markets 1-7 (corn/wheat/soybeans/cattle/coffee/WTI/natgas):
 *     CommodityPriceOracle — daily settlement pushed by CME DataMine keeper.
 *   Market 8 (USD/CAD):
 *     Pyth Network — live on-chain feed, < 5s staleness on Hermes.
 *
 *   Pyth feed IDs are retained for backward compatibility and may be enabled later
 *   via setMarketConfig() through ProtocolTimelock if Pyth begins publishing the
 *   CME/ICE/NYMEX feeds. Quarterly rollover applies only to markets routed through Pyth.
 *
 * ── Option lifecycle ──────────────────────────────────────────────────────────
 *   writeOption()  → Open      Writer locks collateral = strike × lotSize (CURD)
 *   buyOption()    → Sold      Premium split immediately: 10% treasury / 90% writer
 *   exercise()     → Exercised European: block.timestamp >= expiry, reads Pyth price
 *   cancelOption() → Cancelled Writer reclaims collateral on unsold options
 *   releaseStale() → Released  Oracle > 2× maxAge: writer reclaims, buyer forfeits premium
 *
 * ── Price scale ───────────────────────────────────────────────────────────────
 *   Strike prices set by writer in CURD-wei: 1e18 == $1.00 USD.
 *   Pyth prices are converted to CURD-wei at settlement via _pythToWad().
 *   Payout = max(0, strike − oraclePrice) × lotSize  (in CURD wei)
 *
 * ── Premium design ────────────────────────────────────────────────────────────
 *   Premium distributed at buyOption() — writer earns at sale, not expiry (TradFi standard).
 *   10% treasury / 90% writer, immediately. Contract never holds premium.
 *   On releaseStale(): writer reclaims collateral, buyer forfeits premium (already paid out).
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract CheesecoinsOptionsMarket is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ TYPES ============

    enum OptionState { Open, Sold, Exercised, Released, Cancelled }

    struct Option {
        address     writer;
        address     buyer;
        uint256     collateral; // CURD wei == strike × lotSize
        uint256     premium;    // CURD wei (total, for reference — split at buyOption)
        uint256     strike;     // USD price in CURD-wei (1e18 == $1.00)
        uint256     expiry;     // unix timestamp
        uint256     lotSize;    // plain multiplier (e.g. 100 for 100 bu)
        uint256     marketId;
        OptionState state;
    }

    struct MarketConfig {
        bytes32 pythFeedId;       // Pyth price feed ID for this market (used when commodityOracle == 0)
        uint256 maxAge;           // max Pyth oracle age in seconds for exercise() (Pyth path only)
        bool    active;           // false = no new options, existing unaffected
        address commodityOracle;  // 0 = use Pyth path; nonzero = read getPrice() from this CommodityPriceOracle
    }

    // ============ MARKET IDs ============

    uint256 public constant MARKET_CORN     = 1;
    uint256 public constant MARKET_WHEAT    = 2;
    uint256 public constant MARKET_SOYBEANS = 3;
    uint256 public constant MARKET_CATTLE   = 4;
    uint256 public constant MARKET_COFFEE   = 5;
    uint256 public constant MARKET_WTI      = 6;
    uint256 public constant MARKET_NAT_GAS  = 7;
    uint256 public constant MARKET_USD_CAD  = 8;

    // ============ CONSTANTS ============

    uint256 public constant PROTOCOL_FEE_BPS = 1_000;  // 10%
    uint256 public constant BPS_DENOM        = 10_000;
    uint256 public constant BATCH_LIMIT      = 50;
    /// @notice Reject Pyth prices whose confidence interval exceeds this bps fraction
    /// of the price. 1000 bps = 10% — conservative for testnet; tighten for mainnet.
    uint256 public constant MAX_CONF_BPS     = 1_000;

    // Staleness windows
    // CME/NYMEX/ICE markets: 80h covers Fri close → Mon open (longest weekend gap ~49h)
    uint256 internal constant MAX_AGE_CME = 288_000; // 80h
    uint256 internal constant MAX_AGE_FX  =   7_200; // 2h — FX is nearly 24/7

    // ============ STATE ============

    IERC20Upgradeable public curd;
    IPyth             public pyth;
    address           public treasury;

    mapping(uint256 => MarketConfig) public markets;

    uint256 public nextOptionId;
    mapping(uint256 => Option) public options;

    // ============ ERRORS ============

    error ZeroAddress();
    error InvalidParams();
    error InvalidExpiry();
    error MarketNotActive();
    error OptionNotOpen();
    error OptionNotSold();
    error OptionExpired();
    error NotBuyer();
    error NotWriter();
    error NotExpiredYet();
    error OracleStale();
    error NotDoubleStale();
    error NegativeOraclePrice();
    error BatchLimitExceeded();
    error DuplicateOptionId();

    // ============ EVENTS ============

    event OptionWritten(
        uint256 indexed optionId,
        address indexed writer,
        uint256 marketId,
        uint256 strike,
        uint256 lotSize,
        uint256 collateral,
        uint256 premium,
        uint256 expiry
    );
    event OptionBought(uint256 indexed optionId, address indexed buyer, uint256 treasuryFee, uint256 writerIncome);
    event OptionExercised(uint256 indexed optionId, address indexed buyer, uint256 payout, uint256 settlementPrice);
    event OptionReleased(uint256 indexed optionId, address indexed writer, uint256 collateral);
    event OptionCancelled(uint256 indexed optionId, address indexed writer, uint256 collateral);
    event MarketConfigured(uint256 indexed marketId, bytes32 pythFeedId, uint256 maxAge, bool active, address commodityOracle);

    // ============ CONSTRUCTOR ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ============ INITIALIZER ============

    /**
     * @param _owner            ProtocolTimelock on mainnet; deployer on testnet
     * @param _curd             CURD token (18 decimals, 1e18 == $1.00)
     * @param _pyth             Pyth on-chain contract
     *                          Arbitrum One:    0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
     *                          Arbitrum Sepolia: 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF
     * @param _treasury         Fee recipient (Gnosis Safe on mainnet)
     * @param _commodityOracle  CommodityPriceOracle proxy address — used by markets 1-7
     *                          (corn/wheat/soybeans/cattle/coffee/WTI/natgas).
     *                          Market 8 (USD/CAD) keeps Pyth path regardless.
     */
    function initialize(
        address _owner,
        address _curd,
        address _pyth,
        address _treasury,
        address _commodityOracle
    ) external initializer {
        if (_owner            == address(0)) revert ZeroAddress();
        if (_curd             == address(0)) revert ZeroAddress();
        if (_pyth             == address(0)) revert ZeroAddress();
        if (_treasury         == address(0)) revert ZeroAddress();
        if (_commodityOracle  == address(0)) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _transferOwnership(_owner);

        curd     = IERC20Upgradeable(_curd);
        pyth     = IPyth(_pyth);
        treasury = _treasury;

        _configureDefaultMarkets(_commodityOracle);
    }

    // ============ WRITE (CREATE OPTION) ============

    /**
     * @notice Create a covered European put option.
     *         Writer deposits strike × lotSize CURD as collateral (max possible payout).
     */
    function writeOption(
        uint256 marketId,
        uint256 strike,
        uint256 lotSize,
        uint256 premium,
        uint256 expiry
    ) external nonReentrant whenNotPaused returns (uint256 optionId) {
        if (strike == 0 || lotSize == 0 || premium == 0) revert InvalidParams();
        if (expiry <= block.timestamp)                    revert InvalidExpiry();
        if (!markets[marketId].active)                    revert MarketNotActive();

        uint256 collateral = strike * lotSize;

        optionId = nextOptionId++;

        // CEI: state before external call
        options[optionId] = Option({
            writer:     msg.sender,
            buyer:      address(0),
            collateral: collateral,
            premium:    premium,
            strike:     strike,
            expiry:     expiry,
            lotSize:    lotSize,
            marketId:   marketId,
            state:      OptionState.Open
        });

        curd.safeTransferFrom(msg.sender, address(this), collateral);

        emit OptionWritten(optionId, msg.sender, marketId, strike, lotSize, collateral, premium, expiry);
    }

    // ============ BUY ============

    /**
     * @notice Buy an open option. Premium split immediately at purchase:
     *           10% → treasury (protocol fee)
     *           90% → writer   (earned at sale — not refundable, same as TradFi)
     */
    function buyOption(uint256 optionId) external nonReentrant whenNotPaused {
        Option storage opt = options[optionId];
        if (opt.state != OptionState.Open) revert OptionNotOpen();
        if (block.timestamp >= opt.expiry) revert OptionExpired();

        address writer  = opt.writer;
        uint256 premium = opt.premium;
        uint256 fee       = (premium * PROTOCOL_FEE_BPS) / BPS_DENOM;
        uint256 writerCut = premium - fee;

        // CEI: state before transfers
        opt.state = OptionState.Sold;
        opt.buyer = msg.sender;

        curd.safeTransferFrom(msg.sender, treasury, fee);
        curd.safeTransferFrom(msg.sender, writer,   writerCut);

        emit OptionBought(optionId, msg.sender, fee, writerCut);
    }

    // ============ EXERCISE (EUROPEAN) ============

    /**
     * @notice Exercise a sold option at or after expiry.
     *         Routes per-market:
     *           - commodityOracle != 0 → reads getPrice() from CommodityPriceOracle.
     *                                    Reverts OracleStale if !fresh or oracle reverts.
     *           - commodityOracle == 0 → reads from Pyth (must be fresher than market.maxAge).
     *                                    If stale, push fresh VAA via pyth.updatePriceFeeds()
     *                                    from https://hermes.pyth.network before exercising.
     */
    function exercise(uint256 optionId) external nonReentrant whenNotPaused {
        Option storage opt = options[optionId];
        if (opt.state != OptionState.Sold) revert OptionNotSold();
        if (msg.sender != opt.buyer)       revert NotBuyer();
        if (block.timestamp < opt.expiry)  revert NotExpiredYet();

        MarketConfig memory cfg = markets[opt.marketId];

        uint256 currentPrice = _readSettlementPrice(cfg, opt.marketId);

        uint256 strike     = opt.strike;
        uint256 lotSize    = opt.lotSize;
        uint256 collateral = opt.collateral;
        address buyer      = opt.buyer;
        address writer     = opt.writer;

        uint256 payout = 0;
        if (currentPrice < strike) {
            payout = (strike - currentPrice) * lotSize;
            if (payout > collateral) payout = collateral;
        }

        // CEI: state before transfers
        opt.state = OptionState.Exercised;

        if (payout > 0) {
            curd.safeTransfer(buyer, payout);
        }
        uint256 writerReturn = collateral - payout;
        if (writerReturn > 0) {
            curd.safeTransfer(writer, writerReturn);
        }

        emit OptionExercised(optionId, buyer, payout, currentPrice);
    }

    // ============ RELEASE (STALE ORACLE) ============

    /**
     * @notice Release a sold option when the configured oracle has not been updated for
     *         > 2× the staleness window. Writer reclaims collateral.
     *         Buyer receives nothing — premium was already distributed at buyOption().
     *         Callable by anyone (keeper-compatible).
     */
    function releaseStale(uint256 optionId) external nonReentrant {
        Option storage opt = options[optionId];
        if (opt.state != OptionState.Sold) revert OptionNotSold();

        MarketConfig memory cfg = markets[opt.marketId];
        if (!_isDoubleStale(cfg, opt.marketId)) revert NotDoubleStale();

        address writer     = opt.writer;
        uint256 collateral = opt.collateral;

        // CEI: state before transfer
        opt.state = OptionState.Released;

        curd.safeTransfer(writer, collateral);

        emit OptionReleased(optionId, writer, collateral);
    }

    /**
     * @notice Batch-release up to BATCH_LIMIT stale options. Skips non-Sold or non-stale.
     *         Duplicate IDs are rejected.
     */
    function batchRelease(uint256[] calldata optionIds) external nonReentrant {
        uint256 len = optionIds.length;
        if (len > BATCH_LIMIT) revert BatchLimitExceeded();

        // O(n²) dedup — correct and gas-safe at n ≤ 50
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (optionIds[i] == optionIds[j]) revert DuplicateOptionId();
            }
        }

        for (uint256 i = 0; i < len; i++) {
            uint256 id  = optionIds[i];
            Option storage opt = options[id];
            if (opt.state != OptionState.Sold) continue;

            MarketConfig memory cfg = markets[opt.marketId];
            if (!_isDoubleStale(cfg, opt.marketId)) continue;

            address writer     = opt.writer;
            uint256 collateral = opt.collateral;

            // slither-disable-next-line reentrancy-no-eth
            // (intentional: function is `nonReentrant`, CURD is a known
            //  ERC20 with no callbacks, and state is updated before transfer.)
            opt.state = OptionState.Released;
            curd.safeTransfer(writer, collateral);

            emit OptionReleased(id, writer, collateral);
        }
    }

    // ============ CANCEL (UNSOLD) ============

    function cancelOption(uint256 optionId) external nonReentrant {
        Option storage opt = options[optionId];
        if (opt.state != OptionState.Open) revert OptionNotOpen();
        if (msg.sender != opt.writer)      revert NotWriter();

        uint256 collateral = opt.collateral;

        opt.state = OptionState.Cancelled;

        curd.safeTransfer(msg.sender, collateral);

        emit OptionCancelled(optionId, msg.sender, collateral);
    }

    // ============ GOVERNANCE ============

    /**
     * @notice Update a market's oracle config. Use to rotate Pyth feed IDs at quarterly
     *         futures rollover, switch a market between Pyth and CommodityPriceOracle, or
     *         pause a market. Called via ProtocolTimelock — 48h delay on mainnet.
     * @param commodityOracle  Pass address(0) to route through Pyth (uses pythFeedId/maxAge);
     *                         pass a CommodityPriceOracle address to route through it.
     */
    function setMarketConfig(uint256 marketId, bytes32 pythFeedId, uint256 maxAge, bool active, address commodityOracle)
        external onlyOwner
    {
        require(maxAge > 0, "zero maxAge");
        markets[marketId] = MarketConfig({
            pythFeedId:      pythFeedId,
            maxAge:          maxAge,
            active:          active,
            commodityOracle: commodityOracle
        });
        emit MarketConfigured(marketId, pythFeedId, maxAge, active, commodityOracle);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    function setPyth(address newPyth) external onlyOwner {
        if (newPyth == address(0)) revert ZeroAddress();
        pyth = IPyth(newPyth);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ============ INTERNAL ============

    /**
     * @notice Convert a Pyth price (raw int64 + exponent) to CURD-wei (1e18 == $1.00).
     * @dev    Pyth: actual_price = price × 10^expo
     *         CURD-wei: actual_price × 1e18
     *         Combined: price × 1e18 / 10^(-expo)  when expo < 0
     */
    function _pythToWad(int64 rawPrice, int32 expo) internal pure returns (uint256) {
        uint256 p = uint256(int256(rawPrice)); // rawPrice > 0 already checked by caller
        if (expo >= 0) {
            return p * (10 ** uint256(int256(expo))) * 1e18;
        } else {
            uint256 divisor = 10 ** uint256(-int256(expo));
            return p * 1e18 / divisor;
        }
    }

    function _configureDefaultMarkets(address commodityOracle) internal {
        // Markets 1-7 route through CommodityPriceOracle (CME DataMine keeper).
        // Pyth feed IDs retained for backward compatibility — can be enabled later by
        // setting commodityOracle = address(0) on a market via setMarketConfig().
        markets[MARKET_CORN]     = MarketConfig(0xdca56b6f3f4a335a2f4e3b7b3338794710d1aa5779bdeb40059ead4b0854328b, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_WHEAT]    = MarketConfig(0x3b7340060c669c19f9285fab57649ac27a7c332eccaaf2d18e1db3a9c9c26141, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_SOYBEANS] = MarketConfig(0x0d03b648a12b297160e2fdce53cd643d993f7ade4549f8e91ec6e593cc085c21, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_CATTLE]   = MarketConfig(0x99668a9e0f978d486c5b06456362c4090927310b1cf6926e11528e27e958118f, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_COFFEE]   = MarketConfig(0x7ae20d255b4661f9cff4b135960fca84072860a4addbfb33ec51e1e83d3abea3, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_WTI]      = MarketConfig(0x9526e04755ebaed86733913b84fe14db4ea165da8f40f97710014cd877fe545b, MAX_AGE_CME, true, commodityOracle);
        markets[MARKET_NAT_GAS]  = MarketConfig(0x8805823f20690f7b1b138d912a1e6988dca4ed166c813118f8d05cbf00d61dce, MAX_AGE_CME, true, commodityOracle);
        // Market 8 USD/CAD: Pyth path (commodityOracle = address(0))
        markets[MARKET_USD_CAD]  = MarketConfig(0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca, MAX_AGE_FX,  true, address(0));

        for (uint256 i = MARKET_CORN; i <= MARKET_USD_CAD; i++) {
            MarketConfig memory m = markets[i];
            emit MarketConfigured(i, m.pythFeedId, m.maxAge, m.active, m.commodityOracle);
        }
    }

    /**
     * @notice Resolve the settlement price for a market according to its oracle config.
     *         Reverts OracleStale if the configured oracle returns stale data or reverts.
     *         Reverts NegativeOraclePrice if the price is non-positive.
     */
    function _readSettlementPrice(MarketConfig memory cfg, uint256 marketId) internal view returns (uint256) {
        if (cfg.commodityOracle != address(0)) {
            // CommodityPriceOracle path — prices already in CURD-wei.
            // slither-disable-next-line unused-return
            // (intentional: publishTime is intentionally unused — staleness
            //  is signaled by the `fresh` bool returned alongside it.)
            try ICommodityPriceOracle(cfg.commodityOracle).getPrice(marketId)
                returns (uint256 price, uint256 /*publishTime*/, bool fresh)
            {
                if (!fresh)      revert OracleStale();
                if (price == 0)  revert NegativeOraclePrice();
                return price;
            } catch {
                revert OracleStale();
            }
        }

        // Pyth path — convert raw int64 + expo to CURD-wei
        IPyth.Price memory pythPrice = IPyth.Price(0, 0, 0, 0);
        try pyth.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxAge) returns (IPyth.Price memory p) {
            pythPrice = p;
        } catch {
            revert OracleStale();
        }
        if (pythPrice.price <= 0) revert NegativeOraclePrice();
        // Confidence sanity: reject prices whose Pyth confidence interval
        // is wider than MAX_CONF_BPS of the price itself (uncertain markets).
        uint256 absPrice = uint256(int256(pythPrice.price));
        if (uint256(pythPrice.conf) * BPS_DENOM > absPrice * MAX_CONF_BPS) {
            revert OracleStale();
        }
        return _pythToWad(pythPrice.price, pythPrice.expo);
    }

    /**
     * @notice True when the configured oracle is past 2× its staleness window.
     *         A reverting/broken oracle is treated as double-stale (writer can recover
     *         collateral via releaseStale).
     */
    function _isDoubleStale(MarketConfig memory cfg, uint256 marketId) internal view returns (bool) {
        if (cfg.commodityOracle != address(0)) {
            try ICommodityPriceOracle(cfg.commodityOracle).isDoubleStale(marketId) returns (bool ds) {
                return ds;
            } catch {
                return true;
            }
        }
        // slither-disable-next-line pyth-unchecked-confidence
        // (intentional: this is a staleness check, not a price-quality check;
        //  conf is validated in _readSettlementPrice where the price is actually used)
        IPyth.Price memory last = pyth.getPriceUnsafe(cfg.pythFeedId);
        if (last.publishTime == 0) return true;
        return (block.timestamp - last.publishTime) > (cfg.maxAge * 2);
    }

    // ============ STORAGE GAP ============

    uint256[50] private __gap;
}
