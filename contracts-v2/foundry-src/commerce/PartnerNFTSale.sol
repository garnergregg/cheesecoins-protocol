// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProjectRegistry} from "../platform/interfaces/IProjectRegistry.sol";
import {ISceneNFT} from "../nft/interfaces/ISceneNFT.sol";

/**
 * @title PartnerNFTSale
 * @notice Promotional NFT sale contract for the Cheesecoins partner program.
 *
 * @dev HOW IT WORKS
 * ─────────────────
 * 1. A backend wallet (promotionSigner) generates a signed PromotionVoucher
 *    for each approved promotional code redemption. The voucher encodes the
 *    discounted price, expiry, and a one-time nonce so it cannot be replayed.
 *
 * 2. The customer calls promotionalMintWithUSDC(voucher, signature) on-chain,
 *    paying the discounted USDC price encoded in the voucher.
 *
 * 3. The contract verifies the EIP-712 signature, enforces expiry and replay
 *    protection, collects payment, routes proceeds, and mints the NFT — all
 *    in one transaction. No manual Greg involvement.
 *
 * PROMOTION FLEXIBILITY
 * ─────────────────────
 * Promotional terms (discount %, eligibility, expiry) live entirely off-chain
 * in the backend. The contract only verifies that the voucher was signed by
 * the authorized signer. This means new promotions can be launched or changed
 * without any contract deployment.
 *
 * PAYMENT ROUTING
 * ───────────────
 * - If liquidityPool == address(0): 100% to treasury
 * - Otherwise: liquidityShareBps% to liquidityPool, remainder to treasury
 *
 * The liquidity pool receives its share to seed the partner redemption pool
 * (the fund that backs CURD payouts to partners). This makes every
 * promotional NFT sale self-funding for the partner ecosystem.
 *
 * SECURITY
 * ────────
 * - EIP-712 typed-data signatures (not raw message hashes)
 * - One-time nonces prevent voucher replay
 * - Voucher is bound to buyer address — cannot be transferred
 * - Per-wallet promo mint cap prevents a single address from abusing discounts
 * - nonReentrant on all purchase functions
 * - Payment BEFORE mint
 * - SafeERC20 for all token transfers
 * - Owner-only admin functions
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract PartnerNFTSale is Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============ CONSTANTS ============

    /// @notice Basis points denominator
    uint256 public constant BPS = 10_000;

    /// @notice Valid scene range (1-100)
    uint16 public constant MAX_SCENE_NUMBER = 100;

    /// @notice Maximum promotional mints per wallet per scene
    /// @dev Lower than CsaCertificateSale (5) — promos are one-per-customer by design
    uint256 public constant MAX_PROMO_MINTS_PER_WALLET_PER_SCENE = 2;

    /// @notice EIP-712 typehash for PromotionVoucher
    bytes32 public constant PROMOTION_VOUCHER_TYPEHASH = keccak256(
        "PromotionVoucher(uint256 projectId,uint16 sceneNumber,uint256 quantity,address buyer,uint256 discountedPriceUsdc6,bytes32 promotionId,uint256 expiry,bytes32 nonce)"
    );

    // ============ STATE ============

    /// @notice Treasury address — receives its share of all promotional sale proceeds
    address public immutable treasury;

    /// @notice USDC token (6 decimals) — only payment token for promotional mints
    IERC20 public immutable USDC;

    /// @notice ProjectRegistry for resolving project NFT address
    address public projectRegistry;

    /// @notice Backend wallet address that signs PromotionVouchers
    /// @dev Changing this instantly invalidates all previously-issued vouchers
    address public promotionSigner;

    /// @notice Optional liquidity pool address that receives liquidityShareBps of proceeds
    /// @dev address(0) means 100% goes to treasury
    address public liquidityPool;

    /// @notice Basis points of proceeds routed to liquidityPool (0..5000)
    uint256 public liquidityShareBps;

    /// @notice Maximum liquidity share — capped at 50% to protect treasury
    uint256 public constant MAX_LIQUIDITY_SHARE_BPS = 5_000;

    /// @notice Tracks used voucher nonces to prevent replay
    mapping(bytes32 => bool) public usedNonces;

    /// @notice Tracks promotional mints per wallet per scene
    mapping(address => mapping(uint256 => uint256)) private _promoMintedByWalletByScene;

    // ============ EVENTS ============

    /// @notice Emitted on every successful promotional mint
    event PromotionalMintCompleted(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed buyer,
        bytes32 indexed promotionId,
        uint256 quantity,
        uint256 totalPaidUsdc6,
        bytes32 nonce
    );

    /// @notice Emitted when payment is routed
    event PromotionalPaymentRouted(
        uint256 indexed projectId, uint256 totalUsdc6, uint256 toLiquidity, uint256 toTreasury, address liquidityPool
    );

    /// @notice Emitted when promotion signer is updated
    event PromotionSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted when liquidity pool address is updated
    event LiquidityPoolUpdated(address indexed oldPool, address indexed newPool);

    /// @notice Emitted when liquidity share is updated
    event LiquidityShareUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when project registry is updated
    event ProjectRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidScene();
    error InvalidVoucherSignature();
    error VoucherExpired();
    error VoucherAlreadyUsed();
    error UnauthorizedBuyer();
    error ZeroQuantity();
    error PromoMintCapExceeded();
    error LiquidityShareTooHigh(uint256 requested, uint256 max);
    error SignerNotSet();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Deploy PartnerNFTSale
     * @param _owner Contract owner (Gnosis Safe / governance)
     * @param _treasury Treasury address
     * @param _projectRegistry ProjectRegistry contract address
     * @param _usdc USDC token address (6 decimals)
     * @param _promotionSigner Backend wallet that signs vouchers
     */
    constructor(address _owner, address _treasury, address _projectRegistry, address _usdc, address _promotionSigner)
        EIP712("PartnerNFTSale", "1")
    {
        if (_owner == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_projectRegistry == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_promotionSigner == address(0)) revert ZeroAddress();

        _transferOwnership(_owner);
        treasury = _treasury;
        projectRegistry = _projectRegistry;
        USDC = IERC20(_usdc);
        promotionSigner = _promotionSigner;
    }

    // ============ STRUCTS ============

    /**
     * @notice A signed authorization for one promotional NFT purchase
     * @param projectId        Project to mint from
     * @param sceneNumber      Scene to mint (1-100)
     * @param quantity         Number of copies (normally 1)
     * @param buyer            Address that must call this function — cannot be transferred
     * @param discountedPriceUsdc6  Price per NFT in USDC (6 decimals), e.g. 40_000_000 for $40
     * @param promotionId      Off-chain promotion label, e.g. keccak256("PARTNER_LAUNCH_2026_04")
     * @param expiry           Unix timestamp after which this voucher is invalid
     * @param nonce            Random unique value — marks this voucher as one-time use
     */
    struct PromotionVoucher {
        uint256 projectId;
        uint16 sceneNumber;
        uint256 quantity;
        address buyer;
        uint256 discountedPriceUsdc6;
        bytes32 promotionId;
        uint256 expiry;
        bytes32 nonce;
    }

    // ============ CORE FUNCTION ============

    /**
     * @notice Purchase NFT(s) using a signed promotional voucher at a discounted USDC price.
     *
     * @dev Flow:
     *   1. Validate voucher: not expired, nonce not used, buyer matches msg.sender
     *   2. Verify EIP-712 signature from promotionSigner
     *   3. Mark nonce as used (replay protection)
     *   4. Collect USDC payment from buyer
     *   5. Route payment to liquidity pool and/or treasury
     *   6. Mint NFT(s) to buyer
     *   7. Emit events
     *
     * @param voucher   The signed promotion voucher
     * @param signature EIP-712 signature from promotionSigner
     */
    function promotionalMintWithUSDC(PromotionVoucher calldata voucher, bytes calldata signature)
        external
        nonReentrant
    {
        if (promotionSigner == address(0)) revert SignerNotSet();

        // ── 1. Basic validation ──────────────────────────────────────────────
        if (voucher.quantity == 0) revert ZeroQuantity();
        if (voucher.sceneNumber < 1 || voucher.sceneNumber > MAX_SCENE_NUMBER) revert InvalidScene();
        if (block.timestamp > voucher.expiry) revert VoucherExpired();
        if (voucher.buyer != msg.sender) revert UnauthorizedBuyer();

        // ── 2. Replay protection ─────────────────────────────────────────────
        if (usedNonces[voucher.nonce]) revert VoucherAlreadyUsed();

        // ── 3. Per-wallet promo cap ──────────────────────────────────────────
        if (
            _promoMintedByWalletByScene[msg.sender][voucher.sceneNumber] + voucher.quantity
                > MAX_PROMO_MINTS_PER_WALLET_PER_SCENE
        ) revert PromoMintCapExceeded();

        // ── 4. Verify EIP-712 signature ──────────────────────────────────────
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PROMOTION_VOUCHER_TYPEHASH,
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
        if (recoverError != ECDSA.RecoverError.NoError || recovered != promotionSigner) {
            revert InvalidVoucherSignature();
        }

        // ── 5. Mark nonce + per-wallet promo cap (CEI: writes before external calls) ─
        usedNonces[voucher.nonce] = true;
        _promoMintedByWalletByScene[msg.sender][voucher.sceneNumber] += voucher.quantity;

        // ── 6. Collect USDC payment ──────────────────────────────────────────
        uint256 totalPayment = voucher.discountedPriceUsdc6 * voucher.quantity;
        if (totalPayment > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), totalPayment);
            _routePayment(voucher.projectId, totalPayment);
        }

        // ── 7. Mint NFT(s) ───────────────────────────────────────────────────
        _mintCertificates(voucher.projectId, voucher.sceneNumber, voucher.quantity, msg.sender);

        emit PromotionalMintCompleted(
            voucher.projectId,
            voucher.sceneNumber,
            msg.sender,
            voucher.promotionId,
            voucher.quantity,
            totalPayment,
            voucher.nonce
        );
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update the backend wallet that signs vouchers.
     * @dev Changing this immediately invalidates ALL outstanding unsigned vouchers.
     *      Rotate with care — coordinate with the backend before changing.
     */
    function setPromotionSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert ZeroAddress();
        emit PromotionSignerUpdated(promotionSigner, _signer);
        promotionSigner = _signer;
    }

    /**
     * @notice Set the liquidity pool address that receives a share of promotional proceeds.
     * @param _pool  address(0) disables liquidity routing (100% to treasury)
     */
    function setLiquidityPool(address _pool) external onlyOwner {
        emit LiquidityPoolUpdated(liquidityPool, _pool);
        liquidityPool = _pool;
    }

    /**
     * @notice Set the percentage of proceeds routed to the liquidity pool.
     * @param _bps Basis points (0-5000). 5000 = 50% max.
     */
    function setLiquidityShareBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_LIQUIDITY_SHARE_BPS) revert LiquidityShareTooHigh(_bps, MAX_LIQUIDITY_SHARE_BPS);
        emit LiquidityShareUpdated(liquidityShareBps, _bps);
        liquidityShareBps = _bps;
    }

    /**
     * @notice Update project registry address.
     */
    function setProjectRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        emit ProjectRegistryUpdated(projectRegistry, _registry);
        projectRegistry = _registry;
    }

    /**
     * @notice Rescue ERC20 tokens accidentally sent to this contract.
     */
    function sweepToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check how many promotional mints a wallet has used for a given scene.
     */
    function promoMintedBy(address wallet, uint256 sceneId) external view returns (uint256) {
        return _promoMintedByWalletByScene[wallet][sceneId];
    }

    /**
     * @notice Check whether a voucher nonce has been used.
     */
    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return usedNonces[nonce];
    }

    /**
     * @notice Returns the EIP-712 domain separator for this contract.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Route promotional sale proceeds to liquidity pool and/or treasury.
     * @dev If liquidityPool is set and liquidityShareBps > 0, split accordingly.
     *      Otherwise, 100% goes to treasury.
     */
    function _routePayment(uint256 projectId, uint256 total) internal {
        uint256 toLiquidity = 0;
        uint256 toTreasury = total;

        if (liquidityPool != address(0) && liquidityShareBps > 0) {
            toLiquidity = (total * liquidityShareBps) / BPS;
            toTreasury = total - toLiquidity;
            if (toLiquidity > 0) {
                USDC.safeTransfer(liquidityPool, toLiquidity);
            }
        }

        if (toTreasury > 0) {
            USDC.safeTransfer(treasury, toTreasury);
        }

        emit PromotionalPaymentRouted(projectId, total, toLiquidity, toTreasury, liquidityPool);
    }

    /**
     * @notice Resolve NFT address from registry and call mintScene.
     */
    function _mintCertificates(uint256 projectId, uint16 sceneNumber, uint256 quantity, address recipient) internal {
        IProjectRegistry.Project memory project = IProjectRegistry(projectRegistry).getProject(projectId);
        address nftAddress = project.nftAddress;
        require(nftAddress != address(0), "PartnerNFTSale: no NFT for project");
        ISceneNFT(nftAddress).mintScene(recipient, sceneNumber, quantity);
    }
}
