// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IHedgeModule
 * @notice Interface for the Phase-3 hedge buyback module.
 *         HedgeModule swaps treasury-prefunded USDC for CURD on Uniswap v3
 *         and permanently burns the acquired CURD via BurnAuthority.
 *
 * @custom:security-contact security@cheesecoins.io
 */
interface IHedgeModule {
    // ============ EVENTS ============

    /**
     * @notice Emitted after a successful buyback execution
     * @param usdcIn             USDC spent in this execution
     * @param curdOut            CURD acquired and burned
     * @param timestamp          Block timestamp of execution
     * @param remainingDailyBudget USDC remaining in today's budget
     */
    event BuybackExecuted(uint256 usdcIn, uint256 curdOut, uint256 timestamp, uint256 remainingDailyBudget);

    // ============ CORE FUNCTION ============

    /**
     * @notice Execute a USDC→CURD buyback and burn
     * @dev Only callable by the designated coordinator.
     *      HedgeModule must already hold at least `usdcAmount` USDC.
     *      Acquired CURD is transferred to BurnAuthority and immediately burned.
     * @param usdcAmount  USDC to swap (6 decimals)
     * @param minCurdOut  Minimum CURD to receive (18 decimals); protects against slippage
     * @param deadline    Unix timestamp after which the swap reverts
     * @return curdBurned Amount of CURD acquired and burned (18 decimals)
     */
    function executeBuyback(uint256 usdcAmount, uint256 minCurdOut, uint256 deadline)
        external
        returns (uint256 curdBurned);
}
