// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PartnerNFTSale} from "../foundry-src/commerce/PartnerNFTSale.sol";
import {IProjectRegistry} from "../foundry-src/platform/interfaces/IProjectRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockNFT {
    uint256 public mintCount;

    function mintScene(address, uint16, uint256 quantity) external {
        mintCount += quantity;
    }
    function setAuthorizedMinter(address, bool) external {}
}

contract MockRegistry is IProjectRegistry {
    address public nft;

    constructor(address _nft) {
        nft = _nft;
    }

    function getProject(uint256) external view returns (IProjectRegistry.Project memory) {
        return IProjectRegistry.Project({
            id: 2,
            name: "Nubians North",
            owner: address(0),
            nftAddress: nft,
            oracleAddress: address(0),
            yieldPoolAddress: address(0),
            initialDoes: 0,
            registrationTime: 0,
            graduationYear: 0,
            active: true,
            graduated: false
        });
    }

    // ── IProjectRegistry stubs ────────────────────────────────────────────────
    function getOperatorWallet(uint256) external pure returns (address) {
        return address(0);
    }

    function isPayoutsEnabled(uint256) external pure returns (bool) {
        return false;
    }

    function createProject(string memory, address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getProjectMetrics(uint256) external pure returns (IProjectRegistry.ProjectMetrics memory) {
        return IProjectRegistry.ProjectMetrics(0, 0, 0, 0, 0, 0);
    }

    function getProjectCount() external pure returns (uint256) {
        return 0;
    }

    function getGraduationWeight(uint256) external pure returns (uint256) {
        return 0;
    }
    function registerYieldPool(uint256, address) external {}
    function approveProject(uint256) external {}
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract TestPartnerNFTSale is Test {
    PartnerNFTSale public sale;
    MockUSDC public usdc;
    MockNFT public nft;
    MockRegistry public registry;

    address owner = address(0xA1);
    address treasury = address(0xA2);
    address liqPool = address(0xA3);
    address buyer = address(0xBEEF);

    uint256 signerKey = 0xDEAD;
    address signer;

    uint256 constant PROJECT_ID = 2;
    uint16 constant SCENE = 5;
    uint256 constant PRICE_USDC6 = 40_000_000; // $40 USDC

    function setUp() public {
        signer = vm.addr(signerKey);
        usdc = new MockUSDC();
        nft = new MockNFT();
        registry = new MockRegistry(address(nft));

        sale = new PartnerNFTSale(owner, treasury, address(registry), address(usdc), signer);

        // Fund buyer with $40 USDC and approve
        usdc.mint(buyer, 100_000_000);
        vm.prank(buyer);
        usdc.approve(address(sale), type(uint256).max);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _makeVoucher(address _buyer, uint256 _price, uint256 _expiry, bytes32 _nonce)
        internal
        view
        returns (PartnerNFTSale.PromotionVoucher memory)
    {
        return PartnerNFTSale.PromotionVoucher({
            projectId: PROJECT_ID,
            sceneNumber: SCENE,
            quantity: 1,
            buyer: _buyer,
            discountedPriceUsdc6: _price,
            promotionId: keccak256("PARTNER_LAUNCH"),
            expiry: _expiry,
            nonce: _nonce
        });
    }

    function _sign(PartnerNFTSale.PromotionVoucher memory v) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                sale.PROMOTION_VOUCHER_TYPEHASH(),
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", sale.domainSeparator(), structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, vv);
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    function test_SuccessfulPromoMint() public {
        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32("nonce1"));
        bytes memory sig = _sign(v);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 treasBefore = usdc.balanceOf(treasury);
        uint256 nftsBefore = nft.mintCount();

        vm.prank(buyer);
        sale.promotionalMintWithUSDC(v, sig);

        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE_USDC6);
        assertEq(usdc.balanceOf(treasury), treasBefore + PRICE_USDC6);
        assertEq(nft.mintCount(), nftsBefore + 1);
        assertTrue(sale.isNonceUsed(bytes32("nonce1")));
    }

    function test_LiquiditySplitRouting() public {
        vm.prank(owner);
        sale.setLiquidityPool(liqPool);
        vm.prank(owner);
        sale.setLiquidityShareBps(5000); // 50%

        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32("nonce2"));
        bytes memory sig = _sign(v);

        vm.prank(buyer);
        sale.promotionalMintWithUSDC(v, sig);

        assertEq(usdc.balanceOf(liqPool), PRICE_USDC6 / 2);
        assertEq(usdc.balanceOf(treasury), PRICE_USDC6 / 2);
    }

    function test_RevertOnExpiredVoucher() public {
        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp - 1, bytes32("nonce3"));
        bytes memory sig = _sign(v);

        vm.prank(buyer);
        vm.expectRevert(PartnerNFTSale.VoucherExpired.selector);
        sale.promotionalMintWithUSDC(v, sig);
    }

    function test_RevertOnReplayedNonce() public {
        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32("nonce4"));
        bytes memory sig = _sign(v);

        vm.prank(buyer);
        sale.promotionalMintWithUSDC(v, sig);

        // Second attempt with same nonce
        usdc.mint(buyer, PRICE_USDC6);
        vm.prank(buyer);
        vm.expectRevert(PartnerNFTSale.VoucherAlreadyUsed.selector);
        sale.promotionalMintWithUSDC(v, sig);
    }

    function test_RevertOnWrongBuyer() public {
        address impostor = address(0xBAD);
        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32("nonce5"));
        bytes memory sig = _sign(v);

        vm.prank(impostor);
        vm.expectRevert(PartnerNFTSale.UnauthorizedBuyer.selector);
        sale.promotionalMintWithUSDC(v, sig);
    }

    function test_RevertOnBadSignature() public {
        PartnerNFTSale.PromotionVoucher memory v =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32("nonce6"));
        bytes memory fakeSig = _sign(v);
        // Corrupt the signature
        fakeSig[0] = fakeSig[0] ^ 0xFF;

        vm.prank(buyer);
        vm.expectRevert(PartnerNFTSale.InvalidVoucherSignature.selector);
        sale.promotionalMintWithUSDC(v, fakeSig);
    }

    function test_RevertOnPromoCapExceeded() public {
        // Mint up to the cap (2)
        for (uint256 i = 0; i < 2; i++) {
            usdc.mint(buyer, PRICE_USDC6);
            PartnerNFTSale.PromotionVoucher memory v =
                _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32(i + 100));
            bytes memory sig = _sign(v);
            vm.prank(buyer);
            sale.promotionalMintWithUSDC(v, sig);
        }

        // Third attempt should revert
        PartnerNFTSale.PromotionVoucher memory v3 =
            _makeVoucher(buyer, PRICE_USDC6, block.timestamp + 1 hours, bytes32(uint256(999)));
        bytes memory sig3 = _sign(v3);
        vm.prank(buyer);
        vm.expectRevert(PartnerNFTSale.PromoMintCapExceeded.selector);
        sale.promotionalMintWithUSDC(v3, sig3);
    }

    function test_OnlyOwnerCanSetSigner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.setPromotionSigner(address(0x1234));
    }

    function test_LiquidityShareCappedAt50Percent() public {
        vm.prank(owner);
        vm.expectRevert();
        sale.setLiquidityShareBps(5001);
    }
}
