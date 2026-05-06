// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ICommerceNFT
 * @notice Interface for Commerce / Forward-Commitment NFT instruments.
 * @dev Implemented by CommerceNFTTemplate. Used by ProjectSale to mint tokens
 *      after payment is collected, and by the marketplace for display data.
 */
interface ICommerceNFT {
    // ── Minting ───────────────────────────────────────────────────────────────

    /// @notice Mint one token to `to`. Called by ProjectSale after payment.
    function mint(address to) external returns (uint256 tokenId);

    /// @notice Mint `quantity` tokens to `to`.
    function mintBatch(address to, uint256 quantity) external;

    // ── Fulfillment ───────────────────────────────────────────────────────────

    /// @notice Record delivery for a token. Only issuerAddress can call.
    function markFulfilled(uint256 tokenId) external;

    /// @notice Cancel a token. Only issuerAddress can call.
    function markCancelled(uint256 tokenId) external;

    // ── Maturity ──────────────────────────────────────────────────────────────

    /// @notice Extend maturity date (renewable instruments only, issuer only).
    function extendMaturity(uint256 newMaturityDate) external;

    // ── View ──────────────────────────────────────────────────────────────────

    function getProjectId() external view returns (uint256);
    function getIssuer() external view returns (address);
    function getInstrumentSubtype() external view returns (string memory);
    function getTermsUri() external view returns (string memory);
    function getFaceValueUsdc6() external view returns (uint256);
    function isActive() external view returns (bool);
    function hasExpired() external view returns (bool);
    function remainingSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function isTransferable() external view returns (bool);
    function maturityDate() external view returns (uint256);
    function issuerAddress() external view returns (address);
    function instrumentSubtype() external view returns (string memory);
    function faceValueUsdc6() external view returns (uint256);
}
