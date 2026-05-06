// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ClonesUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import {InputCostNFTTemplate} from "../../foundry-src/nft/InputCostNFTTemplate.sol";
import {INFTTransferHook} from "../../foundry-src/nft/interfaces/INFTTransferHook.sol";

// ── Helpers ──────────────────────────────────────────────────────────────────

contract ICMockHook is INFTTransferHook {
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
 * @title InputCostNFTTemplateTest
 * @notice Unit tests for InputCostNFTTemplate — seasonal credit class NFT.
 *
 * Covers: initialization, minting (mint + mintBatch), season expiry enforcement,
 *         renewSeason, supply cap, hook wiring, and admin functions.
 */
contract InputCostNFTTemplateTest is Test {
    using ClonesUpgradeable for address;

    // ── Actors ───────────────────────────────────────────────────────────────

    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    // ── Contracts ─────────────────────────────────────────────────────────────

    InputCostNFTTemplate internal impl;
    InputCostNFTTemplate internal nft;
    ICMockHook internal hook;

    // ── Parameters ────────────────────────────────────────────────────────────

    uint256 internal constant PROJECT_ID = 3;
    uint256 internal constant MAX_SUPPLY = 10;
    uint256 internal constant CREDIT_VALUE = 500e18;
    string internal constant SEASON = "Spring 2026";
    uint256 internal seasonExpiry; // set in setUp
    string internal constant BASE_URI = "ipfs://QmInputCost/";
    string internal constant NAME = "Green Valley Spring Feed 2026";
    string internal constant SYMBOL = "GVSF26";

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.warp(1_000_000); // fixed start time so expiry math is deterministic
        seasonExpiry = block.timestamp + 90 days;

        impl = new InputCostNFTTemplate();
        nft = InputCostNFTTemplate(address(impl).clone());
        hook = new ICMockHook();

        nft.initialize(PROJECT_ID, NAME, SYMBOL, MAX_SUPPLY, CREDIT_VALUE, SEASON, seasonExpiry, BASE_URI, owner);

        vm.prank(owner);
        nft.setAuthorizedMinter(minter, true);
    }

    // ── Initialization ────────────────────────────────────────────────────────

    function test_initialize_setsFields() public view {
        assertEq(nft.projectId(), PROJECT_ID);
        assertEq(nft.maxSupply(), MAX_SUPPLY);
        assertEq(nft.creditValuePerToken(), CREDIT_VALUE);
        assertEq(nft.currentSeason(), SEASON);
        assertEq(nft.seasonExpiry(), seasonExpiry);
        assertEq(nft.name(), NAME);
        assertEq(nft.symbol(), SYMBOL);
        assertEq(nft.owner(), owner);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        nft.initialize(PROJECT_ID, NAME, SYMBOL, MAX_SUPPLY, CREDIT_VALUE, SEASON, seasonExpiry, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroProjectId() public {
        InputCostNFTTemplate fresh = InputCostNFTTemplate(address(impl).clone());
        vm.expectRevert(InputCostNFTTemplate.InvalidProjectId.selector);
        fresh.initialize(0, NAME, SYMBOL, MAX_SUPPLY, CREDIT_VALUE, SEASON, seasonExpiry, BASE_URI, owner);
    }

    function test_initialize_revertsOnZeroSupply() public {
        InputCostNFTTemplate fresh = InputCostNFTTemplate(address(impl).clone());
        vm.expectRevert("InputCostNFT: zero supply");
        fresh.initialize(PROJECT_ID, NAME, SYMBOL, 0, CREDIT_VALUE, SEASON, seasonExpiry, BASE_URI, owner);
    }

    function test_initialize_revertsOnPastExpiry() public {
        InputCostNFTTemplate fresh = InputCostNFTTemplate(address(impl).clone());
        vm.expectRevert("InputCostNFT: expiry in past");
        fresh.initialize(
            PROJECT_ID, NAME, SYMBOL, MAX_SUPPLY, CREDIT_VALUE, SEASON, block.timestamp - 1, BASE_URI, owner
        );
    }

    function test_initialize_revertsOnZeroOwner() public {
        InputCostNFTTemplate fresh = InputCostNFTTemplate(address(impl).clone());
        vm.expectRevert();
        fresh.initialize(PROJECT_ID, NAME, SYMBOL, MAX_SUPPLY, CREDIT_VALUE, SEASON, seasonExpiry, BASE_URI, address(0));
    }

    // ── mint ──────────────────────────────────────────────────────────────────

    function test_mint_returnsCorrectTokenId() public {
        vm.prank(minter);
        uint256 id = nft.mint(alice);
        assertEq(id, 0);
        assertEq(nft.ownerOf(0), alice);
    }

    function test_mint_incrementsSupply() public {
        vm.prank(minter);
        nft.mint(alice);
        vm.prank(minter);
        nft.mint(alice);
        assertEq(nft.totalSupply(), 2);
    }

    function test_mint_revertsForUnauthorizedMinter() public {
        vm.prank(stranger);
        vm.expectRevert(InputCostNFTTemplate.UnauthorizedMinter.selector);
        nft.mint(alice);
    }

    function test_mint_revertsAfterSeasonExpiry() public {
        vm.warp(seasonExpiry); // at expiry (>=)
        vm.prank(minter);
        vm.expectRevert(InputCostNFTTemplate.SeasonExpired.selector);
        nft.mint(alice);
    }

    function test_mint_revertsAtMaxSupply() public {
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            vm.prank(minter);
            nft.mint(alice);
        }
        vm.prank(minter);
        vm.expectRevert(InputCostNFTTemplate.MaxSupplyReached.selector);
        nft.mint(alice);
    }

    function test_mint_revertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert();
        nft.mint(address(0));
    }

    function test_mint_emitsEvent() public {
        vm.expectEmit(true, false, true, true);
        emit InputCostNFTTemplate.CertificateMinted(PROJECT_ID, 0, alice, SEASON);
        vm.prank(minter);
        nft.mint(alice);
    }

    // ── mintBatch ─────────────────────────────────────────────────────────────

    function test_mintBatch_mintsCorrectQuantity() public {
        vm.prank(minter);
        nft.mintBatch(alice, 5);

        assertEq(nft.totalSupply(), 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(nft.ownerOf(i), alice);
        }
    }

    function test_mintBatch_revertsOnZeroQty() public {
        vm.prank(minter);
        vm.expectRevert("InputCostNFT: zero qty");
        nft.mintBatch(alice, 0);
    }

    function test_mintBatch_revertsOnOverflow() public {
        vm.prank(minter);
        nft.mintBatch(alice, MAX_SUPPLY - 1);

        vm.prank(minter);
        vm.expectRevert(InputCostNFTTemplate.MaxSupplyReached.selector);
        nft.mintBatch(alice, 2); // would exceed by 1
    }

    function test_mintBatch_revertsAfterExpiry() public {
        vm.warp(seasonExpiry);
        vm.prank(minter);
        vm.expectRevert(InputCostNFTTemplate.SeasonExpired.selector);
        nft.mintBatch(alice, 3);
    }

    function test_mintBatch_revertsForUnauthorizedMinter() public {
        vm.prank(stranger);
        vm.expectRevert(InputCostNFTTemplate.UnauthorizedMinter.selector);
        nft.mintBatch(alice, 3);
    }

    // ── Season management ─────────────────────────────────────────────────────

    function test_isSeasonActive_trueBeforeExpiry() public view {
        assertTrue(nft.isSeasonActive());
    }

    function test_isSeasonActive_falseAtExpiry() public {
        vm.warp(seasonExpiry);
        assertFalse(nft.isSeasonActive());
    }

    function test_renewSeason_updatesFields() public {
        uint256 newExpiry = block.timestamp + 180 days;
        vm.prank(owner);
        nft.renewSeason("Summer 2026", newExpiry);

        assertEq(nft.currentSeason(), "Summer 2026");
        assertEq(nft.seasonExpiry(), newExpiry);
        assertTrue(nft.isSeasonActive());
    }

    function test_renewSeason_allowsMintingAfterRenewal() public {
        // Expire the season
        vm.warp(seasonExpiry);

        // Renew
        uint256 newExpiry = block.timestamp + 90 days;
        vm.prank(owner);
        nft.renewSeason("Summer 2026", newExpiry);

        // Minting should work again
        vm.prank(minter);
        uint256 id = nft.mint(alice);
        assertEq(nft.ownerOf(id), alice);
    }

    function test_renewSeason_revertsOnPastExpiry() public {
        vm.prank(owner);
        vm.expectRevert("InputCostNFT: expiry in past");
        nft.renewSeason("Bad Season", block.timestamp - 1);
    }

    function test_renewSeason_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.renewSeason("Hack", block.timestamp + 1 days);
    }

    function test_renewSeason_emitsEvent() public {
        uint256 newExpiry = block.timestamp + 180 days;
        vm.expectEmit(false, false, false, true);
        emit InputCostNFTTemplate.SeasonRenewed("Summer 2026", newExpiry);
        vm.prank(owner);
        nft.renewSeason("Summer 2026", newExpiry);
    }

    // ── View functions ────────────────────────────────────────────────────────

    function test_getProjectId() public view {
        assertEq(nft.getProjectId(), PROJECT_ID);
    }

    function test_remainingSupply() public {
        assertEq(nft.remainingSupply(), MAX_SUPPLY);
        vm.prank(minter);
        nft.mintBatch(alice, 3);
        assertEq(nft.remainingSupply(), MAX_SUPPLY - 3);
    }

    // ── Transfer hooks ────────────────────────────────────────────────────────

    function test_hook_notCalledOnMint_before() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));

        vm.prank(minter);
        nft.mint(alice);

        assertEq(hook.beforeCount(), 0); // mints skip beforeNFTTransfer
        assertEq(hook.afterCount(), 1); // afterNFTTransfer fires on mint
    }

    function test_hook_calledOnTransfer() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));

        vm.prank(minter);
        nft.mint(alice);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 0);

        assertEq(hook.beforeCount(), 1);
        assertEq(hook.afterCount(), 2);
    }

    function test_hook_blockingPreventsTransfer() public {
        vm.prank(owner);
        nft.setTransferHook(address(hook));
        hook.setBlockTransfer(true);

        vm.prank(minter);
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert("InputCostNFT: blocked by hook");
        nft.transferFrom(alice, bob, 0);
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
        vm.expectRevert(InputCostNFTTemplate.UnauthorizedMinter.selector);
        nft.mint(alice);
    }

    function test_setTransferHook_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setTransferHook(address(hook));
    }

    function test_setBaseURI_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setBaseURI("ipfs://new/");
    }
}
