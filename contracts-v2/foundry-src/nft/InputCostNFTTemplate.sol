// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title InputCostNFTTemplate
 * @notice Factory-deployable NFT template for Input Cost / Seasonal Credit class projects.
 *
 * NFT CLASS: Input Cost / Seasonal Credit
 * ─────────────────────────────────────────────────────────────────────────────
 * Purpose:    Short-term operating credit for seasonal farm inputs — feed,
 *             seed, fertilizer, labour, packaging. Structured as a DeFi
 *             loan (CSA credit certificate) to avoid securities classification.
 *
 *             Supporters fund a farm's seasonal input needs upfront. The farm
 *             repays with yield at season end. This is modelled as a
 *             community-supported agriculture (CSA) advance purchase, not equity.
 *
 * Governance: NONE — Input Cost NFTs carry no voting rights and do not
 *             contribute to Super Holder eligibility.
 *
 * Staking:    Yield-bearing via StakingManager. APY reflects the farm's
 *             input cost return rate for the season.
 *
 * Term:       Fixed — each token has an expiry timestamp (season end).
 *             Expired tokens can be renewed by the project owner for the
 *             next season, or redeemed when the farm repays the credit.
 *
 * Hooks:      StakingManager only. No SceneTracker (no governance path).
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * COLLECTION STRUCTURE:
 * - Not scene-based — each token represents one credit certificate for a season
 * - Configurable supply cap (e.g. 1,000 certificates per seasonal round)
 * - Configurable credit value per token (in CURD units, informational)
 * - Each token stores: projectId, season identifier, expiry timestamp
 *
 * SEASONALITY:
 * - Owner sets the current season ID and expiry at initialization or renewal
 * - renewSeason(newExpiry) extends all live certificates for another season
 * - Expired certificates can be flagged but transfers are not blocked on-chain
 *   (redemption/renewal logic lives in CsaCertificateSale and off-chain)
 *
 * SECURITY:
 * - ReentrancyGuard on minting
 * - Authorized minters only
 * - Supply cap enforced
 * - Initializer protection
 */
// slither-disable-next-line locked-ether
contract InputCostNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ============ STATE VARIABLES ============

    /// @notice Project ID assigned by ProjectRegistry
    uint256 public projectId;

    /// @notice Maximum certificates that can be minted in total
    uint256 public maxSupply;

    /// @notice Credit value each certificate represents (in CURD, 18 decimals — informational)
    uint256 public creditValuePerToken;

    /// @notice Current season identifier (e.g. "Spring 2026", "Season 3")
    string public currentSeason;

    /// @notice Unix timestamp when the current season ends (certificates expire)
    uint256 public seasonExpiry;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    /// @notice Transfer hook (StakingManager only — no governance path)
    INFTTransferHook public transferHook;

    /// @notice Whitelisted minters (CsaCertificateSale)
    mapping(address => bool) public authorizedMinters;

    /// @notice Prevents double-initialization
    bool private _nftInitialized;

    // ============ ERRORS ============

    error AlreadyInitialized();
    error InvalidProjectId();
    error MaxSupplyReached();
    error UnauthorizedMinter();
    error SeasonExpired();

    // ============ EVENTS ============

    event InputCostProjectInitialized(
        uint256 indexed projectId,
        string name,
        uint256 maxSupply,
        uint256 creditValuePerToken,
        string season,
        uint256 seasonExpiry,
        address indexed owner
    );
    event SeasonRenewed(string newSeason, uint256 newExpiry);
    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event CertificateMinted(uint256 indexed projectId, uint256 tokenId, address indexed to, string season);

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize an Input Cost project clone (called by ProjectFactory)
     * @param _projectId          ProjectRegistry ID
     * @param _name               Collection name (e.g. "Green Valley Spring Feed 2026")
     * @param _symbol             Token symbol (e.g. "GVSF26")
     * @param _maxSupply          Maximum certificates to issue this season
     * @param _creditValuePerToken CURD value each certificate represents (18 dec, informational)
     * @param _season             Human-readable season ID (e.g. "Spring 2026")
     * @param _seasonExpiry       Unix timestamp when this season ends
     * @param baseURI_            IPFS base URI for metadata
     * @param _owner              Project owner
     */
    function initialize(
        uint256 _projectId,
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _creditValuePerToken,
        string memory _season,
        uint256 _seasonExpiry,
        string memory baseURI_,
        address _owner
    ) external initializerERC721A initializer {
        if (_nftInitialized) revert AlreadyInitialized();
        if (_projectId == 0) revert InvalidProjectId();
        ValidationLibrary.requireNonZeroAddress(_owner, "InputCostNFT: zero owner");
        require(_maxSupply > 0, "InputCostNFT: zero supply");
        // slither-disable-next-line timestamp -- expiry validation; block.timestamp manipulation window is negligible for multi-day season terms
        require(_seasonExpiry > block.timestamp, "InputCostNFT: expiry in past");

        __ERC721A_init(_name, _symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = _projectId;
        maxSupply = _maxSupply;
        creditValuePerToken = _creditValuePerToken;
        currentSeason = _season;
        seasonExpiry = _seasonExpiry;
        _baseTokenURI = baseURI_;
        _nftInitialized = true;

        _transferOwnership(_owner);

        emit InputCostProjectInitialized(
            _projectId, _name, _maxSupply, _creditValuePerToken, _season, _seasonExpiry, _owner
        );
    }

    // ============ MINTING ============

    /**
     * @notice Mint a credit certificate to `to`
     * @dev Called by CsaCertificateSale after payment. Reverts if season has expired.
     */
    function mint(address to) external nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "InputCostNFT: zero address");
        // slither-disable-next-line timestamp -- season expiry check; miner manipulation window is negligible vs multi-week season terms
        if (block.timestamp >= seasonExpiry) revert SeasonExpired();
        if (_totalMinted() >= maxSupply) revert MaxSupplyReached();

        tokenId = _nextTokenId();
        _mint(to, 1);

        emit CertificateMinted(projectId, tokenId, to, currentSeason);
    }

    /**
     * @notice Mint multiple certificates at once
     */
    function mintBatch(address to, uint256 quantity) external nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "InputCostNFT: zero address");
        // slither-disable-next-line timestamp -- season expiry check; miner manipulation window is negligible vs multi-week season terms
        if (block.timestamp >= seasonExpiry) revert SeasonExpired();
        require(quantity > 0, "InputCostNFT: zero qty");
        if (_totalMinted() + quantity > maxSupply) revert MaxSupplyReached();

        uint256 firstId = _nextTokenId();
        _mint(to, quantity);

        for (uint256 i = 0; i < quantity; i++) {
            emit CertificateMinted(projectId, firstId + i, to, currentSeason);
        }
    }

    // ============ SEASON RENEWAL ============

    /**
     * @notice Renew the season — extend all certificates for another term
     * @dev Only owner (project operator). Does not mint new tokens; just updates
     *      the season label and expiry. Holders retain their certificates.
     * @param newSeason  Human-readable label for the new season
     * @param newExpiry  New expiry timestamp (must be in the future)
     */
    function renewSeason(string calldata newSeason, uint256 newExpiry) external onlyOwner {
        // slither-disable-next-line timestamp -- renewal expiry validation; multi-day window makes miner manipulation negligible
        require(newExpiry > block.timestamp, "InputCostNFT: expiry in past");
        currentSeason = newSeason;
        seasonExpiry = newExpiry;
        emit SeasonRenewed(newSeason, newExpiry);
    }

    // ============ VIEW FUNCTIONS ============

    function getProjectId() external view returns (uint256) {
        return projectId;
    }

    function isSeasonActive() external view returns (bool) {
        return block.timestamp < seasonExpiry;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalMinted();
    }

    function remainingSupply() external view returns (uint256) {
        return maxSupply - _totalMinted();
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return ERC721AUpgradeable.ownerOf(tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    // ============ TRANSFER HOOKS (StakingManager only) ============

    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(transferHook.beforeNFTTransfer(startTokenId + i, from, to), "InputCostNFT: blocked by hook");
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

    function setTransferHook(address hook) external onlyOwner {
        transferHook = INFTTransferHook(hook);
        emit TransferHookSet(hook);
    }

    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(minter, "InputCostNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }
}
