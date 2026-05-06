// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Config} from "../Config.sol";
import {MathLibrary} from "../libraries/MathLibrary.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";
import {IStakingManager} from "../staking/interfaces/IStakingManager.sol";
import {IProjectRegistry} from "../platform/interfaces/IProjectRegistry.sol";

/**
 * @title GovernanceWeighting
 * @notice Calculates voting power using growth-weighted formula with logarithmic scaling
 * @dev Formula: ln(stakedCURD) × projectGrowthRate × superHolderMultiplier(2x)
 * @custom:security-contact security@cheesecoins.io
 */
contract GovernanceWeighting {
    using MathLibrary for uint256;
    using ValidationLibrary for address;

    // ============ State Variables ============

    /// @notice Staking manager contract for staked amounts
    IStakingManager public immutable stakingManager;

    /// @notice Project registry for growth rates
    IProjectRegistry public immutable projectRegistry;

    /// @notice Last annual recalculation timestamp
    uint256 public lastRecalculation;

    /// @notice Cached growth rates by project (updated annually)
    mapping(uint256 => uint256) public cachedGrowthRates;

    // ============ Errors ============

    error TooSoonToRecalculate();
    error NoProjects();
    error TooManyProjects();

    // ============ Events ============

    event GrowthRatesRecalculated(uint256 timestamp, uint256 projectCount);
    event VotingPowerCalculated(
        address indexed voter, uint256 votingPower, uint256 stakedAmount, uint256 growthRate, bool isSuperHolder
    );

    // ============ Constructor ============

    /**
     * @notice Initialize governance weighting contract
     * @param _stakingManager Staking manager contract address
     * @param _projectRegistry Project registry contract address
     */
    constructor(address _stakingManager, address _projectRegistry) {
        _stakingManager.requireNonZeroAddress("GovWeight: invalid staking manager");
        _projectRegistry.requireNonZeroAddress("GovWeight: invalid project registry");

        stakingManager = IStakingManager(_stakingManager);
        projectRegistry = IProjectRegistry(_projectRegistry);
        lastRecalculation = block.timestamp;
    }

    // ============ Core Functions ============

    /**
     * @notice Calculate voting power for a voter
     * @param voter Address of the voter
     * @param projectId Project ID for the voter's primary stake
     * @param isSuperHolder Whether voter owns complete 100-scene NFT collection
     * @return votingPower Calculated voting power
     * @dev Formula: ln(stakedCURD) × projectGrowthRate × superHolderMultiplier(2x)
     * @dev Logarithmic scaling prevents mega-whale dominance
     * @dev stakedCURD is the per-wallet amount staked in projectId
     */
    function calculateVotingPower(address voter, uint256 projectId, bool isSuperHolder)
        public
        virtual
        returns (uint256 votingPower)
    {
        voter.requireNonZeroAddress("GovWeight: invalid voter");

        // Get per-wallet staked amount for the project
        // slither-disable-next-line calls-loop
        uint256 stakedAmount = stakingManager.getUserProjectStaked(voter, projectId);

        if (stakedAmount == 0) {
            return 0;
        }

        // Calculate ln(stakedCURD) for logarithmic scaling
        // Prevents mega-whale dominance (1M vs 10M stake is only ~2.3x difference in ln)
        uint256 logStake = MathLibrary.ln(stakedAmount);

        // Get project growth rate multiplier
        uint256 growthRate = getProjectGrowthRate(projectId);

        // Base voting power = ln(stake) × growthRate
        votingPower = MathLibrary.mulDiv(logStake, growthRate, 100);

        // Apply super holder 2x multiplier if applicable
        if (isSuperHolder) {
            votingPower = votingPower * Config.SUPER_HOLDER_MULTIPLIER;
        }

        emit VotingPowerCalculated(voter, votingPower, stakedAmount, growthRate, isSuperHolder);

        return votingPower;
    }

    /**
     * @notice Get project growth rate (cached or fresh)
     * @param projectId Project ID
     * @return growthRate Growth rate as percentage (e.g., 120 = 1.2x growth)
     */
    function getProjectGrowthRate(uint256 projectId) public view returns (uint256) {
        // Use cached rate if available and fresh
        if (cachedGrowthRates[projectId] > 0 && block.timestamp < lastRecalculation + Config.ONE_YEAR) {
            return cachedGrowthRates[projectId];
        }

        // Get fresh metrics from project registry
        // slither-disable-next-line calls-loop
        IProjectRegistry.ProjectMetrics memory metrics = projectRegistry.getProjectMetrics(projectId);

        // Default to 100 (1.0x) if no growth rate available
        return metrics.growthRate > 0 ? metrics.growthRate : 100;
    }

    /**
     * @notice Recalculate growth rates for all projects (annual update)
     * @dev Can be called by anyone, but only executes once per year
     */
    function recalculateGrowthRates() external {
        if (block.timestamp < lastRecalculation + Config.ONE_YEAR) revert TooSoonToRecalculate();

        uint256 projectCount = projectRegistry.getProjectCount();

        // Cache growth rates for all projects
        for (uint256 i = 1; i <= projectCount; i++) {
            // slither-disable-next-line calls-loop -- bounded by registered project count; annual owner-triggered update
            IProjectRegistry.ProjectMetrics memory metrics = projectRegistry.getProjectMetrics(i);
            cachedGrowthRates[i] = metrics.growthRate;
        }

        lastRecalculation = block.timestamp;

        emit GrowthRatesRecalculated(block.timestamp, projectCount);
    }

    /**
     * @notice Calculate weighted voting power across multiple stakes
     * @param voter Address of the voter
     * @param projectIds Array of project IDs where voter has stakes
     * @param isSuperHolder Whether voter is a super holder
     * @return totalVotingPower Sum of voting power across all projects
     */
    function calculateMultiProjectVotingPower(address voter, uint256[] memory projectIds, bool isSuperHolder)
        external
        returns (uint256 totalVotingPower)
    {
        if (projectIds.length == 0) revert NoProjects();
        if (projectIds.length > Config.MAX_PROJECTS_PER_TX) revert TooManyProjects();

        for (uint256 i = 0; i < projectIds.length; i++) {
            // slither-disable-next-line calls-loop -- bounded by Config.MAX_PROJECTS_PER_TX; external calls are trusted protocol contracts
            totalVotingPower += calculateVotingPower(voter, projectIds[i], isSuperHolder);
        }

        return totalVotingPower;
    }

    /**
     * @notice Get logarithmic stake value
     * @param stakedAmount Amount of CURD staked
     * @return Logarithmic value of stake
     * @dev Useful for understanding voting power scaling
     */
    function getLogStakeValue(uint256 stakedAmount) external pure returns (uint256) {
        if (stakedAmount == 0) return 0;
        return MathLibrary.ln(stakedAmount);
    }

    /**
     * @notice Preview voting power for a hypothetical stake
     * @param stakedAmount Amount to stake
     * @param projectId Project ID
     * @param isSuperHolder Whether user would be super holder
     * @return votingPower Projected voting power
     */
    function previewVotingPower(uint256 stakedAmount, uint256 projectId, bool isSuperHolder)
        external
        view
        virtual
        returns (uint256 votingPower)
    {
        if (stakedAmount == 0) return 0;

        uint256 logStake = MathLibrary.ln(stakedAmount);
        uint256 growthRate = getProjectGrowthRate(projectId);

        votingPower = MathLibrary.mulDiv(logStake, growthRate, 100);

        if (isSuperHolder) {
            votingPower = votingPower * Config.SUPER_HOLDER_MULTIPLIER;
        }

        return votingPower;
    }
}
