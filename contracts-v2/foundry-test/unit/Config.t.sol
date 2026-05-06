// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/libraries/MathLibrary.sol";

/**
 * @title ConfigTest
 * @notice Unit tests for Config library
 */
contract ConfigTest is Test {
    function testConfigConstants() public {
        // Test token supply constants
        assertEq(Config.INITIAL_SUPPLY, 200_000_000 * 10 ** 18, "Initial supply should be 200M");
        assertEq(Config.MAX_SUPPLY, 400_000_000 * 10 ** 18, "Max supply should be 400M");
        assertEq(Config.ANNUAL_MINT_CAP_PERCENT, 2, "Annual mint cap should be 2%");

        // Test staking constants
        assertEq(Config.MIN_STAKE_PER_NFT, 100 * 10 ** 18, "Min stake should be 100 CURD");
        assertEq(Config.COMMUNITY_90_PERCENT_TARGET, 90, "Community target should be 90%");
        assertEq(Config.COMMUNITY_90_PERCENT_BONUS, 25, "Community bonus should be 25%");

        // Test maturity tiers
        assertEq(Config.MATURITY_1Y_APY, 100, "1Y APY should be 100 (1.0x)");
        assertEq(Config.MATURITY_2Y_APY, 125, "2Y APY should be 125 (1.25x)");
        assertEq(Config.MATURITY_3Y_APY, 150, "3Y APY should be 150 (1.50x)");
        assertEq(Config.MATURITY_5Y_APY, 200, "5Y APY should be 200 (2.0x)");

        // Test governance constants
        assertEq(Config.FOUNDER_ALLOCATION, 20_000_000 * 10 ** 18, "Founder allocation should be 20M");
        assertEq(Config.FOUNDER_DECENTRALIZATION_YEARS, 5, "Decentralization should be 5 years");
        assertEq(Config.FOUNDER_INITIAL_WEIGHT, 50, "Founder initial weight should be 50%");
        assertEq(Config.SUPERMAJORITY_THRESHOLD, 66, "Supermajority should be 66%");
        assertEq(Config.GOVERNANCE_VOTING_PERIOD, 30 days, "Voting period should be 30 days");
        assertEq(Config.TIMELOCK_DELAY, 2 days, "Timelock should be 2 days");
    }

    function testBurnRateSchedule() public {
        // Test burn rate progression Y1-Y10
        assertEq(Config.getBurnRateForYear(0), 0, "Y0 burn should be 0");
        assertEq(Config.getBurnRateForYear(1), 1 * 10 ** 18, "Y1 burn should be 1");
        assertEq(Config.getBurnRateForYear(2), 2 * 10 ** 18, "Y2 burn should be 2");
        assertEq(Config.getBurnRateForYear(3), 3 * 10 ** 18, "Y3 burn should be 3");
        assertEq(Config.getBurnRateForYear(4), 4 * 10 ** 18, "Y4 burn should be 4");
        assertEq(Config.getBurnRateForYear(10), 4 * 10 ** 18, "Y10+ burn should be fixed at 4");
    }

    function testProjectGraduationWeights() public {
        // Test age-based weight reduction
        assertEq(Config.getProjectGraduationWeight(0), 10000, "Y0 should be 100%");
        assertEq(Config.getProjectGraduationWeight(1), 10000, "Y1 should be 100%");
        assertEq(Config.getProjectGraduationWeight(2), 9500, "Y2 should be 95%");
        assertEq(Config.getProjectGraduationWeight(3), 9000, "Y3 should be 90%");
        assertEq(Config.getProjectGraduationWeight(5), 8500, "Y5+ should be 85%");
    }

    function testSeasonalMultipliers() public {
        assertEq(Config.MILK_SPRING_SUMMER, 150, "Spring/summer milk should be 1.5x");
        assertEq(Config.MILK_FALL, 100, "Fall milk should be 1.0x");
        assertEq(Config.MILK_WINTER, 50, "Winter milk should be 0.5x");
        assertEq(Config.MEAT_FALL, 200, "Fall meat should be 2.0x");
        assertEq(Config.MEAT_OTHER, 100, "Other season meat should be 1.0x");
    }

    function testGrowthBonusThresholds() public {
        assertEq(Config.GROWTH_BONUS_THRESHOLD, 120, "Growth threshold should be 1.2x");
        assertEq(Config.GROWTH_BONUS_1_PROJECT, 110, "1 project bonus should be +10%");
        assertEq(Config.GROWTH_BONUS_2_PROJECTS, 115, "2+ projects bonus should be +15%");
        assertEq(Config.GROWTH_BONUS_5_PROJECTS, 120, "5+ projects bonus should be +20%");
    }
}
