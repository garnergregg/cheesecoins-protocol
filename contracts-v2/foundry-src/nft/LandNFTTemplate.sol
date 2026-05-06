// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ILandNFT} from "./interfaces/ILandNFT.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title LandNFTTemplate
 * @notice Factory-deployable NFT template for Land Right instruments.
 *
 * NFT CLASS: Land / Capital
 * ─────────────────────────────────────────────────────────────────────────────
 * Purpose:    Represents a specific legal right over a parcel of farmland.
 *             Each token is a fractional, on-chain instrument encoding:
 *               - Which right is being granted (fee simple, lease, minerals, etc.)
 *               - How much land area each token represents
 *               - The legal deed/parcel it references
 *               - The jurisdiction (province/state) governing it
 *
 *             IMPORTANT: These instruments exist on-chain as digital records of
 *             real-world legal rights. The on-chain token is NOT itself the legal
 *             instrument — it is evidence of it. The binding legal agreement is
 *             the terms document (termsUri) and associated off-chain filings.
 *             Legal review is required before offering these instruments for sale
 *             in any jurisdiction.
 *
 * Right Types (set at init, immutable):
 *   FeeSingle          — Fractional fee-simple ownership stake
 *   AgriculturalLease  — Right to farm for a fixed term
 *   DevelopmentRights  — Right to build or develop on the parcel
 *   MineralRights      — Sub-surface extraction rights
 *   Easement           — Right of way, water access, shared infrastructure
 *
 * Governance: ELIGIBLE — Land right holders can participate in SuperHolder
 *             governance once the project is registered. FeeSingle holders
 *             carry the strongest governance claim.
 *
 * Staking:    Optional — set yieldEnabled at init. If enabled, StakingManager
 *             hook is wired and holders earn yield from land use income.
 *
 * Term:       Permanent (maturityDate = 0) or time-limited (maturityDate > 0).
 *             Leases and easements typically have a maturityDate.
 *             Fee simple ownership is typically permanent.
 *             Renewable if isRenewable = true — issuer can extend term.
 *
 * Area:       Each token represents `areaPerTokenSqm` square meters × 1e6.
 *             Total parcel area is `parcelAreaSqm` × 1e6.
 *             Example: 100-acre parcel, 1,000 tokens → 0.1 acres / token.
 *
 * Deed Link:  `parentDeedId` is the keccak256 of the IPFS CID of the title
 *             deed / legal description document. Provides off-chain traceability.
 *
 * Transfers:  Always allowed — land rights are tradeable on secondary market.
 *
 * Hooks:      Optional StakingManager hook. No SceneTracker needed (no scenes).
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * DEPLOYMENT:
 * - Deployed once as implementation contract
 * - ProjectFactory creates EIP-1167 minimal proxy clones for each project
 * - TESTNET ONLY until legal review is complete per jurisdiction
 *
 * SECURITY:
 * - ReentrancyGuard on minting
 * - Authorized minters only (ProjectSale must be whitelisted)
 * - Supply cap enforced on every mint
 * - Minting blocked after maturityDate if set
 * - Initializer protection (one-time init per clone)
 *
 * @custom:legal TESTNET ONLY — do not deploy to mainnet without legal review.
 * @custom:security-contact security@cheesecoins.io
 */
// slither-disable-next-line locked-ether
contract LandNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ============ STATE VARIABLES ============

    /// @notice Project ID assigned by ProjectRegistry
    uint256 public projectId;

    /// @notice The farmer / landowner who issued these rights
    address public issuerAddress;

    /// @notice The type of land right this collection represents
    ILandNFT.LandRightType public rightType;

    /// @notice keccak256 of the IPFS CID of the deed / title document
    /// @dev Used to link on-chain tokens back to the physical legal document.
    ///      Verify: keccak256(abi.encodePacked("ipfs://QmXxx...")) off-chain.
    bytes32 public parentDeedId;

    /// @notice Total parcel area in square meters × 1e6 (sub-meter precision)
    /// @dev Example: 100 acres = 404,685.64 sqm → stored as 404_685_640_000
    uint256 public parcelAreaSqm;

    /// @notice Area each token represents in square meters × 1e6
    /// @dev Example: 0.1 acres = 404.686 sqm → stored as 404_686_000
    uint256 public areaPerTokenSqm;

    /// @notice IPFS URI to the full legal description, survey map, and title search
    string public legalDescriptionUri;

    /// @notice Province or state code governing this land right (e.g. "ON", "BC", "AB")
    string public jurisdiction;

    /// @notice IPFS URI pointing to the full terms document for this right
    string public termsUri;

    /// @notice Maximum number of land right tokens that can be minted
    uint256 public maxSupply;

    /// @notice Unix timestamp when this right expires (0 = permanent)
    /// @dev 0 for fee simple ownership. Set for leases, easements, dev rights.
    uint256 public maturityDate;

    /// @notice Whether the issuer can extend the maturityDate
    bool public isRenewable;

    /// @notice Whether staking yield is active for this instrument
    bool public yieldEnabled;

    /// @notice Base URI for token metadata (IPFS)
    string private _baseTokenURI;

    /// @notice Transfer hook (optional — StakingManager if yieldEnabled)
    INFTTransferHook public transferHook;

    /// @notice Whitelisted minters (ProjectSale contract)
    mapping(address => bool) public authorizedMinters;

    // ============ ERRORS ============

    error InvalidProjectId();
    error InvalidIssuer();
    error MaxSupplyReached();
    error UnauthorizedMinter();
    error InstrumentExpired();
    error InvalidMaturityDate();
    error NotIssuer();

    // ============ EVENTS ============

    event LandProjectInitialized(
        uint256 indexed projectId,
        address indexed issuer,
        ILandNFT.LandRightType rightType,
        bytes32 parentDeedId,
        uint256 maxSupply,
        uint256 parcelAreaSqm,
        uint256 areaPerTokenSqm,
        string jurisdiction,
        uint256 maturityDate,
        address indexed owner
    );
    event LandTokenMinted(
        uint256 indexed projectId,
        uint256 indexed tokenId,
        address indexed to,
        ILandNFT.LandRightType rightType,
        uint256 areaPerTokenSqm
    );
    event MaturityExtended(uint256 indexed projectId, uint256 oldMaturity, uint256 newMaturity);
    event LegalDescriptionUriUpdated(uint256 indexed projectId, string newUri);
    event TermsUriUpdated(uint256 indexed projectId, string newUri);
    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event BaseURIUpdated(string newBaseURI);

    // ============ INIT PARAMS STRUCT ============

    /**
     * @notice Initialization parameters — grouped to avoid stack-too-deep.
     */
    struct InitParams {
        uint256 projectId;
        string name;
        string symbol;
        address issuerAddress;
        ILandNFT.LandRightType rightType;
        bytes32 parentDeedId; // keccak256 of IPFS CID of deed document
        uint256 parcelAreaSqm; // Total parcel area in sqm × 1e6
        uint256 areaPerTokenSqm; // Area per token in sqm × 1e6
        string legalDescriptionUri; // IPFS — survey, title search, legal description
        string jurisdiction; // Province/state code e.g. "ON"
        string termsUri; // IPFS — full terms document
        uint256 maxSupply;
        uint256 maturityDate; // 0 = permanent rights
        bool isRenewable;
        bool yieldEnabled;
        string baseURI;
        address owner;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize a Land right NFT clone (called by ProjectFactory).
     * @param p  All initialization parameters — see InitParams struct.
     */
    function initialize(InitParams calldata p) external initializerERC721A initializer {
        if (p.projectId == 0) revert InvalidProjectId();
        if (p.issuerAddress == address(0)) revert InvalidIssuer();
        ValidationLibrary.requireNonZeroAddress(p.owner, "LandNFT: zero owner");
        require(p.maxSupply > 0, "LandNFT: zero supply");
        require(p.parcelAreaSqm > 0, "LandNFT: zero parcel area");
        require(p.areaPerTokenSqm > 0, "LandNFT: zero area per token");
        // slither-disable-next-line timestamp
        require(p.maturityDate == 0 || p.maturityDate > block.timestamp, "LandNFT: maturity in past");

        __ERC721A_init(p.name, p.symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = p.projectId;
        issuerAddress = p.issuerAddress;
        rightType = p.rightType;
        parentDeedId = p.parentDeedId;
        parcelAreaSqm = p.parcelAreaSqm;
        areaPerTokenSqm = p.areaPerTokenSqm;
        legalDescriptionUri = p.legalDescriptionUri;
        jurisdiction = p.jurisdiction;
        termsUri = p.termsUri;
        maxSupply = p.maxSupply;
        maturityDate = p.maturityDate;
        isRenewable = p.isRenewable;
        yieldEnabled = p.yieldEnabled;
        _baseTokenURI = p.baseURI;

        _transferOwnership(p.owner);

        emit LandProjectInitialized(
            p.projectId,
            p.issuerAddress,
            p.rightType,
            p.parentDeedId,
            p.maxSupply,
            p.parcelAreaSqm,
            p.areaPerTokenSqm,
            p.jurisdiction,
            p.maturityDate,
            p.owner
        );
    }

    // ============ MINTING ============

    /**
     * @notice Mint one land right token to `to`.
     * @dev Called by ProjectSale after payment is received.
     */
    function mint(address to) external nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "LandNFT: zero address");
        // slither-disable-next-line timestamp
        if (maturityDate != 0 && block.timestamp >= maturityDate) revert InstrumentExpired();
        if (_totalMinted() >= maxSupply) revert MaxSupplyReached();

        tokenId = _nextTokenId();
        _mint(to, 1);

        emit LandTokenMinted(projectId, tokenId, to, rightType, areaPerTokenSqm);
    }

    /**
     * @notice Mint multiple land right tokens to `to`.
     * @dev Called by ProjectSale after payment is received.
     */
    function mintBatch(address to, uint256 quantity) external nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "LandNFT: zero address");
        // slither-disable-next-line timestamp
        if (maturityDate != 0 && block.timestamp >= maturityDate) revert InstrumentExpired();
        require(quantity > 0, "LandNFT: zero qty");
        if (_totalMinted() + quantity > maxSupply) revert MaxSupplyReached();

        uint256 firstId = _nextTokenId();
        _mint(to, quantity);

        for (uint256 i = 0; i < quantity; i++) {
            emit LandTokenMinted(projectId, firstId + i, to, rightType, areaPerTokenSqm);
        }
    }

    // ============ MATURITY EXTENSION ============

    /**
     * @notice Extend the maturity / term end date (issuer only, renewable only).
     * @dev Allows a lease or easement to be rolled over without redeploying.
     *      Fee simple ownership typically has no maturityDate, so this is unused.
     */
    function extendMaturity(uint256 newMaturityDate) external {
        if (msg.sender != issuerAddress) revert NotIssuer();
        require(isRenewable, "LandNFT: not renewable");
        // slither-disable-next-line timestamp
        require(newMaturityDate > block.timestamp, "LandNFT: new maturity in past");
        require(maturityDate == 0 || newMaturityDate > maturityDate, "LandNFT: must extend, not shorten");

        uint256 old = maturityDate;
        maturityDate = newMaturityDate;
        emit MaturityExtended(projectId, old, newMaturityDate);
    }

    // ============ VIEW FUNCTIONS ============

    function getProjectId() external view returns (uint256) {
        return projectId;
    }

    function getIssuer() external view returns (address) {
        return issuerAddress;
    }

    function getRightType() external view returns (ILandNFT.LandRightType) {
        return rightType;
    }

    function getParentDeedId() external view returns (bytes32) {
        return parentDeedId;
    }

    function getParcelAreaSqm() external view returns (uint256) {
        return parcelAreaSqm;
    }

    function getAreaPerTokenSqm() external view returns (uint256) {
        return areaPerTokenSqm;
    }

    function getLegalDescriptionUri() external view returns (string memory) {
        return legalDescriptionUri;
    }

    function getJurisdiction() external view returns (string memory) {
        return jurisdiction;
    }

    function getTermsUri() external view returns (string memory) {
        return termsUri;
    }

    function isActive() external view returns (bool) {
        // slither-disable-next-line timestamp
        return maturityDate == 0 || block.timestamp < maturityDate;
    }

    function hasExpired() external view returns (bool) {
        // slither-disable-next-line timestamp
        return maturityDate != 0 && block.timestamp >= maturityDate;
    }

    function remainingSupply() external view returns (uint256) {
        return maxSupply - _totalMinted();
    }

    function totalSupply() public view override returns (uint256) {
        return _totalMinted();
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return ERC721AUpgradeable.ownerOf(tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(_baseTokenURI, _toString(tokenId)));
    }

    /**
     * @notice Total area represented by all minted tokens in sqm × 1e6.
     * @dev Useful for marketplace display: "X acres sold out of Y total".
     */
    function totalAreaMintedSqm() external view returns (uint256) {
        return _totalMinted() * areaPerTokenSqm;
    }

    /**
     * @notice Area represented by a specific holder's tokens in sqm × 1e6.
     * @dev Iterates — not for use on-chain. Frontend read-only helper.
     */
    function holderAreaSqm(address holder) external view returns (uint256) {
        return balanceOf(holder) * areaPerTokenSqm;
    }

    // ============ TRANSFER HOOKS ============

    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // Wire transfer hook (StakingManager) if set
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(transferHook.beforeNFTTransfer(startTokenId + i, from, to), "LandNFT: blocked by hook");
            }
        }
    }

    function _afterTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._afterTokenTransfers(from, to, startTokenId, quantity);
        if (address(transferHook) != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                transferHook.afterNFTTransfer(startTokenId + i, from, to);
            }
        }
    }

    // ============ ADMIN ============

    /**
     * @notice Update legal description URI (issuer or owner).
     * @dev Use only to correct errors or add survey updates.
     *      Material changes to the underlying right require re-deployment.
     */
    function setLegalDescriptionUri(string calldata newUri) external {
        require(msg.sender == issuerAddress || msg.sender == owner(), "LandNFT: not issuer or owner");
        legalDescriptionUri = newUri;
        emit LegalDescriptionUriUpdated(projectId, newUri);
    }

    /// @notice Update terms URI (issuer or owner).
    function setTermsUri(string calldata newUri) external {
        require(msg.sender == issuerAddress || msg.sender == owner(), "LandNFT: not issuer or owner");
        termsUri = newUri;
        emit TermsUriUpdated(projectId, newUri);
    }

    function setTransferHook(address hook) external onlyOwner {
        transferHook = INFTTransferHook(hook);
        emit TransferHookSet(hook);
    }

    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(minter, "LandNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }
}
