// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import {ISceneNFT} from "../nft/interfaces/ISceneNFT.sol";
import {ICommerceNFT} from "../nft/interfaces/ICommerceNFT.sol";
import {ILandNFT} from "../nft/interfaces/ILandNFT.sol";

/**
 * @title ProjectSale
 * @notice Unified upgradeable sale contract for all Cheesecoins protocol NFT instruments.
 *
 * @dev WHAT IT DOES
 * ─────────────────
 * ProjectSale is the single payment and minting gateway for every NFT project
 * on the Cheesecoins protocol — Nubians North, partner capital raises, commerce
 * instruments, land sub-NFTs, and any future instrument types.
 *
 * HOW IT WORKS
 * ─────────────
 * 1. Protocol admin registers a SaleConfig for each NFT project.
 *    Sale starts paused — admin calls activateSale() to make it live.
 *
 * 2. For fixed-price sales: buyer calls buy(projectId, quantity).
 *    Payment collected, protocol fee routed to treasury, remainder to issuer,
 *    NFT(s) minted to buyer.
 *
 * 3. For voucher-based (promotional) sales: buyer calls buyWithVoucher(voucher, sig).
 *    Backend wallet signs a SaleVoucher encoding discounted price, expiry, nonce.
 *    Same payment routing, replay-protected via one-time nonces.
 *
 * NFT TYPES SUPPORTED
 * ────────────────────
 * - ISceneNFT: CapexNFTTemplate, NubiansNorthNFT — scene-based collections
 * - ICommerceNFT: CommerceNFTTemplate — forward-commitment instruments
 * Both implement a mint function; ProjectSale detects which interface to call
 * via the nftType field in SaleConfig.
 *
 * PROTOCOL FEE
 * ─────────────
 * - Commerce instruments: 5% to treasury (500 BPS)
 * - Capital / Land instruments: 2.5% to treasury (250 BPS)
 * - Fee set per SaleConfig by admin — cannot exceed MAX_PROTOCOL_FEE_BPS (1000 = 10%)
 * - CURD token transfers themselves carry no fee — fee only applies to NFT minting
 *
 * PAYMENT ROUTING
 * ────────────────
 * totalPayment = pricePerToken × quantity
 * protocolFee  = totalPayment × protocolFeeBps / 10000
 * issuerAmount = totalPayment - protocolFee
 *   → protocolFee  → treasury
 *   → issuerAmount → issuer (partner address in SaleConfig)
 * If issuer == treasury (e.g. Nubians North): 100% goes to treasury.
 *
 * SECURITY
 * ─────────
 * - Upgradeable (Transparent Proxy) — protocol can fix bugs without redeployment
 * - ReentrancyGuard on all purchase functions
 * - SafeERC20 for all token transfers
 * - EIP-712 typed-data signatures for vouchers (not raw hashes)
 * - One-time nonces prevent voucher replay
 * - Voucher bound to buyer address — cannot be used by another wallet
 * - Per-wallet purchase cap per project
 * - Sale start/end timestamps enforced
 * - Payment BEFORE mint (CEI order)
 * - Owner-only admin functions
 * - Max protocol fee cap (10%) prevents admin abuse
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract ProjectSale is OwnableUpgradeable, ReentrancyGuardUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============ CONSTANTS ============

    uint256 public constant BPS = 10_000;

    /// @notice Maximum protocol fee — 10%. Protects partners from admin abuse.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000;

    /// @notice EIP-712 typehash for SaleVoucher (voucher-based purchases)
    bytes32 public constant SALE_VOUCHER_TYPEHASH = keccak256(
        "SaleVoucher(uint256 projectId,uint16 sceneNumber,uint256 quantity,address buyer,uint256 discountedPriceUsdc6,bytes32 promotionId,uint256 expiry,bytes32 nonce)"
    );

    // ============ ENUMS ============

    /// @notice Which mint interface the NFT contract implements
    enum NftType {
        SceneNFT, // ISceneNFT — CapexNFTTemplate, NubiansNorthNFT (scene-based)
        CommerceNFT, // ICommerceNFT — CommerceNFTTemplate (certificate-based)
        LandNFT // ILandNFT — LandNFTTemplate (fractional land rights, testnet only)
    }

    // ============ STRUCTS ============

    /**
     * @notice Configuration for one NFT project's sale.
     * @dev Stored per projectId. Admin registers, then activates.
     */
    struct SaleConfig {
        address nftContract; // The NFT contract to mint from
        address issuer; // Receives proceeds after protocol fee (use treasury for genesis projects)
        address paymentToken; // USDC or CURD address
        NftType nftType; // SceneNFT or CommerceNFT
        uint256 pricePerToken; // Price per token in paymentToken units (0 = voucher-only)
        uint256 protocolFeeBps; // Protocol fee in BPS (500 = 5%, 250 = 2.5%)
        uint256 maxPerWallet; // Max tokens per wallet (0 = unlimited)
        uint256 saleStart; // Unix timestamp (0 = immediately)
        uint256 saleEnd; // Unix timestamp (0 = no end)
        bool active; // Admin must flip to true to open sale
    }

    /**
     * @notice A signed authorization for one discounted NFT purchase.
     * @dev Signed by voucherSigner. Used for promotional / partner-code purchases.
     */
    struct SaleVoucher {
        uint256 projectId;
        uint16 sceneNumber; // Scene to mint (SceneNFT only; ignored for CommerceNFT)
        uint256 quantity;
        address buyer; // Must match msg.sender
        uint256 discountedPriceUsdc6; // Discounted price per token (paymentToken units)
        bytes32 promotionId; // Off-chain promotion label
        uint256 expiry; // Voucher expires after this timestamp
        bytes32 nonce; // One-time use
    }

    // ============ STATE ============

    /// @notice Protocol treasury — receives protocol fee on every sale
    address public treasury;

    /// @notice Backend wallet that signs SaleVouchers for promotional purchases
    address public voucherSigner;

    /// @notice Sale configurations per projectId
    mapping(uint256 => SaleConfig) public saleConfigs;

    /// @notice Whether a projectId has been registered (distinguishes zero-value from unregistered)
    mapping(uint256 => bool) public saleRegistered;

    /// @notice Tokens purchased per wallet per projectId (for maxPerWallet cap)
    mapping(uint256 => mapping(address => uint256)) private _purchasedByWallet;

    /// @notice Used voucher nonces (replay protection)
    mapping(bytes32 => bool) public usedNonces;

    // ============ EVENTS ============

    event SaleRegistered(uint256 indexed projectId, address indexed nftContract, address indexed issuer);
    event SaleActivated(uint256 indexed projectId);
    event SalePaused(uint256 indexed projectId);
    event SaleConfigUpdated(uint256 indexed projectId);
    event TokensPurchased(
        uint256 indexed projectId, address indexed buyer, uint256 quantity, uint256 totalPayment, address paymentToken
    );
    event VoucherPurchase(
        uint256 indexed projectId,
        address indexed buyer,
        bytes32 indexed promotionId,
        uint256 quantity,
        uint256 totalPayment,
        bytes32 nonce
    );
    event PaymentRouted(
        uint256 indexed projectId,
        uint256 totalPayment,
        uint256 protocolFee,
        uint256 issuerAmount,
        address issuer,
        address treasury
    );
    event VoucherSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ ERRORS ============

    error SaleNotRegistered(uint256 projectId);
    error SaleNotActive(uint256 projectId);
    error SaleNotStarted(uint256 projectId);
    error SaleEnded(uint256 projectId);
    error ZeroQuantity();
    error ZeroPrice();
    error WalletCapExceeded(uint256 projectId, address buyer, uint256 cap);
    error VoucherExpired();
    error VoucherAlreadyUsed();
    error InvalidVoucherSignature();
    error UnauthorizedBuyer();
    error VoucherSignerNotSet();
    error ProtocolFeeTooHigh(uint256 requested, uint256 max);
    error ZeroAddress();
    error AlreadyRegistered(uint256 projectId);

    // ============ INITIALIZER ============

    /**
     * @notice Initialize the ProjectSale contract (called once via proxy).
     * @param initialOwner    Contract owner (Gnosis Safe / timelock)
     * @param _treasury       Protocol treasury address
     * @param _voucherSigner  Backend wallet that signs promotional vouchers
     */
    function initialize(address initialOwner, address _treasury, address _voucherSigner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        // voucherSigner intentionally allows address(0) — can be set later via setVoucherSigner.
        // buyWithVoucher reverts with VoucherSignerNotSet when signer is zero.

        __Ownable_init();
        __ReentrancyGuard_init();
        __EIP712_init("ProjectSale", "1");

        _transferOwnership(initialOwner);
        treasury = _treasury;
        // slither-disable-next-line missing-zero-check
        voucherSigner = _voucherSigner;
    }

    // ============ SALE REGISTRATION (admin) ============

    /**
     * @notice Register a new NFT project sale. Sale starts paused.
     * @dev Admin calls this after partner is approved and NFT project is deployed.
     *      Partner self-registers via web UI; admin reviews and calls this on-chain.
     */
    function registerSale(uint256 projectId, SaleConfig calldata config) external onlyOwner {
        if (saleRegistered[projectId]) revert AlreadyRegistered(projectId);
        if (config.nftContract == address(0)) revert ZeroAddress();
        if (config.issuer == address(0)) revert ZeroAddress();
        if (config.paymentToken == address(0)) revert ZeroAddress();
        if (config.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeTooHigh(config.protocolFeeBps, MAX_PROTOCOL_FEE_BPS);
        }

        // Store config with active = false regardless of what was passed
        SaleConfig memory cfg = config;
        cfg.active = false;
        saleConfigs[projectId] = cfg;
        saleRegistered[projectId] = true;

        emit SaleRegistered(projectId, config.nftContract, config.issuer);
    }

    /**
     * @notice Activate a registered sale, making it open to buyers.
     */
    function activateSale(uint256 projectId) external onlyOwner {
        if (!saleRegistered[projectId]) revert SaleNotRegistered(projectId);
        saleConfigs[projectId].active = true;
        emit SaleActivated(projectId);
    }

    /**
     * @notice Pause an active sale (emergency or scheduled close).
     */
    function pauseSale(uint256 projectId) external onlyOwner {
        if (!saleRegistered[projectId]) revert SaleNotRegistered(projectId);
        saleConfigs[projectId].active = false;
        emit SalePaused(projectId);
    }

    /**
     * @notice Update sale configuration (price, dates, cap, fee).
     * @dev Cannot change nftContract or issuer after registration — those are fixed.
     */
    function updateSaleConfig(uint256 projectId, SaleConfig calldata config) external onlyOwner {
        if (!saleRegistered[projectId]) revert SaleNotRegistered(projectId);
        if (config.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeTooHigh(config.protocolFeeBps, MAX_PROTOCOL_FEE_BPS);
        }

        // Preserve the immutable fields
        SaleConfig storage existing = saleConfigs[projectId];
        address nftContract = existing.nftContract;
        address issuer = existing.issuer;

        saleConfigs[projectId] = config;
        saleConfigs[projectId].nftContract = nftContract;
        saleConfigs[projectId].issuer = issuer;

        emit SaleConfigUpdated(projectId);
    }

    // ============ PURCHASE — FIXED PRICE ============

    /**
     * @notice Purchase NFT(s) at the fixed price for a project.
     *
     * @param projectId   The project to buy from
     * @param quantity    Number of tokens to purchase
     * @param sceneNumber Scene to mint (SceneNFT only; pass 0 for CommerceNFT)
     */
    function buy(uint256 projectId, uint256 quantity, uint16 sceneNumber) external nonReentrant {
        SaleConfig storage cfg = _validateSale(projectId, quantity);
        if (cfg.pricePerToken == 0) revert ZeroPrice();

        uint256 totalPayment = cfg.pricePerToken * quantity;

        _enforceWalletCap(projectId, cfg, quantity);
        _purchasedByWallet[projectId][msg.sender] += quantity; // CEI: effect before interactions
        _collectAndRoute(projectId, cfg, totalPayment);
        _mintTokens(cfg, msg.sender, quantity, sceneNumber);

        emit TokensPurchased(projectId, msg.sender, quantity, totalPayment, cfg.paymentToken);
    }

    // ============ PURCHASE — VOUCHER (PROMOTIONAL) ============

    /**
     * @notice Purchase NFT(s) using a signed promotional voucher at a discounted price.
     *
     * @dev Flow:
     *   1. Validate voucher: not expired, nonce unused, buyer matches msg.sender
     *   2. Verify EIP-712 signature from voucherSigner
     *   3. Mark nonce as used
     *   4. Collect payment at discounted price
     *   5. Route payment (protocol fee + issuer share)
     *   6. Mint NFT(s)
     *
     * @param voucher   The signed promotion voucher
     * @param signature EIP-712 signature from voucherSigner
     */
    function buyWithVoucher(SaleVoucher calldata voucher, bytes calldata signature) external nonReentrant {
        if (voucherSigner == address(0)) revert VoucherSignerNotSet();

        SaleConfig storage cfg = _validateSale(voucher.projectId, voucher.quantity);

        // ── Voucher validation ──────────────────────────────────────────────
        // slither-disable-next-line timestamp
        if (block.timestamp > voucher.expiry) revert VoucherExpired();
        if (voucher.buyer != msg.sender) revert UnauthorizedBuyer();
        if (usedNonces[voucher.nonce]) revert VoucherAlreadyUsed();

        // ── EIP-712 signature verification ───────────────────────────────────
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SALE_VOUCHER_TYPEHASH,
                    voucher.projectId,
                    voucher.sceneNumber,
                    voucher.quantity,
                    voucher.buyer,
                    voucher.discountedPriceUsdc6,
                    voucher.promotionId,
                    voucher.expiry,
                    voucher.nonce
                )
            )
        );
        (address recovered, ECDSA.RecoverError recoverError) = digest.tryRecover(signature);
        if (recoverError != ECDSA.RecoverError.NoError || recovered != voucherSigner) {
            revert InvalidVoucherSignature();
        }

        // ── Mark nonce spent BEFORE payment (replay protection) ──────────────
        usedNonces[voucher.nonce] = true;

        uint256 totalPayment = voucher.discountedPriceUsdc6 * voucher.quantity;

        _enforceWalletCap(voucher.projectId, cfg, voucher.quantity);
        _purchasedByWallet[voucher.projectId][msg.sender] += voucher.quantity; // CEI: effect before interactions
        if (totalPayment > 0) {
            _collectAndRoute(voucher.projectId, cfg, totalPayment);
        }
        _mintTokens(cfg, msg.sender, voucher.quantity, voucher.sceneNumber);

        emit VoucherPurchase(
            voucher.projectId, msg.sender, voucher.promotionId, voucher.quantity, totalPayment, voucher.nonce
        );
    }

    // ============ VIEW FUNCTIONS ============

    function getSaleConfig(uint256 projectId) external view returns (SaleConfig memory) {
        return saleConfigs[projectId];
    }

    function purchasedBy(uint256 projectId, address wallet) external view returns (uint256) {
        return _purchasedByWallet[projectId][wallet];
    }

    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return usedNonces[nonce];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============ INTERNAL HELPERS ============

    /**
     * @dev Validate sale is registered, active, within time window, and quantity > 0.
     *      Returns the SaleConfig storage pointer.
     */
    function _validateSale(uint256 projectId, uint256 quantity) internal view returns (SaleConfig storage cfg) {
        if (!saleRegistered[projectId]) revert SaleNotRegistered(projectId);
        cfg = saleConfigs[projectId];
        if (!cfg.active) revert SaleNotActive(projectId);
        if (quantity == 0) revert ZeroQuantity();
        // slither-disable-next-line timestamp
        if (cfg.saleStart > 0 && block.timestamp < cfg.saleStart) revert SaleNotStarted(projectId);
        // slither-disable-next-line timestamp
        if (cfg.saleEnd > 0 && block.timestamp > cfg.saleEnd) revert SaleEnded(projectId);
    }

    /**
     * @dev Enforce per-wallet purchase cap if set.
     */
    function _enforceWalletCap(uint256 projectId, SaleConfig storage cfg, uint256 quantity) internal view {
        if (cfg.maxPerWallet > 0) {
            if (_purchasedByWallet[projectId][msg.sender] + quantity > cfg.maxPerWallet) {
                revert WalletCapExceeded(projectId, msg.sender, cfg.maxPerWallet);
            }
        }
    }

    /**
     * @dev Collect payment from buyer, then route:
     *      protocolFee → treasury
     *      remainder   → issuer (or treasury if issuer == treasury)
     */
    function _collectAndRoute(uint256 projectId, SaleConfig storage cfg, uint256 totalPayment) internal {
        IERC20 token = IERC20(cfg.paymentToken);

        // Collect from buyer
        token.safeTransferFrom(msg.sender, address(this), totalPayment);

        // Calculate split
        uint256 protocolFee = (totalPayment * cfg.protocolFeeBps) / BPS;
        uint256 issuerAmount = totalPayment - protocolFee;

        // Route
        if (protocolFee > 0) {
            token.safeTransfer(treasury, protocolFee);
        }
        if (issuerAmount > 0) {
            token.safeTransfer(cfg.issuer, issuerAmount);
        }

        emit PaymentRouted(projectId, totalPayment, protocolFee, issuerAmount, cfg.issuer, treasury);
    }

    /**
     * @dev Mint token(s) to recipient based on NFT type.
     *      SceneNFT: calls mintScene(recipient, sceneNumber, quantity)
     *      CommerceNFT: calls mintBatch(recipient, quantity) — not scene-based
     */
    function _mintTokens(SaleConfig storage cfg, address recipient, uint256 quantity, uint16 sceneNumber) internal {
        if (cfg.nftType == NftType.SceneNFT) {
            ISceneNFT(cfg.nftContract).mintScene(recipient, sceneNumber, quantity);
        } else if (cfg.nftType == NftType.CommerceNFT) {
            ICommerceNFT(cfg.nftContract).mintBatch(recipient, quantity);
        } else {
            // NftType.LandNFT — same mintBatch signature as ICommerceNFT
            ILandNFT(cfg.nftContract).mintBatch(recipient, quantity);
        }
    }

    // ============ ADMIN ============

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setVoucherSigner(address _signer) external onlyOwner {
        // address(0) is valid — disables voucher purchases (buyWithVoucher reverts with VoucherSignerNotSet)
        emit VoucherSignerUpdated(voucherSigner, _signer);
        // slither-disable-next-line missing-zero-check
        voucherSigner = _signer;
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev This contract should hold no tokens between transactions.
     *      All payments are routed in the same tx they arrive.
     */
    function sweepToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }
}
