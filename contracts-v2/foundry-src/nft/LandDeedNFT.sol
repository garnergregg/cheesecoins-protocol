// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILandNFT} from "./interfaces/ILandNFT.sol";

/**
 * @title LandDeedNFT
 * @notice On-chain registry of land parcel deeds. One token per unique parcel.
 *
 * PURPOSE
 * ────────
 * LandDeedNFT is the root record for every land parcel in the Cheesecoins
 * protocol. It does NOT represent a transferable financial instrument — it is
 * the protocol's internal record that a parcel exists and has been verified.
 *
 * Each Deed token:
 *   - Represents one unique physical land parcel
 *   - Is held by the farmer / landowner (issuer)
 *   - Links to the IPFS legal description document
 *   - Records all LandNFTTemplate sub-collections that have been issued
 *     against this parcel
 *
 * RELATIONSHIP TO LandNFTTemplate
 * ─────────────────────────────────
 * When a partner creates a land right project (e.g. "100-acre lease on
 * Sunrise Farm"), ProjectFactory deploys a LandNFTTemplate clone. That clone
 * stores `parentDeedId = keccak256(abi.encodePacked(deedTokenId))` to link
 * back to this registry.
 *
 * CAPPING TOTAL ISSUED AREA
 * ──────────────────────────
 * The protocol owner tracks total issued area per parcel on-chain to prevent
 * over-issuance (issuing more rights than the parcel physically supports).
 * `totalIssuedAreaSqm[deedId]` is updated when a sub-project is registered
 * via `registerSubProject()`.
 *
 * IMPORTANT: This is a TESTNET ONLY contract until full legal/title
 * verification flows are built. Mainnet requires jurisdiction-specific
 * legal review and title search integration.
 *
 * @custom:legal TESTNET ONLY — do not deploy to mainnet without legal review.
 * @custom:security-contact security@cheesecoins.io
 */
contract LandDeedNFT is ERC721, Ownable {
    // ============ STRUCTS ============

    /**
     * @notice On-chain metadata for one land parcel deed.
     */
    struct DeedMetadata {
        address farmer; // Farmer / landowner who holds this deed
        uint256 parcelAreaSqm; // Total parcel area in sqm × 1e6
        string legalDescriptionUri; // IPFS — full legal description, survey, title
        string jurisdiction; // Province/state code e.g. "ON"
        uint256 registeredAt; // Block timestamp when registered
        bool verified; // Protocol admin has verified title documents
    }

    // ============ STATE ============

    /// @notice Auto-incrementing deed token counter
    uint256 private _nextDeedId;

    /// @notice Deed metadata per token ID
    mapping(uint256 => DeedMetadata) public deedMetadata;

    /// @notice Sub-NFT project addresses issued against each deed
    /// @dev deedId → array of LandNFTTemplate contract addresses
    mapping(uint256 => address[]) private _subProjects;

    /// @notice Total area already issued as sub-NFT rights per deed (sqm × 1e6)
    /// @dev Used to prevent over-issuance
    mapping(uint256 => uint256) public totalIssuedAreaSqm;

    /// @notice Whether an address is an approved LandNFTTemplate deployer
    /// @dev Only ProjectFactory should be added here
    mapping(address => bool) public approvedRegistrars;

    // ============ ERRORS ============

    error DeedNotFound(uint256 deedId);
    error NotDeedHolder(uint256 deedId, address caller);
    error OverIssuance(uint256 deedId, uint256 requested, uint256 available);
    error NotApprovedRegistrar();

    // ============ EVENTS ============

    event DeedRegistered(
        uint256 indexed deedId,
        address indexed farmer,
        uint256 parcelAreaSqm,
        string jurisdiction,
        string legalDescriptionUri
    );
    event DeedVerified(uint256 indexed deedId, address indexed verifiedBy);
    event SubProjectRegistered(uint256 indexed deedId, address indexed subProject, uint256 issuedAreaSqm);
    event RegistrarApproved(address indexed registrar, bool approved);

    // ============ CONSTRUCTOR ============

    constructor(address _owner) ERC721("Cheesecoins Land Deed", "DEED") {
        _transferOwnership(_owner);
    }

    // ============ DEED REGISTRATION ============

    /**
     * @notice Register a new land parcel deed and mint the deed token to the farmer.
     * @dev Only the protocol owner can register deeds (requires off-chain title verification).
     *
     * @param farmer              The farmer / landowner who will hold this deed
     * @param parcelAreaSqm      Total parcel area in sqm × 1e6
     * @param legalDescriptionUri IPFS URI to survey, title search, and legal description
     * @param jurisdiction        Province/state code e.g. "ON"
     * @return deedId             The new deed token ID
     */
    function registerDeed(
        address farmer,
        uint256 parcelAreaSqm,
        string calldata legalDescriptionUri,
        string calldata jurisdiction
    ) external onlyOwner returns (uint256 deedId) {
        require(farmer != address(0), "LandDeed: zero farmer");
        require(parcelAreaSqm > 0, "LandDeed: zero area");

        deedId = _nextDeedId++;
        deedMetadata[deedId] = DeedMetadata({
            farmer: farmer,
            parcelAreaSqm: parcelAreaSqm,
            legalDescriptionUri: legalDescriptionUri,
            jurisdiction: jurisdiction,
            registeredAt: block.timestamp,
            verified: false
        });

        _safeMint(farmer, deedId);

        emit DeedRegistered(deedId, farmer, parcelAreaSqm, jurisdiction, legalDescriptionUri);
    }

    /**
     * @notice Mark a deed as verified after title documents have been reviewed.
     * @dev Only owner can verify. Should be called after manual title search
     *      confirms the farmer holds clear title.
     */
    function verifyDeed(uint256 deedId) external onlyOwner {
        if (!_exists(deedId)) revert DeedNotFound(deedId);
        deedMetadata[deedId].verified = true;
        emit DeedVerified(deedId, msg.sender);
    }

    // ============ SUB-PROJECT REGISTRATION ============

    /**
     * @notice Register a LandNFTTemplate sub-project against a deed.
     * @dev Called by ProjectFactory (approved registrar) when deploying a
     *      land right collection. Tracks issued area to prevent over-issuance.
     *
     * @param deedId        The deed token ID this right is issued against
     * @param subProject    The LandNFTTemplate contract address
     * @param issuedAreaSqm Total area being issued by this sub-project (sqm × 1e6)
     */
    function registerSubProject(uint256 deedId, address subProject, uint256 issuedAreaSqm) external {
        if (!approvedRegistrars[msg.sender]) revert NotApprovedRegistrar();
        if (!_exists(deedId)) revert DeedNotFound(deedId);
        require(subProject != address(0), "LandDeed: zero sub-project");

        DeedMetadata storage meta = deedMetadata[deedId];
        uint256 available = meta.parcelAreaSqm - totalIssuedAreaSqm[deedId];
        if (issuedAreaSqm > available) {
            revert OverIssuance(deedId, issuedAreaSqm, available);
        }

        totalIssuedAreaSqm[deedId] += issuedAreaSqm;
        _subProjects[deedId].push(subProject);

        emit SubProjectRegistered(deedId, subProject, issuedAreaSqm);
    }

    // ============ VIEW ============

    /**
     * @notice Returns the keccak256 deed ID used as `parentDeedId` in LandNFTTemplate.
     * @dev LandNFTTemplate stores `parentDeedId = getLandDeedHash(deedId)`.
     *      This links sub-NFTs back to this registry without storing a contract address.
     */
    function getLandDeedHash(uint256 deedId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(deedId));
    }

    /// @notice All sub-project addresses issued against a deed
    function getSubProjects(uint256 deedId) external view returns (address[] memory) {
        return _subProjects[deedId];
    }

    /// @notice Returns full DeedMetadata struct for a given deed ID.
    function getDeedMetadata(uint256 deedId) external view returns (DeedMetadata memory) {
        return deedMetadata[deedId];
    }

    /// @notice Remaining area available for sub-project issuance (sqm × 1e6)
    function availableAreaSqm(uint256 deedId) external view returns (uint256) {
        if (!_exists(deedId)) revert DeedNotFound(deedId);
        return deedMetadata[deedId].parcelAreaSqm - totalIssuedAreaSqm[deedId];
    }

    /// @notice Number of deeds registered
    function totalDeeds() external view returns (uint256) {
        return _nextDeedId;
    }

    // ============ ADMIN ============

    function setApprovedRegistrar(address registrar, bool approved) external onlyOwner {
        require(registrar != address(0), "LandDeed: zero registrar");
        approvedRegistrars[registrar] = approved;
        emit RegistrarApproved(registrar, approved);
    }

    /**
     * @notice Update legal description URI for a deed (owner only).
     * @dev Only for corrections. Changing the underlying land parcel requires
     *      revoking and re-issuing the deed.
     */
    function updateLegalDescriptionUri(uint256 deedId, string calldata newUri) external onlyOwner {
        if (!_exists(deedId)) revert DeedNotFound(deedId);
        deedMetadata[deedId].legalDescriptionUri = newUri;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://";
    }
}
