// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ILandNFT
 * @notice Interface for Land Right NFT instruments.
 * @dev Implemented by LandNFTTemplate. Used by ProjectSale to mint tokens
 *      after payment is collected, and by the marketplace for display data.
 *
 * Land rights supported:
 *   FeeSingle          — Fractional ownership stake in fee simple title
 *   AgriculturalLease  — Right to farm for a fixed term
 *   DevelopmentRights  — Right to build/develop on the parcel
 *   MineralRights      — Sub-surface mineral extraction rights
 *   Easement           — Right of way, water access, shared infrastructure
 */
interface ILandNFT {
    /// @notice The type of land right this collection represents
    enum LandRightType {
        FeeSingle, // Fractional ownership — most valuable, governance-eligible
        AgriculturalLease, // Term-based farming rights
        DevelopmentRights, // Right to develop / construct
        MineralRights, // Sub-surface extraction
        Easement // Access / shared infrastructure
    }

    // ── Minting ───────────────────────────────────────────────────────────────

    /// @notice Mint `quantity` land right tokens to `to`. Called by ProjectSale.
    function mintBatch(address to, uint256 quantity) external;

    /// @notice Mint one token to `to`. Called by ProjectSale.
    function mint(address to) external returns (uint256 tokenId);

    // ── Maturity ──────────────────────────────────────────────────────────────

    /// @notice Extend lease/right term (renewable instruments only, issuer only).
    function extendMaturity(uint256 newMaturityDate) external;

    // ── View ──────────────────────────────────────────────────────────────────

    function getProjectId() external view returns (uint256);
    function getIssuer() external view returns (address);
    function getRightType() external view returns (LandRightType);
    function getParentDeedId() external view returns (bytes32);
    function getParcelAreaSqm() external view returns (uint256);
    function getAreaPerTokenSqm() external view returns (uint256);
    function getLegalDescriptionUri() external view returns (string memory);
    function getJurisdiction() external view returns (string memory);
    function getTermsUri() external view returns (string memory);
    function isActive() external view returns (bool);
    function hasExpired() external view returns (bool);
    function remainingSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function maturityDate() external view returns (uint256);
    function issuerAddress() external view returns (address);
}
