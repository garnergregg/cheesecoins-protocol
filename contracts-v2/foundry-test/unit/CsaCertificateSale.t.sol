// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../foundry-src/commerce/CsaCertificateSale.sol";
import "../../foundry-src/platform/interfaces/IProjectRegistry.sol";
import "../../foundry-src/nft/extensions/SceneTracker.sol";
import "../../foundry-src/nft/interfaces/INFTTransferHook.sol";

// ============ MOCKS ============

/// @dev Minimal ERC20 with public mint for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal IProjectRegistry mock
contract MockProjectRegistry {
    mapping(uint256 => address) public nftAddresses;
    mapping(uint256 => address) public operatorWallets;
    mapping(uint256 => bool) public payoutsDisabled;

    function setProjectNFT(uint256 projectId, address nft) external {
        nftAddresses[projectId] = nft;
    }

    function setOperatorWallet(uint256 projectId, address wallet) external {
        operatorWallets[projectId] = wallet;
    }

    function setPayoutsEnabled(uint256 projectId, bool enabled) external {
        payoutsDisabled[projectId] = !enabled;
    }

    function getProject(uint256 projectId) external view returns (IProjectRegistry.Project memory) {
        IProjectRegistry.Project memory p;
        p.id = projectId;
        p.nftAddress = nftAddresses[projectId];
        p.active = true;
        return p;
    }

    function getOperatorWallet(uint256 projectId) external view returns (address) {
        return operatorWallets[projectId];
    }

    function isPayoutsEnabled(uint256 projectId) external view returns (bool) {
        return !payoutsDisabled[projectId];
    }
}

/**
 * @dev Scene-aware NFT mock.
 *      - Tracks mintedPerScene and per-token scene via tokenScene mapping.
 *      - Enforces SCENE_MAX_SUPPLY (500) per scene.
 *      - Calls INFTTransferHook.afterNFTTransfer for every minted token
 *        so SceneTracker tests work correctly.
 */
contract MockSceneNFT {
    uint16 public constant TOTAL_SCENES = 100;
    uint256 public constant SCENE_MAX_SUPPLY = 500;

    mapping(address => bool) public authorizedMinters;
    mapping(uint16 => uint256) public mintedPerScene;
    mapping(uint256 => uint16) public tokenScene;
    uint256 public nextTokenId = 1;
    address public owner;
    INFTTransferHook public transferHook;

    error UnauthorizedMinter();
    error SceneCapReached(uint16 scene, uint256 cap);
    error InvalidSceneNumber();
    error InvalidQuantity();

    constructor(address _owner) {
        owner = _owner;
    }

    function setAuthorizedMinter(address minter, bool authorized) external {
        require(msg.sender == owner, "not owner");
        authorizedMinters[minter] = authorized;
    }

    function setTransferHook(address hook) external {
        require(msg.sender == owner, "not owner");
        transferHook = INFTTransferHook(hook);
    }

    function mintScene(address to, uint16 sceneNumber, uint256 quantity) external returns (uint256 firstTokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (quantity == 0) revert InvalidQuantity();
        if (mintedPerScene[sceneNumber] + quantity > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }

        firstTokenId = nextTokenId;
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tid = nextTokenId++;
            tokenScene[tid] = sceneNumber;
            // Call hook for SceneTracker (from == address(0) signals mint)
            if (address(transferHook) != address(0)) {
                transferHook.afterNFTTransfer(tid, address(0), to);
            }
        }
        mintedPerScene[sceneNumber] += quantity;
    }

    // Legacy single-copy shim (used by tests that call mint directly)
    function mint(address to, uint16 sceneNumber) external returns (uint256 tokenId) {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        if (sceneNumber == 0 || sceneNumber > TOTAL_SCENES) revert InvalidSceneNumber();
        if (mintedPerScene[sceneNumber] + 1 > SCENE_MAX_SUPPLY) {
            revert SceneCapReached(sceneNumber, SCENE_MAX_SUPPLY);
        }
        tokenId = nextTokenId++;
        tokenScene[tokenId] = sceneNumber;
        mintedPerScene[sceneNumber] += 1;
        if (address(transferHook) != address(0)) {
            transferHook.afterNFTTransfer(tokenId, address(0), to);
        }
    }
}

// ============ TEST CONTRACT ============

/**
 * @title CsaCertificateSaleTest
 * @notice Unit tests for CsaCertificateSale + SceneTracker (scene economics)
 */
contract CsaCertificateSaleTest is Test {
    CsaCertificateSale public sale;
    MockProjectRegistry public registry;
    MockSceneNFT public nft;
    MockERC20 public curd;
    MockERC20 public usdc;
    SceneTracker public tracker;

    address public owner;
    address public treasury;
    address public operator;
    address public buyer;
    address public recipient;

    uint256 public constant PROJECT_ID = 1;
    uint16 public constant SCENE = 7;
    uint256 public constant PRICE_CURD = 100e18;
    uint256 public constant PRICE_USDC6 = 100e6;

    // ── Events ──────────────────────────────────────────────
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PaymentSplit(
        uint256 indexed projectId,
        address token,
        uint256 total,
        uint256 feeToTreasury,
        uint256 payoutToProject,
        address payoutWallet
    );
    event CertificatePurchasedWithCURD(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed buyer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid,
        bytes32 invoiceId
    );
    event CertificatePurchasedWithUSDC(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed buyer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid,
        bytes32 invoiceId
    );
    event CertificateAdminMinted(
        uint256 indexed projectId,
        uint16 sceneNumber,
        address indexed to,
        uint256 quantity,
        bytes32 referenceId,
        string reason
    );
    event SuperHolderStatusChanged(address indexed user, bool isSuper);
    event SceneMintEnabled(uint256 indexed sceneId, bool enabled);
    event AdminMint(address indexed to, uint256 indexed sceneNumber, uint256 quantity);

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        operator = makeAddr("operator");
        buyer = makeAddr("buyer");
        recipient = makeAddr("recipient");

        // Tokens
        curd = new MockERC20("Cheesecoins CURD", "CURD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Registry + NFT
        registry = new MockProjectRegistry();
        nft = new MockSceneNFT(owner);
        registry.setProjectNFT(PROJECT_ID, address(nft));

        // SceneTracker (hook)
        tracker = new SceneTracker(owner, address(nft));
        nft.setTransferHook(address(tracker));

        // Sale contract
        sale = new CsaCertificateSale(
            owner, treasury, address(registry), address(curd), address(usdc), PRICE_CURD, PRICE_USDC6
        );

        // Authorize sale as NFT minter
        nft.setAuthorizedMinter(address(sale), true);

        // Enable the default test scene so existing purchase tests pass
        sale.setSceneMintEnabled(SCENE, true);

        // Fund buyer
        curd.mint(buyer, 100_000e18);
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        curd.approve(address(sale), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(sale), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════
    // SCENE MINTING MECHANICS
    // ══════════════════════════════════════════════════════

    /// @dev mintedPerScene increments correctly and tokenScene is set for every token
    function testSceneMinting_TracksPerSceneCountsAndTokenScene() public {
        uint256 qty = 3;
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32(0));

        assertEq(nft.mintedPerScene(SCENE), qty, "mintedPerScene should be qty");
        // Tokens 1,2,3 were minted (nextTokenId started at 1)
        assertEq(nft.tokenScene(1), SCENE, "tokenScene[1] should be SCENE");
        assertEq(nft.tokenScene(2), SCENE, "tokenScene[2] should be SCENE");
        assertEq(nft.tokenScene(3), SCENE, "tokenScene[3] should be SCENE");
    }

    /// @dev Per-scene cap: 500 copies succeeds, 1 more reverts
    function testSceneMinting_EnforcesPerSceneCap() public {
        uint256 cap = nft.SCENE_MAX_SUPPLY(); // 500
        // Authorize owner to mint directly on NFT for this test
        nft.setAuthorizedMinter(owner, true);

        // Mint exactly 500 copies of scene 5 directly
        nft.mintScene(recipient, 5, cap);
        assertEq(nft.mintedPerScene(5), cap, "should be fully minted");

        // One more should revert
        vm.expectRevert(abi.encodeWithSelector(MockSceneNFT.SceneCapReached.selector, uint16(5), cap));
        nft.mintScene(recipient, 5, 1);
    }

    // ══════════════════════════════════════════════════════
    // SALE: EXPLICIT SCENE SELECTION
    // ══════════════════════════════════════════════════════

    /// @dev Buying scene 7 qty 3 mints 3 tokens all tagged scene 7
    function testBuyWithCURD_MintsExplicitScene() public {
        uint16 scene = 7;
        uint256 qty = 3;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, scene, qty, recipient, bytes32("INV-SCENE"));

        assertEq(nft.mintedPerScene(scene), qty, "mintedPerScene[7] should be 3");
        for (uint256 i = 1; i <= qty; i++) {
            assertEq(nft.tokenScene(i), scene, "All minted tokens must be tagged scene 7");
        }
    }

    // ══════════════════════════════════════════════════════
    // PAYMENT ROUTING: CURD
    // ══════════════════════════════════════════════════════

    function testBuyWithCURD_SplitsCorrectly_WhenOperatorAndPayoutsEnabled() public {
        registry.setOperatorWallet(PROJECT_ID, operator);

        uint256 qty = 1;
        uint256 total = PRICE_CURD * qty;
        uint256 expectedFee = (total * 1000) / 10_000;
        uint256 expectedPayout = total - expectedFee;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-001"));

        assertEq(curd.balanceOf(treasury), expectedFee, "Treasury should receive 10%");
        assertEq(curd.balanceOf(operator), expectedPayout, "Operator should receive 90%");
    }

    function testBuyWithCURD_MultipleQty_SplitsAndMintsAll() public {
        registry.setOperatorWallet(PROJECT_ID, operator);

        uint256 qty = 3;
        uint256 total = PRICE_CURD * qty;
        uint256 expectedFee = (total * 1000) / 10_000;
        uint256 expectedPayout = total - expectedFee;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-002"));

        assertEq(curd.balanceOf(treasury), expectedFee, "Treasury 10% of total");
        assertEq(curd.balanceOf(operator), expectedPayout, "Operator 90% of total");
        assertEq(nft.mintedPerScene(SCENE), qty, "Should have minted qty tokens");
    }

    function testBuyWithCURD_RoutesAllToTreasury_WhenOperatorUnset() public {
        uint256 qty = 2;
        uint256 total = PRICE_CURD * qty;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-003"));

        assertEq(curd.balanceOf(treasury), total, "Treasury should receive 100%");
        assertEq(curd.balanceOf(operator), 0, "Operator should receive nothing");
    }

    function testBuyWithCURD_RoutesAllToTreasury_WhenPayoutsDisabled() public {
        registry.setOperatorWallet(PROJECT_ID, operator);
        registry.setPayoutsEnabled(PROJECT_ID, false);

        uint256 qty = 1;
        uint256 total = PRICE_CURD * qty;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-004"));

        assertEq(curd.balanceOf(treasury), total, "100% to treasury when payouts disabled");
        assertEq(curd.balanceOf(operator), 0, "Operator gets nothing when payouts disabled");
    }

    // ══════════════════════════════════════════════════════
    // PAYMENT ROUTING: USDC (6 decimals)
    // ══════════════════════════════════════════════════════

    function testBuyWithUSDC_SplitsCorrectly_WithSixDecimals() public {
        registry.setOperatorWallet(PROJECT_ID, operator);

        uint256 qty = 2;
        uint256 total = PRICE_USDC6 * qty; // 200e6
        uint256 expectedFee = (total * 1000) / 10_000; // 20e6
        uint256 expectedPayout = total - expectedFee; // 180e6

        vm.prank(buyer);
        sale.buyWithUSDC(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-005"));

        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury should receive 10% USDC");
        assertEq(usdc.balanceOf(operator), expectedPayout, "Operator should receive 90% USDC");
    }

    function testBuyWithUSDC_RoutesAllToTreasury_WhenOperatorUnset() public {
        uint256 qty = 1;
        uint256 total = PRICE_USDC6 * qty;

        vm.prank(buyer);
        sale.buyWithUSDC(PROJECT_ID, SCENE, qty, recipient, bytes32("INV-006"));

        assertEq(usdc.balanceOf(treasury), total, "Treasury should receive 100% USDC");
    }

    // ══════════════════════════════════════════════════════
    // setProtocolFeeBps
    // ══════════════════════════════════════════════════════

    function testSetProtocolFeeBps_UpdatesAndEmitsEvent() public {
        uint256 newFee = 500;
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(1000, newFee);
        sale.setProtocolFeeBps(newFee);
        assertEq(sale.protocolFeeBps(), newFee);
    }

    function testSetProtocolFeeBps_AllowsZero() public {
        sale.setProtocolFeeBps(0);
        assertEq(sale.protocolFeeBps(), 0);
    }

    function testSetProtocolFeeBps_AllowsMaximum() public {
        sale.setProtocolFeeBps(2000);
        assertEq(sale.protocolFeeBps(), 2000);
    }

    function testSetProtocolFeeBps_RevertsAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(CsaCertificateSale.FeeTooHigh.selector, 2001, 2000));
        sale.setProtocolFeeBps(2001);
    }

    function testSetProtocolFeeBps_RevertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.setProtocolFeeBps(500);
    }

    // ══════════════════════════════════════════════════════
    // adminMint
    // ══════════════════════════════════════════════════════

    function testAdminMint_MintsAndEmitsEvent() public {
        uint256 qty = 2;
        bytes32 refId = bytes32("REF-001");
        string memory reason = "Grant for community member";

        vm.expectEmit(true, false, true, true);
        emit CertificateAdminMinted(PROJECT_ID, SCENE, treasury, qty, refId, reason);

        sale.adminMint(PROJECT_ID, SCENE, qty, treasury, refId, reason);

        assertEq(nft.mintedPerScene(SCENE), qty, "adminMint should have minted qty tokens");
    }

    function testAdminMint_RevertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.adminMint(PROJECT_ID, SCENE, 1, recipient, bytes32(0), "test");
    }

    function testAdminMint_RevertsForNonAllowedAddress() public {
        vm.expectRevert("ADMIN_MINT_RESTRICTED");
        sale.adminMint(PROJECT_ID, SCENE, 1, address(0), bytes32(0), "test");
    }

    function testAdminMint_RevertsForZeroQty() public {
        vm.expectRevert(CsaCertificateSale.ZeroQuantity.selector);
        sale.adminMint(PROJECT_ID, SCENE, 0, recipient, bytes32(0), "test");
    }

    // ══════════════════════════════════════════════════════
    // Purchase validation
    // ══════════════════════════════════════════════════════

    function testBuyWithCURD_RevertsForZeroQty() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.ZeroQuantity.selector);
        sale.buyWithCURD(PROJECT_ID, SCENE, 0, recipient, bytes32(0));
    }

    function testBuyWithCURD_RevertsForZeroRecipient() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.ZeroRecipient.selector);
        sale.buyWithCURD(PROJECT_ID, SCENE, 1, address(0), bytes32(0));
    }

    function testBuyWithUSDC_RevertsForZeroQty() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.ZeroQuantity.selector);
        sale.buyWithUSDC(PROJECT_ID, SCENE, 0, recipient, bytes32(0));
    }

    // ══════════════════════════════════════════════════════
    // Events
    // ══════════════════════════════════════════════════════

    function testBuyWithCURD_EmitsPurchaseEvent() public {
        registry.setOperatorWallet(PROJECT_ID, operator);
        uint256 qty = 1;
        uint256 total = PRICE_CURD * qty;
        bytes32 invoiceId = bytes32("INV-EVT");

        vm.expectEmit(true, false, true, true);
        emit CertificatePurchasedWithCURD(PROJECT_ID, SCENE, buyer, recipient, qty, total, invoiceId);

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, invoiceId);
    }

    function testBuyWithUSDC_EmitsPurchaseEvent() public {
        uint256 qty = 1;
        uint256 total = PRICE_USDC6 * qty;
        bytes32 invoiceId = bytes32("INV-EVT-USDC");

        vm.expectEmit(true, false, true, true);
        emit CertificatePurchasedWithUSDC(PROJECT_ID, SCENE, buyer, recipient, qty, total, invoiceId);

        vm.prank(buyer);
        sale.buyWithUSDC(PROJECT_ID, SCENE, qty, recipient, invoiceId);
    }

    // ══════════════════════════════════════════════════════
    // Custom fee rate
    // ══════════════════════════════════════════════════════

    function testBuyWithCURD_UsesCustomFeeRate() public {
        registry.setOperatorWallet(PROJECT_ID, operator);
        sale.setProtocolFeeBps(500); // 5%

        uint256 qty = 1;
        uint256 total = PRICE_CURD * qty;
        uint256 expectedFee = (total * 500) / 10_000;
        uint256 expectedPayout = total - expectedFee;

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, qty, recipient, bytes32(0));

        assertEq(curd.balanceOf(treasury), expectedFee, "Treasury should receive 5%");
        assertEq(curd.balanceOf(operator), expectedPayout, "Operator should receive 95%");
    }

    // ══════════════════════════════════════════════════════
    // sweepToken
    // ══════════════════════════════════════════════════════

    function testSweepToken_TransfersToRecipient() public {
        curd.mint(address(sale), 500e18);
        uint256 before = curd.balanceOf(owner);
        sale.sweepToken(IERC20(address(curd)), owner, 500e18);
        assertEq(curd.balanceOf(owner), before + 500e18);
    }

    function testSweepToken_RevertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.sweepToken(IERC20(address(curd)), buyer, 1e18);
    }

    // ══════════════════════════════════════════════════════
    // Constructor validation
    // ══════════════════════════════════════════════════════

    function testConstructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(CsaCertificateSale.ZeroAddress.selector);
        new CsaCertificateSale(
            owner, address(0), address(registry), address(curd), address(usdc), PRICE_CURD, PRICE_USDC6
        );
    }

    function testConstructor_RevertsOnZeroPrice() public {
        vm.expectRevert(CsaCertificateSale.ZeroAmount.selector);
        new CsaCertificateSale(owner, treasury, address(registry), address(curd), address(usdc), 0, PRICE_USDC6);
    }

    // ══════════════════════════════════════════════════════
    // SUPER HOLDER MECHANICS
    // ══════════════════════════════════════════════════════

    /**
     * @dev Simulate a user acquiring 1 token from each of scenes 1..100.
     *      The SceneTracker hook fires on every mintScene call (from==address(0)).
     *      After 100 distinct scenes are minted to `collector`, hasFullCollection must be true.
     */
    function testSuperHolder_HasFullCollection_AfterAllScenes() public {
        address collector = makeAddr("collector");

        // Authorize owner to mint directly on NFT for this test
        nft.setAuthorizedMinter(owner, true);

        for (uint16 scene = 1; scene <= 100; scene++) {
            nft.mintScene(collector, scene, 1);
        }

        assertTrue(tracker.hasFullCollection(collector), "Collector should have full collection");
    }

    /**
     * @dev Transferring away all tokens of a scene removes Super Holder status.
     */
    function testSuperHolder_LostAfterTransferringLastTokenOfAScene() public {
        address collector = makeAddr("collector2");
        address other = makeAddr("other");

        nft.setAuthorizedMinter(owner, true);

        // Collect all 100 scenes
        for (uint16 scene = 1; scene <= 100; scene++) {
            nft.mintScene(collector, scene, 1);
        }
        assertTrue(tracker.hasFullCollection(collector), "Should have full collection before transfer");

        // Check scene 1 token ID = 1 (mintScene starts at nextTokenId=1)
        assertEq(nft.tokenScene(1), 1, "Token 1 should be scene 1");

        // Simulate transfer of token #1 (scene 1) by calling hook directly as nft
        vm.prank(address(nft));
        tracker.afterNFTTransfer(1, collector, other);

        assertFalse(tracker.hasFullCollection(collector), "Should lose super holder after transfer");
        assertEq(tracker.getUserSceneCount(collector, 1), 0, "Scene 1 count should be 0");
        assertEq(tracker.getUserSceneCount(other, 1), 1, "Other should have scene 1");
    }

    /**
     * @dev SceneTracker accumulates counts when user holds multiple copies of same scene.
     */
    function testSuperHolder_MultipleTokensSameScene_CountsAccumulate() public {
        address collector = makeAddr("collector3");
        nft.setAuthorizedMinter(owner, true);

        nft.mintScene(collector, 1, 3); // 3 copies of scene 1

        assertEq(tracker.getUserSceneCount(collector, 1), 3, "Should count 3 copies of scene 1");
        assertFalse(tracker.hasFullCollection(collector), "Only has scene 1, not all 100");
    }

    /**
     * @dev SceneTracker: bit is cleared only when count reaches 0 (not just decremented).
     */
    function testSuperHolder_BitClearedOnlyWhenCountReachesZero() public {
        address collector = makeAddr("collector4");
        nft.setAuthorizedMinter(owner, true);

        nft.mintScene(collector, 1, 2); // 2 tokens of scene 1

        // Transfer one away
        vm.prank(address(nft));
        tracker.afterNFTTransfer(1, collector, makeAddr("x"));

        assertEq(tracker.getUserSceneCount(collector, 1), 1, "Should still have 1 copy");
        uint256 bitmask = tracker.getSceneBitmask(collector);
        assertTrue((bitmask & 1) == 1, "Bit 0 (scene 1) should still be set");

        // Transfer second one away
        vm.prank(address(nft));
        tracker.afterNFTTransfer(2, collector, makeAddr("y"));

        assertEq(tracker.getUserSceneCount(collector, 1), 0, "Should have 0 copies");
        bitmask = tracker.getSceneBitmask(collector);
        assertTrue((bitmask & 1) == 0, "Bit 0 should be cleared now");
    }

    /**
     * @dev SuperHolderStatusChanged event fires when user completes or loses collection.
     */
    function testSuperHolder_EmitsSuperHolderStatusChangedOnCompletion() public {
        address collector = makeAddr("collector5");
        nft.setAuthorizedMinter(owner, true);

        // Mint scenes 1..99
        for (uint16 scene = 1; scene <= 99; scene++) {
            nft.mintScene(collector, scene, 1);
        }
        assertFalse(tracker.hasFullCollection(collector));

        // Minting scene 100 should emit SuperHolderStatusChanged(collector, true)
        vm.expectEmit(true, false, false, true);
        emit SuperHolderStatusChanged(collector, true);
        nft.mintScene(collector, 100, 1);

        assertTrue(tracker.hasFullCollection(collector));
    }

    // ══════════════════════════════════════════════════════
    // HOOK ORDERING REGRESSION — scene must be readable at hook-call time
    // ══════════════════════════════════════════════════════

    /**
     * @dev Regression: verifies that the hook receives the correct non-zero scene
     *      at the moment it fires, i.e. tokenScene is populated BEFORE the hook call.
     *      In MockSceneNFT this ordering is explicit. For NubiansNorthNFT the equivalent
     *      fix is setting tokenScene before _mint() (see mintScene/mint implementations).
     *
     *      Asserts BOTH:
     *        (1) SceneTracker recorded the correct scene (count + bitmask) — proves hook
     *            read a non-zero scene and did not hit the "scene==0, skip" guard.
     *        (2) tokenScene[tokenId] == sceneNumber — proves _nextTokenId() was used
     *            correctly and the mapping covers exactly the minted ID.
     */
    function testHookOrdering_SceneTrackerReceivesCorrectSceneOnMint() public {
        address collector = makeAddr("hookOrderCollector");
        nft.setAuthorizedMinter(owner, true);

        // Mint scene 42 qty 1; first token ID starts at 1 (MockSceneNFT.nextTokenId)
        uint256 firstId = nft.nextTokenId(); // capture before mint
        nft.mintScene(collector, 42, 1);

        // (1) SceneTracker must have recorded scene 42 immediately at hook-fire time
        assertEq(tracker.getUserSceneCount(collector, 42), 1, "SceneTracker must see scene 42 at hook-fire time");
        uint256 bitmask = tracker.getSceneBitmask(collector);
        uint256 expectedBit = uint256(1) << (42 - 1);
        assertTrue((bitmask & expectedBit) != 0, "Bit for scene 42 must be set immediately after mint");

        // (2) tokenScene mapping must contain the correct scene for the minted token ID
        assertEq(nft.tokenScene(firstId), 42, "tokenScene[firstId] must equal 42 (non-zero, correct scene)");
    }

    /**
     * @dev Same ordering check for batch mint (qty > 1): every token in the batch must
     *      (1) be correctly registered with SceneTracker, AND
     *      (2) have tokenScene[tokenId] == sceneNumber for each individual token.
     */
    function testHookOrdering_BatchMint_AllTokensTrackedCorrectly() public {
        address collector = makeAddr("hookBatchCollector");
        nft.setAuthorizedMinter(owner, true);

        uint256 qty = 5;
        uint256 firstId = nft.nextTokenId(); // capture before mint
        nft.mintScene(collector, 55, qty);

        // (1) SceneTracker count and bitmask
        assertEq(tracker.getUserSceneCount(collector, 55), qty, "All batch tokens must be tracked");
        uint256 bitmask = tracker.getSceneBitmask(collector);
        uint256 expectedBit = uint256(1) << (55 - 1);
        assertTrue((bitmask & expectedBit) != 0, "Bit for scene 55 must be set after batch mint");

        // (2) Every individual tokenId in the batch must map to scene 55
        for (uint256 i = 0; i < qty; i++) {
            assertEq(
                nft.tokenScene(firstId + i),
                55,
                "Each token in batch must have tokenScene == 55 (non-zero, correct scene)"
            );
        }
    }

    // ══════════════════════════════════════════════════════
    // SALE: SCENE VALIDATION (fast-fail before NFT call)
    // ══════════════════════════════════════════════════════

    function testBuyWithCURD_RevertsForSceneZero() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.InvalidScene.selector);
        sale.buyWithCURD(PROJECT_ID, 0, 1, recipient, bytes32(0));
    }

    function testBuyWithCURD_RevertsForSceneAbove100() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.InvalidScene.selector);
        sale.buyWithCURD(PROJECT_ID, 101, 1, recipient, bytes32(0));
    }

    function testBuyWithUSDC_RevertsForInvalidScene() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.InvalidScene.selector);
        sale.buyWithUSDC(PROJECT_ID, 0, 1, recipient, bytes32(0));
    }

    function testAdminMint_RevertsForInvalidScene() public {
        vm.expectRevert(CsaCertificateSale.InvalidScene.selector);
        sale.adminMint(PROJECT_ID, 101, 1, treasury, bytes32(0), "test");
    }

    // ══════════════════════════════════════════════════════
    // adminMint — ADMIN_MINT_RESTRICTED destination check
    // ══════════════════════════════════════════════════════

    /// @dev adminMint to a random address reverts with ADMIN_MINT_RESTRICTED
    function testAdminMint_RevertsForRandomAddress() public {
        address randomAddr = makeAddr("randomWallet");
        vm.expectRevert("ADMIN_MINT_RESTRICTED");
        sale.adminMint(PROJECT_ID, SCENE, 1, randomAddr, bytes32(0), "test");
    }

    /// @dev adminMint to treasury succeeds and emits both events
    function testAdminMint_ToTreasury_Succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit AdminMint(treasury, uint256(SCENE), 1);
        sale.adminMint(PROJECT_ID, SCENE, 1, treasury, bytes32(0), "treasury grant");
        assertEq(nft.mintedPerScene(SCENE), 1, "Should have minted 1 token for treasury");
    }

    /// @dev adminMint to owner() succeeds and emits both events
    function testAdminMint_ToOwner_Succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit AdminMint(owner, uint256(SCENE), 1);
        sale.adminMint(PROJECT_ID, SCENE, 1, owner, bytes32(0), "owner grant");
        assertEq(nft.mintedPerScene(SCENE), 1, "Should have minted 1 token for owner");
    }

    // ══════════════════════════════════════════════════════
    // INVALID_SCENE — explicit bounds on USDC path
    // ══════════════════════════════════════════════════════

    /// @dev buyWithUSDC with scene 101 reverts INVALID_SCENE
    function testBuyWithUSDC_RevertsForSceneAbove100() public {
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.InvalidScene.selector);
        sale.buyWithUSDC(PROJECT_ID, 101, 1, recipient, bytes32(0));
    }

    // ══════════════════════════════════════════════════════
    // SCENE GATING (wave/staged release)
    // ══════════════════════════════════════════════════════

    /// @dev Purchase reverts when the scene has not been enabled yet
    function testBuyWithCURD_RevertsWhenSceneNotLive() public {
        uint16 disabledScene = 42;
        // scene 42 is disabled by default
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.SceneNotLive.selector);
        sale.buyWithCURD(PROJECT_ID, disabledScene, 1, recipient, bytes32(0));
    }

    /// @dev Purchase succeeds after owner enables the scene
    function testBuyWithCURD_SucceedsAfterSceneEnabled() public {
        uint16 newScene = 42;
        sale.setSceneMintEnabled(newScene, true);

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, newScene, 1, recipient, bytes32(0));

        assertEq(nft.mintedPerScene(newScene), 1, "Scene 42 should have 1 minted token");
    }

    /// @dev USDC purchase reverts when scene not live
    function testBuyWithUSDC_RevertsWhenSceneNotLive() public {
        uint16 disabledScene = 50;
        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.SceneNotLive.selector);
        sale.buyWithUSDC(PROJECT_ID, disabledScene, 1, recipient, bytes32(0));
    }

    /// @dev USDC purchase succeeds after scene is enabled
    function testBuyWithUSDC_SucceedsAfterSceneEnabled() public {
        uint16 newScene = 50;
        sale.setSceneMintEnabled(newScene, true);

        vm.prank(buyer);
        sale.buyWithUSDC(PROJECT_ID, newScene, 1, recipient, bytes32(0));

        assertEq(nft.mintedPerScene(newScene), 1, "Scene 50 should have 1 minted token");
    }

    /// @dev setSceneMintEnabled emits SceneMintEnabled event
    function testSetSceneMintEnabled_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit SceneMintEnabled(33, true);
        sale.setSceneMintEnabled(33, true);
        assertTrue(sale.sceneMintEnabled(33), "Scene 33 should be enabled");
    }

    /// @dev setSceneMintEnabled can disable an already-enabled scene
    function testSetSceneMintEnabled_CanDisableScene() public {
        sale.setSceneMintEnabled(SCENE, false);
        assertFalse(sale.sceneMintEnabled(SCENE), "Scene should be disabled");

        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.SceneNotLive.selector);
        sale.buyWithCURD(PROJECT_ID, SCENE, 1, recipient, bytes32(0));
    }

    /// @dev setSceneMintEnabled reverts for non-owner
    function testSetSceneMintEnabled_RevertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.setSceneMintEnabled(1, true);
    }

    /// @dev setSceneMintEnabledBatch enables multiple scenes and emits events for each
    function testSetSceneMintEnabledBatch_EnablesMultipleScenes() public {
        uint256[] memory scenes = new uint256[](3);
        scenes[0] = 10;
        scenes[1] = 20;
        scenes[2] = 30;

        sale.setSceneMintEnabledBatch(scenes, true);

        assertTrue(sale.sceneMintEnabled(10), "Scene 10 should be enabled");
        assertTrue(sale.sceneMintEnabled(20), "Scene 20 should be enabled");
        assertTrue(sale.sceneMintEnabled(30), "Scene 30 should be enabled");
    }

    /// @dev setSceneMintEnabledBatch emits SceneMintEnabled for each scene
    function testSetSceneMintEnabledBatch_EmitsEventsForEachScene() public {
        uint256[] memory scenes = new uint256[](2);
        scenes[0] = 11;
        scenes[1] = 22;

        vm.expectEmit(true, false, false, true);
        emit SceneMintEnabled(11, true);
        vm.expectEmit(true, false, false, true);
        emit SceneMintEnabled(22, true);
        sale.setSceneMintEnabledBatch(scenes, true);
    }

    /// @dev setSceneMintEnabledBatch reverts for non-owner
    function testSetSceneMintEnabledBatch_RevertsForNonOwner() public {
        uint256[] memory scenes = new uint256[](1);
        scenes[0] = 1;
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        sale.setSceneMintEnabledBatch(scenes, true);
    }

    // ══════════════════════════════════════════════════════
    // PER-WALLET-PER-SCENE MINT CAP
    // ══════════════════════════════════════════════════════

    /// @dev Minting exactly MAX_MINT_PER_WALLET_PER_SCENE (5) succeeds
    function testMintCap_ExactlyFiveSucceeds() public {
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 5, recipient, bytes32(0));

        assertEq(sale.mintedBy(buyer, SCENE), 5, "mintedBy should be 5 after buying 5");
        assertEq(nft.mintedPerScene(SCENE), 5, "NFT should have 5 minted for scene");
    }

    /// @dev Minting 1 more after the cap of 5 reverts with SCENE_MINT_CAP
    function testMintCap_SixthMintRevertsWithSceneMintCap() public {
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 5, recipient, bytes32(0));

        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.SceneMintCapExceeded.selector);
        sale.buyWithCURD(PROJECT_ID, SCENE, 1, recipient, bytes32(0));
    }

    /// @dev Cap applies per scene; minting 5 of scene X and 5 of scene Y both succeed
    function testMintCap_IsPerScene_DifferentScenesAreIndependent() public {
        uint16 sceneX = SCENE; // 7, already enabled
        uint16 sceneY = 8;
        sale.setSceneMintEnabled(sceneY, true);

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, sceneX, 5, recipient, bytes32(0));

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, sceneY, 5, recipient, bytes32(0));

        assertEq(sale.mintedBy(buyer, sceneX), 5, "mintedBy for sceneX should be 5");
        assertEq(sale.mintedBy(buyer, sceneY), 5, "mintedBy for sceneY should be 5");
    }

    /// @dev Cap is per wallet; a different buyer can still mint up to 5
    function testMintCap_IsPerWallet_DifferentBuyersHaveIndependentCaps() public {
        address buyer2 = makeAddr("buyer2");
        curd.mint(buyer2, 100_000e18);
        vm.prank(buyer2);
        curd.approve(address(sale), type(uint256).max);

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 5, recipient, bytes32(0));

        // buyer2 can still mint 5 for the same scene
        vm.prank(buyer2);
        sale.buyWithCURD(PROJECT_ID, SCENE, 5, recipient, bytes32(0));

        assertEq(sale.mintedBy(buyer, SCENE), 5, "buyer mintedBy should be 5");
        assertEq(sale.mintedBy(buyer2, SCENE), 5, "buyer2 mintedBy should be 5");
    }

    /// @dev SCENE_MINT_CAP also enforced on buyWithUSDC
    function testMintCap_EnforcedOnBuyWithUSDC() public {
        vm.prank(buyer);
        sale.buyWithUSDC(PROJECT_ID, SCENE, 5, recipient, bytes32(0));

        vm.prank(buyer);
        vm.expectRevert(CsaCertificateSale.SceneMintCapExceeded.selector);
        sale.buyWithUSDC(PROJECT_ID, SCENE, 1, recipient, bytes32(0));
    }

    /// @dev Cap is not enforced in adminMint (restricted to treasury/owner, but no qty limit)
    function testMintCap_NotEnforcedInAdminMint() public {
        sale.adminMint(PROJECT_ID, SCENE, 10, treasury, bytes32(0), "grant");
        assertEq(nft.mintedPerScene(SCENE), 10, "adminMint should bypass the cap");
    }

    // ══════════════════════════════════════════════════════
    // COUNTER CORRECTNESS — mintedBy view
    // ══════════════════════════════════════════════════════

    /// @dev mintedBy returns 0 before any purchase
    function testMintedBy_ReturnsZeroInitially() public {
        assertEq(sale.mintedBy(buyer, SCENE), 0, "mintedBy should start at 0");
    }

    /// @dev mintedBy accumulates across multiple purchases up to the cap
    function testMintedBy_AccumulatesAcrossMultiplePurchases() public {
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 2, recipient, bytes32(0));
        assertEq(sale.mintedBy(buyer, SCENE), 2, "mintedBy should be 2");

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 3, recipient, bytes32(0));
        assertEq(sale.mintedBy(buyer, SCENE), 5, "mintedBy should be 5 after second purchase");
    }

    /// @dev mintedBy is independent per scene
    function testMintedBy_IsIndependentPerScene() public {
        uint16 sceneA = SCENE; // 7, enabled
        uint16 sceneB = 9;
        sale.setSceneMintEnabled(sceneB, true);

        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, sceneA, 2, recipient, bytes32(0));
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, sceneB, 3, recipient, bytes32(0));

        assertEq(sale.mintedBy(buyer, sceneA), 2, "mintedBy for sceneA should be 2");
        assertEq(sale.mintedBy(buyer, sceneB), 3, "mintedBy for sceneB should be 3");
    }

    /// @dev mintedBy counter does not decrease when NFTs are transferred (mint-based only)
    function testMintedBy_DoesNotDecreaseOnTransfer() public {
        vm.prank(buyer);
        sale.buyWithCURD(PROJECT_ID, SCENE, 3, recipient, bytes32(0));
        assertEq(sale.mintedBy(buyer, SCENE), 3, "mintedBy should be 3 before transfer");

        // Simulate transfer (hook call) — counter should not change
        vm.prank(address(nft));
        tracker.afterNFTTransfer(1, recipient, makeAddr("randomAddr"));

        assertEq(sale.mintedBy(buyer, SCENE), 3, "mintedBy must not decrease after NFT transfer");
    }

    // ══════════════════════════════════════════════════════
    // EXCLUSIVE MINT PATH — NFT mint restricted to authorized minters
    // ══════════════════════════════════════════════════════

    /// @dev Direct call to NFT mintScene from a non-authorized address reverts
    function testExclusiveMint_DirectNFTMintRevertsForUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(MockSceneNFT.UnauthorizedMinter.selector);
        nft.mintScene(attacker, SCENE, 1);
    }

    /// @dev Direct call to NFT mint (legacy shim) from a non-authorized address reverts
    function testExclusiveMint_DirectNFTMintLegacyRevertsForUnauthorized() public {
        address attacker = makeAddr("attacker2");
        vm.prank(attacker);
        vm.expectRevert(MockSceneNFT.UnauthorizedMinter.selector);
        nft.mint(attacker, SCENE);
    }

    /// @dev Only the authorized sale contract can mint through the NFT
    function testExclusiveMint_SaleContractIsAuthorizedMinter() public {
        assertTrue(nft.authorizedMinters(address(sale)), "Sale contract must be authorized minter");
    }
}
