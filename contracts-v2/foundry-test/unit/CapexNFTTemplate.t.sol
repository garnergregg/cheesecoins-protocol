// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ClonesUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import {CapexNFTTemplate} from "../../foundry-src/nft/CapexNFTTemplate.sol";
import {INFTTransferHook} from "../../foundry-src/nft/interfaces/INFTTransferHook.sol";

// ── Helpers ──────────────────────────────────────────────────────────────────

contract MockHook is INFTTransferHook {
    uint256 public beforeCount;
    uint256 public afterCount;
    bool internal _blockTransfer;

    function setBlockTransfer(bool v) external {
        _blockTransfer = v;
    }

    function beforeNFTTransfer(uint256, address, address) external override returns (bool) {
        beforeCount++;
        return !_blockTransfer;
    }

    function afterNFTTransfer(uint256, address, address) external override {
        afterCount++;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/**
 * @title CapexNFTTemplateTest
 * @notice Unit tests for CapexNFTTemplate — Capex / Growth class NFT.
 *
 * Covers: initialization, minting (mintScene + mint), scene cap enforcement,
 *         supply math, hook wiring, admin functions, and re-init guard.
 */
contract CapexNFTTemplateTest is Test {
    using ClonesUpgradeable for address;

    // ── Actors ───────────────────────────────────────────────────────────────

    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    // ── Contracts ─────────────────────────────────────────────────────────────

    CapexNFTTemplate internal impl;
    CapexNFTTemplate internal nft; // clone under test
    MockHook internal hook;

    // ── Parameters ────────────────────────────────────────────────────────────

    uint256 internal constant PROJECT_ID = 7;
    uint16 internal constant TOTAL_SCENES = 10;
    uint256 internal constant COPIES_PER_SCENE = 5;
    string internal constant BASE_URI = "ipfs://Qm.../";
    string internal constant NAME = "Sunrise Dairy";
    string internal constant SYMBOL = "SUNR";

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        impl = new CapexNFTTemplate();
        nft = CapexNFTTemplate(address(impl).clone());
        hook = new MockHook();

        nft.initialize(PROJECT_ID, NAME, SYMBOL, TOTAL_SCENES, COPIES_PER_SCENE, BASE_URI, owner);

        vm.prank(owner);
        nft.setAuthorizedMinter(minter, true);
    }

    // ── Initialization ────────────────────────────────────────────────────────

    function test_initialize_setsFields() public view {
        assertEq(nft.projectId(), PROJECT_ID);
        assertEq(nft.TOTAL_SCENES(), TOTAL_SCENES);
        assertEq(nft.SCENE_MAX_SUPPLY(), COPIES_PER_SCENE);
        assertEq(nft.TOTAL_MAX_SUPPLY(), uint256(TOTAL_SCENES) * COPIES_PER_SCENE);
        assertEq(nft.name(), NAME);
        assertEq(nft.symbol(), SYMBOL);
        assertEq(nft.owner(), owner);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert(); // AlreadyInitialized or OZ initializer guard
        nft.initialize(PROJECT_ID, NAME, SYMBOL, TOTAL_SCENES, COPIES_PER_SCENE, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroProjectId() public {
        CapexNFTTemplate fresh = CapexNFTTemplate(address(impl).clone());
        vm.expectRevert(CapexNFTTemplate.InvalidProjectId.selector);
        fresh.initialize(0, NAME, SYMBOL, TOTAL_SCENES, COPIES_PER_SCENE, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroScenes() public {
        CapexNFTTemplate fresh = CapexNFTTemplate(address(impl).clone());
        vm.expectRevert(CapexNFTTemplate.InvalidSceneConfig.selector);
        fresh.initialize(PROJECT_ID, NAME, SYMBOL, 0, COPIES_PER_SCENE, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroCopies() public {
        CapexNFTTemplate fresh = CapexNFTTemplate(address(impl).clone());
        vm.expectRevert(CapexNFTTemplate.InvalidSceneConfig.selector);
        fresh.initialize(PROJECT_ID, NAME, SYMBOL, TOTAL_SCENES, 0, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroOwner() public {
        CapexNFTTemplate fresh = CapexNFTTemplate(address(impl).clone());
        vm.expectRevert();
        fresh.initialize(PROJECT_ID, NAME, SYMBOL, TOTAL_SCENES, COPIES_PER_SCENE, BASE_URI, address(0));
    }

    // ── mintScene ─────────────────────────────────────────────────────────────

    function test_mintScene_mintsToRecipient() public {
        vm.prank(minter);
        nft.mintScene(alice, 1, 3);

        assertEq(nft.totalSupply(), 3);
        assertEq(nft.mintedPerScene(1), 3);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
    }

    function test_mintScene_setsTokenScene() public {
        vm.prank(minter);
        nft.mintScene(alice, 3, 2);

        assertEq(nft.tokenScene(0), 3);
        assertEq(nft.tokenScene(1), 3);
    }

    function test_mintScene_multipleScenes_correctMapping() public {
        vm.prank(minter);
        nft.mintScene(alice, 1, 2);
        vm.prank(minter);
        nft.mintScene(bob, 2, 1);

        assertEq(nft.tokenScene(0), 1);
        assertEq(nft.tokenScene(1), 1);
        assertEq(nft.tokenScene(2), 2);
        assertEq(nft.ownerOf(2), bob);
    }

    function test_mintScene_revertsForUnauthorizedMinter() public {
        vm.prank(stranger);
        vm.expectRevert(CapexNFTTemplate.UnauthorizedMinter.selector);
        nft.mintScene(alice, 1, 1);
    }

    function test_mintScene_revertsOnZeroScene() public {
        vm.prank(minter);
        vm.expectRevert(CapexNFTTemplate.InvalidSceneNumber.selector);
        nft.mintScene(alice, 0, 1);
    }

    function test_mintScene_revertsOnSceneAboveTotal() public {
        vm.prank(minter);
        vm.expectRevert(CapexNFTTemplate.InvalidSceneNumber.selector);
        nft.mintScene(alice, TOTAL_SCENES + 1, 1);
    }

    function test_mintScene_revertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert();
        nft.mintScene(address(0), 1, 1);
    }

    function test_mintScene_revertsWhenSceneCapReached() public {
        // Fill scene 1 to cap
        vm.prank(minter);
        nft.mintScene(alice, 1, COPIES_PER_SCENE);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(CapexNFTTemplate.SceneCapReached.selector, uint16(1), COPIES_PER_SCENE));
        nft.mintScene(alice, 1, 1);
    }

    function test_mintScene_revertsOnPartialOverflow() public {
        vm.prank(minter);
        nft.mintScene(alice, 2, COPIES_PER_SCENE - 1);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(CapexNFTTemplate.SceneCapReached.selector, uint16(2), COPIES_PER_SCENE));
        nft.mintScene(alice, 2, 2); // would exceed cap by 1
    }

    function test_mintScene_emitsEvent() public {
        vm.expectEmit(true, false, true, true);
        emit CapexNFTTemplate.SceneMinted(PROJECT_ID, 1, 2, alice);
        vm.prank(minter);
        nft.mintScene(alice, 1, 2);
    }

    // ── mint (single) ─────────────────────────────────────────────────────────

    function test_mint_singleToken() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(alice, 4);

        assertEq(tokenId, 0);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.tokenScene(0), 4);
        assertEq(nft.mintedPerScene(4), 1);
    }

    function test_mint_revertsForUnauthorizedMinter() public {
        vm.prank(stranger);
        vm.expectRevert(CapexNFTTemplate.UnauthorizedMinter.selector);
        nft.mint(alice, 1);
    }

    function test_mint_revertsOnSceneCap() public {
        for (uint256 i = 0; i < COPIES_PER_SCENE; i++) {
            vm.prank(minter);
            nft.mint(alice, 5);
        }
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(CapexNFTTemplate.SceneCapReached.selector, uint16(5), COPIES_PER_SCENE));
        nft.mint(alice, 5);
    }

    // ── View functions ────────────────────────────────────────────────────────

    function test_getProjectId() public view {
        assertEq(nft.getProjectId(), PROJECT_ID);
    }

    function test_getSceneNumber() public {
        vm.prank(minter);
        nft.mintScene(alice, 7, 1);
        assertEq(nft.getSceneNumber(0), 7);
    }

    function test_remainingForScene() public {
        vm.prank(minter);
        nft.mintScene(alice, 1, 2);

        assertEq(nft.remainingForScene(1), COPIES_PER_SCENE - 2);
        assertEq(nft.remainingForScene(2), COPIES_PER_SCENE); // untouched scene
        assertEq(nft.remainingForScene(0), 0); // invalid scene
        assertEq(nft.remainingForScene(TOTAL_SCENES + 1), 0); // out of range
    }

    function test_totalSupply_incrementsCorrectly() public {
        assertEq(nft.totalSupply(), 0);
        vm.prank(minter);
        nft.mintScene(alice, 1, 3);
        assertEq(nft.totalSupply(), 3);
        vm.prank(minter);
        nft.mintScene(alice, 2, 2);
        assertEq(nft.totalSupply(), 5);
    }

    function test_tokenURI_usesSceneNumber() public {
        vm.prank(minter);
        nft.mintScene(alice, 3, 1);
        string memory uri = nft.tokenURI(0);
        assertEq(uri, string(abi.encodePacked(BASE_URI, "3")));
    }

    // ── Transfer hooks ────────────────────────────────────────────────────────

    function test_transferHook_calledOnTransfer() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));

        vm.prank(minter);
        nft.mintScene(alice, 1, 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 0);

        assertEq(hook.beforeCount(), 1);
        assertEq(hook.afterCount(), 2); // mint + transfer
    }

    function test_transferHook_notCalledOnMint_before() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));

        vm.prank(minter);
        nft.mintScene(alice, 1, 1);

        // beforeNFTTransfer must NOT be called for mints (from == address(0))
        assertEq(hook.beforeCount(), 0);
        // afterNFTTransfer IS called for mints
        assertEq(hook.afterCount(), 1);
    }

    function test_transferHook_blockingHookPreventsTransfer() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));
        hook.setBlockTransfer(true);

        vm.prank(minter);
        nft.mintScene(alice, 1, 1);

        vm.prank(alice);
        vm.expectRevert("CapexNFT: blocked by hook");
        nft.transferFrom(alice, bob, 0);
    }

    function test_transferHook_noHookByDefault() public {
        vm.prank(minter);
        nft.mintScene(alice, 1, 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 0); // must not revert
        assertEq(nft.ownerOf(0), bob);
    }

    // ── Admin functions ───────────────────────────────────────────────────────

    function test_setAuthorizedMinter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setAuthorizedMinter(stranger, true);
    }

    function test_setAuthorizedMinter_revokesAccess() public {
        vm.prank(owner);
        nft.setAuthorizedMinter(minter, false);

        vm.prank(minter);
        vm.expectRevert(CapexNFTTemplate.UnauthorizedMinter.selector);
        nft.mintScene(alice, 1, 1);
    }

    function test_setTransferHook_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setTransferHook(address(hook));
    }

    function test_setTransferHook_updatesHook() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));
        assertEq(address(nft.transferHook()), address(hook));
    }

    function test_setBaseURI_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setBaseURI("ipfs://new/");
    }

    function test_setBaseURI_updatesURI() public {
        vm.prank(owner);
        nft.setBaseURI("ipfs://new/");

        vm.prank(minter);
        nft.mintScene(alice, 1, 1);
        assertEq(nft.tokenURI(0), "ipfs://new/1");
    }

    // ── Supply invariant ──────────────────────────────────────────────────────

    function testFuzz_totalMaxSupply_neverExceeded(uint16 scene, uint256 qty) public {
        scene = uint16(bound(scene, 1, TOTAL_SCENES));
        qty = bound(qty, 1, COPIES_PER_SCENE);

        // mint up to cap for the scene
        uint256 alreadyMinted = nft.mintedPerScene(scene);
        uint256 remaining = COPIES_PER_SCENE - alreadyMinted;
        qty = bound(qty, 1, remaining);

        vm.prank(minter);
        nft.mintScene(alice, scene, qty);

        assertLe(nft.totalSupply(), nft.TOTAL_MAX_SUPPLY());
    }
}
