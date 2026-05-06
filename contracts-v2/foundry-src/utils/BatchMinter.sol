// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface INFTMint {
    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external;
}

/**
 * @notice One-shot batch minter for NubiansNorthNFT.
 * Deploy this contract, authorize it as a minter on NubiansNorthNFT,
 * then call mintRange to mint multiple scenes in a single transaction.
 */
contract BatchMinter {
    function mintRange(address nft, address to, uint16 fromScene, uint16 toScene, uint256 qty) external {
        INFTMint nftContract = INFTMint(nft);
        for (uint16 i = fromScene; i <= toScene; i++) {
            nftContract.mintScene(to, i, qty);
        }
    }
}
