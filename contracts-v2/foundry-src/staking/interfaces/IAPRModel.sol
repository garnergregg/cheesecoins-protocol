// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title IAPRModel
/// @notice Pluggable APR model for TrancheStakingManager
interface IAPRModel {
    /// @notice Returns the APR in basis points for a given NFT and principal amount
    /// @param nftId The CSA NFT token ID
    /// @param principal The principal amount being staked
    /// @return aprBps APR in basis points (e.g. 1000 = 10%)
    function getApr(uint256 nftId, uint256 principal) external view returns (uint32 aprBps);
}
