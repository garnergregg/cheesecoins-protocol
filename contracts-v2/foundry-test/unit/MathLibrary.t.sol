// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/libraries/MathLibrary.sol";

/**
 * @title MathLibraryTest
 * @notice Unit tests for MathLibrary functions
 */
contract MathLibraryTest is Test {
    using MathLibrary for uint256;

    uint256 constant WAD = 1e18;

    function testLnBasicValues() public {
        // ln(1) = 0
        assertEq(MathLibrary.ln(WAD), 0, "ln(1) should be 0");

        // ln(2) ≈ 0.693
        uint256 ln2 = MathLibrary.ln(2 * WAD);
        assertApproxEqRel(ln2, 693147180559945309, 0.01e18, "ln(2) should be ~0.693");

        // ln(10) ≈ 2.303
        uint256 ln10 = MathLibrary.ln(10 * WAD);
        assertApproxEqRel(ln10, 2302585092994045684, 0.05e18, "ln(10) should be ~2.303");
    }

    function testCalculateCAGR() public {
        // Test 20% growth over 1 year
        uint256 cagr = MathLibrary.calculateCAGR(100, 120, 1);
        assertEq(cagr, 120, "20% growth should give CAGR of 120");

        // Test no growth
        cagr = MathLibrary.calculateCAGR(100, 100, 1);
        assertEq(cagr, 100, "No growth should give CAGR of 100");

        // Test decline
        cagr = MathLibrary.calculateCAGR(100, 80, 1);
        assertLe(cagr, 100, "Decline should give CAGR < 100");
    }

    function testCompoundInterest() public {
        // Test 10% APY for 1 period
        uint256 result = MathLibrary.compoundInterest(1000, 1000, 1); // 10% (1000 bps)
        assertEq(result, 1100, "10% for 1 period should yield 1100");

        // Test 0 periods
        result = MathLibrary.compoundInterest(1000, 1000, 0);
        assertEq(result, 1000, "0 periods should return principal");

        // Test 0 rate
        result = MathLibrary.compoundInterest(1000, 0, 5);
        assertEq(result, 1000, "0 rate should return principal");
    }

    function testWeightedAverage() public {
        uint256[] memory values = new uint256[](3);
        uint256[] memory weights = new uint256[](3);

        values[0] = 100;
        values[1] = 200;
        values[2] = 300;

        weights[0] = 1;
        weights[1] = 2;
        weights[2] = 1;

        // (100*1 + 200*2 + 300*1) / (1+2+1) = 800/4 = 200
        uint256 avg = MathLibrary.weightedAverage(values, weights);
        assertEq(avg, 200, "Weighted average should be 200");
    }

    function testMulDiv() public {
        // Test basic multiplication with scaling
        uint256 result = MathLibrary.mulDiv(100, 200, 10);
        assertEq(result, 2000, "mulDiv should handle basic math");

        // Test with WAD scaling
        result = MathLibrary.mulDiv(2 * WAD, 3 * WAD, WAD);
        assertEq(result, 6 * WAD, "mulDiv should handle WAD scaling");
    }

    function testPercentageOf() public {
        // Test 50% of 100
        uint256 result = MathLibrary.percentageOf(100, 5000); // 50% in basis points
        assertEq(result, 50, "50% of 100 should be 50");

        // Test 100% of 100
        result = MathLibrary.percentageOf(100, 10000); // 100% in basis points
        assertEq(result, 100, "100% of 100 should be 100");

        // Test 10% of 1000
        result = MathLibrary.percentageOf(1000, 1000); // 10% in basis points
        assertEq(result, 100, "10% of 1000 should be 100");
    }

    function testMinMax() public {
        assertEq(MathLibrary.min(5, 10), 5, "min(5, 10) should be 5");
        assertEq(MathLibrary.min(10, 5), 5, "min(10, 5) should be 5");
        assertEq(MathLibrary.max(5, 10), 10, "max(5, 10) should be 10");
        assertEq(MathLibrary.max(10, 5), 10, "max(10, 5) should be 10");
    }

    function testLerp() public {
        // Test linear interpolation
        // 0% between 100 and 200 = 100
        uint256 result = MathLibrary.lerp(100, 200, 0);
        assertEq(result, 100, "lerp at 0% should be start value");

        // 50% between 100 and 200 = 150
        result = MathLibrary.lerp(100, 200, 0.5e18);
        assertEq(result, 150, "lerp at 50% should be midpoint");

        // 100% between 100 and 200 = 200
        result = MathLibrary.lerp(100, 200, 1e18);
        assertEq(result, 200, "lerp at 100% should be end value");
    }
}
