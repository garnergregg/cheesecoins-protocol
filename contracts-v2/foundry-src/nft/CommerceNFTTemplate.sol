// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title CommerceNFTTemplate
 * @notice Factory-deployable NFT template for Commerce / Forward-Commitment instruments.
 *
 * NFT CLASS: Commerce
 * ─────────────────────────────────────────────────────────────────────────────
 * Purpose:    Represents any forward commercial commitment between a Cheesecoins
 *             protocol participant (issuer) and a buyer (holder).
 *
 *             The issuer commits to deliver something — product, service,
 *             priority access, credit, or an agreement — in exchange for
 *             upfront payment. The holder is entitled to that delivery.
 *
 *             This is the canonical instrument for:
 *               - CSA subscriptions (weekly vegetable box for a season)
 *               - Priority purchase agreements (first dibs at locked price)
 *               - Bulk purchase agreements (50 bales of hay at set price)
 *               - Service commitments (20 hours vet services)
 *               - Processing agreements (process 50 pigs at $X each)
 *               - Delivery contracts (weekly milk to restaurant)
 *               - Gift certificates ($100 of farm products)
 *               - Loyalty/discount instruments
 *               - Lines of credit (farm funded upfront, repaid at harvest)
 *
 * Participants: Any approved Cheesecoins partner can be an issuer — farmer,
 *               retailer, feed store, processor, service provider.
 *
 * Governance: NONE — Commerce NFTs carry no voting rights.
 *
 * Staking:    Optional — set yieldEnabled at init. If enabled, StakingManager
 *             hook is wired and holders earn yield.
 *
 * Term:       Fixed (maturityDate > 0) or open-ended (maturityDate = 0).
 *             Renewable if isRenewable = true — issuer can extend maturityDate.
 *             Minting is blocked after maturityDate if set.
 *
 * Transfers:  Configurable — issuer sets isTransferable at init.
 *             Non-transferable instruments (e.g. service commitments tied to
 *             a specific customer) block secondary sales.
 *
 * Fulfillment: Issuer calls markFulfilled(tokenId) when delivery is complete.
 *              Tracks delivery on-chain for dispute resolution / audit.
 *
 * Hooks:      Optional StakingManager hook. No SceneTracker (no governance).
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * COLLECTION STRUCTURE:
 * - Not scene-based — each token is one discrete commitment
 * - Configurable supply cap (set at initialization)
 * - Each token stores: projectId, issuer, subtype, faceValue, fulfillment status
 *
 * SECURITY:
 * - ReentrancyGuard on minting
 * - Authorized minters only (ProjectSale must be whitelisted)
 * - Supply cap enforced
 * - Minting blocked after maturityDate (if set)
 * - Transfer restriction enforced in _beforeTokenTransfers
 * - Initializer protection (one-time init per clone)
 */
// slither-disable-next-line locked-ether
contract CommerceNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ============ ENUMS ============

    /// @notice Fulfillment lifecycle for each token
    enum FulfillmentStatus {
        Pending, // Default — delivery not yet made
        Fulfilled, // Issuer confirmed delivery
        Expired, // Maturity passed without fulfillment
        Cancelled // Issuer cancelled (refund handled off-chain / via ProjectSale)
    }

    // ============ STATE VARIABLES ============

    /// @notice Project ID assigned by ProjectRegistry
    uint256 public projectId;

    /// @notice Partner address that issued this instrument — receives sale proceeds
    address public issuerAddress;

    /// @notice Human-readable instrument subtype
    /// @dev e.g. "csa_subscription", "priority_purchase", "bulk_agreement",
    ///      "line_of_credit", "service_commitment", "processing_agreement",
    ///      "delivery_contract", "gift_certificate", "loyalty_discount"
    string public instrumentSubtype;

    /// @notice Nominal USDC value each token represents (6 decimals, informational)
    /// @dev Used by marketplace for display. Does not affect on-chain payment.
    uint256 public faceValueUsdc6;

    /// @notice IPFS URI pointing to the full terms document for this instrument
    /// @dev Should describe: what holder receives, delivery timeline, redemption
    ///      instructions, cancellation policy, legal jurisdiction.
    string public termsUri;

    /// @notice Unix timestamp when this instrument expires (0 = no expiry)
    uint256 public maturityDate;

    /// @notice Whether the issuer can extend the maturityDate
    bool public isRenewable;

    /// @notice Whether tokens can be transferred on secondary market
    /// @dev If false, transfers are blocked (except minting)
    bool public isTransferable;

    /// @notice Maximum tokens that can be minted
    uint256 public maxSupply;

    /// @notice Base URI for token metadata (IPFS)
    string private _baseTokenURI;

    /// @notice Transfer hook (optional — StakingManager if yieldEnabled)
    INFTTransferHook public transferHook;

    /// @notice Whether staking yield is active for this instrument
    bool public yieldEnabled;

    /// @notice Whitelisted minters (ProjectSale contract)
    mapping(address => bool) public authorizedMinters;

    /// @notice Fulfillment status per token ID
    mapping(uint256 => FulfillmentStatus) public fulfillmentStatus;

    /// @notice Prevents double-initialization
    // slither-disable-next-line shadowing-state
    // (intentional: shadows OZ Initializable._initialized but is a separate
    //  storage slot. Renaming would require redeploying mainnet impl —
    //  keeping the slot stable for upgrade safety.)
    bool private _initialized;

    // ============ ERRORS ============

    error AlreadyInitialized();
    error InvalidProjectId();
    error InvalidIssuer();
    error MaxSupplyReached();
    error UnauthorizedMinter();
    error InstrumentExpired();
    error TransferNotAllowed();
    error InvalidMaturityDate();
    error NotIssuer();
    error TokenAlreadyFulfilled();
    error TokenCancelled();

    // ============ EVENTS ============

    event CommerceProjectInitialized(
        uint256 indexed projectId,
        address indexed issuer,
        string instrumentSubtype,
        uint256 maxSupply,
        uint256 faceValueUsdc6,
        uint256 maturityDate,
        bool isTransferable,
        bool isRenewable,
        address indexed owner
    );
    event TokenMinted(uint256 indexed projectId, uint256 tokenId, address indexed to, string instrumentSubtype);
    event TokenFulfilled(uint256 indexed projectId, uint256 indexed tokenId, address indexed issuer);
    event TokenCancelledEvent(uint256 indexed projectId, uint256 indexed tokenId, address indexed issuer);
    event MaturityExtended(uint256 indexed projectId, uint256 oldMaturity, uint256 newMaturity);
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
        string instrumentSubtype;
        uint256 faceValueUsdc6;
        string termsUri;
        uint256 maxSupply;
        uint256 maturityDate; // 0 = no expiry
        bool isRenewable;
        bool isTransferable;
        bool yieldEnabled;
        string baseURI;
        address owner;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize a Commerce instrument clone (called by ProjectFactory).
     * @param p  All initialization parameters — see InitParams struct.
     */
    function initialize(InitParams calldata p) external initializerERC721A initializer {
        if (_initialized) revert AlreadyInitialized();
        if (p.projectId == 0) revert InvalidProjectId();
        if (p.issuerAddress == address(0)) revert InvalidIssuer();
        ValidationLibrary.requireNonZeroAddress(p.owner, "CommerceNFT: zero owner");
        require(p.maxSupply > 0, "CommerceNFT: zero supply");
        // slither-disable-next-line timestamp
        require(p.maturityDate == 0 || p.maturityDate > block.timestamp, "CommerceNFT: maturity in past");

        __ERC721A_init(p.name, p.symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = p.projectId;
        issuerAddress = p.issuerAddress;
        instrumentSubtype = p.instrumentSubtype;
        faceValueUsdc6 = p.faceValueUsdc6;
        termsUri = p.termsUri;
        maxSupply = p.maxSupply;
        maturityDate = p.maturityDate;
        isRenewable = p.isRenewable;
        isTransferable = p.isTransferable;
        yieldEnabled = p.yieldEnabled;
        _baseTokenURI = p.baseURI;
        _initialized = true;

        _transferOwnership(p.owner);

        emit CommerceProjectInitialized(
            p.projectId,
            p.issuerAddress,
            p.instrumentSubtype,
            p.maxSupply,
            p.faceValueUsdc6,
            p.maturityDate,
            p.isTransferable,
            p.isRenewable,
            p.owner
        );
    }

    // ============ MINTING ============

    /**
     * @notice Mint one commerce token to `to`
     * @dev Called by ProjectSale after payment is received.
     *      Reverts if instrument has expired or supply is exhausted.
     */
    function mint(address to) external nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "CommerceNFT: zero address");
        // slither-disable-next-line timestamp
        if (maturityDate != 0 && block.timestamp >= maturityDate) revert InstrumentExpired();
        if (_totalMinted() >= maxSupply) revert MaxSupplyReached();

        tokenId = _nextTokenId();
        _mint(to, 1);
        // fulfillmentStatus defaults to Pending (enum 0) — no explicit write needed

        emit TokenMinted(projectId, tokenId, to, instrumentSubtype);
    }

    /**
     * @notice Mint multiple commerce tokens to `to`
     */
    function mintBatch(address to, uint256 quantity) external nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "CommerceNFT: zero address");
        // slither-disable-next-line timestamp
        if (maturityDate != 0 && block.timestamp >= maturityDate) revert InstrumentExpired();
        require(quantity > 0, "CommerceNFT: zero qty");
        if (_totalMinted() + quantity > maxSupply) revert MaxSupplyReached();

        uint256 firstId = _nextTokenId();
        _mint(to, quantity);

        for (uint256 i = 0; i < quantity; i++) {
            emit TokenMinted(projectId, firstId + i, to, instrumentSubtype);
        }
    }

    // ============ FULFILLMENT ============

    /**
     * @notice Record that delivery has been made for a token.
     * @dev Only issuerAddress can call. Emits event for audit trail.
     *      Off-chain redemption flow: holder presents token → issuer delivers →
     *      issuer calls markFulfilled() → on-chain record of delivery.
     */
    function markFulfilled(uint256 tokenId) external {
        if (msg.sender != issuerAddress) revert NotIssuer();
        FulfillmentStatus status = fulfillmentStatus[tokenId];
        if (status == FulfillmentStatus.Fulfilled) revert TokenAlreadyFulfilled();
        if (status == FulfillmentStatus.Cancelled) revert TokenCancelled();

        fulfillmentStatus[tokenId] = FulfillmentStatus.Fulfilled;
        emit TokenFulfilled(projectId, tokenId, msg.sender);
    }

    /**
     * @notice Mark a token as cancelled (refund handled externally or via ProjectSale).
     * @dev Only issuerAddress can cancel. Cancellation blocks fulfillment.
     */
    function markCancelled(uint256 tokenId) external {
        if (msg.sender != issuerAddress) revert NotIssuer();
        if (fulfillmentStatus[tokenId] == FulfillmentStatus.Fulfilled) revert TokenAlreadyFulfilled();

        fulfillmentStatus[tokenId] = FulfillmentStatus.Cancelled;
        emit TokenCancelledEvent(projectId, tokenId, msg.sender);
    }

    // ============ MATURITY EXTENSION ============

    /**
     * @notice Extend the maturity date (issuer only, renewable instruments only).
     * @dev Allows issuer to roll over a seasonal instrument without redeployment.
     *      New maturity must be in the future and after current maturity.
     */
    function extendMaturity(uint256 newMaturityDate) external {
        if (msg.sender != issuerAddress) revert NotIssuer();
        require(isRenewable, "CommerceNFT: not renewable");
        // slither-disable-next-line timestamp
        require(newMaturityDate > block.timestamp, "CommerceNFT: new maturity in past");
        require(maturityDate == 0 || newMaturityDate > maturityDate, "CommerceNFT: must extend, not shorten");

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

    function getInstrumentSubtype() external view returns (string memory) {
        return instrumentSubtype;
    }

    function getTermsUri() external view returns (string memory) {
        return termsUri;
    }

    function getFaceValueUsdc6() external view returns (uint256) {
        return faceValueUsdc6;
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

    // ============ TRANSFER RESTRICTION ============

    /**
     * @dev Block transfers if isTransferable == false.
     *      Minting (from == address(0)) is always allowed.
     *      Burning (to == address(0)) is always allowed.
     */
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // Allow mint and burn; restrict secondary transfers if not transferable
        if (from != address(0) && to != address(0) && !isTransferable) {
            revert TransferNotAllowed();
        }

        // Wire transfer hook (StakingManager) if set
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(transferHook.beforeNFTTransfer(startTokenId + i, from, to), "CommerceNFT: blocked by hook");
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

    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    // ============ ADMIN ============

    /**
     * @notice Update the IPFS terms URI (issuer or owner).
     * @dev Allows issuer to update terms document (e.g. correct a typo, update delivery address).
     *      Material changes to economic terms should not be made post-sale.
     */
    function setTermsUri(string calldata newUri) external {
        require(msg.sender == issuerAddress || msg.sender == owner(), "CommerceNFT: not issuer or owner");
        termsUri = newUri;
        emit TermsUriUpdated(projectId, newUri);
    }

    function setTransferHook(address hook) external onlyOwner {
        transferHook = INFTTransferHook(hook);
        emit TransferHookSet(hook);
    }

    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(minter, "CommerceNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }
}
