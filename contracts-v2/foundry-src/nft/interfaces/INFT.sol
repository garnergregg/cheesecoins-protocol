// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title INFT
 * @notice Interface for project NFT contracts
 * @dev For ERC721 standard methods (ownerOf, transferFrom, totalSupply),
 *      use IERC721 or IERC721Enumerable interfaces instead
 */
interface INFT {
    function mint(address to, uint16 sceneNumber) external returns (uint256 tokenId);

    function getSceneNumber(uint256 tokenId) external view returns (uint16);

    function getProjectId() external view returns (uint256);
}
