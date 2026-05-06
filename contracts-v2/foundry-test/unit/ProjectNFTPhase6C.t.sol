// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/nft/ProjectNFTTemplate.sol";
import "../../foundry-src/nft/NubiansNorthNFT.sol";
import "../../foundry-src/nft/TransferHookRouter.sol";
import "../../foundry-src/nft/interfaces/INFTTransferHook.sol";

// ============ RECORDING HOOK ============

/**
 * @dev Records every afterNFTTransfer call and, at callback time, queries
 *      tokenScene(nftId) from the calling NFT contract (msg.sender) to prove
 *      that the scene mapping is populated BEFORE the hook fires.
 */
interface ITokenSceneQuery {
    function tokenScene(uint256 tokenId) external view returns (uint256);
}

contract RecordingHook is INFTTransferHook {
    struct Call {
        uint256 nftId;
        address from;
        address to;
        uint256 sceneAtCallback; // scene queried from the NFT during the callback
    }

    /// @notice The NFT contract to query tokenScene from at callback time.
    ///         Using this instead of msg.sender so the hook works correctly when
    ///         invoked through a TransferHookRouter (where msg.sender is the router).
    address public immutable nft;

    Call[] public afterCalls;
    bool[] public beforeResults; // ordered return values for beforeNFTTransfer
    uint256 private _beforeIdx;

    /// @notice Number of times beforeNFTTransfer has been called
    uint256 public beforeCallCount;

    constructor(address nft_) {
        nft = nft_;
    }

    /// @dev Prime return values; defaults to always returning true when empty
    function queueBeforeResult(bool result) external {
        beforeResults.push(result);
    }

    function beforeNFTTransfer(uint256, address, address) external override returns (bool) {
        beforeCallCount++;
        if (_beforeIdx < beforeResults.length) {
            return beforeResults[_beforeIdx++];
        }
        return true;
    }

    function afterNFTTransfer(uint256 nftId, address from, address to) external override {
        // Query tokenScene from the known NFT contract rather than msg.sender so
        // this hook works correctly when invoked through a TransferHookRouter.
        uint256 scene = 0;
        if (nft != address(0)) {
            try ITokenSceneQuery(nft).tokenScene(nftId) returns (uint256 s) {
                scene = s;
            } catch {}
        }
        afterCalls.push(Call({nftId: nftId, from: from, to: to, sceneAtCallback: scene}));
    }

    function callCount() external view returns (uint256) {
        return afterCalls.length;
    }
}

/**
 * @dev Hook that always blocks transfers (returns false from beforeNFTTransfer).
 */
contract BlockingHook is INFTTransferHook {
    function beforeNFTTransfer(uint256, address, address) external pure override returns (bool) {
        return false;
    }

    function afterNFTTransfer(uint256, address, address) external override {}
}

// ============ PHASE 6C STEP 1 TESTS — ProjectNFTTemplate ============

contract ProjectNFTPhase6CTemplateTest is Test {
    ProjectNFTTemplate public nft;
    RecordingHook public hook;

    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        nft = new ProjectNFTTemplate();
        nft.initialize(1, "Test Project", "TPRJ", owner);

        hook = new RecordingHook(address(nft));

        vm.startPrank(owner);
        nft.setAuthorizedMinter(minter, true);
        nft.setTransferHook(address(hook));
        vm.stopPrank();
    }

    // ── tokenScene canonical interface ─────────────────────────────────────

    function test_tokenScene_revertsOnNonexistentToken() public {
        vm.expectRevert(ProjectNFTTemplate.InvalidTokenId.selector);
        nft.tokenScene(999);
    }

    function test_tokenScene_returnsCorrectScene() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, 42);
        assertEq(nft.tokenScene(tokenId), 42, "tokenScene should return 42");
    }

    function test_tokenScene_widenedToUint256() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, 100);
        // Return type is uint256 — confirm the value is correct and is uint256-compatible
        uint256 scene = nft.tokenScene(tokenId);
        assertEq(scene, 100);
    }

    // ── Hook fires on mint with from == address(0) ─────────────────────────

    function test_mintFiresAfterHookWithZeroFrom() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, 7);

        assertEq(hook.callCount(), 1, "afterNFTTransfer should be called once");

        (uint256 nftId, address from, address to, uint256 _sc) = hook.afterCalls(0);
        assertEq(nftId, tokenId, "hook nftId should match minted tokenId");
        assertEq(from, address(0), "from must be address(0) on mint");
        assertEq(to, recipient, "to must be the recipient");
    }

    // ── tokenScene is populated BEFORE hook fires ──────────────────────────

    function test_tokenSceneCorrectDuringMintHookCallback() public {
        uint16 scene = 55;
        vm.prank(minter);
        nft.mint(recipient, scene);

        assertEq(hook.callCount(), 1, "hook must be called");
        (uint256 _id, address _from, address _to, uint256 sceneAtCallback) = hook.afterCalls(0);
        assertEq(sceneAtCallback, scene, "tokenScene must return correct scene during mint callback");
    }

    // ── Hook fires on transfer (not just mint) ─────────────────────────────

    function test_transferFiresAfterHook() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, 3);

        address newOwner = makeAddr("newOwner");

        vm.prank(recipient);
        nft.transferFrom(recipient, newOwner, tokenId);

        // Two calls: one for mint, one for transfer
        assertEq(hook.callCount(), 2, "afterNFTTransfer should fire on mint AND transfer");

        (uint256 nftId2, address from2, address to2, uint256 _sc3) = hook.afterCalls(1);
        assertEq(nftId2, tokenId);
        assertEq(from2, recipient);
        assertEq(to2, newOwner);
    }

    // ── beforeNFTTransfer loops per token ─────────────────────────────────

    function test_beforeHookBlocksTransfer() public {
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, 10);

        // Replace hook with one that blocks transfers
        BlockingHook blocker = new BlockingHook();
        vm.prank(owner);
        nft.setTransferHook(address(blocker));

        address newOwner = makeAddr("newOwner");
        vm.prank(recipient);
        vm.expectRevert("ProjectNFT: transfer blocked by hook");
        nft.transferFrom(recipient, newOwner, tokenId);
    }

    function test_beforeHookNotCalledOnMint() public {
        // BlockingHook returns false; if it were called on mint, mint would revert
        BlockingHook blocker = new BlockingHook();
        vm.startPrank(owner);
        nft.setTransferHook(address(blocker));
        vm.stopPrank();

        // Must NOT revert — before hook is not called during mint
        vm.prank(minter);
        nft.mint(recipient, 5);
    }

    // ── Multiple mints produce correct hook calls per token ────────────────

    function test_multipleMintsEachFireHookOnce() public {
        vm.startPrank(minter);
        uint256 t1 = nft.mint(recipient, 1);
        uint256 t2 = nft.mint(recipient, 2);
        uint256 t3 = nft.mint(recipient, 3);
        vm.stopPrank();

        assertEq(hook.callCount(), 3, "three mints => three hook calls");

        (uint256 id0, address _from0, address _to0, uint256 sc0) = hook.afterCalls(0);
        (uint256 id1, address _from1, address _to1, uint256 sc1) = hook.afterCalls(1);
        (uint256 id2, address _from2, address _to2, uint256 sc2) = hook.afterCalls(2);

        assertEq(id0, t1);
        assertEq(sc0, 1);
        assertEq(id1, t2);
        assertEq(sc1, 2);
        assertEq(id2, t3);
        assertEq(sc2, 3);
    }
}

// ============ PHASE 6C STEP 1 TESTS — NubiansNorthNFT (batch) ============

contract ProjectNFTPhase6CBatchTest is Test {
    NubiansNorthNFT public nft;
    RecordingHook public hook;

    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        nft = new NubiansNorthNFT();
        nft.initialize();

        hook = new RecordingHook(address(nft));

        nft.setAuthorizedMinter(minter, true);
        nft.setTransferHook(address(hook));
    }

    // ── Batch mint invokes hook once per tokenId ───────────────────────────

    function test_batchMint_hookCalledOncePerToken() public {
        uint256 qty = 5;
        uint16 scene = 77;

        vm.prank(minter);
        nft.mintScene(recipient, scene, qty);

        assertEq(hook.callCount(), qty, "hook must be called once per token in batch");

        (uint256 firstId,,,) = hook.afterCalls(0);
        for (uint256 i = 0; i < qty; i++) {
            (uint256 nftId, address from, address _to, uint256 sceneAtCallback) = hook.afterCalls(i);
            assertEq(nftId, firstId + i, "nftId must be sequential");
            assertEq(from, address(0), "from must be address(0) for all minted tokens");
            assertEq(sceneAtCallback, scene, "tokenScene must be correct for each token at callback time");
        }
    }

    function test_batchMint_fromIsZeroForAllTokens() public {
        vm.prank(minter);
        nft.mintScene(recipient, 10, 3);

        for (uint256 i = 0; i < 3; i++) {
            (uint256 _nftId, address from, address _to, uint256 _sc) = hook.afterCalls(i);
            assertEq(from, address(0), "every minted token must fire with from == address(0)");
        }
    }
}

// ============ PHASE 6C STEP 1 TESTS — TransferHookRouter ============

contract TransferHookRouterTest is Test {
    TransferHookRouter public router;
    RecordingHook public hookA;
    RecordingHook public hookB;

    address internal owner = makeAddr("owner");

    function setUp() public {
        router = new TransferHookRouter(owner, makeAddr("nftAddress"));
        // Router tests verify call routing and ordering; sceneAtCallback is not
        // asserted in these tests, so address(0) is sufficient for the NFT arg.
        hookA = new RecordingHook(address(0));
        hookB = new RecordingHook(address(0));
    }

    // ── setHooks / getHooks ────────────────────────────────────────────────

    function test_setAndGetHooks() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);

        vm.prank(owner);
        router.setHooks(hooks);

        address[] memory stored = router.getHooks();
        assertEq(stored.length, 2);
        assertEq(stored[0], address(hookA));
        assertEq(stored[1], address(hookB));
    }

    function test_setHooks_revertsOnZeroAddress() public {
        address[] memory hooks = new address[](1);
        hooks[0] = address(0);

        vm.prank(owner);
        vm.expectRevert(TransferHookRouter.ZeroAddress.selector);
        router.setHooks(hooks);
    }

    function test_constructor_revertsOnZeroNFTContract() public {
        vm.expectRevert(TransferHookRouter.ZeroAddress.selector);
        new TransferHookRouter(owner, address(0));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(TransferHookRouter.ZeroAddress.selector);
        new TransferHookRouter(address(0), makeAddr("nftAddress"));
    }

    function test_constructor_storesNFTContract() public {
        address nftAddr = makeAddr("someNFT");
        TransferHookRouter r = new TransferHookRouter(owner, nftAddr);
        assertEq(r.nftContract(), nftAddr, "nftContract must be stored immutably");
    }

    function test_setHooks_onlyOwner() public {
        address[] memory hooks = new address[](0);
        vm.expectRevert("Ownable: caller is not the owner");
        router.setHooks(hooks);
    }

    function test_setHooks_replacesExistingList() public {
        address[] memory first = new address[](1);
        first[0] = address(hookA);
        vm.prank(owner);
        router.setHooks(first);

        address[] memory second = new address[](1);
        second[0] = address(hookB);
        vm.prank(owner);
        router.setHooks(second);

        address[] memory stored = router.getHooks();
        assertEq(stored.length, 1);
        assertEq(stored[0], address(hookB));
    }

    // ── afterNFTTransfer routing ───────────────────────────────────────────

    function test_afterNFTTransfer_routesToAllHooks() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);
        vm.prank(owner);
        router.setHooks(hooks);

        address alice = makeAddr("alice");

        // Call router as if we are the NFT contract
        vm.prank(makeAddr("nftAddress"));
        router.afterNFTTransfer(42, address(0), alice);

        assertEq(hookA.callCount(), 1, "hookA must receive afterNFTTransfer");
        assertEq(hookB.callCount(), 1, "hookB must receive afterNFTTransfer");

        (uint256 nftId, address from, address to, uint256 _sc2) = hookA.afterCalls(0);
        assertEq(nftId, 42);
        assertEq(from, address(0));
        assertEq(to, alice);
    }

    function test_afterNFTTransfer_orderPreserved() public {
        // Use a hook that records call index to verify ordering
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);
        vm.prank(owner);
        router.setHooks(hooks);

        vm.prank(makeAddr("nftAddress"));
        router.afterNFTTransfer(1, address(0), makeAddr("bob"));
        vm.prank(makeAddr("nftAddress"));
        router.afterNFTTransfer(2, address(0), makeAddr("bob"));

        // Both hooks should have received calls in order
        assertEq(hookA.callCount(), 2);
        assertEq(hookB.callCount(), 2);

        (uint256 idA0, address _fromA0, address _toA0, uint256 _scA0) = hookA.afterCalls(0);
        (uint256 idA1, address _fromA1, address _toA1, uint256 _scA1) = hookA.afterCalls(1);
        assertEq(idA0, 1);
        assertEq(idA1, 2);
    }

    function test_afterNFTTransfer_emptyHooks_noRevert() public {
        // Router with no hooks should be a no-op
        vm.prank(makeAddr("nftAddress"));
        router.afterNFTTransfer(1, address(0), makeAddr("carol"));
    }

    // ── beforeNFTTransfer routing ──────────────────────────────────────────

    function test_beforeNFTTransfer_returnsTrueWhenAllAllow() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);
        vm.prank(owner);
        router.setHooks(hooks);

        vm.prank(makeAddr("nftAddress"));
        bool result = router.beforeNFTTransfer(1, makeAddr("alice"), makeAddr("bob"));
        assertTrue(result);
    }

    function test_beforeNFTTransfer_returnsFalseOnFirstBlock() public {
        BlockingHook blocker = new BlockingHook();

        address[] memory hooks = new address[](2);
        hooks[0] = address(blocker);
        hooks[1] = address(hookB);
        vm.prank(owner);
        router.setHooks(hooks);

        vm.prank(makeAddr("nftAddress"));
        bool result = router.beforeNFTTransfer(1, makeAddr("alice"), makeAddr("bob"));
        assertFalse(result, "router must return false when first hook blocks");
        // hookB must NOT have been called — short-circuit stops after the first blocking hook
        assertEq(hookB.beforeCallCount(), 0, "hookB.beforeNFTTransfer must not be called after short-circuit");
        assertEq(hookB.callCount(), 0, "hookB.afterNFTTransfer must not be called after short-circuit");
    }

    function test_beforeNFTTransfer_emptyHooks_returnsTrue() public {
        vm.prank(makeAddr("nftAddress"));
        bool result = router.beforeNFTTransfer(1, makeAddr("alice"), makeAddr("bob"));
        assertTrue(result, "empty router should allow all transfers");
    }
}

// ============ PHASE 6C STEP 1 TESTS — Router Integration (NFT → Router → Hook) ============

/**
 * @title ProjectNFTPhase6CRouterIntegrationTest
 * @notice Proves the key Phase 6C invariant: scene mapping is visible at hook callback time
 *         even when the NFT routes through a TransferHookRouter.
 *
 * Setup:
 *   nft.setTransferHook(address(router))
 *   router contains RecordingHook(address(nft))
 *
 * This is the path that SceneTracker + StakingManager will use in production.
 */
contract ProjectNFTPhase6CRouterIntegrationTest is Test {
    ProjectNFTTemplate public nft;
    TransferHookRouter public router;
    RecordingHook public hook;

    address internal nftOwner = makeAddr("nftOwner");
    address internal routerOwner = makeAddr("routerOwner");
    address internal minter = makeAddr("minter");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        // Deploy and initialise NFT
        nft = new ProjectNFTTemplate();
        nft.initialize(1, "Router Integration", "RTST", nftOwner);

        // Deploy router
        router = new TransferHookRouter(routerOwner, address(nft));

        // Deploy RecordingHook that queries the NFT (not msg.sender)
        hook = new RecordingHook(address(nft));

        // Wire: router → hook
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        vm.prank(routerOwner);
        router.setHooks(hooks);

        // Wire: nft → router
        vm.startPrank(nftOwner);
        nft.setAuthorizedMinter(minter, true);
        nft.setTransferHook(address(router));
        vm.stopPrank();
    }

    // ── Core invariant: scene visible at hook time through the router ───────

    /**
     * @notice Proves that _tokenToScene is set before _mint fires, and that this
     *         holds even when the hook is invoked via TransferHookRouter.
     */
    function test_routerPath_sceneCorrectAtMintCallback() public {
        uint16 scene = 33;
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, scene);

        assertEq(hook.callCount(), 1, "hook must be called once through router on mint");

        (uint256 nftId, address from, address to, uint256 sceneAtCallback) = hook.afterCalls(0);
        assertEq(nftId, tokenId, "nftId must match");
        assertEq(from, address(0), "from must be address(0) on mint");
        assertEq(to, recipient, "to must be recipient");
        assertEq(sceneAtCallback, scene, "scene must be correct at callback time even through router");
    }

    function test_routerPath_mintHookFromIsZero() public {
        vm.prank(minter);
        nft.mint(recipient, 88);

        (uint256 _nftId, address from, address _to, uint256 _sc) = hook.afterCalls(0);
        assertEq(from, address(0), "from must be address(0) for mint routed through TransferHookRouter");
    }

    function test_routerPath_transferSceneCorrect() public {
        uint16 scene = 12;
        vm.prank(minter);
        uint256 tokenId = nft.mint(recipient, scene);

        address newOwner = makeAddr("newOwner");
        vm.prank(recipient);
        nft.transferFrom(recipient, newOwner, tokenId);

        // Two hook calls through router: mint + transfer
        assertEq(hook.callCount(), 2, "hook must fire on both mint and transfer through router");

        (uint256 nftId2, address from2, address to2, uint256 sceneAtTransfer) = hook.afterCalls(1);
        assertEq(nftId2, tokenId);
        assertEq(from2, recipient);
        assertEq(to2, newOwner);
        assertEq(sceneAtTransfer, scene, "scene must be correct at transfer callback through router");
    }
}
