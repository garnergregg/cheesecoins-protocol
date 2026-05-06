// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title InnovationNFTTemplate
 * @notice Factory-deployable NFT template for Innovation / Special Project class.
 *
 * NFT CLASS: Innovation / Special Projects
 * ─────────────────────────────────────────────────────────────────────────────
 * Purpose:    Fixed-term credit certificates for discrete agricultural R&D,
 *             pilot programs, infrastructure experiments, or any project that
 *             doesn't fit the long-term Capex model or the recurring-seasonal
 *             Input Cost model.
 *
 *             Examples: A new aquaponics trial, solar installation pilot,
 *             mobile processing unit test run, precision irrigation study.
 *
 *             Structured as a CSA advance-purchase / community credit note to
 *             avoid securities classification. Supporters fund the initiative
 *             upfront; the farm repays value at term end (produce, services,
 *             or CURD) as specified off-chain in the project prospectus.
 *
 * Governance: NONE — Innovation NFTs carry no voting rights and do not
 *             contribute to Super Holder eligibility.
 *
 * Staking:    Yield-bearing via StakingManager (optional — set by owner).
 *             APY reflects the project's expected return profile.
 *
 * Term:       Fixed and NON-RENEWABLE. Each token has a hard maturity date
 *             set at initialization. Unlike Input Cost, there is no renewSeason().
 *             At maturity the farm settles the credit (product delivery,
 *             CURD buyback, or other agreed mechanism). Expired tokens are
 *             non-transferable if the lock flag is set by the owner.
 *
 * Hooks:      StakingManager only. No SceneTracker (no governance path).
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * COLLECTION STRUCTURE:
 * - Not scene-based — each token represents one credit certificate
 * - Fixed supply cap set at initialization (e.g. 250 certificates)
 * - Fixed credit value per token (in CURD units, informational)
 * - Each token stores: projectId, maturity timestamp
 *
 * TERM MECHANICS:
 * - Maturity timestamp is set once at init and cannot be changed
 * - After maturity: minting is blocked; optional transfer lock available
 * - isMatured() and timeToMaturity() view helpers for front-end
 *
 * SECURITY:
 * - ReentrancyGuard on minting
 * - Authorized minters only
 * - Supply cap enforced
 * - Minting blocked after maturity
 * - Initializer protection
 */
// slither-disable-next-line locked-ether
contract InnovationNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ============ STATE VARIABLES ============

    /// @notice Project ID assigned by ProjectRegistry
    uint256 public projectId;

    /// @notice Maximum certificates that can be minted
    uint256 public maxSupply;

    /// @notice Credit value each certificate represents (in CURD, 18 decimals — informational)
    uint256 public creditValuePerToken;

    /// @notice Unix timestamp when this project's term ends (hard maturity — non-renewable)
    uint256 public maturityDate;

    /// @notice Human-readable label for what this project funds (e.g. "Solar Pilot Q3 2026")
    string public projectLabel;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    /// @notice Transfer hook (StakingManager only — no governance path)
    INFTTransferHook public transferHook;

    /// @notice Whitelisted minters (CsaCertificateSale)
    mapping(address => bool) public authorizedMinters;

    /// @notice When true, transfers are blocked after maturity (owner-configurable)
    bool public lockTransfersOnMaturity;

    /// @notice Prevents double-initialization
    bool private _nftInitialized;

    // ============ ERRORS ============

    error AlreadyInitialized();
    error InvalidProjectId();
    error MaxSupplyReached();
    error UnauthorizedMinter();
    error ProjectMatured();
    error TransferLockedAtMaturity();

    // ============ EVENTS ============

    event InnovationProjectInitialized(
        uint256 indexed projectId,
        string name,
        uint256 maxSupply,
        uint256 creditValuePerToken,
        string projectLabel,
        uint256 maturityDate,
        address indexed owner
    );
    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event TransferLockSet(bool locked);
    event CertificateMinted(uint256 indexed projectId, uint256 tokenId, address indexed to);

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize an Innovation project clone (called by ProjectFactory)
     * @param _projectId          ProjectRegistry ID
     * @param _name               Collection name (e.g. "Nubians North Solar Pilot 2026")
     * @param _symbol             Token symbol (e.g. "NNSP26")
     * @param _maxSupply          Maximum certificates to issue (fixed, non-renewable)
     * @param _creditValuePerToken CURD value each certificate represents (18 dec, informational)
     * @param _projectLabel       Human-readable description of what this project funds
     * @param _maturityDate       Unix timestamp when the project term ends (hard, non-renewable)
     * @param baseURI_            IPFS base URI for metadata
     * @param _owner              Project owner
     */
    function initialize(
        uint256 _projectId,
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _creditValuePerToken,
        string memory _projectLabel,
        uint256 _maturityDate,
        string memory baseURI_,
        address _owner
    ) external initializerERC721A initializer {
        if (_nftInitialized) revert AlreadyInitialized();
        if (_projectId == 0) revert InvalidProjectId();
        ValidationLibrary.requireNonZeroAddress(_owner, "InnovationNFT: zero owner");
        require(_maxSupply > 0, "InnovationNFT: zero supply");
        // slither-disable-next-line timestamp -- maturity validation; block.timestamp manipulation window is negligible for multi-month project terms
        require(_maturityDate > block.timestamp, "InnovationNFT: maturity in past");

        __ERC721A_init(_name, _symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = _projectId;
        maxSupply = _maxSupply;
        creditValuePerToken = _creditValuePerToken;
        projectLabel = _projectLabel;
        maturityDate = _maturityDate;
        _baseTokenURI = baseURI_;
        _nftInitialized = true;

        _transferOwnership(_owner);

        emit InnovationProjectInitialized(
            _projectId, _name, _maxSupply, _creditValuePerToken, _projectLabel, _maturityDate, _owner
        );
    }

    // ============ MINTING ============

    /**
     * @notice Mint a credit certificate to `to`
     * @dev Called by CsaCertificateSale after payment. Reverts if project has matured.
     */
    function mint(address to) external nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "InnovationNFT: zero address");
        // slither-disable-next-line timestamp -- maturity check; miner manipulation window is negligible vs multi-month project terms
        if (block.timestamp >= maturityDate) revert ProjectMatured();
        if (_totalMinted() >= maxSupply) revert MaxSupplyReached();

        tokenId = _nextTokenId();
        _mint(to, 1);

        emit CertificateMinted(projectId, tokenId, to);
    }

    /**
     * @notice Mint multiple certificates at once
     */
    function mintBatch(address to, uint256 quantity) external nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "InnovationNFT: zero address");
        // slither-disable-next-line timestamp -- maturity check; miner manipulation window is negligible vs multi-month project terms
        if (block.timestamp >= maturityDate) revert ProjectMatured();
        require(quantity > 0, "InnovationNFT: zero qty");
        if (_totalMinted() + quantity > maxSupply) revert MaxSupplyReached();

        uint256 firstId = _nextTokenId();
        _mint(to, quantity);

        for (uint256 i = 0; i < quantity; i++) {
            emit CertificateMinted(projectId, firstId + i, to);
        }
    }

    // ============ VIEW FUNCTIONS ============

    function getProjectId() external view returns (uint256) {
        return projectId;
    }

    function isMatured() external view returns (bool) {
        return block.timestamp >= maturityDate;
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

    /// @notice Seconds until maturity (0 if already matured)
    function timeToMaturity() external view returns (uint256) {
        if (block.timestamp >= maturityDate) return 0;
        return maturityDate - block.timestamp;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ============ TRANSFER (maturity lock) ============

    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        // slither-disable-next-line timestamp -- maturity transfer lock; miner manipulation window is negligible vs multi-month terms
        if (lockTransfersOnMaturity && block.timestamp >= maturityDate) {
            revert TransferLockedAtMaturity();
        }
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    // ============ TRANSFER HOOKS (StakingManager only) ============

    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(transferHook.beforeNFTTransfer(startTokenId + i, from, to), "InnovationNFT: blocked by hook");
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
        ValidationLibrary.requireNonZeroAddress(minter, "InnovationNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }

    /**
     * @notice Toggle whether transfers are blocked after maturity.
     * @dev Use this to freeze certificates once the project has matured,
     *      preventing secondary-market trading of expired credits.
     */
    function setLockTransfersOnMaturity(bool locked) external onlyOwner {
        lockTransfersOnMaturity = locked;
        emit TransferLockSet(locked);
    }
}
