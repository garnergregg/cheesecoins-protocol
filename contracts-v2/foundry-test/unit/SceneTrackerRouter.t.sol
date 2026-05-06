// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/nft/extensions/SceneTracker.sol";
import "../../foundry-src/nft/TransferHookRouter.sol";
import "../../foundry-src/nft/interfaces/INFTTransferHook.sol";

// ============ MINIMAL MOCKS ============

/// @dev Minimal NFT that SceneTracker can call tokenScene() on, and that exposes
///      a settable transferHook() to support the NFT-anchored authorization check.
contract MockSceneNFT {
    mapping(uint256 => uint16) private _scenes;
    /// @notice Mirrors the ProjectNFTTemplate / NubiansNorthNFT public field.
    address public transferHook;

    function setScene(uint256 tokenId, uint16 scene) external {
        _scenes[tokenId] = scene;
    }

    function setTransferHook(address hook) external {
        transferHook = hook;
    }

    function tokenScene(uint256 tokenId) external view returns (uint16) {
        return _scenes[tokenId];
    }
}

/// @dev A spoofing contract: exposes nftContract() as a public getter returning the correct
///      NFT address, just as the old self-assertion check would have trusted.  It is NOT the
///      NFT's configured transferHook.  Used to prove the new NFT-anchored check blocks it.
contract SpoofingRouter {
    address public immutable nftContract;

    constructor(address nft_) {
        nftContract = nft_;
    }
}

// ============ TESTS ============

/**
 * @title SceneTrackerRouterTest
 * @notice Verifies that SceneTracker accepts calls from:
 *   1. The NFT contract directly (existing path)
 *   2. The address the NFT has configured as its transferHook (router path)
 * And rejects calls from:
 *   3. Arbitrary contracts / EOAs
 *   4. A contract that claims router-for-correct-NFT but is NOT the configured hook (spoof)
 *   5. A router configured for a different NFT
 */
contract SceneTrackerRouterTest is Test {
    MockSceneNFT internal nft;
    SceneTracker internal tracker;
    TransferHookRouter internal router;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        nft = new MockSceneNFT();

        // SceneTracker is tied to the MockSceneNFT
        tracker = new SceneTracker(owner, address(nft));

        // Router is bound to the same NFT
        router = new TransferHookRouter(owner, address(nft));

        // Wire the NFT to use the router as its transfer hook.
        // This is what makes the router authorised: the NFT's own state says so.
        nft.setTransferHook(address(router));
    }

    // ── Direct NFT call (existing path) ───────────────────────────────────────

    function test_afterNFTTransfer_acceptsDirectNFTCall() public {
        nft.setScene(1, 5);
        vm.prank(address(nft));
        tracker.afterNFTTransfer(1, address(0), alice);
        assertEq(tracker.userSceneCounts(alice, 5), 1);
    }

    function test_beforeNFTTransfer_acceptsDirectNFTCall() public {
        vm.prank(address(nft));
        bool result = tracker.beforeNFTTransfer(1, alice, stranger);
        assertTrue(result, "beforeNFTTransfer should return true");
    }

    // ── Configured hook (router) call ─────────────────────────────────────────

    function test_afterNFTTransfer_acceptsConfiguredHook() public {
        nft.setScene(2, 10);
        // router is nft.transferHook() — this is the NFT-anchored authorisation
        vm.prank(address(router));
        tracker.afterNFTTransfer(2, address(0), alice);
        assertEq(tracker.userSceneCounts(alice, 10), 1, "scene credit must be applied when called by configured hook");
    }

    function test_beforeNFTTransfer_acceptsConfiguredHook() public {
        vm.prank(address(router));
        bool result = tracker.beforeNFTTransfer(1, alice, stranger);
        assertTrue(result, "beforeNFTTransfer via configured hook must return true");
    }

    // ── Rejected callers ──────────────────────────────────────────────────────

    function test_afterNFTTransfer_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(SceneTracker.OnlyNFTContract.selector);
        tracker.afterNFTTransfer(1, address(0), alice);
    }

    function test_beforeNFTTransfer_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(SceneTracker.OnlyNFTContract.selector);
        tracker.beforeNFTTransfer(1, alice, stranger);
    }

    /**
     * @notice Spoof-attack test (Blocker 1 regression).
     * @dev A contract that implements nftContract() returning the correct NFT address
     *      MUST be rejected if it is not the NFT's configured transferHook.
     *      With the old self-assertion check this attack would have succeeded.
     */
    function test_afterNFTTransfer_rejectsSpoofingContract() public {
        // SpoofingRouter has nftContract() == address(nft) but is not the configured hook
        SpoofingRouter spoof = new SpoofingRouter(address(nft));

        vm.prank(address(spoof));
        vm.expectRevert(SceneTracker.OnlyNFTContract.selector);
        tracker.afterNFTTransfer(1, address(0), alice);
    }

    function test_beforeNFTTransfer_rejectsSpoofingContract() public {
        SpoofingRouter spoof = new SpoofingRouter(address(nft));

        vm.prank(address(spoof));
        vm.expectRevert(SceneTracker.OnlyNFTContract.selector);
        tracker.beforeNFTTransfer(1, alice, stranger);
    }

    function test_afterNFTTransfer_rejectsUnconfiguredRouter() public {
        // A new router bound to the same NFT but NOT set as the NFT's transferHook
        TransferHookRouter unconfiguredRouter = new TransferHookRouter(owner, address(nft));
        // nft.transferHook() == address(router), not address(unconfiguredRouter)

        vm.prank(address(unconfiguredRouter));
        vm.expectRevert(SceneTracker.OnlyNFTContract.selector);
        tracker.afterNFTTransfer(1, address(0), alice);
    }

    // ── Full pipeline: NFT → Router → SceneTracker ───────────────────────────

    function test_fullPipeline_nftRouterSceneTracker() public {
        nft.setScene(3, 7);

        // Wire: router hooks include tracker
        address[] memory hooks = new address[](1);
        hooks[0] = address(tracker);
        vm.prank(owner);
        router.setHooks(hooks);

        // Simulate: NFT calls router, router calls SceneTracker.
        // msg.sender seen by SceneTracker is address(router) == nft.transferHook() ✓
        vm.prank(address(nft));
        router.afterNFTTransfer(3, address(0), alice);

        assertEq(tracker.userSceneCounts(alice, 7), 1, unicode"pipeline: NFT→Router→SceneTracker must apply scene");
    }
}
