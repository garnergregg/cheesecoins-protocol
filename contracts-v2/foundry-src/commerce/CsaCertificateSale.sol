// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProjectRegistry} from "../platform/interfaces/IProjectRegistry.sol";
import {ISceneNFT} from "../nft/interfaces/ISceneNFT.sol";

/**
 * @title CsaCertificateSale
 * @notice Hardened CSA certificate sale contract with treasury-first payment routing
 * @dev Accepts CURD and USDC payments, mints project NFT certificates for specific scenes,
 *      and routes payments to treasury and/or project operator wallet based on project config.
 *
 * SCENE ECONOMICS:
 * - Buyers select which scene (1-100) they want to purchase.
 * - Allows collecting complete sets for Super Holder eligibility.
 * - Per-scene supply is enforced by the NFT contract (500 copies max per scene).
 *
 * PAYMENT ROUTING (treasury-first policy):
 * - operatorWallet == address(0): 100% to treasury
 * - payoutsEnabled == false: 100% to treasury
 * - Otherwise: protocolFeeBps% to treasury, remainder to operator wallet
 *
 * SECURITY:
 * - nonReentrant on all purchase functions
 * - Payment transfers BEFORE NFT mint
 * - SafeERC20 for all token transfers
 * - Owner-only admin functions
 * - Protocol fee capped at MAX_PROTOCOL_FEE_BPS (2000 bps = 20%)
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract CsaCertificateSale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ CONSTANTS ============

    /// @notice Basis points denominator (100% = 10_000)
    uint256 public constant BPS = 10_000;

    /// @notice Maximum protocol fee in basis points (2000 bps = 20%)
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 2_000;

    /// @notice Valid scene range (1-100); checked before NFT call for fast-fail UX
    uint16 public constant MAX_SCENE_NUMBER = 100;

    /// @notice Maximum mints allowed per wallet per scene via sale contract
    uint256 public constant MAX_MINT_PER_WALLET_PER_SCENE = 5;

    // ============ STATE VARIABLES ============

    /// @notice Protocol fee in basis points (default 10% = 1000 bps)
    uint256 public protocolFeeBps = 1_000;

    /// @notice Treasury address -- receives protocol fee and full payment when operator routing inactive
    address public immutable treasury;

    /// @notice ProjectRegistry for reading project NFT address, operatorWallet, and payoutsEnabled
    address public projectRegistry;

    /// @notice CURD token (18 decimals)
    IERC20 public immutable CURD;

    /// @notice USDC token (6 decimals)
    IERC20 public immutable USDC;

    /// @notice Price per certificate in CURD (18 decimals)
    uint256 public priceCurd;

    /// @notice Price per certificate in USDC (6 decimals)
    uint256 public priceUsdc6;

    /// @notice Tracks how many certificates each wallet has minted per scene via this sale contract
    mapping(address => mapping(uint256 => uint256)) private _mintedByWalletByScene;

    /// @notice Controls whether minting is enabled for each scene (wave/staged release gating)
    mapping(uint256 => bool) public sceneMintEnabled;

    // ============ EVENTS ============

    /// @notice Emitted when protocol fee is updated
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when CURD certificate price is updated
    event PriceCurdUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when USDC certificate price is updated
    event PriceUsdc6Updated(uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when scene mint gating is toggled
    event SceneMintEnabled(uint256 indexed sceneId, bool enabled);
    /// @notice Emitted when project registry address is updated
    event ProjectRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted on every admin mint (no payment)
    event AdminMint(address indexed to, uint256 indexed sceneNumber, uint256 quantity);

    /// @notice Emitted on every payment routing (treasury split)
    event PaymentSplit(
        uint256 indexed projectId,
        address token,
        uint256 total,
        uint256 feeToTreasury,
        uint256 payoutToProject,
        address payoutWallet
    );

    /// @notice Emitted when certificates are purchased with CURD
    event CertificatePurchasedWithCURD(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed buyer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid,
        bytes32 invoiceId
    );

    /// @notice Emitted when certificates are purchased with USDC
    event CertificatePurchasedWithUSDC(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed buyer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid,
        bytes32 invoiceId
    );

    /// @notice Emitted when certificates are admin-minted without payment
    event CertificateAdminMinted(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed to,
        uint256 quantity,
        bytes32 referenceId,
        string reason
    );

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint256 requested, uint256 max);
    error ZeroQuantity();
    error ZeroRecipient();
    error InvalidScene();
    error SceneNotLive();
    error SceneMintCapExceeded();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Deploy the CSA certificate sale contract
     * @param _owner Contract owner (governance/multisig)
     * @param _treasury Treasury address for protocol fees
     * @param _projectRegistry ProjectRegistry contract address
     * @param _curd CURD token address (18 decimals)
     * @param _usdc USDC token address (6 decimals)
     * @param _priceCurd Price per certificate in CURD (18-decimal units)
     * @param _priceUsdc6 Price per certificate in USDC (6-decimal units)
     */
    constructor(
        address _owner,
        address _treasury,
        address _projectRegistry,
        address _curd,
        address _usdc,
        uint256 _priceCurd,
        uint256 _priceUsdc6
    ) {
        if (_owner == address(0) || _treasury == address(0) || _projectRegistry == address(0)) {
            revert ZeroAddress();
        }
        if (_curd == address(0) || _usdc == address(0)) revert ZeroAddress();
        if (_priceCurd == 0 || _priceUsdc6 == 0) revert ZeroAmount();

        _transferOwnership(_owner);
        treasury = _treasury;
        projectRegistry = _projectRegistry;
        CURD = IERC20(_curd);
        USDC = IERC20(_usdc);
        priceCurd = _priceCurd;
        priceUsdc6 = _priceUsdc6;
    }

    // ============ PURCHASE FUNCTIONS ============

    /**
     * @notice Purchase CSA certificates for a specific scene using CURD tokens
     * @param projectId Project to buy certificates for
     * @param sceneNumber Scene to purchase (1-100); buyers choose scenes to build complete sets
     * @param quantity Number of copies to mint
     * @param recipient Address that will receive the minted NFTs
     * @param invoiceId Off-chain invoice reference (bytes32, emitted in event only)
     *
     * @dev Payment transfers occur BEFORE mint. Routing follows treasury-first policy.
     */
    function buyWithCURD(uint256 projectId, uint16 sceneNumber, uint256 quantity, address recipient, bytes32 invoiceId)
        external
        nonReentrant
    {
        if (quantity == 0) revert ZeroQuantity();
        if (recipient == address(0)) revert ZeroRecipient();
        if (sceneNumber < 1 || sceneNumber > MAX_SCENE_NUMBER) revert InvalidScene();
        if (!sceneMintEnabled[sceneNumber]) revert SceneNotLive();
        if (_mintedByWalletByScene[msg.sender][sceneNumber] + quantity > MAX_MINT_PER_WALLET_PER_SCENE) {
            revert SceneMintCapExceeded();
        }

        uint256 total = priceCurd * quantity;

        // Pull payment from buyer first
        CURD.safeTransferFrom(msg.sender, address(this), total);

        // Route payment to treasury and/or operator
        _splitAndRoute(projectId, CURD, total);

        // Mint NFTs after all transfers
        _mintCertificates(projectId, sceneNumber, quantity, recipient);

        // Track wallet mint count per scene (mint-based, never decremented)
        _mintedByWalletByScene[msg.sender][sceneNumber] += quantity;

        emit CertificatePurchasedWithCURD(projectId, sceneNumber, msg.sender, recipient, quantity, total, invoiceId);
    }

    /**
     * @notice Purchase CSA certificates for a specific scene using USDC tokens
     * @param projectId Project to buy certificates for
     * @param sceneNumber Scene to purchase (1-100)
     * @param quantity Number of copies to mint
     * @param recipient Address that will receive the minted NFTs
     * @param invoiceId Off-chain invoice reference (bytes32, emitted in event only)
     *
     * @dev Payment transfers occur BEFORE mint. Routing follows treasury-first policy.
     */
    function buyWithUSDC(uint256 projectId, uint16 sceneNumber, uint256 quantity, address recipient, bytes32 invoiceId)
        external
        nonReentrant
    {
        if (quantity == 0) revert ZeroQuantity();
        if (recipient == address(0)) revert ZeroRecipient();
        if (sceneNumber < 1 || sceneNumber > MAX_SCENE_NUMBER) revert InvalidScene();
        if (!sceneMintEnabled[sceneNumber]) revert SceneNotLive();
        if (_mintedByWalletByScene[msg.sender][sceneNumber] + quantity > MAX_MINT_PER_WALLET_PER_SCENE) {
            revert SceneMintCapExceeded();
        }

        uint256 total = priceUsdc6 * quantity;

        // Pull payment from buyer first
        USDC.safeTransferFrom(msg.sender, address(this), total);

        // Route payment to treasury and/or operator
        _splitAndRoute(projectId, USDC, total);

        // Mint NFTs after all transfers
        _mintCertificates(projectId, sceneNumber, quantity, recipient);

        // Track wallet mint count per scene (mint-based, never decremented)
        _mintedByWalletByScene[msg.sender][sceneNumber] += quantity;

        emit CertificatePurchasedWithUSDC(projectId, sceneNumber, msg.sender, recipient, quantity, total, invoiceId);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Mint certificates without payment (admin/grant use)
     * @param projectId Project to mint certificates for
     * @param sceneNumber Scene to mint (1-100)
     * @param quantity Number of copies to mint
     * @param to Recipient address
     * @param referenceId Off-chain reference (bytes32, emitted in event only)
     * @param reason Human-readable reason for the admin mint
     */
    function adminMint(
        uint256 projectId,
        uint16 sceneNumber,
        uint256 quantity,
        address to,
        bytes32 referenceId,
        string calldata reason
    ) external onlyOwner nonReentrant {
        if (quantity == 0) revert ZeroQuantity();
        require(to == treasury || to == owner(), "ADMIN_MINT_RESTRICTED");
        if (sceneNumber < 1 || sceneNumber > MAX_SCENE_NUMBER) revert InvalidScene();

        _mintCertificates(projectId, sceneNumber, quantity, to);

        emit CertificateAdminMinted(projectId, sceneNumber, to, quantity, referenceId, reason);
        emit AdminMint(to, sceneNumber, quantity);
    }

    /**
     * @notice Enable or disable minting for a single scene (wave/staged release gating)
     * @param sceneId Scene number to update
     * @param enabled True to enable minting, false to disable
     */
    function setSceneMintEnabled(uint256 sceneId, bool enabled) external onlyOwner {
        sceneMintEnabled[sceneId] = enabled;
        emit SceneMintEnabled(sceneId, enabled);
    }

    /**
     * @notice Enable or disable minting for multiple scenes in one transaction
     * @param sceneIds Array of scene numbers to update
     * @param enabled True to enable minting, false to disable
     */
    function setSceneMintEnabledBatch(uint256[] calldata sceneIds, bool enabled) external onlyOwner {
        for (uint256 i = 0; i < sceneIds.length; i++) {
            sceneMintEnabled[sceneIds[i]] = enabled;
            emit SceneMintEnabled(sceneIds[i], enabled);
        }
    }

    /**
     * @notice Update protocol fee in basis points
     * @param newFeeBps New fee (0..2000; default 1000 = 10%)
     */
    function setProtocolFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_PROTOCOL_FEE_BPS);
        uint256 old = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(old, newFeeBps);
    }

    /**
     * @notice Update project registry address
     * @param _projectRegistry New project registry address
     */
    function setProjectRegistry(address _projectRegistry) external onlyOwner {
        if (_projectRegistry == address(0)) revert ZeroAddress();
        emit ProjectRegistryUpdated(projectRegistry, _projectRegistry);
        projectRegistry = _projectRegistry;
    }

    /**
     * @notice Update CURD certificate price
     * @param _priceCurd New price in CURD (18-decimal units)
     */
    function setPriceCurd(uint256 _priceCurd) external onlyOwner {
        if (_priceCurd == 0) revert ZeroAmount();
        uint256 old = priceCurd;
        priceCurd = _priceCurd;
        emit PriceCurdUpdated(old, _priceCurd);
    }

    /**
     * @notice Update USDC certificate price
     * @param _priceUsdc6 New price in USDC (6-decimal units)
     */
    function setPriceUsdc6(uint256 _priceUsdc6) external onlyOwner {
        if (_priceUsdc6 == 0) revert ZeroAmount();
        uint256 old = priceUsdc6;
        priceUsdc6 = _priceUsdc6;
        emit PriceUsdc6Updated(old, _priceUsdc6);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns how many certificates a wallet has minted for a specific scene via this sale contract
     * @param wallet Wallet address to query
     * @param sceneId Scene number to query
     * @return Number of certificates minted by wallet for scene
     */
    function mintedBy(address wallet, uint256 sceneId) external view returns (uint256) {
        return _mintedByWalletByScene[wallet][sceneId];
    }

    // ============ RESCUE FUNCTIONS ============

    /**
     * @notice Rescue ERC20 tokens accidentally sent to this contract
     * @param token Token to rescue
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function sweepToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Rescue ETH accidentally sent to this contract
     * @param to Recipient address
     * @param amount Amount of ETH to transfer (wei)
     */
    function sweepETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        // slither-disable-next-line low-level-calls -- owner-only rescue; checks success; no state changes after call
        (bool success,) = to.call{value: amount}("");
        require(success, "CsaCertificateSale: ETH transfer failed");
    }

    /// @notice Accept ETH (for sweepETH rescue path)
    receive() external payable {}

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Route payment to treasury and/or project operator wallet
     * @dev Treasury-first routing policy:
     *   - If operatorWallet == address(0) OR payoutsEnabled == false: 100% to treasury
     *   - Otherwise: protocolFeeBps to treasury, remainder to operatorWallet
     * @param projectId Project ID for registry lookup
     * @param token ERC20 token to route
     * @param total Total amount to route (already held by this contract)
     */
    function _splitAndRoute(uint256 projectId, IERC20 token, uint256 total) internal {
        address operatorWallet = IProjectRegistry(projectRegistry).getOperatorWallet(projectId);
        bool payoutsEnabled = IProjectRegistry(projectRegistry).isPayoutsEnabled(projectId);

        uint256 feeToTreasury;
        uint256 payoutToProject;
        address payoutWallet;

        if (operatorWallet == address(0) || !payoutsEnabled) {
            // 100% to treasury
            feeToTreasury = total;
            payoutToProject = 0;
            payoutWallet = address(0);
            token.safeTransfer(treasury, total);
        } else {
            feeToTreasury = (total * protocolFeeBps) / BPS;
            payoutToProject = total - feeToTreasury;
            payoutWallet = operatorWallet;
            token.safeTransfer(treasury, feeToTreasury);
            token.safeTransfer(operatorWallet, payoutToProject);
        }

        emit PaymentSplit(projectId, address(token), total, feeToTreasury, payoutToProject, payoutWallet);
    }

    /**
     * @notice Mint NFT certificates for a specific scene
     * @dev Resolves the project's NFT address from the registry and calls mintScene.
     *      The NFT contract must have this sale contract as an authorized minter.
     * @param projectId Project ID
     * @param sceneNumber Scene to mint (1-100)
     * @param quantity Number of copies
     * @param recipient Recipient of minted NFTs
     */
    function _mintCertificates(uint256 projectId, uint16 sceneNumber, uint256 quantity, address recipient) internal {
        IProjectRegistry.Project memory project = IProjectRegistry(projectRegistry).getProject(projectId);
        address nftAddress = project.nftAddress;
        require(nftAddress != address(0), "CsaCertificateSale: no NFT for project");

        // Mint NFT certificates via the scene NFT interface (void return; sale contract only needs success)
        ISceneNFT(nftAddress).mintScene(recipient, sceneNumber, quantity);
    }
}
