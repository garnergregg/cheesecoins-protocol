// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {LandNFTTemplate} from "../../foundry-src/nft/LandNFTTemplate.sol";
import {ILandNFT} from "../../foundry-src/nft/interfaces/ILandNFT.sol";

// ============ HELPERS ============

/// @dev 100 acres in sqm × 1e6 = 404_685_640_000
uint256 constant PARCEL_AREA = 404_685_640_000;
/// @dev 0.1 acres per token × 1e6 = 404_686_000
uint256 constant AREA_PER_TOK = 404_686_000;

function makeLandParams(
    uint256 pid,
    address issuer,
    address owner_,
    uint256 maxSupply,
    uint256 maturityDate,
    bool isRenewable,
    ILandNFT.LandRightType rightType
) pure returns (LandNFTTemplate.InitParams memory p) {
    p = LandNFTTemplate.InitParams({
        projectId: pid,
        name: "Sunrise Farm Lease Rights",
        symbol: "SFLR",
        issuerAddress: issuer,
        rightType: rightType,
        parentDeedId: keccak256(abi.encodePacked(uint256(1))),
        parcelAreaSqm: PARCEL_AREA,
        areaPerTokenSqm: AREA_PER_TOK,
        legalDescriptionUri: "ipfs://QmLegal",
        jurisdiction: "ON",
        termsUri: "ipfs://QmTerms",
        maxSupply: maxSupply,
        maturityDate: maturityDate,
        isRenewable: isRenewable,
        yieldEnabled: false,
        baseURI: "ipfs://QmBase/",
        owner: owner_
    });
}

// ============ TEST CONTRACT ============

contract LandNFTTemplateTest is Test {
    LandNFTTemplate public impl;
    LandNFTTemplate public nft;
    ProxyAdmin public proxyAdmin;

    address owner_ = address(0x1001);
    address issuer = address(0x1002);
    address minter = address(0x1003);
    address buyer = address(0x1004);
    address buyer2 = address(0x1005);

    function setUp() public {
        impl = new LandNFTTemplate();
        proxyAdmin = new ProxyAdmin();

        LandNFTTemplate.InitParams memory p = makeLandParams(
            1, issuer, owner_, 1000, block.timestamp + 365 days, true, ILandNFT.LandRightType.AgriculturalLease
        );
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), data);
        nft = LandNFTTemplate(address(proxy));

        vm.prank(owner_);
        nft.setAuthorizedMinter(minter, true);
    }

    // ─── Initialization ───────────────────────────────────────────────────────

    function test_initialize_setsFields() public view {
        assertEq(nft.projectId(), 1);
        assertEq(nft.issuerAddress(), issuer);
        assertEq(uint8(nft.rightType()), uint8(ILandNFT.LandRightType.AgriculturalLease));
        assertEq(nft.parentDeedId(), keccak256(abi.encodePacked(uint256(1))));
        assertEq(nft.parcelAreaSqm(), PARCEL_AREA);
        assertEq(nft.areaPerTokenSqm(), AREA_PER_TOK);
        assertEq(nft.jurisdiction(), "ON");
        assertEq(nft.maxSupply(), 1000);
        assertEq(nft.isRenewable(), true);
        assertEq(nft.owner(), owner_);
    }

    function test_initialize_revertsOnSecondCall() public {
        LandNFTTemplate.InitParams memory p =
            makeLandParams(1, issuer, owner_, 100, 0, false, ILandNFT.LandRightType.FeeSingle);
        vm.expectRevert();
        nft.initialize(p);
    }

    function test_initialize_revertsZeroProjectId() public {
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p =
            makeLandParams(0, issuer, owner_, 100, 0, false, ILandNFT.LandRightType.FeeSingle);
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    function test_initialize_revertsZeroIssuer() public {
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p =
            makeLandParams(1, address(0), owner_, 100, 0, false, ILandNFT.LandRightType.FeeSingle);
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    function test_initialize_revertsMaturityInPast() public {
        vm.warp(1_000_000);
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p = makeLandParams(
            1, issuer, owner_, 100, block.timestamp - 1, false, ILandNFT.LandRightType.AgriculturalLease
        );
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    function test_initialize_feeSingle_permanent() public {
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p =
            makeLandParams(2, issuer, owner_, 500, 0, false, ILandNFT.LandRightType.FeeSingle);
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        LandNFTTemplate feeSingle = LandNFTTemplate(address(proxy));
        assertEq(uint8(feeSingle.rightType()), uint8(ILandNFT.LandRightType.FeeSingle));
        assertEq(feeSingle.maturityDate(), 0);
        assertTrue(feeSingle.isActive());
        assertFalse(feeSingle.hasExpired());
    }

    // ─── Minting ──────────────────────────────────────────────────────────────

    function test_mint_succeeds() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(buyer);
        assertEq(tokenId, 0);
        assertEq(nft.ownerOf(0), buyer);
        assertEq(nft.totalSupply(), 1);
    }

    function test_mintBatch_succeeds() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 10);
        assertEq(nft.totalSupply(), 10);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(nft.ownerOf(i), buyer);
        }
    }

    function test_mint_revertsUnauthorizedMinter() public {
        vm.prank(buyer);
        vm.expectRevert(LandNFTTemplate.UnauthorizedMinter.selector);
        nft.mint(buyer);
    }

    function test_mint_revertsAtMaxSupply() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 1000); // fill cap

        vm.prank(minter);
        vm.expectRevert(LandNFTTemplate.MaxSupplyReached.selector);
        nft.mint(buyer);
    }

    function test_mint_revertsAfterMaturity() public {
        vm.warp(block.timestamp + 366 days);
        vm.prank(minter);
        vm.expectRevert(LandNFTTemplate.InstrumentExpired.selector);
        nft.mint(buyer);
    }

    function test_mint_permanentRights_noExpiry() public {
        // Deploy permanent fee simple
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p =
            makeLandParams(3, issuer, owner_, 200, 0, false, ILandNFT.LandRightType.FeeSingle);
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        LandNFTTemplate perm = LandNFTTemplate(address(proxy));

        vm.prank(owner_);
        perm.setAuthorizedMinter(minter, true);

        vm.warp(block.timestamp + 10_000 days); // far future
        vm.prank(minter);
        perm.mint(buyer);
        assertEq(perm.totalSupply(), 1);
    }

    // ─── Area accounting ──────────────────────────────────────────────────────

    function test_totalAreaMintedSqm() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 5);
        assertEq(nft.totalAreaMintedSqm(), 5 * AREA_PER_TOK);
    }

    function test_holderAreaSqm() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 3);
        assertEq(nft.holderAreaSqm(buyer), 3 * AREA_PER_TOK);
        assertEq(nft.holderAreaSqm(buyer2), 0);
    }

    function test_remainingSupply() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 100);
        assertEq(nft.remainingSupply(), 900);
    }

    // ─── Maturity extension ───────────────────────────────────────────────────

    function test_extendMaturity_succeeds() public {
        uint256 newDate = block.timestamp + 730 days;
        vm.prank(issuer);
        nft.extendMaturity(newDate);
        assertEq(nft.maturityDate(), newDate);
    }

    function test_extendMaturity_revertsIfNotIssuer() public {
        vm.prank(buyer);
        vm.expectRevert(LandNFTTemplate.NotIssuer.selector);
        nft.extendMaturity(block.timestamp + 730 days);
    }

    function test_extendMaturity_revertsIfNotRenewable() public {
        LandNFTTemplate newImpl = new LandNFTTemplate();
        LandNFTTemplate.InitParams memory p = makeLandParams(
            4, issuer, owner_, 100, block.timestamp + 365 days, false, ILandNFT.LandRightType.AgriculturalLease
        );
        bytes memory data = abi.encodeWithSelector(LandNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        LandNFTTemplate nonRenew = LandNFTTemplate(address(proxy));

        vm.prank(issuer);
        vm.expectRevert("LandNFT: not renewable");
        nonRenew.extendMaturity(block.timestamp + 730 days);
    }

    function test_extendMaturity_revertsIfShorter() public {
        uint256 current = nft.maturityDate();
        vm.prank(issuer);
        vm.expectRevert("LandNFT: must extend, not shorten");
        nft.extendMaturity(current - 1 days);
    }

    // ─── Transfer (always allowed for land rights) ────────────────────────────

    function test_transfer_succeeds() public {
        vm.prank(minter);
        nft.mint(buyer);
        vm.prank(buyer);
        nft.transferFrom(buyer, buyer2, 0);
        assertEq(nft.ownerOf(0), buyer2);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function test_isActive_trueBeforeMaturity() public view {
        assertTrue(nft.isActive());
        assertFalse(nft.hasExpired());
    }

    function test_isActive_falseAfterMaturity() public {
        vm.warp(block.timestamp + 366 days);
        assertFalse(nft.isActive());
        assertTrue(nft.hasExpired());
    }

    function test_tokenURI() public {
        vm.prank(minter);
        nft.mint(buyer);
        assertEq(nft.tokenURI(0), "ipfs://QmBase/0");
    }

    function test_getters() public view {
        assertEq(nft.getProjectId(), 1);
        assertEq(nft.getIssuer(), issuer);
        assertEq(uint8(nft.getRightType()), uint8(ILandNFT.LandRightType.AgriculturalLease));
        assertEq(nft.getParentDeedId(), keccak256(abi.encodePacked(uint256(1))));
        assertEq(nft.getParcelAreaSqm(), PARCEL_AREA);
        assertEq(nft.getAreaPerTokenSqm(), AREA_PER_TOK);
        assertEq(nft.getLegalDescriptionUri(), "ipfs://QmLegal");
        assertEq(nft.getJurisdiction(), "ON");
        assertEq(nft.getTermsUri(), "ipfs://QmTerms");
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function test_setLegalDescriptionUri_byIssuer() public {
        vm.prank(issuer);
        nft.setLegalDescriptionUri("ipfs://QmNewLegal");
        assertEq(nft.legalDescriptionUri(), "ipfs://QmNewLegal");
    }

    function test_setLegalDescriptionUri_byOwner() public {
        vm.prank(owner_);
        nft.setLegalDescriptionUri("ipfs://QmOwnerLegal");
        assertEq(nft.legalDescriptionUri(), "ipfs://QmOwnerLegal");
    }

    function test_setLegalDescriptionUri_revertsIfNeither() public {
        vm.prank(buyer);
        vm.expectRevert("LandNFT: not issuer or owner");
        nft.setLegalDescriptionUri("ipfs://QmHack");
    }

    function test_setTermsUri_byIssuer() public {
        vm.prank(issuer);
        nft.setTermsUri("ipfs://QmNewTerms");
        assertEq(nft.termsUri(), "ipfs://QmNewTerms");
    }

    function test_setAuthorizedMinter_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setAuthorizedMinter(buyer, true);
    }
}
