// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title Config
 * @notice Central configuration contract for all protocol parameters
 * @dev All critical values are stored here for easy pre-launch adjustment
 *
 * TOKENOMICS STRATEGY:
 * - Initial supply (200M) represents 10 years of herd production value pre-minted NOW
 * - This aggressive but justified approach provides:
 *   1. Liquidity for DEX/CEX launches
 *   2. Capital for onboarding new agricultural projects
 *   3. Resources for ecosystem development (dapps, financing, insurance)
 * - Backed by real production: ~196M CURD value over 10 years
 * - Path to close gap: Onboard projects, build dapps, create financing/insurance products
 * - Better than meme coins: Real asset backing, not pure speculation
 */
library Config {
    // ============ TOKEN SUPPLY & MINTING ============

    /// @notice Initial token supply: 200 million CURD
    /// @dev Represents 10-year herd production value (~196M) pre-minted for strategic launch
    /// @dev Provides liquidity for DEX/CEX, capital for project onboarding, ecosystem development
    uint256 public constant INITIAL_SUPPLY = 200_000_000 * 10 ** 18;

    /// @notice Maximum token supply cap: 400 million CURD (2x initial)
    /// @dev Allows for 20+ year expansion, new project onboarding, utility growth
    uint256 public constant MAX_SUPPLY = 400_000_000 * 10 ** 18;

    /// @notice Annual mint cap as percentage (2% per year)
    uint256 public constant ANNUAL_MINT_CAP_PERCENT = 2;

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Treasury ecosystem allocation at genesis: 180 million CURD
    uint256 public constant TREASURY_ALLOCATION = 180_000_000 * 10 ** 18;

    /// @notice Minimum USDC in treasury to permit minting (6-decimal USDC: 40M)
    uint256 public constant TREASURY_USDC_THRESHOLD = 40_000_000 * 10 ** 6;

    /// @notice Minimum backing ratio in basis points required to permit minting (75%)
    uint256 public constant MIN_BACKING_BPS = 7500;

    /// @notice Founder revenue share in basis points (1%)
    uint256 public constant FOUNDER_REVENUE_BPS = 100;

    /// @notice Founder vesting duration: 4 years in seconds
    uint64 public constant FOUNDER_VEST_DURATION = uint64(4 * 365 days);

    // ============ STAKING REQUIREMENTS ============

    /// @notice Minimum CURD required per NFT to trigger rewards
    uint256 public constant MIN_STAKE_PER_NFT = 100 * 10 ** 18;

    /// @notice Target percentage for community staking bonus (90%)
    uint256 public constant COMMUNITY_90_PERCENT_TARGET = 90;

    /// @notice Bonus APY when 90% target is reached (+25%)
    uint256 public constant COMMUNITY_90_PERCENT_BONUS = 25;

    // ============ MATURITY TIERS (APY MULTIPLIERS) ============

    /// @notice 1-year lock APY multiplier (100 = 1.0x)
    uint256 public constant MATURITY_1Y_APY = 100;

    /// @notice 2-year lock APY multiplier (125 = 1.25x)
    uint256 public constant MATURITY_2Y_APY = 125;

    /// @notice 3-year lock APY multiplier (150 = 1.50x)
    uint256 public constant MATURITY_3Y_APY = 150;

    /// @notice 5+ year lock APY multiplier (200 = 2.0x - loyalty bonus)
    uint256 public constant MATURITY_5Y_APY = 200;

    /// @notice Lock period thresholds in months
    uint256 public constant LOCK_1_YEAR_MONTHS = 12;
    uint256 public constant LOCK_2_YEAR_MONTHS = 24;
    uint256 public constant LOCK_3_YEAR_MONTHS = 36;
    uint256 public constant LOCK_5_YEAR_MONTHS = 60;

    // ============ BURN SCHEDULE (Y1→Y10) ============

    /// @notice Burn rate per unstaked CURD by year (fixed at 4 after Y10)
    /// @dev Y0, Y1, Y2, Y3, Y4, Y5-Y10 (then fixed at 4)
    function getBurnRateForYear(uint256 year) internal pure returns (uint256) {
        if (year == 0) return 0;
        if (year == 1) return 1 * 10 ** 18;
        if (year == 2) return 2 * 10 ** 18;
        if (year == 3) return 3 * 10 ** 18;
        if (year >= 4) return 4 * 10 ** 18;
        return 0; // Should never reach
    }

    // ============ TREASURY ALLOCATION ============

    /// @notice Treasury allocation percentages (must sum to 100)
    uint256 public constant TREASURY_ECOSYSTEM_PERCENT = 40; // Ecosystem development
    uint256 public constant TREASURY_FARMERS_PERCENT = 30; // Farmer support
    uint256 public constant TREASURY_MARKETING_PERCENT = 20; // Marketing
    uint256 public constant TREASURY_RESERVE_PERCENT = 10; // Emergency reserve

    // ============ INSURANCE & FEES ============

    /// @notice Insurance premium rate (2% annual on staked CURD)
    uint256 public constant INSURANCE_PREMIUM_PERCENT = 2;

    /// @notice Early unstake penalty distribution (50% burn, 50% operations)
    uint256 public constant EARLY_UNSTAKE_BURN_PERCENT = 50;
    uint256 public constant EARLY_UNSTAKE_OPS_PERCENT = 50;

    // ============ GOVERNANCE ============

    /// @notice Founder allocation: 20 million CURD (vesting wallet genesis mint)
    uint256 public constant FOUNDER_ALLOCATION = 20_000_000 * 10 ** 18;

    /// @notice Founder decentralization period (5 years)
    uint256 public constant FOUNDER_DECENTRALIZATION_YEARS = 5;

    /// @notice Founder initial governance weight (50% in Y1)
    uint256 public constant FOUNDER_INITIAL_WEIGHT = 50;

    /// @notice Founder weight decrement per year (10% per year)
    uint256 public constant FOUNDER_WEIGHT_DECREMENT = 10;

    /// @notice Supermajority threshold for governance votes (66%)
    uint256 public constant SUPERMAJORITY_THRESHOLD = 66;

    /// @notice Governance voting period (30 days)
    uint256 public constant GOVERNANCE_VOTING_PERIOD = 30 days;

    /// @notice Timelock delay for execution (2 days)
    uint256 public constant TIMELOCK_DELAY = 2 days;

    /// @notice Super holder multiplier (2x voting power)
    uint256 public constant SUPER_HOLDER_MULTIPLIER = 2;

    /// @notice Required NFT scenes for super holder status (complete collection)
    uint256 public constant SUPER_HOLDER_REQUIRED_SCENES = 100;

    // ============ SEASONAL MULTIPLIERS ============

    /// @notice Milk production - Spring/Summer (1.5x)
    uint256 public constant MILK_SPRING_SUMMER = 150;

    /// @notice Milk production - Fall (1.0x)
    uint256 public constant MILK_FALL = 100;

    /// @notice Milk production - Winter (0.5x)
    uint256 public constant MILK_WINTER = 50;

    /// @notice Meat harvest - Fall (2.0x)
    uint256 public constant MEAT_FALL = 200;

    /// @notice Meat harvest - Other seasons (1.0x)
    uint256 public constant MEAT_OTHER = 100;

    // ============ PROJECT GRADUATION (AGING WEIGHTS) ============

    /// @notice Project weight reduction by age (basis points)
    /// @dev Y1: 100%, Y2: 95%, Y3: 90%, Y5+: 85%
    function getProjectGraduationWeight(uint256 yearsSinceStart) internal pure returns (uint256) {
        if (yearsSinceStart == 0) return 10000; // 100%
        if (yearsSinceStart == 1) return 10000; // 100%
        if (yearsSinceStart == 2) return 9500; // 95%
        if (yearsSinceStart == 3) return 9000; // 90%
        if (yearsSinceStart == 4) return 9000; // 90%
        return 8500; // 85% for Y5+
    }

    // ============ GROWTH BONUSES ============

    /// @notice Growth rate threshold for bonuses (120 = 1.2x growth)
    uint256 public constant GROWTH_BONUS_THRESHOLD = 120;

    /// @notice Bonus when 1 project hits threshold (+10%)
    uint256 public constant GROWTH_BONUS_1_PROJECT = 110;

    /// @notice Bonus when 2+ projects hit threshold (+15%)
    uint256 public constant GROWTH_BONUS_2_PROJECTS = 115;

    /// @notice Bonus when 5+ projects hit threshold (+20%)
    uint256 public constant GROWTH_BONUS_5_PROJECTS = 120;

    // ============ ORACLE & DATA FEEDS ============

    /// @notice Oracle staleness threshold (24 hours)
    uint256 public constant ORACLE_STALENESS_THRESHOLD = 24 hours;

    /// @notice Price decimals (8 decimals for Chainlink USD feeds)
    uint256 public constant PRICE_DECIMALS = 8;

    /// @notice Initial peg price (1 CURD = $1 = 1e8 in 8 decimals)
    uint256 public constant PEG_PRICE = 1e8;

    // ============ NFT CONFIGURATION ============

    /// @notice Unique scenes in NFT collection per project
    uint256 public constant NFT_UNIQUE_SCENES = 100;

    /// @notice Copies per scene (500 copies × 100 scenes = 50,000 total NFTs)
    uint256 public constant NFT_COPIES_PER_SCENE = 500;

    /// @notice Total NFT collection size for initial project (Nubians North)
    uint256 public constant NFT_TOTAL_COLLECTION = 50_000; // 100 scenes × 500 copies

    /// @notice Initial NFT value tied to Real World Assets
    uint256 public constant NFT_INITIAL_VALUE = 80 * 10 ** 18; // $80 per NFT in Year 1

    /// @notice Base URI for NFT metadata
    string public constant NFT_BASE_URI = "ipfs://bafybeig6evhwhmgswnwnpl4jaeea2xhpq2shm4l7lx62s4sbpq2wmsn7fy/";

    // ============ TIME CONSTANTS ============

    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant ONE_MONTH = 30 days;
    uint256 public constant ONE_YEAR = 365 days;

    // ============ PRODUCTION ECONOMICS ============

    /// @notice Milk revenue per liter (processed)
    uint256 public constant MILK_REVENUE_PER_LITER = 2 * 10 ** 18; // $2.00

    /// @notice Meat price per pound
    uint256 public constant MEAT_PRICE_PER_LB = 15 * 10 ** 18; // $15.00

    /// @notice Milk production per doe per year
    uint256 public constant MILK_LITERS_PER_DOE_YEAR = 300;

    /// @notice Meat production per doe per year
    uint256 public constant MEAT_LBS_PER_DOE_YEAR = 40;

    /// @notice Total annual revenue per doe
    /// @dev Calculated as: (300L × $2) + (40lb × $15) = $600 + $600 = $1,200
    uint256 public constant REVENUE_PER_DOE_YEAR = 1_200 * 10 ** 18;

    /// @notice Doe value including lifetime production
    /// @dev $800 value ALREADY INCLUDES 5-year LPT and HIAA factor (1.75)
    /// @dev This is the base valuation - no additional HIAA multiplier needed
    uint256 public constant DOE_VALUE = 800 * 10 ** 18;

    /// @notice Initial herd size for Nubians North
    uint256 public constant INITIAL_HERD_SIZE = 500;

    /// @notice Expected herd growth rate (CAGR)
    /// @dev 60% annual growth (herd doubles every ~1.2 years)
    uint256 public constant HERD_GROWTH_RATE_PERCENT = 60;

    /// @notice Herd attrition rate
    uint256 public constant HERD_ATTRITION_RATE = 125; // 1.25% in basis points

    /// @notice Lifetime Production Time used in doe valuation
    /// @dev This is ALREADY FACTORED INTO the $800 doe value above
    uint256 public constant LIFETIME_PRODUCTION_TIME = 5; // years

    /// @notice HIAA (Herd In Active Age) factor
    /// @dev This is ALREADY BAKED INTO the $800 doe value above
    /// @dev No need to apply as separate multiplier in calculations
    /// @dev 175 = 1.75 factor (in basis points: 175/100 = 1.75)
    uint256 public constant HIAA_FACTOR_BASIS_POINTS = 175;

    // ============ MERKLE CLAIM SETTINGS ============

    /// @notice Merkle tree claim window (30 days to claim)
    uint256 public constant MERKLE_CLAIM_WINDOW = 30 days;

    // ============ DEFLATIONARY MECHANICS ============

    /// @notice Maximum burn multiplier cap
    uint256 public constant MAX_BURN_MULTIPLIER = 4 * 10 ** 18;

    /// @notice Deflation trajectory update frequency (annual)
    uint256 public constant DEFLATION_UPDATE_FREQUENCY = ONE_YEAR;

    // ============ SECURITY LIMITS ============

    /// @notice Maximum projects to process in single transaction (gas limit)
    uint256 public constant MAX_PROJECTS_PER_TX = 50;

    /// @notice Maximum NFTs to process in single stake operation
    uint256 public constant MAX_NFTS_PER_STAKE = 10;

    /// @notice Minimum time between audits
    uint256 public constant MIN_AUDIT_INTERVAL = 180 days;

    // ============ AUDIT PARAMETERS ============

    /// @notice Audit penalty for missing targets (5% burn)
    uint256 public constant AUDIT_MISS_PENALTY_PERCENT = 5;

    /// @notice Audit reward for exceeding targets (+10% unlock)
    uint256 public constant AUDIT_EXCEED_REWARD_PERCENT = 10;

    /// @notice Maximum audit burn cap (10% of project allocation)
    uint256 public constant AUDIT_BURN_CAP_PERCENT = 10;
}
