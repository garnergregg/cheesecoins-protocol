// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title CommodityPriceOracle
 * @notice Governance-published on-chain price store for the Cheesecoins Options Market.
 *
 * Role separation:
 *   publisher  — hot wallet EOA that calls setPrice() (e.g. Operations MetaMask).
 *                Owner (ProtocolTimelock) can rotate this address at any time.
 *   owner      — ProtocolTimelock (48h delay). Configures markets, rotates publisher.
 *
 * The Gnosis Safe treasury is NOT involved in price publishing.
 *
 * Security layers on setPrice():
 *   1. Caller must be publisher
 *   2. publishTime must be > 0 and <= block.timestamp
 *   3. price must be within per-market [minPrice, maxPrice] bounds
 *   4. price must not move more than maxMoveBps from the last published price
 *      (first publish for a market bypasses this check)
 *
 * Default maxMoveBps:
 *   CME grain / livestock  1000 (10%)  — daily limit move is ~5 %; 10 % gives headroom
 *   ICE coffee             1000 (10%)
 *   NYMEX WTI              1000 (10%)
 *   NYMEX NatGas           1500 (15%)  — historically more volatile than oil
 *   FX (USD/CAD)            500  (5%)  — FX rarely moves > 1 % per day
 *
 * All prices stored in CURD-wei scale: 1e18 == $1.00 USD.
 * Example: corn at $4.50/bu → 4_500_000_000_000_000_000
 *
 * Staleness defaults:
 *   CME / ICE / NYMEX  288_000 s  (80 h) — covers Fri close → Mon open
 *   FX (USD/CAD)       259_200 s  (72 h)
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract CommodityPriceOracle is Initializable, OwnableUpgradeable {

    // ============ TYPES ============

    struct MarketConfig {
        uint256 minPrice;        // lower bound, wei scale
        uint256 maxPrice;        // upper bound, wei scale
        uint256 stalenessWindow; // seconds
        uint256 maxMoveBps;      // max % move per publish (basis points, 10000 = 100%)
        bool    active;
    }

    struct PriceData {
        uint256 price;       // wei scale (1e18 == $1.00)
        uint256 publishTime; // unix timestamp of the underlying data point
    }

    // ============ CONSTANTS ============

    uint256 public constant BPS_DENOM = 10_000;

    // ============ MARKET IDs ============

    uint256 public constant MARKET_CORN     = 1;
    uint256 public constant MARKET_WHEAT    = 2;
    uint256 public constant MARKET_SOYBEANS = 3;
    uint256 public constant MARKET_CATTLE   = 4;
    uint256 public constant MARKET_COFFEE   = 5;
    uint256 public constant MARKET_WTI      = 6;
    uint256 public constant MARKET_NAT_GAS  = 7;
    uint256 public constant MARKET_USD_CAD  = 8;

    // ============ STATE ============

    address public publisher; // hot wallet — may call setPrice()

    mapping(uint256 => MarketConfig) public markets;
    mapping(uint256 => PriceData)   public prices;

    // ============ ERRORS ============

    error NotPublisher();
    error MarketNotActive();
    error InvalidPublishTime();
    error PriceOutOfBounds();
    error PriceMoveTooLarge();  // exceeds maxMoveBps from last price
    error InvalidBounds();
    error ZeroStaleness();
    error ZeroMaxMove();
    error ZeroAddress();

    // ============ EVENTS ============

    event PricePublished(uint256 indexed marketId, uint256 price, uint256 publishTime);
    event MarketConfigured(uint256 indexed marketId, uint256 minPrice, uint256 maxPrice, uint256 stalenessWindow, uint256 maxMoveBps, bool active);
    event PublisherUpdated(address indexed oldPublisher, address indexed newPublisher);

    // ============ CONSTRUCTOR ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ============ INITIALIZER ============

    /**
     * @param _owner      ProtocolTimelock — governs market config and publisher rotation
     * @param _publisher  Hot wallet EOA that will call setPrice() daily
     */
    function initialize(address _owner, address _publisher) external initializer {
        if (_owner     == address(0)) revert ZeroAddress();
        if (_publisher == address(0)) revert ZeroAddress();

        __Ownable_init();
        _transferOwnership(_owner);

        publisher = _publisher;
        _configureDefaults();
    }

    // ============ PRICE PUBLISHING ============

    /**
     * @notice Publish an updated price for a market.
     *         Caller must be the publisher (hot wallet EOA, not the Gnosis Safe).
     *
     * @param marketId    Market identifier (use MARKET_* constants).
     * @param price       Price in wei scale (1e18 == $1.00 USD).
     * @param publishTime Unix timestamp of the underlying data point (e.g. CME settlement).
     *                    Must be > 0 and <= block.timestamp.
     */
    function setPrice(uint256 marketId, uint256 price, uint256 publishTime) external {
        if (msg.sender != publisher) revert NotPublisher();

        MarketConfig storage cfg = markets[marketId];
        if (!cfg.active)                                              revert MarketNotActive();
        if (publishTime == 0 || publishTime > block.timestamp)        revert InvalidPublishTime();
        if (price < cfg.minPrice || price > cfg.maxPrice)             revert PriceOutOfBounds();

        // Max move guard — skipped on first publish (prev price == 0)
        uint256 prev = prices[marketId].price;
        if (prev > 0) {
            uint256 diff = price > prev ? price - prev : prev - price;
            // diff / prev > maxMoveBps / BPS_DENOM  ↔  diff * BPS_DENOM > prev * maxMoveBps
            if (diff * BPS_DENOM > prev * cfg.maxMoveBps) revert PriceMoveTooLarge();
        }

        prices[marketId] = PriceData({ price: price, publishTime: publishTime });

        emit PricePublished(marketId, price, publishTime);
    }

    // ============ READ FUNCTIONS ============

    /**
     * @notice Return the latest price and whether it is within the staleness window.
     */
    function getPrice(uint256 marketId)
        external view
        returns (uint256 price, uint256 publishTime, bool fresh)
    {
        PriceData    memory p   = prices[marketId];
        MarketConfig memory cfg = markets[marketId];
        bool isFresh = p.publishTime > 0
            && (block.timestamp - p.publishTime) <= cfg.stalenessWindow;
        return (p.price, p.publishTime, isFresh);
    }

    /**
     * @notice True if the last price is older than the staleness window.
     */
    function isStale(uint256 marketId) external view returns (bool) {
        PriceData    memory p   = prices[marketId];
        MarketConfig memory cfg = markets[marketId];
        if (p.publishTime == 0) return true;
        return (block.timestamp - p.publishTime) > cfg.stalenessWindow;
    }

    /**
     * @notice True if the last price is older than 2× the staleness window.
     *         At this threshold CheesecoinsOptionsMarket auto-releases stale options.
     */
    function isDoubleStale(uint256 marketId) external view returns (bool) {
        PriceData    memory p   = prices[marketId];
        MarketConfig memory cfg = markets[marketId];
        if (p.publishTime == 0) return true;
        return (block.timestamp - p.publishTime) > (cfg.stalenessWindow * 2);
    }

    // ============ GOVERNANCE (onlyOwner = ProtocolTimelock) ============

    /**
     * @notice Configure or update a market.
     * @param active     Set false to pause new option writes on this market.
     * @param maxMoveBps Maximum allowed price movement per publish (e.g. 1000 = 10%).
     */
    function setMarketConfig(
        uint256 marketId,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 stalenessWindow,
        uint256 maxMoveBps,
        bool    active
    ) external onlyOwner {
        _setMarketConfig(marketId, minPrice, maxPrice, stalenessWindow, maxMoveBps, active);
    }

    /**
     * @notice Rotate the price publisher. No timelock — owner can act fast if key is compromised.
     */
    function setPublisher(address newPublisher) external onlyOwner {
        if (newPublisher == address(0)) revert ZeroAddress();
        emit PublisherUpdated(publisher, newPublisher);
        publisher = newPublisher;
    }

    // ============ INTERNAL ============

    function _configureDefaults() internal {
        uint256 WAD = 1e18;
        //                         min        max       staleness   maxMove  active
        // CME grain (USD per bushel) — daily settlement, 80h covers Fri close → Mon open
        _setMarketConfig(MARKET_CORN,      1*WAD,   50*WAD,  288_000,  1000, true);
        _setMarketConfig(MARKET_WHEAT,     1*WAD,   50*WAD,  288_000,  1000, true);
        _setMarketConfig(MARKET_SOYBEANS,  1*WAD,  100*WAD,  288_000,  1000, true);
        // CME livestock (USD per cwt)
        _setMarketConfig(MARKET_CATTLE,   50*WAD,  500*WAD,  288_000,  1000, true);
        // ICE soft (USD per lb) — coffee KCU futures
        _setMarketConfig(MARKET_COFFEE,    1*WAD,   10*WAD,  288_000,  1000, true);
        // NYMEX energy (USD per bbl WTI / mmBtu nat gas)
        _setMarketConfig(MARKET_WTI,      20*WAD,  200*WAD,  288_000,  1000, true);
        _setMarketConfig(MARKET_NAT_GAS,   1*WAD,   30*WAD,  288_000,  1500, true);
        // FX (USD per CAD) — currently sourced from Pyth in options market; oracle entry retained for future flexibility
        _setMarketConfig(MARKET_USD_CAD,   1*WAD,    2*WAD,  259_200,   500, true);
    }

    function _setMarketConfig(
        uint256 marketId,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 stalenessWindow,
        uint256 maxMoveBps,
        bool    active
    ) internal {
        if (maxPrice <= minPrice)   revert InvalidBounds();
        if (stalenessWindow == 0)   revert ZeroStaleness();
        if (maxMoveBps == 0)        revert ZeroMaxMove();

        markets[marketId] = MarketConfig({
            minPrice:        minPrice,
            maxPrice:        maxPrice,
            stalenessWindow: stalenessWindow,
            maxMoveBps:      maxMoveBps,
            active:          active
        });

        emit MarketConfigured(marketId, minPrice, maxPrice, stalenessWindow, maxMoveBps, active);
    }

    // ============ STORAGE GAP ============

    uint256[50] private __gap;
}
