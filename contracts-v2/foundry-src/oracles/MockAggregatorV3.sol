// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Minimal Chainlink AggregatorV3 mock for testnets.
/// Only implements what your ChainlinkPriceFeed uses: latestRoundData().
contract MockAggregatorV3 {
    int256 public answer;
    uint8 public decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }
}
