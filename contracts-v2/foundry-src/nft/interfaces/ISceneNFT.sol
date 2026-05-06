// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ISceneNFT
 * @notice Interface for scene-based NFT collections (100 scenes × 500 copies each)
 * @dev Extends the basic NFT interface with multi-copy scene minting.
 *      CsaCertificateSale uses this interface to mint specific scenes.
 */
interface ISceneNFT {
    /// @notice Mint `quantity` copies of `sceneNumber` to `to`
    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external;

    /// @notice Returns the scene number for a given token ID
    function tokenScene(uint256 tokenId) external view returns (uint16);

    /// @notice Returns how many copies of `sceneNumber` have been minted so far
    function mintedPerScene(uint16 sceneNumber) external view returns (uint256);

    /// @notice Total number of distinct scenes (100)
    function TOTAL_SCENES() external view returns (uint16);

    /// @notice Maximum copies allowed per scene (500)
    function SCENE_MAX_SUPPLY() external view returns (uint256);
}
