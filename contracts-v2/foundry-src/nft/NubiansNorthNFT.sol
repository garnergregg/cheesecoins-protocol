// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC721AUpgradeable} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {INFT} from "./interfaces/INFT.sol";
import {ISceneNFT} from "./interfaces/ISceneNFT.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";
import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title NubiansNorthNFT
 * @notice Flagship NFT collection for Nubians North dairy goat farm (Minnesota).
 *         Genesis project of the Cheesecoins ecosystem — illustrates how real agricultural
 *         production value underwrites CURD token mints. The 10-year herd growth cycle of
 *         this farm is the basis for the 200,000,000 CURD initial supply.
 *
 * @dev ERC721A for gas-efficient minting with scene-based token tracking.
 *      Deployed as a standalone contract (not through ProjectFactory) — wired into the
 *      ecosystem manually as the Genesis / Capex-class project.
 *
 * COLLECTION STRUCTURE:
 * - 100 unique scenes (emotion-capture photographs of farm life)
 * - 500 copies per scene
 * - 100 scenes × 500 copies = 50,000 total NFTs maximum
 * - Collecting one token from each of the 100 scenes confers Super Holder status
 *   and grants governance voting rights in SuperHolderGovernance
 *
 * DEPLOYMENT NOTE:
 * - Canonical deployment: ProjectRegistry project ID 2 (Arbitrum Sepolia)
 * - PROJECT_ID constant below is hardcoded to 1 (legacy error from initial deploy)
 * - DO NOT call getProjectId() — always use StakingManager.nftToProject[nftAddress]
 *   which is set correctly to project ID 2 after the post-Tuesday upgrade executes
 * - A prior deployment (project ID 1) exists at a different address and is ABANDONED
 *
 * NFT CLASS: Capex / Growth
 * - Long-term asset backing (livestock, equipment, infrastructure)
 * - Full governance and Super Holder eligibility
 * - Staking with maturity tiers (1, 2, 3, 5+ year lockups)
 *
 * FEATURES:
 * - Gas-efficient ERC721A batch minting
 * - Per-scene copy counter (mintedPerScene) enforcing 500-copy cap
 * - tokenScene public mapping for off-chain and hook lookups
 * - Pluggable transfer hook (SceneTracker + StakingManager via TransferHookRouter)
 *   fires on every token in a batch AND on mints (from == address(0))
 *
 * SECURITY:
 * - ReentrancyGuard on minting functions
 * - Authorized minters only (CsaCertificateSale must be whitelisted)
 * - Scene number validation (1-100)
 * - Per-scene supply cap (500)
 */
// slither-disable-next-line locked-ether -- ERC721AUpgradeable.transferFrom is payable as a gas optimisation; ETH is never sent to this contract so Slither's locked-ether warning is a false positive
contract NubiansNorthNFT is ERC721AUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, INFT, ISceneNFT {
    // ============ CONSTANTS ============

    /// @notice Legacy project ID constant — INCORRECT (registry uses project ID 2).
    /// @dev DO NOT use this value. Always resolve project ID via StakingManager.nftToProject[address(this)].
    ///      This constant exists only for interface compatibility and cannot be changed on the deployed contract.
    uint256 public constant PROJECT_ID = 1;

    /// @notice Total number of distinct scenes in the collection (100 unique photographs)
    uint16 public constant TOTAL_SCENES = 100;

    /// @notice Maximum copies allowed per scene
    uint256 public constant SCENE_MAX_SUPPLY = 500;

    /// @notice Hard cap on total NFT supply: 100 scenes × 500 copies = 50,000 NFTs
    uint256 public constant TOTAL_MAX_SUPPLY = uint256(TOTAL_SCENES) * SCENE_MAX_SUPPLY; // 50,000

    // ============ STATE VARIABLES ============

    /// @notice Base URI for metadata
    string private _baseTokenURI;

    /// @notice Maps token ID to scene number (1-100); public for SceneTracker lookups
    mapping(uint256 => uint16) public tokenScene;

    /// @notice How many copies of each scene have been minted so far
    mapping(uint16 => uint256) public mintedPerScene;

    /// @notice Transfer hook contract for SceneTracker / marketplace integration
    INFTTransferHook public transferHook;

    /// @notice Authorized minters (CsaCertificateSale, StakingManager, etc.)
    mapping(address => bool) public authorizedMinters;

    // ── Storage added in audit-upgrade v2 ───────────────────────────────────
    // IMPORTANT: always append new variables here — never insert above existing
    // slots or storage layout will diverge from the deployed proxy.

    /// @notice ERC2981 royalty recipient (founder EOA; set in initialize)
    address private _royaltyReceiver;

    /// @notice Contract-level metadata URI for OpenSea collection page
    string private _contractURIString;

    // ============ ERRORS ============

    error InvalidSceneNumber();
    error SceneCapReached(uint16 sceneNumber, uint256 cap);
    error InvalidQuantity();
    error UnauthorizedMinter();
    error InvalidTokenId();
    error ETHTransferFailed();
    error ZeroRoyaltyReceiver();

    // ============ EVENTS ============

    /// @notice Emitted for every scene mint batch
    event SceneMinted(address indexed to, uint16 indexed sceneNumber, uint256 quantity, uint256 firstTokenId);

    event TransferHookSet(address indexed hook);
    event MinterAuthorized(address indexed minter, bool authorized);
    event BaseURIUpdated(string newBaseURI);
    event RoyaltyReceiverUpdated(address indexed receiver);
    event ContractURIUpdated(string uri);

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the Nubians North NFT collection
     * @dev Uses initializer pattern for upgradeable contracts
     */
    function initialize() external initializerERC721A initializer {
        __ERC721A_init("Nubians North Collection", "NUBN");
        __Ownable_init();
        __ReentrancyGuard_init();

        _baseTokenURI = string(abi.encodePacked(Config.NFT_BASE_URI, "1/"));
        _royaltyReceiver = msg.sender; // founder/deployer — receives secondary-sale royalties
    }

    // ============ MINTING ============

    /**
     * @notice Mint `quantity` copies of `sceneNumber` to `to`
     * @dev Only authorized minters can call. Per-scene supply capped at SCENE_MAX_SUPPLY (500).
     *      Uses ERC721A batch mint for gas efficiency; tokenScene is populated for every token.
     * @param to Recipient address
     * @param sceneNumber Scene to mint (1-100)
     * @param quantity Number of copies to mint
     */
    // slither-disable-next-line reentrancy-no-eth -- nonReentrant; all state (tokenScene, mintedPerScene) set before _mint; hook fires inside ERC721A._mint under CEI
    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external override nonReentrant {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "NubiansNorthNFT: zero address");
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (quantity == 0) revert InvalidQuantity();
        if (mintedPerScene[sceneNumber] + quantity > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }

        // Capture the starting token ID before mint
        uint256 firstTokenId = _nextTokenId();

        // CRITICAL: populate tokenScene BEFORE _mint.
        // ERC721A fires _afterTokenTransfers (which calls the SceneTracker hook) INSIDE
        // _mint(). The hook reads ISceneNFT.tokenScene(nftId) — if we set it after _mint
        // returns the hook will see scene==0 and silently skip the update, breaking Super
        // Holder tracking. Setting scene first is safe because nonReentrant prevents anyone
        // else from minting these IDs between _nextTokenId() and _mint().
        for (uint256 i = 0; i < quantity; i++) {
            tokenScene[firstTokenId + i] = sceneNumber;
        }

        // Increment per-scene counter BEFORE _mint to close hook-based reentrancy:
        // a malicious afterNFTTransfer hook could re-enter mintScene before this
        // counter updates and slip past the SCENE_MAX_SUPPLY cap.
        // Safe: if _mint reverts, the whole tx reverts and the counter reverts too.
        mintedPerScene[sceneNumber] += quantity;

        // Batch mint via ERC721A — triggers _afterTokenTransfers (and therefore hook) here
        _mint(to, quantity);

        emit SceneMinted(to, sceneNumber, quantity, firstTokenId);
    }

    /**
     * @notice Mint a single copy of a scene (INFT backward-compatibility shim)
     * @dev Checks scene cap and delegates to internal mint logic.
     * @param to Recipient address
     * @param sceneNumber Scene number (1-100)
     * @return tokenId The minted token ID
     */
    // slither-disable-next-line reentrancy-no-eth -- nonReentrant; tokenScene and mintedPerScene set before _mint; hook fires inside ERC721A._mint under CEI
    function mint(address to, uint16 sceneNumber) external override nonReentrant returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        ValidationLibrary.requireNonZeroAddress(to, "NubiansNorthNFT: zero address");
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (mintedPerScene[sceneNumber] + 1 > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }

        tokenId = _nextTokenId();
        // Set scene BEFORE _mint so the hook (fired inside _mint) reads the correct scene.
        tokenScene[tokenId] = sceneNumber;
        // Increment per-scene counter BEFORE _mint to close hook-based reentrancy:
        // a malicious afterNFTTransfer hook could re-enter mint before this counter
        // updates and slip past the SCENE_MAX_SUPPLY cap.
        // Safe: if _mint reverts, the whole tx reverts and the counter reverts too.
        mintedPerScene[sceneNumber] += 1;
        _mint(to, 1);

        emit SceneMinted(to, sceneNumber, 1, tokenId);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get scene number for a token (INFT interface)
     * @param tokenId Token ID to query
     * @return Scene number (1-100)
     */
    function getSceneNumber(uint256 tokenId) external view override returns (uint16) {
        if (!_exists(tokenId)) revert InvalidTokenId();
        return tokenScene[tokenId];
    }

    /**
     * @notice Get project ID (INFT interface)
     * @return Project ID (1 for Nubians North)
     */
    function getProjectId() external pure override returns (uint256) {
        return PROJECT_ID;
    }

    /**
     * @notice Check how many copies of a scene remain available
     * @param sceneNumber Scene to query
     * @return remaining Copies still mintable for this scene
     */
    function sceneRemaining(uint16 sceneNumber) external view returns (uint256 remaining) {
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) return 0;
        uint256 minted = mintedPerScene[sceneNumber];
        return minted >= SCENE_MAX_SUPPLY ? 0 : SCENE_MAX_SUPPLY - minted;
    }

    /**
     * @notice Get base URI for metadata
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice Get token URI for metadata
     * @dev Returns: baseURI + sceneNumber
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert InvalidTokenId();
        return string(abi.encodePacked(_baseURI(), _toString(tokenScene[tokenId]), ".json"));
    }

    /**
     * @notice Get total supply of minted NFTs
     */
    function totalSupply() public view override returns (uint256) {
        return _totalMinted();
    }

    /**
     * @notice Get owner of a token
     */
    function ownerOf(uint256 tokenId) public view override returns (address) {
        return ERC721AUpgradeable.ownerOf(tokenId);
    }

    /**
     * @notice Transfer token from one address to another
     */
    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        ERC721AUpgradeable.transferFrom(from, to, tokenId);
    }

    // ============ TRANSFER HOOKS ============

    /**
     * @notice Before token transfer hook -- blocks transfers when hook returns false
     * @dev Only calls hook on non-mint transfers (from != address(0))
     */
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        if (address(transferHook) != address(0) && from != address(0)) {
            require(transferHook.beforeNFTTransfer(startTokenId, from, to), "NubiansNorthNFT: transfer blocked by hook");
        }
    }

    /**
     * @notice After token transfer hook -- updates scene tracking for every token in batch
     * @dev Fires for BOTH mints (from == address(0)) and normal transfers so SceneTracker
     *      can maintain accurate per-user scene ownership without isContract gating.
     *      Loops over each token in the ERC721A batch to deliver per-tokenId callbacks.
     */
    function _afterTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal override {
        super._afterTokenTransfers(from, to, startTokenId, quantity);

        if (address(transferHook) != address(0)) {
            for (uint256 i = 0; i < quantity; i++) {
                // slither-disable-next-line calls-loop -- bounded by ERC721A batch size; transferHook is a trusted protocol contract
                transferHook.afterNFTTransfer(startTokenId + i, from, to);
            }
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set transfer hook contract (must be a valid contract address)
     * @dev address(0) is rejected — disabling the hook would silently break SceneTracker
     *      and StakingManager accounting for all future transfers. Those transfer events
     *      cannot be replayed. To replace the hook, set the new contract address directly.
     * @param hook Transfer hook contract address
     */
    function setTransferHook(address hook) external onlyOwner {
        require(hook != address(0) && hook.code.length > 0, "NubiansNorthNFT: hook must be a contract");
        transferHook = INFTTransferHook(hook);
        emit TransferHookSet(hook);
    }

    /**
     * @notice Rescue ETH accidentally sent via the payable transferFrom inherited from ERC721A
     * @param to Recipient address
     */
    function sweepETH(address payable to) external onlyOwner {
        require(to != address(0), "NubiansNorthNFT: zero address");
        uint256 bal = address(this).balance;
        require(bal > 0, "NubiansNorthNFT: no ETH");
        // slither-disable-next-line low-level-calls -- owner-only rescue; success checked
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert ETHTransferFailed();
    }

    /**
     * @notice Authorize or revoke a minter address
     * @param minter Minter address
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(minter, "NubiansNorthNFT: zero address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    /**
     * @notice Update base URI for metadata
     * @param newBaseURI New base URI
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    // ============ ERC2981 ROYALTIES ============

    /**
     * @notice ERC2981 royalty info — 5% to the royalty receiver on every secondary sale.
     * @param salePrice The sale price to calculate royalty from
     * @return receiver Royalty recipient address
     * @return royaltyAmount Amount in the same currency as salePrice
     */
    function royaltyInfo(
        uint256,
        /*tokenId*/
        uint256 salePrice
    )
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = _royaltyReceiver;
        royaltyAmount = (salePrice * 500) / 10_000; // 5%
    }

    /**
     * @notice Update the royalty receiver address
     * @param receiver New royalty recipient
     */
    function setRoyaltyReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroRoyaltyReceiver();
        _royaltyReceiver = receiver;
        emit RoyaltyReceiverUpdated(receiver);
    }

    // ============ CONTRACT METADATA (OpenSea) ============

    /**
     * @notice Contract-level metadata URI for OpenSea collection page.
     *         Must point to a JSON file with: name, description, image, external_link,
     *         seller_fee_basis_points (500), fee_recipient.
     */
    function contractURI() external view returns (string memory) {
        return _contractURIString;
    }

    /**
     * @notice Set the contract-level metadata URI (owner only)
     * @param uri IPFS or HTTPS URI pointing to collection metadata JSON
     */
    function setContractURI(string calldata uri) external onlyOwner {
        _contractURIString = uri;
        emit ContractURIUpdated(uri);
    }

    // ============ INTERFACE SUPPORT ============

    /**
     * @notice Declare support for ERC2981 (royalties) in addition to ERC721A interfaces.
     * @param interfaceId Interface identifier to check
     */
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a // ERC2981
            || super.supportsInterface(interfaceId);
    }
}
