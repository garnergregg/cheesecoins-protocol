// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";
import {MathLibrary} from "../libraries/MathLibrary.sol";

/**
 * @title FounderDecentralization
 * @notice Manages 5-year founder decentralization schedule
 * @dev Y1: 50% → Y2: 40% → Y3: 30% → Y4: 20% → Y5: 10% → Y5 cliff: 0% (converts to regular super holder)
 * @custom:security-contact security@cheesecoins.io
 */
contract FounderDecentralization {
    using ValidationLibrary for address;
    using ValidationLibrary for uint256;
    using MathLibrary for uint256;

    // ============ State Variables ============

    /// @notice Founder address (receives 10M CURD allocation)
    address public immutable founder;

    /// @notice Protocol start timestamp (genesis)
    uint256 public immutable startTime;

    /// @notice Current founder governance weight (starts at 50%)
    uint256 public currentFounderWeight;

    /// @notice Last weight update timestamp
    uint256 public lastWeightUpdate;

    /// @notice Whether founder has reached Y5 cliff (converted to regular super holder)
    bool public hasReachedCliff;

    /// @notice Founder CURD allocation (10M tokens)
    uint256 public constant FOUNDER_ALLOCATION = Config.FOUNDER_ALLOCATION;

    // ============ Events ============

    event FounderWeightUpdated(uint256 indexed year, uint256 newWeight, uint256 timestamp);

    event FounderDecentralizationComplete(address indexed founder, uint256 finalWeight, uint256 timestamp);

    event AnnualWeightDecrement(uint256 indexed year, uint256 oldWeight, uint256 newWeight);

    // ============ Errors ============

    error NotFounder();
    error TooSoonToUpdate();
    error AlreadyDecentralized();
    error InvalidYear();

    // ============ Constructor ============

    /**
     * @notice Initialize founder decentralization contract
     * @param _founder Founder address
     */
    constructor(address _founder) {
        _founder.requireNonZeroAddress("FounderDecent: invalid founder");

        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        founder = _founder;
        startTime = block.timestamp;
        currentFounderWeight = Config.FOUNDER_INITIAL_WEIGHT; // 50%
        lastWeightUpdate = block.timestamp;
        hasReachedCliff = false;
    }

    // ============ Core Functions ============

    /**
     * @notice Get current year since protocol launch
     * @return year Current year (1-5, then 6+)
     */
    function getCurrentYear() public view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        return (elapsed / Config.ONE_YEAR) + 1;
    }

    /**
     * @notice Get founder governance weight based on current year
     * @return weight Governance weight percentage (0-50)
     * @dev Y1: 50%, Y2: 40%, Y3: 30%, Y4: 20%, Y5: 10%, Y5+: 0%
     */
    function getFounderWeight() public view returns (uint256) {
        if (hasReachedCliff) {
            return 0;
        }

        uint256 year = getCurrentYear();

        if (year >= Config.FOUNDER_DECENTRALIZATION_YEARS) {
            return 0; // Y5 cliff: founder becomes regular super holder
        }

        // Calculate weight: 50% - (10% × (year - 1))
        uint256 decrementYears = year - 1;
        uint256 totalDecrement = decrementYears * Config.FOUNDER_WEIGHT_DECREMENT;

        if (totalDecrement >= Config.FOUNDER_INITIAL_WEIGHT) {
            return 0;
        }

        return Config.FOUNDER_INITIAL_WEIGHT - totalDecrement;
    }

    /**
     * @notice Update founder weight (annual mechanism)
     * @dev Can be called by anyone, but only executes once per year
     */
    function updateFounderWeight() external {
        if (hasReachedCliff) {
            revert AlreadyDecentralized();
        }

        // Require at least 1 year since last update
        if (block.timestamp < lastWeightUpdate + Config.ONE_YEAR) {
            revert TooSoonToUpdate();
        }

        uint256 year = getCurrentYear();
        uint256 oldWeight = currentFounderWeight;
        uint256 newWeight = getFounderWeight();

        currentFounderWeight = newWeight;
        lastWeightUpdate = block.timestamp;

        emit AnnualWeightDecrement(year, oldWeight, newWeight);
        emit FounderWeightUpdated(year, newWeight, block.timestamp);

        // Check if Y5 cliff reached
        if (year >= Config.FOUNDER_DECENTRALIZATION_YEARS) {
            hasReachedCliff = true;
            emit FounderDecentralizationComplete(founder, 0, block.timestamp);
        }
    }

    /**
     * @notice Force update to Y5 cliff (emergency function)
     * @dev Only founder can call, useful if annual update mechanism fails
     */
    function forceCliff() external {
        if (msg.sender != founder) {
            revert NotFounder();
        }

        uint256 year = getCurrentYear();
        if (year < Config.FOUNDER_DECENTRALIZATION_YEARS) {
            revert InvalidYear();
        }

        if (hasReachedCliff) {
            revert AlreadyDecentralized();
        }

        currentFounderWeight = 0;
        hasReachedCliff = true;
        lastWeightUpdate = block.timestamp;

        emit FounderDecentralizationComplete(founder, 0, block.timestamp);
    }

    /**
     * @notice Get founder voting power multiplier
     * @return multiplier Voting power multiplier (0-50 representing 0-50%)
     * @dev Used by SuperHolderGovernance to calculate founder's vote weight
     */
    function getFounderMultiplier() external view returns (uint256) {
        return getFounderWeight();
    }

    /**
     * @notice Check if address is the founder
     * @param account Address to check
     * @return True if address is founder
     */
    function isFounder(address account) external view returns (bool) {
        return account == founder;
    }

    /**
     * @notice Get time until next weight update is allowed
     * @return seconds Time in seconds (0 if update is allowed now)
     */
    function timeUntilNextUpdate() external view returns (uint256) {
        uint256 nextUpdateTime = lastWeightUpdate + Config.ONE_YEAR;
        if (block.timestamp >= nextUpdateTime) {
            return 0;
        }
        return nextUpdateTime - block.timestamp;
    }

    /**
     * @notice Get decentralization progress
     * @return year Current year
     * @return weight Current founder weight
     * @return isComplete Whether decentralization is complete
     * @return nextUpdateIn Seconds until next update
     */
    function getDecentralizationStatus()
        external
        view
        returns (uint256 year, uint256 weight, bool isComplete, uint256 nextUpdateIn)
    {
        year = getCurrentYear();
        weight = getFounderWeight();
        isComplete = hasReachedCliff;

        uint256 nextUpdateTime = lastWeightUpdate + Config.ONE_YEAR;
        nextUpdateIn = block.timestamp >= nextUpdateTime ? 0 : nextUpdateTime - block.timestamp;

        return (year, weight, isComplete, nextUpdateIn);
    }

    /**
     * @notice Get expected weight for a future year
     * @param year Future year (1-5+)
     * @return weight Expected governance weight for that year
     */
    function getExpectedWeightForYear(uint256 year) external pure returns (uint256) {
        year.requireInRange(1, 10, "FounderDecent: invalid year");

        if (year >= Config.FOUNDER_DECENTRALIZATION_YEARS) {
            return 0;
        }

        uint256 decrementYears = year - 1;
        uint256 totalDecrement = decrementYears * Config.FOUNDER_WEIGHT_DECREMENT;

        if (totalDecrement >= Config.FOUNDER_INITIAL_WEIGHT) {
            return 0;
        }

        return Config.FOUNDER_INITIAL_WEIGHT - totalDecrement;
    }

    /**
     * @notice Calculate founder adjusted voting power
     * @param baseVotingPower Base voting power from stakes/NFTs
     * @return adjustedPower Voting power adjusted by founder weight
     * @dev Only applies if caller is founder and before Y5 cliff
     */
    function calculateFounderAdjustedPower(address voter, uint256 baseVotingPower) external view returns (uint256) {
        if (voter != founder || hasReachedCliff) {
            return baseVotingPower;
        }

        uint256 founderWeight = getFounderWeight();
        // slither-disable-next-line incorrect-equality -- founderWeight == 0 means decentralization complete; no bonus applied
        if (founderWeight == 0) {
            return baseVotingPower;
        }

        // Apply founder weight multiplier: base * (1 + founderWeight/100)
        uint256 founderBonus = (baseVotingPower * founderWeight) / 100;
        return baseVotingPower + founderBonus;
    }
}
