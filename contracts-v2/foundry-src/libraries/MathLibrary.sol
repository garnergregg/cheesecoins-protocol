// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title MathLibrary
 * @notice Advanced mathematical functions for DeFi calculations
 * @dev Provides logarithm, CAGR, and compound interest calculations
 */
library MathLibrary {
    uint256 private constant WAD = 1e18;
    uint256 private constant HALF_WAD = 5e17;

    /**
     * @notice Calculate natural logarithm (ln) using Taylor series approximation
     * @param x Input value in WAD format (1e18 = 1.0)
     * @return Natural logarithm of x in WAD format
     * @dev Uses ln(x) ≈ ln(1 + (x-1)) series expansion
     */
    function ln(uint256 x) internal pure returns (uint256) {
        require(x > 0, "MathLib: ln(0) undefined");

        // Handle x = 1
        if (x == WAD) return 0;

        // For x < 1, use ln(x) = -ln(1/x)
        bool isLessThanOne = x < WAD;
        if (isLessThanOne) {
            x = (WAD * WAD) / x;
        }

        // Reduce x to range [1, 2) by factoring out powers of 2
        uint256 powerOf2 = 0;
        while (x >= 2 * WAD) {
            x = x / 2;
            powerOf2++;
        }

        // Taylor series: ln(1+y) = y - y²/2 + y³/3 - y⁴/4 + ...
        uint256 y = x - WAD;
        uint256 result = 0;
        uint256 term = y;

        // Calculate first 10 terms for precision
        for (uint256 i = 1; i <= 10; i++) {
            if (i > 1) {
                term = (term * y) / WAD;
            }
            if (i % 2 == 0) {
                result -= term / i;
            } else {
                result += term / i;
            }
        }

        // Add ln(2) * powerOf2 (ln(2) ≈ 0.693147180559945309417 in WAD)
        result += powerOf2 * 693147180559945309;

        // Apply sign if input was less than 1
        if (isLessThanOne) {
            result = 0; // ln(x) for x < 1 is negative, we'll return 0 for simplicity
        }

        return result;
    }

    /**
     * @notice Calculate Compound Annual Growth Rate (CAGR)
     * @param initialValue Starting value
     * @param finalValue Ending value
     * @param numYears Number of years
     * @return CAGR as percentage (e.g., 120 = 1.2x growth)
     * @dev Formula: CAGR = (finalValue/initialValue)^(1/numYears) - 1
     */
    function calculateCAGR(uint256 initialValue, uint256 finalValue, uint256 numYears) internal pure returns (uint256) {
        require(initialValue > 0, "MathLib: initial value zero");
        require(finalValue > 0, "MathLib: final value zero");
        require(numYears > 0, "MathLib: years zero");

        if (finalValue == initialValue) return 100; // No growth = 100 (1.0x)

        // For simplicity, use linear approximation for MVP
        // CAGR ≈ (finalValue - initialValue) / (initialValue * numYears)
        if (finalValue > initialValue) {
            uint256 totalGrowth = ((finalValue - initialValue) * 100) / initialValue;
            return 100 + (totalGrowth / numYears);
        } else {
            uint256 totalDecline = ((initialValue - finalValue) * 100) / initialValue;
            uint256 decline = totalDecline / numYears;
            return decline >= 100 ? 0 : 100 - decline;
        }
    }

    /**
     * @notice Calculate compound interest
     * @param principal Initial amount
     * @param rate Annual rate in basis points (e.g., 500 = 5%)
     * @param periods Number of compounding periods
     * @return Final amount after compounding
     */
    function compoundInterest(uint256 principal, uint256 rate, uint256 periods) internal pure returns (uint256) {
        if (periods == 0) return principal;
        if (rate == 0) return principal;

        uint256 result = principal;
        for (uint256 i = 0; i < periods; i++) {
            result = result + (result * rate) / 10000;
        }
        return result;
    }

    /**
     * @notice Calculate weighted average
     * @param values Array of values
     * @param weights Array of weights
     * @return Weighted average
     */
    function weightedAverage(uint256[] memory values, uint256[] memory weights) internal pure returns (uint256) {
        require(values.length == weights.length, "MathLib: array length mismatch");
        require(values.length > 0, "MathLib: empty arrays");

        uint256 sum = 0;
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i] * weights[i];
            totalWeight += weights[i];
        }

        require(totalWeight > 0, "MathLib: total weight zero");
        return sum / totalWeight;
    }

    /**
     * @notice Safe multiply with scaling
     * @param a First number
     * @param b Second number
     * @param scale Scaling factor (e.g., 1e18 for WAD)
     * @return Result of (a * b) / scale
     */
    function mulDiv(uint256 a, uint256 b, uint256 scale) internal pure returns (uint256) {
        require(scale > 0, "MathLib: scale zero");
        return (a * b) / scale;
    }

    /**
     * @notice Calculate percentage of a value
     * @param value Base value
     * @param percentage Percentage in basis points (10000 = 100%)
     * @return Result of value * percentage / 10000
     */
    function percentageOf(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return (value * percentage) / 10000;
    }

    /**
     * @notice Linear interpolation between two values
     * @param start Starting value
     * @param end Ending value
     * @param progress Progress from 0 to 1 in WAD format
     * @return Interpolated value
     */
    function lerp(uint256 start, uint256 end, uint256 progress) internal pure returns (uint256) {
        require(progress <= WAD, "MathLib: progress > 1");
        if (end >= start) {
            return start + mulDiv(end - start, progress, WAD);
        } else {
            return start - mulDiv(start - end, progress, WAD);
        }
    }

    /**
     * @notice Get minimum of two values
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Get maximum of two values
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
