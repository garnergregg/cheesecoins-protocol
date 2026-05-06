// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ProjectSale} from "../../foundry-src/commerce/ProjectSale.sol";
import {CommerceNFTTemplate} from "../../foundry-src/nft/CommerceNFTTemplate.sol";
import {ISceneNFT} from "../../foundry-src/nft/interfaces/ISceneNFT.sol";
import {ICommerceNFT} from "../../foundry-src/nft/interfaces/ICommerceNFT.sol";
import {ILandNFT} from "../../foundry-src/nft/interfaces/ILandNFT.sol";

// ============ MOCKS ============

contract MockERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock SceneNFT — records mint calls for assertion
contract MockSceneNFT {
    mapping(address => uint256) public mintedTo;
    mapping(uint16 => uint256) public mintedPerScene;
    uint256 public totalMinted;

    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external {
        mintedTo[to] += quantity;
        mintedPerScene[sceneNumber] += quantity;
        totalMinted += quantity;
    }

    // ISceneNFT view stubs (unused in sale tests)
    function tokenScene(uint256) external pure returns (uint16) {
        return 0;
    }

    function TOTAL_SCENES() external pure returns (uint16) {
        return 100;
    }

    function SCENE_MAX_SUPPLY() external pure returns (uint256) {
        return 500;
    }
}

/// @dev Minimal mock LandNFT — records mint calls (same signature as CommerceNFT)
contract MockLandNFT {
    mapping(address => uint256) public mintedTo;
    uint256 public totalMinted;

    function mint(address to) external returns (uint256 tokenId) {
        mintedTo[to]++;
        tokenId = totalMinted++;
    }

    function mintBatch(address to, uint256 quantity) external {
        mintedTo[to] += quantity;
        totalMinted += quantity;
    }
}

/// @dev Minimal mock CommerceNFT — records mint calls
contract MockCommerceNFT {
    mapping(address => uint256) public mintedTo;
    uint256 public totalMinted;

    function mint(address to) external returns (uint256 tokenId) {
        mintedTo[to]++;
        tokenId = totalMinted++;
    }

    function mintBatch(address to, uint256 quantity) external {
        mintedTo[to] += quantity;
        totalMinted += quantity;
    }

    // Unused stubs to satisfy ICommerceNFT checks (not called in sale tests)
    function markFulfilled(uint256) external {}
    function markCancelled(uint256) external {}
    function extendMaturity(uint256) external {}

    function getProjectId() external pure returns (uint256) {
        return 1;
    }

    function getIssuer() external pure returns (address) {
        return address(0);
    }

    function getInstrumentSubtype() external pure returns (string memory) {
        return "";
    }

    function getTermsUri() external pure returns (string memory) {
        return "";
    }

    function getFaceValueUsdc6() external pure returns (uint256) {
        return 0;
    }

    function isActive() external pure returns (bool) {
        return true;
    }

    function hasExpired() external pure returns (bool) {
        return false;
    }

    function remainingSupply() external pure returns (uint256) {
        return 9999;
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function maxSupply() external pure returns (uint256) {
        return 9999;
    }

    function isTransferable() external pure returns (bool) {
        return true;
    }

    function maturityDate() external pure returns (uint256) {
        return 0;
    }

    function issuerAddress() external pure returns (address) {
        return address(0);
    }

    function instrumentSubtype() external pure returns (string memory) {
        return "";
    }

    function faceValueUsdc6() external pure returns (uint256) {
        return 0;
    }
}

// ============ TEST CONTRACT ============

contract ProjectSaleTest is Test {
    ProjectSale public sale;
    ProxyAdmin public proxyAdmin;
    MockERC20 public usdc;
    MockSceneNFT public sceneNft;
    MockCommerceNFT public commerceNft;
    MockLandNFT public landNft;

    address admin = address(0x1001);
    address treasury = address(0x1002);
    address issuer = address(0x1003);
    address buyer = address(0x1004);
    address buyer2 = address(0x1005);

    uint256 voucherSignerPk = 0xDEAD;
    address voucherSigner;

    uint256 constant PRICE = 80_000_000; // $80 USDC (6 dec)
    uint256 constant PROJECT_SCENE = 1;
    uint256 constant PROJECT_COMMERCE = 2;
    uint256 constant PROJECT_LAND = 3;
    uint256 constant COMMERCE_FEE_BPS = 500; // 5%
    uint256 constant CAPITAL_FEE_BPS = 250; // 2.5%

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        voucherSigner = vm.addr(voucherSignerPk);

        // Deploy USDC mock (6 decimals)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock NFTs
        sceneNft = new MockSceneNFT();
        commerceNft = new MockCommerceNFT();
        landNft = new MockLandNFT();

        // Deploy ProjectSale proxy
        ProjectSale impl = new ProjectSale();
        proxyAdmin = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(ProjectSale.initialize.selector, admin, treasury, voucherSigner);
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        sale = ProjectSale(address(proxy));

        // Fund buyer with USDC
        usdc.mint(buyer, 10_000 * 1e6);
        usdc.mint(buyer2, 10_000 * 1e6);

        // Register a SceneNFT sale (project 1)
        vm.prank(admin);
        sale.registerSale(
            PROJECT_SCENE,
            ProjectSale.SaleConfig({
                nftContract: address(sceneNft),
                issuer: issuer,
                paymentToken: address(usdc),
                nftType: ProjectSale.NftType.SceneNFT,
                pricePerToken: PRICE,
                protocolFeeBps: CAPITAL_FEE_BPS,
                maxPerWallet: 5,
                saleStart: 0,
                saleEnd: 0,
                active: false // always overridden to false at registration
            })
        );

        // Register a CommerceNFT sale (project 2)
        vm.prank(admin);
        sale.registerSale(
            PROJECT_COMMERCE,
            ProjectSale.SaleConfig({
                nftContract: address(commerceNft),
                issuer: issuer,
                paymentToken: address(usdc),
                nftType: ProjectSale.NftType.CommerceNFT,
                pricePerToken: PRICE,
                protocolFeeBps: COMMERCE_FEE_BPS,
                maxPerWallet: 0, // unlimited
                saleStart: 0,
                saleEnd: 0,
                active: false
            })
        );

        // Register a LandNFT sale (project 3)
        vm.prank(admin);
        sale.registerSale(
            PROJECT_LAND,
            ProjectSale.SaleConfig({
                nftContract: address(landNft),
                issuer: issuer,
                paymentToken: address(usdc),
                nftType: ProjectSale.NftType.LandNFT,
                pricePerToken: PRICE,
                protocolFeeBps: CAPITAL_FEE_BPS, // 2.5% for land
                maxPerWallet: 0,
                saleStart: 0,
                saleEnd: 0,
                active: false
            })
        );
    }

    // ─── Initialization ───────────────────────────────────────────────────────

    function test_initialize_setsFields() public view {
        assertEq(sale.treasury(), treasury);
        assertEq(sale.voucherSigner(), voucherSigner);
        assertEq(sale.owner(), admin);
    }

    function test_initialize_revertsZeroOwner() public {
        ProjectSale impl = new ProjectSale();
        bytes memory data = abi.encodeWithSelector(ProjectSale.initialize.selector, address(0), treasury, address(0));
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), data);
    }

    function test_initialize_revertsZeroTreasury() public {
        ProjectSale impl = new ProjectSale();
        bytes memory data = abi.encodeWithSelector(ProjectSale.initialize.selector, admin, address(0), address(0));
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), data);
    }

    // ─── Sale registration ────────────────────────────────────────────────────

    function test_registerSale_registersAndStartsPaused() public view {
        assertTrue(sale.saleRegistered(PROJECT_SCENE));
        ProjectSale.SaleConfig memory cfg = sale.getSaleConfig(PROJECT_SCENE);
        assertFalse(cfg.active); // always starts paused
        assertEq(cfg.nftContract, address(sceneNft));
        assertEq(cfg.issuer, issuer);
        assertEq(cfg.pricePerToken, PRICE);
        assertEq(cfg.protocolFeeBps, CAPITAL_FEE_BPS);
    }

    function test_registerSale_revertsIfDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.AlreadyRegistered.selector, PROJECT_SCENE));
        sale.registerSale(PROJECT_SCENE, _sceneConfig());
    }

    function test_registerSale_revertsFeeTooHigh() public {
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.protocolFeeBps = 1_001; // > 10%
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.ProtocolFeeTooHigh.selector, 1_001, 1_000));
        sale.registerSale(99, cfg);
    }

    function test_registerSale_revertsZeroNftContract() public {
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.nftContract = address(0);
        vm.prank(admin);
        vm.expectRevert(ProjectSale.ZeroAddress.selector);
        sale.registerSale(99, cfg);
    }

    function test_registerSale_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.registerSale(99, _sceneConfig());
    }

    // ─── Activate / Pause ────────────────────────────────────────────────────

    function test_activateSale_opensForBuying() public {
        vm.prank(admin);
        sale.activateSale(PROJECT_SCENE);
        assertTrue(sale.getSaleConfig(PROJECT_SCENE).active);
    }

    function test_pauseSale_closesSale() public {
        vm.prank(admin);
        sale.activateSale(PROJECT_SCENE);
        vm.prank(admin);
        sale.pauseSale(PROJECT_SCENE);
        assertFalse(sale.getSaleConfig(PROJECT_SCENE).active);
    }

    function test_activateSale_revertsIfNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.SaleNotRegistered.selector, 999));
        sale.activateSale(999);
    }

    // ─── updateSaleConfig ────────────────────────────────────────────────────

    function test_updateSaleConfig_updatesPrice() public {
        _activateAll();
        ProjectSale.SaleConfig memory cfg = sale.getSaleConfig(PROJECT_SCENE);
        cfg.pricePerToken = 100_000_000; // $100
        vm.prank(admin);
        sale.updateSaleConfig(PROJECT_SCENE, cfg);
        assertEq(sale.getSaleConfig(PROJECT_SCENE).pricePerToken, 100_000_000);
    }

    function test_updateSaleConfig_preservesNftContractAndIssuer() public {
        ProjectSale.SaleConfig memory cfg = sale.getSaleConfig(PROJECT_SCENE);
        address originalNft = cfg.nftContract;
        address originalIssuer = cfg.issuer;
        cfg.nftContract = address(0x9999);
        cfg.issuer = address(0x8888);
        vm.prank(admin);
        sale.updateSaleConfig(PROJECT_SCENE, cfg);
        assertEq(sale.getSaleConfig(PROJECT_SCENE).nftContract, originalNft);
        assertEq(sale.getSaleConfig(PROJECT_SCENE).issuer, originalIssuer);
    }

    // ─── buy() — LandNFT ──────────────────────────────────────────────────────

    function test_buy_landNft_succeeds() public {
        _activateAll();

        uint256 issuerBefore = usdc.balanceOf(issuer);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE * 4);
        vm.prank(buyer);
        sale.buy(PROJECT_LAND, 4, 0); // sceneNumber ignored for land

        // LandNFT mintBatch called
        assertEq(landNft.mintedTo(buyer), 4);

        // 2.5% protocol fee
        uint256 total = PRICE * 4;
        uint256 expectedFee = (total * CAPITAL_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expectedFee);
        assertEq(usdc.balanceOf(issuer), issuerBefore + (total - expectedFee));
    }

    function test_buy_landNft_registeredAsSeparateNftType() public view {
        // Ensure LandNFT is stored with NftType.LandNFT (not CommerceNFT)
        ProjectSale.SaleConfig memory cfg = sale.getSaleConfig(PROJECT_LAND);
        assertEq(uint8(cfg.nftType), uint8(ProjectSale.NftType.LandNFT));
    }

    // ─── buy() — SceneNFT ─────────────────────────────────────────────────────

    function test_buy_sceneNft_succeeds() public {
        _activateAll();

        uint256 buyerBalBefore = usdc.balanceOf(buyer);
        uint256 issuerBalBefore = usdc.balanceOf(issuer);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE);

        vm.prank(buyer);
        sale.buy(PROJECT_SCENE, 1, 5); // sceneNumber = 5

        // Token minted
        assertEq(sceneNft.mintedTo(buyer), 1);
        assertEq(sceneNft.mintedPerScene(5), 1);

        // Payment routing: 2.5% to treasury, 97.5% to issuer
        uint256 expectedFee = (PRICE * CAPITAL_FEE_BPS) / 10_000; // 2,000_000
        uint256 expectedIssuer = PRICE - expectedFee;
        assertEq(usdc.balanceOf(buyer), buyerBalBefore - PRICE);
        assertEq(usdc.balanceOf(treasury), treasuryBalBefore + expectedFee);
        assertEq(usdc.balanceOf(issuer), issuerBalBefore + expectedIssuer);

        // Wallet purchase count recorded
        assertEq(sale.purchasedBy(PROJECT_SCENE, buyer), 1);
    }

    function test_buy_commerceNft_succeeds() public {
        _activateAll();

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE * 3);

        vm.prank(buyer);
        sale.buy(PROJECT_COMMERCE, 3, 0);

        assertEq(commerceNft.mintedTo(buyer), 3);

        // 5% fee check
        uint256 total = PRICE * 3;
        uint256 expectedFee = (total * COMMERCE_FEE_BPS) / 10_000;
        uint256 expectedIssuer = total - expectedFee;
        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(issuer), expectedIssuer);
    }

    function test_buy_revertsIfNotActive() public {
        // Sale is registered but not yet activated
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.SaleNotActive.selector, PROJECT_SCENE));
        sale.buy(PROJECT_SCENE, 1, 1);
    }

    function test_buy_revertsIfNotRegistered() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.SaleNotRegistered.selector, 999));
        sale.buy(999, 1, 1);
    }

    function test_buy_revertsZeroQuantity() public {
        _activateAll();
        vm.prank(buyer);
        vm.expectRevert(ProjectSale.ZeroQuantity.selector);
        sale.buy(PROJECT_SCENE, 0, 1);
    }

    function test_buy_revertsZeroPrice() public {
        // Register a sale with price = 0 (voucher-only)
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.pricePerToken = 0;
        sale.registerSale(50, cfg);
        vm.prank(admin);
        sale.activateSale(50);

        vm.prank(buyer);
        vm.expectRevert(ProjectSale.ZeroPrice.selector);
        sale.buy(50, 1, 1);
    }

    function test_buy_revertsWalletCapExceeded() public {
        _activateAll();

        // maxPerWallet = 5 for PROJECT_SCENE
        vm.prank(buyer);
        usdc.approve(address(sale), PRICE * 6);

        vm.prank(buyer);
        sale.buy(PROJECT_SCENE, 5, 1); // buy up to cap

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.WalletCapExceeded.selector, PROJECT_SCENE, buyer, 5));
        sale.buy(PROJECT_SCENE, 1, 1); // cap exceeded
    }

    function test_buy_revertsBeforeSaleStart() public {
        // Set saleStart to 1 hour from now
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.saleStart = block.timestamp + 1 hours;
        sale.registerSale(60, cfg);
        vm.prank(admin);
        sale.activateSale(60);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.SaleNotStarted.selector, 60));
        sale.buy(60, 1, 1);
    }

    function test_buy_succeedsAfterSaleStart() public {
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.saleStart = block.timestamp + 1 hours;
        sale.registerSale(61, cfg);
        vm.prank(admin);
        sale.activateSale(61);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE);
        vm.prank(buyer);
        sale.buy(61, 1, 1);
    }

    function test_buy_revertsAfterSaleEnd() public {
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.saleEnd = block.timestamp + 1 hours;
        sale.registerSale(62, cfg);
        vm.prank(admin);
        sale.activateSale(62);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ProjectSale.SaleEnded.selector, 62));
        sale.buy(62, 1, 1);
    }

    // ─── Payment routing when issuer == treasury ──────────────────────────────

    function test_buy_issuerIsTreasury_allGoesToTreasury() public {
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.issuer = treasury; // Nubians North genesis project pattern
        sale.registerSale(70, cfg);
        vm.prank(admin);
        sale.activateSale(70);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE);
        vm.prank(buyer);
        sale.buy(70, 1, 1);

        // Treasury receives everything (fee + remainder both go to treasury)
        assertEq(usdc.balanceOf(treasury), treasuryBefore + PRICE);
    }

    // ─── buyWithVoucher() ─────────────────────────────────────────────────────

    function test_buyWithVoucher_succeeds() public {
        _activateAll();

        uint256 discountedPrice = 40_000_000; // 50% discount
        bytes32 nonce = keccak256("nonce-001");

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 2,
            buyer: buyer,
            discountedPriceUsdc6: discountedPrice,
            promotionId: keccak256("LAUNCH50"),
            expiry: block.timestamp + 1 hours,
            nonce: nonce
        });

        bytes memory sig = _signVoucher(voucher);

        uint256 totalPayment = discountedPrice * 2;

        vm.prank(buyer);
        usdc.approve(address(sale), totalPayment);
        vm.prank(buyer);
        sale.buyWithVoucher(voucher, sig);

        assertEq(commerceNft.mintedTo(buyer), 2);
        assertTrue(sale.isNonceUsed(nonce));
    }

    function test_buyWithVoucher_freeVoucher_mintsWithoutPayment() public {
        _activateAll();

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer,
            discountedPriceUsdc6: 0, // free
            promotionId: keccak256("AIRDROP"),
            expiry: block.timestamp + 1 hours,
            nonce: keccak256("nonce-free")
        });

        bytes memory sig = _signVoucher(voucher);

        vm.prank(buyer);
        sale.buyWithVoucher(voucher, sig);

        assertEq(commerceNft.mintedTo(buyer), 1);
        // buyer's USDC balance unchanged
        assertEq(usdc.balanceOf(buyer), 10_000 * 1e6);
    }

    function test_buyWithVoucher_revertsExpired() public {
        _activateAll();

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer,
            discountedPriceUsdc6: PRICE,
            promotionId: keccak256("PROMO"),
            expiry: block.timestamp - 1, // already expired
            nonce: keccak256("nonce-exp")
        });
        bytes memory sig = _signVoucher(voucher);

        vm.prank(buyer);
        vm.expectRevert(ProjectSale.VoucherExpired.selector);
        sale.buyWithVoucher(voucher, sig);
    }

    function test_buyWithVoucher_revertsWrongBuyer() public {
        _activateAll();

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer, // voucher is for buyer
            discountedPriceUsdc6: PRICE,
            promotionId: keccak256("PROMO"),
            expiry: block.timestamp + 1 hours,
            nonce: keccak256("nonce-wrong")
        });
        bytes memory sig = _signVoucher(voucher);

        vm.prank(buyer2); // buyer2 tries to use buyer's voucher
        vm.expectRevert(ProjectSale.UnauthorizedBuyer.selector);
        sale.buyWithVoucher(voucher, sig);
    }

    function test_buyWithVoucher_revertsNonceReplay() public {
        _activateAll();

        bytes32 nonce = keccak256("nonce-replay");
        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer,
            discountedPriceUsdc6: PRICE,
            promotionId: keccak256("PROMO"),
            expiry: block.timestamp + 1 hours,
            nonce: nonce
        });
        bytes memory sig = _signVoucher(voucher);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE * 2);

        vm.prank(buyer);
        sale.buyWithVoucher(voucher, sig);

        vm.prank(buyer);
        vm.expectRevert(ProjectSale.VoucherAlreadyUsed.selector);
        sale.buyWithVoucher(voucher, sig);
    }

    function test_buyWithVoucher_revertsInvalidSignature() public {
        _activateAll();

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: PROJECT_COMMERCE,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer,
            discountedPriceUsdc6: PRICE,
            promotionId: keccak256("PROMO"),
            expiry: block.timestamp + 1 hours,
            nonce: keccak256("nonce-badsig")
        });

        // Sign with wrong private key
        bytes memory badSig = _signVoucherWithKey(voucher, 0xBAD);

        vm.prank(buyer);
        vm.expectRevert(ProjectSale.InvalidVoucherSignature.selector);
        sale.buyWithVoucher(voucher, badSig);
    }

    function test_buyWithVoucher_revertsIfSignerNotSet() public {
        // Deploy new sale with zero voucherSigner
        ProjectSale impl = new ProjectSale();
        bytes memory data = abi.encodeWithSelector(ProjectSale.initialize.selector, admin, treasury, address(0));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), data);
        ProjectSale noSigner = ProjectSale(address(proxy));

        vm.prank(admin);
        noSigner.registerSale(1, _sceneConfig());
        vm.prank(admin);
        noSigner.activateSale(1);

        ProjectSale.SaleVoucher memory voucher = ProjectSale.SaleVoucher({
            projectId: 1,
            sceneNumber: 0,
            quantity: 1,
            buyer: buyer,
            discountedPriceUsdc6: PRICE,
            promotionId: bytes32(0),
            expiry: block.timestamp + 1 hours,
            nonce: keccak256("nonce-nosigner")
        });

        vm.prank(buyer);
        vm.expectRevert(ProjectSale.VoucherSignerNotSet.selector);
        noSigner.buyWithVoucher(voucher, new bytes(65));
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    function test_setTreasury_updatesAddress() public {
        address newTreasury = address(0xBEEF);
        vm.prank(admin);
        sale.setTreasury(newTreasury);
        assertEq(sale.treasury(), newTreasury);
    }

    function test_setTreasury_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ProjectSale.ZeroAddress.selector);
        sale.setTreasury(address(0));
    }

    function test_setVoucherSigner_updatesAddress() public {
        address newSigner = address(0xCAFE);
        vm.prank(admin);
        sale.setVoucherSigner(newSigner);
        assertEq(sale.voucherSigner(), newSigner);
    }

    function test_sweepToken_rescuesTokens() public {
        // Simulate tokens accidentally sent to sale contract
        usdc.mint(address(sale), 1_000_000);
        address rescueTo = address(0xFEED);
        vm.prank(admin);
        sale.sweepToken(usdc, rescueTo, 1_000_000);
        assertEq(usdc.balanceOf(rescueTo), 1_000_000);
    }

    function test_sweepToken_revertsZeroTo() public {
        usdc.mint(address(sale), 1_000_000);
        vm.prank(admin);
        vm.expectRevert(ProjectSale.ZeroAddress.selector);
        sale.sweepToken(usdc, address(0), 1_000_000);
    }

    function test_sweepToken_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.sweepToken(usdc, buyer, 1);
    }

    // ─── Protocol fee boundary ────────────────────────────────────────────────

    function test_buy_exactMaxFee_succeeds() public {
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.protocolFeeBps = 1_000; // exactly 10% — should succeed
        sale.registerSale(80, cfg);
        vm.prank(admin);
        sale.activateSale(80);

        vm.prank(buyer);
        usdc.approve(address(sale), PRICE);
        vm.prank(buyer);
        sale.buy(80, 1, 1);

        uint256 expectedFee = (PRICE * 1_000) / 10_000;
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }

    function test_buy_zeroFee_allToIssuer() public {
        vm.prank(admin);
        ProjectSale.SaleConfig memory cfg = _sceneConfig();
        cfg.protocolFeeBps = 0; // 0% fee
        sale.registerSale(81, cfg);
        vm.prank(admin);
        sale.activateSale(81);

        uint256 issuerBefore = usdc.balanceOf(issuer);
        vm.prank(buyer);
        usdc.approve(address(sale), PRICE);
        vm.prank(buyer);
        sale.buy(81, 1, 1);

        assertEq(usdc.balanceOf(issuer), issuerBefore + PRICE);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ─── domainSeparator sanity ───────────────────────────────────────────────

    function test_domainSeparator_nonZero() public view {
        assertTrue(sale.domainSeparator() != bytes32(0));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _activateAll() internal {
        vm.prank(admin);
        sale.activateSale(PROJECT_SCENE);
        vm.prank(admin);
        sale.activateSale(PROJECT_COMMERCE);
        vm.prank(admin);
        sale.activateSale(PROJECT_LAND);
    }

    function _sceneConfig() internal view returns (ProjectSale.SaleConfig memory) {
        return ProjectSale.SaleConfig({
            nftContract: address(sceneNft),
            issuer: issuer,
            paymentToken: address(usdc),
            nftType: ProjectSale.NftType.SceneNFT,
            pricePerToken: PRICE,
            protocolFeeBps: CAPITAL_FEE_BPS,
            maxPerWallet: 5,
            saleStart: 0,
            saleEnd: 0,
            active: false
        });
    }

    function _signVoucher(ProjectSale.SaleVoucher memory v) internal view returns (bytes memory) {
        return _signVoucherWithKey(v, voucherSignerPk);
    }

    function _signVoucherWithKey(ProjectSale.SaleVoucher memory v, uint256 pk) internal view returns (bytes memory) {
        bytes32 domainSep = sale.domainSeparator();
        bytes32 structHash = keccak256(
            abi.encode(
                sale.SALE_VOUCHER_TYPEHASH(),
                v.projectId,
                v.sceneNumber,
                v.quantity,
                v.buyer,
                v.discountedPriceUsdc6,
                v.promotionId,
                v.expiry,
                v.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, vv);
    }
}
