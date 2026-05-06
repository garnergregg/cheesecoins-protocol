// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFT} from "./interfaces/INFT.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {IDomainAlphaEvents} from "../domain-alpha/interfaces/IDomainAlphaEvents.sol";
import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title ProjectNFTTemplate
 * @notice Generic cloneable NFT template for agricultural projects (10K+ projects)
 * @dev Minimal proxy (clone) pattern via ProjectFactory for gas efficiency
 *
 * ARCHITECTURE:
 * - Deployed once as implementation contract
 * - ProjectFactory creates minimal proxies (clones) for each new project
 * - Each clone is initialized with project-specific parameters
 * - Supports 10K+ projects with minimal gas cost per deployment
 *
 * FEATURES:
 * - 100 unique scenes per project collection
 * - Gas-efficient ERC721A implementation
 * - Community staker eligibility tracking
 * - Marketplace transfer hooks for staking integration
 * - Configurable project ID and metadata
 * - Domain Alpha event emission
 *
 * USAGE:
 * 1. Deploy implementation once
 * 2. ProjectFactory.createProject() clones this template
 * 3. Newly cloned contract calls initialize(projectId, projectName, owner)
 * 4. Each project has independent NFT collection
 *
 * SECURITY:
 * - ReentrancyGuard on critical functions
 * - Ownable per-project owner
 * - Scene validation (1-100)
 * - Initializer protection (can only init once)
 */
// slither-disable-next-line locked-ether -- ERC721AUpgradeable.transferFrom is payable as a gas optimisation; ETH is never sent to this contract so Slither's locked-ether warning is a false positive
contract ProjectNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, INFT {
    // ============ STATE VARIABLES ============

    /// @notice Project ID (unique per clone)
    uint256 public projectId;

    /// @notice Base URI for metadata (includes project ID)
    string private _baseTokenURI;

    /// @notice Mapping from token ID to scene number (1-100)
    mapping(uint256 => uint16) private _tokenToScene;

    /// @notice Mapping from scene number to whether it's been minted
    mapping(uint16 => bool) private _sceneMinted;

    /// @notice Transfer hook contract for marketplace integration
    INFTTransferHook public transferHook;

    /// @notice Authorized minter (StakingManager or Core)
    mapping(address => bool) public authorizedMinters;

    /// @notice Initialization status (prevent double-init)
    /// @dev Renamed from _initialized to avoid shadowing Initializable._initialized from OZ upgradeable.
    bool private _nftInitialized;

    // ============ ERRORS ============

    error InvalidSceneNumber();
    error SceneAlreadyMinted();
    error UnauthorizedMinter();
    error InvalidTokenId();
    error MaxSupplyReached();
    error AlreadyInitialized();
    error InvalidProjectId();

    // ============ EVENTS ============

    event ProjectInitialized(uint256 indexed projectId, string name, address indexed owner);
    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event BaseURIUpdated(string newBaseURI);
    event NFTMinted(
        uint256 indexed projectId, uint256 indexed tokenId, uint16 sceneNumber, address indexed to, uint256 timestamp
    );

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize project NFT collection (called by ProjectFactory)
     * @dev Can only be called once per clone
     * @param _projectId Unique project ID
     * @param _name Project name for collection
     * @param _symbol Token symbol (e.g., "PROJ001")
     * @param _owner Project owner address
     */
    function initialize(uint256 _projectId, string memory _name, string memory _symbol, address _owner)
        external
        initializerERC721A
        initializer
    {
        if (_nftInitialized) revert AlreadyInitialized();
        if (_projectId == 0) revert InvalidProjectId();
        ValidationLibrary.requireNonZeroAddress(_owner, "ProjectNFT: zero owner");

        __ERC721A_init(_name, _symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = _projectId;
        _nftInitialized = true;

        // Transfer ownership to project owner
        _transferOwnership(_owner);

        // Set base URI: Config.NFT_BASE_URI + projectId + "/"
        _baseTokenURI = string(abi.encodePacked(Config.NFT_BASE_URI, _toString(_projectId), "/"));

        emit ProjectInitialized(_projectId, _name, _owner);
    }

    // ============ MINTING ============

    /**
     * @notice Mint NFT representing a specific scene
     * @dev Only authorized minters (StakingManager, Core) can call
     * @param to Recipient address
     * @param sceneNumber Scene number (1-100)
     * @return tokenId Newly minted token ID
     */
    // slither-disable-next-line reentrancy-no-eth
    // The transfer hook router is owned by the protocol timelock; only whitelisted hooks are allowed.
    // State (scene mapping, sceneMinted) is set before _mint in CEI order.
    function mint(address to, uint16 sceneNumber) external override nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "ProjectNFT: zero address");

        // Validate scene number (1-100)
        if (sceneNumber == 0 || sceneNumber > Config.NFT_UNIQUE_SCENES) {
            revert InvalidSceneNumber();
        }

        // Check if scene already minted
        if (_sceneMinted[sceneNumber]) {
            revert SceneAlreadyMinted();
        }

        // Check max supply
        if (_totalMinted() >= Config.NFT_UNIQUE_SCENES) {
            revert MaxSupplyReached();
        }

        // Mint using ERC721A (next sequential token ID)
        tokenId = _nextTokenId();

        // CRITICAL: set scene mapping BEFORE _mint so that transfer hooks fired
        // inside _mint (afterNFTTransfer) can read the correct scene.
        _tokenToScene[tokenId] = sceneNumber;
        _sceneMinted[sceneNumber] = true;

        _mint(to, 1);

        // Emit Domain Alpha event for social bot
        emit NFTMinted(projectId, tokenId, sceneNumber, to, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get scene number for a token
     * @param tokenId Token ID to query
     * @return Scene number (1-100)
     */
    function getSceneNumber(uint256 tokenId) external view override returns (uint16) {
        if (!_exists(tokenId)) revert InvalidTokenId();
        return _tokenToScene[tokenId];
    }

    /**
     * @notice Canonical hook-facing scene query (Phase 6C)
     * @dev Returns the scene as uint256 so TransferHookRouter and SceneTracker can use it
     *      without casting. Reverts on nonexistent token.
     * @param tokenId Token ID to query
     * @return Scene number (1-100) widened to uint256
     */
    function tokenScene(uint256 tokenId) external view returns (uint256) {
        if (!_exists(tokenId)) revert InvalidTokenId();
        return uint256(_tokenToScene[tokenId]);
    }

    /**
     * @notice Get project ID
     * @return Project ID for this collection
     */
    function getProjectId() external view override returns (uint256) {
        return projectId;
    }

    /**
     * @notice Check if a scene has been minted
     * @param sceneNumber Scene number (1-100)
     * @return True if scene is minted
     */
    function isSceneMinted(uint16 sceneNumber) external view returns (bool) {
        return _sceneMinted[sceneNumber];
    }

    /**
     * @notice Get base URI for metadata
     * @return Base URI string
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice Get token URI for metadata
     * @dev Returns: baseURI + projectId + "/" + sceneNumber
     * @param tokenId Token ID
     * @return Token URI string
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert InvalidTokenId();

        string memory baseURI = _baseURI();
        uint16 sceneNumber = _tokenToScene[tokenId];

        return string(abi.encodePacked(baseURI, _toString(sceneNumber)));
    }

    /**
     * @notice Get total supply of minted NFTs
     * @return Total number of minted tokens
     */
    function totalSupply() public view override returns (uint256) {
        return _totalMinted();
    }

    /**
     * @notice Get owner of a token
     * @param tokenId Token ID to query
     * @return Owner address
     */
    function ownerOf(uint256 tokenId) public view override returns (address) {
        return ERC721AUpgradeable.ownerOf(tokenId);
    }

    /**
     * @notice Transfer token from one address to another
     * @param from Current owner
     * @param to Recipient
     * @param tokenId Token ID to transfer
     */
    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    /**
     * @notice Check if contract is initialized
     * @return True if initialized
     */
    function isInitialized() external view returns (bool) {
        return _nftInitialized;
    }

    // ============ TRANSFER HOOKS ============

    /**
     * @notice Before token transfer hook
     * @dev Integrates with marketplace for staking management.
     *      Loops over every token in the batch for correctness; mints are not gated.
     */
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // Call transfer hook if set (marketplace integration); skip on mint
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(
                    transferHook.beforeNFTTransfer(startTokenId + i, from, to), "ProjectNFT: transfer blocked by hook"
                );
            }
        }
    }

    /**
     * @notice After token transfer hook
     * @dev Notifies marketplace/staking of completed transfer.
     *      Fires on BOTH mints (from == address(0)) and normal transfers.
     *      Loops over every token in the ERC721A batch to deliver per-tokenId callbacks.
     */
    function _afterTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._afterTokenTransfers(from, to, startTokenId, quantity);

        // Call transfer hook if set — fires on mint AND transfer (no from != address(0) gate)
        if (address(transferHook) != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                transferHook.afterNFTTransfer(startTokenId + i, from, to);
            }
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set transfer hook contract
     * @dev Only project owner can set hook
     * @param hook Transfer hook contract address
     */
    function setTransferHook(address hook) external onlyOwner {
        transferHook = INFTTransferHook(hook);
        emit TransferHookSet(hook);
    }

    /**
     * @notice Authorize or revoke minter
     * @dev Only project owner can manage minters
     * @param minter Minter address
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(minter, "ProjectNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    /**
     * @notice Update base URI for metadata
     * @dev Only project owner can update
     * @param newBaseURI New base URI
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }
}
