// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title ChainlinkPriceFeed
 * @notice Chainlink V3 aggregator integration for CURD/USD price feed
 * @dev Provides reliable price data with staleness protection and fallback
 *
 * FEATURES:
 * - Chainlink V3 aggregator integration
 * - Staleness check (24-hour threshold)
 * - Fallback to peg price ($1) if data is stale
 * - 8 decimal precision (standard for USD pairs)
 * - Price update events for monitoring
 *
 * SECURITY:
 * - Staleness protection prevents using outdated prices
 * - Fallback mechanism ensures system continuity
 * - Read-only aggregator access (no manipulation)
 * - Owner can update aggregator address if needed
 *
 * USAGE:
 * 1. Deploy with Chainlink CURD/USD aggregator address
 * 2. Call getLatestPrice() to get current CURD price
 * 3. System automatically uses peg price if feed is stale
 * 4. Monitor PriceUpdated events for price changes
 */
contract ChainlinkPriceFeed is OwnableUpgradeable {
    // ============ STATE VARIABLES ============

    /// @notice Chainlink price aggregator (CURD/USD)
    AggregatorV3Interface public priceFeed;

    /// @notice Last retrieved price (cached)
    int256 public lastPrice;

    /// @notice Last price update timestamp
    uint256 public lastUpdateTime;

    /// @notice Staleness threshold (from Config)
    uint256 public constant STALENESS_THRESHOLD = Config.ORACLE_STALENESS_THRESHOLD;

    /// @notice Fallback peg price (1 CURD = $1 = 1e8)
    int256 public constant PEG_PRICE = int256(Config.PEG_PRICE);

    /// @notice Price decimals (8 for USD feeds)
    uint8 public constant DECIMALS = uint8(Config.PRICE_DECIMALS);

    // ============ EVENTS ============

    event PriceUpdated(int256 price, uint256 timestamp, bool isStale);
    event AggregatorUpdated(address indexed oldAggregator, address indexed newAggregator);

    // ============ ERRORS ============

    error InvalidAggregator();
    error InvalidPrice();
    error StalePrice();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize price feed with Chainlink aggregator
     * @param _priceFeed Chainlink aggregator address (CURD/USD)
     */
    constructor(address _priceFeed) {
        ValidationLibrary.requireNonZeroAddress(_priceFeed, "ChainlinkPriceFeed: zero address");
        priceFeed = AggregatorV3Interface(_priceFeed);

        // Validate aggregator works
        try priceFeed.decimals() returns (uint8 feedDecimals) {
            require(feedDecimals == DECIMALS, "ChainlinkPriceFeed: invalid decimals");
        } catch {
            revert InvalidAggregator();
        }
    }

    // ============ PRICE QUERIES ============

    /**
     * @notice Get latest CURD/USD price with staleness protection
     * @dev Returns peg price if Chainlink data is stale (> 24 hours old)
     * @return price CURD price in USD (8 decimals)
     * @return isStale True if using fallback peg price
     */
    function getLatestPrice() external returns (int256 price, bool isStale) {
        try priceFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            // Validate price is positive
            if (answer <= 0) {
                return _usePegPrice();
            }

            // Chainlink sanity checks: detect incomplete rounds
            if (startedAt == 0) {
                return _usePegPrice();
            }

            // Chainlink sanity checks: detect stale/incomplete rounds
            if (updatedAt == 0 || answeredInRound < roundId) {
                return _usePegPrice();
            }

            // Check staleness
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) {
                return _usePegPrice();
            }

            // Price is fresh
            lastPrice = answer;
            lastUpdateTime = updatedAt;

            emit PriceUpdated(answer, updatedAt, false);
            return (answer, false);
        } catch {
            // Chainlink call failed, use peg
            return _usePegPrice();
        }
    }

    /**
     * @notice Get latest price (view-only, no state update)
     * @dev Does not update lastPrice state variable
     * @return price CURD price in USD (8 decimals)
     * @return isStale True if using fallback peg price
     */
    function viewLatestPrice() external view returns (int256 price, bool isStale) {
        try priceFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            // Validate price is positive
            if (answer <= 0) {
                return (PEG_PRICE, true);
            }

            // Chainlink sanity checks: detect incomplete rounds
            if (startedAt == 0) {
                return (PEG_PRICE, true);
            }

            // Chainlink sanity checks: detect stale/incomplete rounds
            if (updatedAt == 0 || answeredInRound < roundId) {
                return (PEG_PRICE, true);
            }

            // Check staleness
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) {
                return (PEG_PRICE, true);
            }

            return (answer, false);
        } catch {
            return (PEG_PRICE, true);
        }
    }

    /**
     * @notice Check if price feed is fresh
     * @return True if data is within staleness threshold
     */
    function isFresh() external view returns (bool) {
        try priceFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return false;
            if (startedAt == 0) return false;
            if (updatedAt == 0 || answeredInRound < roundId) return false;
            return block.timestamp - updatedAt <= STALENESS_THRESHOLD;
        } catch {
            return false;
        }
    }

    /**
     * @notice Get decimals for price
     * @return Decimals (8 for USD feeds)
     */
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Get description of price feed
     * @return Description string
     */
    function description() external view returns (string memory) {
        try priceFeed.description() returns (string memory desc) {
            return desc;
        } catch {
            return "CURD/USD Price Feed";
        }
    }

    // ============ INTERNAL HELPERS ============

    /**
     * @notice Use fallback peg price ($1)
     * @return price Peg price (1e8)
     * @return isStale True (indicating fallback)
     */
    function _usePegPrice() internal returns (int256 price, bool isStale) {
        lastPrice = PEG_PRICE;
        lastUpdateTime = block.timestamp;

        emit PriceUpdated(PEG_PRICE, block.timestamp, true);
        return (PEG_PRICE, true);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update Chainlink aggregator address
     * @dev Only owner can update (in case of aggregator migration)
     * @param _newAggregator New aggregator address
     */
    function updateAggregator(address _newAggregator) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(_newAggregator, "ChainlinkPriceFeed: zero address");

        // Validate new aggregator works
        AggregatorV3Interface newFeed = AggregatorV3Interface(_newAggregator);
        try newFeed.decimals() returns (uint8 feedDecimals) {
            require(feedDecimals == DECIMALS, "ChainlinkPriceFeed: invalid decimals");
        } catch {
            revert InvalidAggregator();
        }

        address oldAggregator = address(priceFeed);
        priceFeed = newFeed;

        emit AggregatorUpdated(oldAggregator, _newAggregator);
    }

    /**
     * @notice Get last cached price and timestamp
     * @return price Last cached price
     * @return timestamp Last update timestamp
     */
    function getLastCachedPrice() external view returns (int256 price, uint256 timestamp) {
        return (lastPrice, lastUpdateTime);
    }
}
