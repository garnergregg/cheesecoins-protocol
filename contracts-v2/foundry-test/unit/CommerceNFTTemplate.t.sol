// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {CommerceNFTTemplate} from "../../foundry-src/nft/CommerceNFTTemplate.sol";

// ============ HELPERS ============

function makeParams(
    uint256 pid,
    address issuer,
    address owner,
    uint256 maxSupply,
    uint256 maturityDate,
    bool isRenewable,
    bool isTransferable
) pure returns (CommerceNFTTemplate.InitParams memory p) {
    p = CommerceNFTTemplate.InitParams({
        projectId: pid,
        name: "CSA Subscription",
        symbol: "CSA",
        issuerAddress: issuer,
        instrumentSubtype: "csa_subscription",
        faceValueUsdc6: 100_000_000, // $100
        termsUri: "ipfs://QmTerms",
        maxSupply: maxSupply,
        maturityDate: maturityDate,
        isRenewable: isRenewable,
        isTransferable: isTransferable,
        yieldEnabled: false,
        baseURI: "ipfs://QmBase/",
        owner: owner
    });
}

// ============ TEST CONTRACT ============

contract CommerceNFTTemplateTest is Test {
    CommerceNFTTemplate public impl;
    CommerceNFTTemplate public nft; // proxy-wrapped instance
    ProxyAdmin public proxyAdmin;

    address owner = address(0x1001);
    address issuer = address(0x1002);
    address minter = address(0x1003);
    address buyer = address(0x1004);
    address buyer2 = address(0x1005);

    function setUp() public {
        impl = new CommerceNFTTemplate();
        proxyAdmin = new ProxyAdmin();

        // Use a future maturity date by default: 1 year from now
        CommerceNFTTemplate.InitParams memory p =
            makeParams(1, issuer, owner, 100, block.timestamp + 365 days, true, true);

        bytes memory initData = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        nft = CommerceNFTTemplate(address(proxy));

        // Authorize the minter
        vm.prank(owner);
        nft.setAuthorizedMinter(minter, true);
    }

    // ─── Initialization ───────────────────────────────────────────────────────

    function test_initialize_setsFields() public view {
        assertEq(nft.projectId(), 1);
        assertEq(nft.issuerAddress(), issuer);
        assertEq(nft.instrumentSubtype(), "csa_subscription");
        assertEq(nft.faceValueUsdc6(), 100_000_000);
        assertEq(nft.maxSupply(), 100);
        assertEq(nft.isRenewable(), true);
        assertEq(nft.isTransferable(), true);
        assertEq(nft.owner(), owner);
    }

    function test_initialize_revertsOnSecondCall() public {
        CommerceNFTTemplate.InitParams memory p = makeParams(1, issuer, owner, 100, 0, false, false);
        vm.expectRevert();
        nft.initialize(p);
    }

    function test_initialize_revertsZeroProjectId() public {
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p = makeParams(0, issuer, owner, 100, 0, false, false);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    function test_initialize_revertsZeroIssuer() public {
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p = makeParams(1, address(0), owner, 100, 0, false, false);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    function test_initialize_revertsMaturityInPast() public {
        // Warp so block.timestamp is large enough that a past value is > 0
        vm.warp(1_000_000);
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p = makeParams(1, issuer, owner, 100, block.timestamp - 1, false, false);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
    }

    // ─── Minting ──────────────────────────────────────────────────────────────

    function test_mint_succeeds() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(buyer);
        assertEq(tokenId, 0); // ERC721A starts at 0
        assertEq(nft.ownerOf(0), buyer);
        assertEq(nft.totalSupply(), 1);
    }

    function test_mintBatch_succeeds() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 5);
        assertEq(nft.totalSupply(), 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(nft.ownerOf(i), buyer);
        }
    }

    function test_mint_revertsUnauthorizedMinter() public {
        vm.prank(buyer);
        vm.expectRevert(CommerceNFTTemplate.UnauthorizedMinter.selector);
        nft.mint(buyer);
    }

    function test_mint_revertsAtMaxSupply() public {
        // Mint up to the cap
        vm.startPrank(minter);
        nft.mintBatch(buyer, 100);
        vm.expectRevert(CommerceNFTTemplate.MaxSupplyReached.selector);
        nft.mint(buyer);
        vm.stopPrank();
    }

    function test_mint_revertsAfterMaturity() public {
        // Warp past maturity
        vm.warp(block.timestamp + 366 days);

        vm.prank(minter);
        vm.expectRevert(CommerceNFTTemplate.InstrumentExpired.selector);
        nft.mint(buyer);
    }

    function test_mint_succeedsWithNoMaturityDate() public {
        // Deploy a fresh NFT with maturityDate = 0 (no expiry)
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p = makeParams(2, issuer, owner, 50, 0, false, true);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        CommerceNFTTemplate noExpiry = CommerceNFTTemplate(address(proxy));

        vm.prank(owner);
        noExpiry.setAuthorizedMinter(minter, true);

        vm.warp(block.timestamp + 1000 days); // far future
        vm.prank(minter);
        noExpiry.mint(buyer);
        assertEq(noExpiry.totalSupply(), 1);
    }

    // ─── Fulfillment ──────────────────────────────────────────────────────────

    function test_markFulfilled_succeeds() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.prank(issuer);
        nft.markFulfilled(0);

        assertEq(uint8(nft.fulfillmentStatus(0)), uint8(CommerceNFTTemplate.FulfillmentStatus.Fulfilled));
    }

    function test_markFulfilled_revertsIfNotIssuer() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.prank(buyer);
        vm.expectRevert(CommerceNFTTemplate.NotIssuer.selector);
        nft.markFulfilled(0);
    }

    function test_markFulfilled_revertsIfAlreadyFulfilled() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.startPrank(issuer);
        nft.markFulfilled(0);
        vm.expectRevert(CommerceNFTTemplate.TokenAlreadyFulfilled.selector);
        nft.markFulfilled(0);
        vm.stopPrank();
    }

    function test_markCancelled_succeeds() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.prank(issuer);
        nft.markCancelled(0);

        assertEq(uint8(nft.fulfillmentStatus(0)), uint8(CommerceNFTTemplate.FulfillmentStatus.Cancelled));
    }

    function test_markCancelled_revertsIfNotIssuer() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.prank(buyer);
        vm.expectRevert(CommerceNFTTemplate.NotIssuer.selector);
        nft.markCancelled(0);
    }

    function test_markFulfilled_revertsIfCancelled() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.startPrank(issuer);
        nft.markCancelled(0);
        vm.expectRevert(CommerceNFTTemplate.TokenCancelled.selector);
        nft.markFulfilled(0);
        vm.stopPrank();
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
        vm.expectRevert(CommerceNFTTemplate.NotIssuer.selector);
        nft.extendMaturity(block.timestamp + 730 days);
    }

    function test_extendMaturity_revertsIfNotRenewable() public {
        // Deploy non-renewable instrument
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p =
            makeParams(3, issuer, owner, 50, block.timestamp + 365 days, false, true);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        CommerceNFTTemplate nonRenewable = CommerceNFTTemplate(address(proxy));

        vm.prank(issuer);
        vm.expectRevert("CommerceNFT: not renewable");
        nonRenewable.extendMaturity(block.timestamp + 730 days);
    }

    function test_extendMaturity_revertsInPast() public {
        vm.prank(issuer);
        vm.expectRevert("CommerceNFT: new maturity in past");
        nft.extendMaturity(block.timestamp - 1);
    }

    function test_extendMaturity_revertsIfShorter() public {
        uint256 currentMaturity = nft.maturityDate();
        vm.prank(issuer);
        vm.expectRevert("CommerceNFT: must extend, not shorten");
        nft.extendMaturity(currentMaturity - 1 days);
    }

    // ─── Transfer restriction ─────────────────────────────────────────────────

    function test_transfer_succeeds_whenTransferable() public {
        vm.prank(minter);
        nft.mint(buyer);

        vm.prank(buyer);
        nft.transferFrom(buyer, buyer2, 0);
        assertEq(nft.ownerOf(0), buyer2);
    }

    function test_transfer_reverts_whenNonTransferable() public {
        // Deploy non-transferable instrument
        CommerceNFTTemplate newImpl = new CommerceNFTTemplate();
        CommerceNFTTemplate.InitParams memory p = makeParams(4, issuer, owner, 50, 0, false, false);
        bytes memory data = abi.encodeWithSelector(CommerceNFTTemplate.initialize.selector, p);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(newImpl), address(proxyAdmin), data);
        CommerceNFTTemplate noTransfer = CommerceNFTTemplate(address(proxy));

        vm.prank(owner);
        noTransfer.setAuthorizedMinter(minter, true);

        vm.prank(minter);
        noTransfer.mint(buyer);

        vm.prank(buyer);
        vm.expectRevert(CommerceNFTTemplate.TransferNotAllowed.selector);
        noTransfer.transferFrom(buyer, buyer2, 0);
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

    function test_remainingSupply() public {
        vm.prank(minter);
        nft.mintBatch(buyer, 10);
        assertEq(nft.remainingSupply(), 90);
    }

    function test_tokenURI() public {
        vm.prank(minter);
        nft.mint(buyer);
        assertEq(nft.tokenURI(0), "ipfs://QmBase/0");
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function test_setAuthorizedMinter_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setAuthorizedMinter(minter, false);
    }

    function test_setTermsUri_byIssuer() public {
        vm.prank(issuer);
        nft.setTermsUri("ipfs://QmNewTerms");
        assertEq(nft.termsUri(), "ipfs://QmNewTerms");
    }

    function test_setTermsUri_byOwner() public {
        vm.prank(owner);
        nft.setTermsUri("ipfs://QmOwnerTerms");
        assertEq(nft.termsUri(), "ipfs://QmOwnerTerms");
    }

    function test_setTermsUri_revertsIfNeither() public {
        vm.prank(buyer);
        vm.expectRevert("CommerceNFT: not issuer or owner");
        nft.setTermsUri("ipfs://QmHack");
    }

    function test_setBaseURI_onlyOwner() public {
        vm.prank(owner);
        nft.setBaseURI("ipfs://QmNew/");
        vm.prank(minter);
        nft.mint(buyer);
        assertEq(nft.tokenURI(0), "ipfs://QmNew/0");
    }
}
