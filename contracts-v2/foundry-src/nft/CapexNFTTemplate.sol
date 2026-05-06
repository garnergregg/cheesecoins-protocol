// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFT} from "./interfaces/INFT.sol";
import {ISceneNFT} from "./interfaces/ISceneNFT.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title CapexNFTTemplate
 * @notice Factory-deployable NFT template for Capex / Growth class agricultural projects.
 *
 * NFT CLASS: Capex / Growth
 * ─────────────────────────────────────────────────────────────────────────────
 * Purpose:    Long-term asset financing — livestock, buildings, equipment,
 *             infrastructure. Illustrates how real farm capital underwrites
 *             CURD token mints over a multi-year growth cycle.
 *
 * Governance: FULL — holders are eligible for Super Holder status and
 *             governance voting in SuperHolderGovernance once they own one
 *             token from every scene in the collection.
 *
 * Staking:    Full maturity-tier staking (1, 2, 3, 5+ year lockups).
 *
 * Term:       No expiry. Tokens represent long-term ownership stakes in the
 *             farm's productive capital.
 *
 * Hooks:      SceneTracker (Super Holder eligibility) + StakingManager (yield).
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * COLLECTION STRUCTURE:
 * - Configurable scene count and copies per scene (set at initialization)
 * - Default model: 100 scenes × 500 copies = 50,000 NFTs max
 * - Collecting one token from each scene confers Super Holder status
 *
 * DEPLOYMENT:
 * - Deployed once as implementation contract
 * - ProjectFactory creates EIP-1167 minimal proxy clones for each project
 * - Factory wires: SceneTracker + StakingManager hooks atomically
 * - NubiansNorthNFT is the Genesis Capex project (standalone, pre-factory)
 *
 * SECURITY:
 * - ReentrancyGuard on minting
 * - Authorized minters only (CsaCertificateSale must be whitelisted)
 * - Scene number and supply cap validation
 * - Initializer protection (one-time init per clone)
 */
// slither-disable-next-line locked-ether
contract CapexNFTTemplate is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, INFT, ISceneNFT {
    // ============ STATE VARIABLES ============

    /// @notice Project ID assigned by ProjectRegistry
    uint256 public projectId;

    /// @notice Total number of distinct scenes (set at init, immutable after)
    uint16 public TOTAL_SCENES;

    /// @notice Maximum copies per scene (set at init, immutable after)
    uint256 public SCENE_MAX_SUPPLY;

    /// @notice Total hard cap: TOTAL_SCENES × SCENE_MAX_SUPPLY
    uint256 public TOTAL_MAX_SUPPLY;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    /// @notice Maps token ID → scene number (1..TOTAL_SCENES)
    mapping(uint256 => uint16) public tokenScene;

    /// @notice Copies minted per scene so far
    mapping(uint16 => uint256) public mintedPerScene;

    /// @notice Transfer hook router (SceneTracker + StakingManager)
    INFTTransferHook public transferHook;

    /// @notice Whitelisted minters (CsaCertificateSale)
    mapping(address => bool) public authorizedMinters;

    /// @notice Prevents double-initialization
    bool private _nftInitialized;

    // ============ ERRORS ============

    error AlreadyInitialized();
    error InvalidProjectId();
    error InvalidSceneConfig();
    error InvalidSceneNumber();
    error SceneCapReached(uint16 scene, uint256 cap);
    error UnauthorizedMinter();

    // ============ EVENTS ============

    event CapexProjectInitialized(
        uint256 indexed projectId, string name, uint16 totalScenes, uint256 copiesPerScene, address indexed owner
    );
    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event SceneMinted(uint256 indexed projectId, uint16 sceneNumber, uint256 quantity, address indexed to);

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize a Capex project NFT clone (called by ProjectFactory)
     * @param _projectId   ProjectRegistry ID for this project
     * @param _name        Collection name (e.g. "Sunrise Dairy")
     * @param _symbol      Token symbol (e.g. "SUNR")
     * @param _totalScenes Number of unique scenes (e.g. 100)
     * @param _copiesPerScene Max copies per scene (e.g. 500)
     * @param baseURI_     IPFS base URI for metadata
     * @param _owner       Project owner (set to timelock/governance by factory)
     */
    function initialize(
        uint256 _projectId,
        string memory _name,
        string memory _symbol,
        uint16 _totalScenes,
        uint256 _copiesPerScene,
        string memory baseURI_,
        address _owner
    ) external initializerERC721A initializer {
        if (_nftInitialized) revert AlreadyInitialized();
        if (_projectId == 0) revert InvalidProjectId();
        if (_totalScenes == 0 || _copiesPerScene == 0) revert InvalidSceneConfig();
        ValidationLibrary.requireNonZeroAddress(_owner, "CapexNFT: zero owner");

        __ERC721A_init(_name, _symbol);
        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = _projectId;
        TOTAL_SCENES = _totalScenes;
        SCENE_MAX_SUPPLY = _copiesPerScene;
        TOTAL_MAX_SUPPLY = uint256(_totalScenes) * _copiesPerScene;
        _baseTokenURI = baseURI_;
        _nftInitialized = true;

        _transferOwnership(_owner);

        emit CapexProjectInitialized(_projectId, _name, _totalScenes, _copiesPerScene, _owner);
    }

    // ============ MINTING (ISceneNFT) ============

    /**
     * @notice Mint `quantity` copies of `sceneNumber` to `to`
     * @dev Called by CsaCertificateSale after payment is received.
     *      Sets scene mapping BEFORE _mint so hooks read correct data.
     */
    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external override nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "CapexNFT: zero address");
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (mintedPerScene[sceneNumber] + quantity > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }

        uint256 firstTokenId = _nextTokenId();

        // Set scene mapping and increment counter BEFORE _mint (CEI order)
        for (uint256 i = 0; i < quantity; i++) {
            tokenScene[firstTokenId + i] = sceneNumber;
        }
        mintedPerScene[sceneNumber] += quantity;

        _mint(to, quantity);

        emit SceneMinted(projectId, sceneNumber, quantity, to);
    }

    /// @notice Single-copy mint (INFT compatibility)
    function mint(address to, uint16 sceneNumber) external override nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "CapexNFT: zero address");
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (mintedPerScene[sceneNumber] + 1 > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }

        tokenId = _nextTokenId();
        tokenScene[tokenId] = sceneNumber;
        mintedPerScene[sceneNumber] += 1;

        _mint(to, 1);
    }

    // ============ VIEW FUNCTIONS ============

    function getProjectId() external view override returns (uint256) {
        return projectId;
    }

    function getSceneNumber(uint256 tokenId) external view override returns (uint16) {
        return tokenScene[tokenId];
    }

    function totalSupply() public view override returns (uint256) {
        return _totalMinted();
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return ERC721AUpgradeable.ownerOf(tokenId);
    }

    function remainingForScene(uint16 sceneNumber) external view returns (uint256) {
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) return 0;
        return SCENE_MAX_SUPPLY - mintedPerScene[sceneNumber];
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(_baseTokenURI, _toString(tokenScene[tokenId])));
    }

    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    // ============ TRANSFER HOOKS ============

    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);
        if (address(transferHook) != address(0) && from != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop
                require(transferHook.beforeNFTTransfer(startTokenId + i, from, to), "CapexNFT: blocked by hook");
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
        ValidationLibrary.requireNonZeroAddress(minter, "CapexNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }
}
