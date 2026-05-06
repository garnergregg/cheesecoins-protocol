// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title INFTTransferHook
 * @notice Interface for marketplace transfer hooks
 */
interface INFTTransferHook {
    function beforeNFTTransfer(uint256 nftId, address from, address to) external returns (bool);

    function afterNFTTransfer(uint256 nftId, address from, address to) external;
}
