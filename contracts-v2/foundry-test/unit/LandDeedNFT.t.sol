// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {LandDeedNFT} from "../../foundry-src/nft/LandDeedNFT.sol";

contract LandDeedNFTTest is Test {
    LandDeedNFT public deed;

    address admin = address(0x1001);
    address farmer1 = address(0x1002);
    address farmer2 = address(0x1003);
    address registrar = address(0x1004);
    address subProj1 = address(0x2001);
    address subProj2 = address(0x2002);
    address stranger = address(0x9999);

    // 100 acres in sqm × 1e6
    uint256 constant PARCEL_100AC = 404_685_640_000;
    // 40 acres in sqm × 1e6
    uint256 constant PARCEL_40AC = 161_874_256_000;

    function setUp() public {
        deed = new LandDeedNFT(admin);

        vm.prank(admin);
        deed.setApprovedRegistrar(registrar, true);
    }

    // ─── registerDeed ─────────────────────────────────────────────────────────

    function test_registerDeed_mintsToFarmer() public {
        vm.prank(admin);
        uint256 deedId = deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://QmLegal1", "ON");

        assertEq(deedId, 0);
        assertEq(deed.ownerOf(0), farmer1);
        assertEq(deed.totalDeeds(), 1);

        LandDeedNFT.DeedMetadata memory meta = deed.getDeedMetadata(0);
        assertEq(meta.farmer, farmer1);
        assertEq(meta.parcelAreaSqm, PARCEL_100AC);
        assertEq(meta.jurisdiction, "ON");
        assertEq(meta.legalDescriptionUri, "ipfs://QmLegal1");
        assertFalse(meta.verified);
    }

    function test_registerDeed_incrementsIds() public {
        vm.startPrank(admin);
        uint256 id0 = deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");
        uint256 id1 = deed.registerDeed(farmer2, PARCEL_40AC, "ipfs://B", "BC");
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(deed.totalDeeds(), 2);
        assertEq(deed.ownerOf(1), farmer2);
    }

    function test_registerDeed_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");
    }

    function test_registerDeed_revertsZeroFarmer() public {
        vm.prank(admin);
        vm.expectRevert("LandDeed: zero farmer");
        deed.registerDeed(address(0), PARCEL_100AC, "ipfs://A", "ON");
    }

    function test_registerDeed_revertsZeroArea() public {
        vm.prank(admin);
        vm.expectRevert("LandDeed: zero area");
        deed.registerDeed(farmer1, 0, "ipfs://A", "ON");
    }

    // ─── verifyDeed ───────────────────────────────────────────────────────────

    function test_verifyDeed_setsVerified() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(admin);
        deed.verifyDeed(0);

        assertTrue(deed.getDeedMetadata(0).verified);
    }

    function test_verifyDeed_revertsNotFound() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LandDeedNFT.DeedNotFound.selector, 99));
        deed.verifyDeed(99);
    }

    function test_verifyDeed_onlyOwner() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        deed.verifyDeed(0);
    }

    // ─── getLandDeedHash ──────────────────────────────────────────────────────

    function test_getLandDeedHash_deterministicAndConsistent() public view {
        bytes32 hash0 = deed.getLandDeedHash(0);
        bytes32 hash0Again = deed.getLandDeedHash(0);
        bytes32 hash1 = deed.getLandDeedHash(1);

        assertEq(hash0, hash0Again);
        assertTrue(hash0 != hash1);
        assertEq(hash0, keccak256(abi.encodePacked(uint256(0))));
    }

    // ─── registerSubProject ───────────────────────────────────────────────────

    function test_registerSubProject_succeeds() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        // Issue rights covering 40 acres
        vm.prank(registrar);
        deed.registerSubProject(0, subProj1, PARCEL_40AC);

        assertEq(deed.totalIssuedAreaSqm(0), PARCEL_40AC);
        assertEq(deed.availableAreaSqm(0), PARCEL_100AC - PARCEL_40AC);
        assertEq(deed.getSubProjects(0).length, 1);
        assertEq(deed.getSubProjects(0)[0], subProj1);
    }

    function test_registerSubProject_multipleProjects() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(registrar);
        deed.registerSubProject(0, subProj1, PARCEL_40AC);
        vm.prank(registrar);
        deed.registerSubProject(0, subProj2, PARCEL_40AC);

        assertEq(deed.totalIssuedAreaSqm(0), PARCEL_40AC * 2);
        assertEq(deed.getSubProjects(0).length, 2);
    }

    function test_registerSubProject_revertsOverIssuance() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_40AC, "ipfs://A", "ON"); // only 40 acres

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(LandDeedNFT.OverIssuance.selector, 0, PARCEL_100AC, PARCEL_40AC));
        deed.registerSubProject(0, subProj1, PARCEL_100AC); // requesting 100 acres
    }

    function test_registerSubProject_exactlyFillsParcel() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(registrar);
        deed.registerSubProject(0, subProj1, PARCEL_100AC); // 100% of parcel

        assertEq(deed.availableAreaSqm(0), 0);

        // Next issuance should fail
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(LandDeedNFT.OverIssuance.selector, 0, 1, 0));
        deed.registerSubProject(0, subProj2, 1);
    }

    function test_registerSubProject_revertsNotApprovedRegistrar() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(stranger);
        vm.expectRevert(LandDeedNFT.NotApprovedRegistrar.selector);
        deed.registerSubProject(0, subProj1, PARCEL_40AC);
    }

    function test_registerSubProject_revertsInvalidDeed() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(LandDeedNFT.DeedNotFound.selector, 99));
        deed.registerSubProject(99, subProj1, PARCEL_40AC);
    }

    // ─── availableAreaSqm ─────────────────────────────────────────────────────

    function test_availableAreaSqm_fullAtStart() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");
        assertEq(deed.availableAreaSqm(0), PARCEL_100AC);
    }

    function test_availableAreaSqm_revertsInvalidDeed() public {
        vm.expectRevert(abi.encodeWithSelector(LandDeedNFT.DeedNotFound.selector, 55));
        deed.availableAreaSqm(55);
    }

    // ─── setApprovedRegistrar ─────────────────────────────────────────────────

    function test_setApprovedRegistrar_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        deed.setApprovedRegistrar(stranger, true);
    }

    function test_setApprovedRegistrar_canRevoke() public {
        vm.prank(admin);
        deed.setApprovedRegistrar(registrar, false);
        assertFalse(deed.approvedRegistrars(registrar));

        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(registrar);
        vm.expectRevert(LandDeedNFT.NotApprovedRegistrar.selector);
        deed.registerSubProject(0, subProj1, PARCEL_40AC);
    }

    // ─── updateLegalDescriptionUri ────────────────────────────────────────────

    function test_updateLegalDescriptionUri_onlyOwner() public {
        vm.prank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");

        vm.prank(admin);
        deed.updateLegalDescriptionUri(0, "ipfs://QmUpdated");
        assertEq(deed.getDeedMetadata(0).legalDescriptionUri, "ipfs://QmUpdated");

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        deed.updateLegalDescriptionUri(0, "ipfs://QmHack");
    }

    // ─── ERC721 standard ──────────────────────────────────────────────────────

    function test_deedIsERC721_farmersCanHoldMultiple() public {
        vm.startPrank(admin);
        deed.registerDeed(farmer1, PARCEL_100AC, "ipfs://A", "ON");
        deed.registerDeed(farmer1, PARCEL_40AC, "ipfs://B", "BC");
        vm.stopPrank();

        assertEq(deed.balanceOf(farmer1), 2);
        assertEq(deed.ownerOf(0), farmer1);
        assertEq(deed.ownerOf(1), farmer1);
    }
}
