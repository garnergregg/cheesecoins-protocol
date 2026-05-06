// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/core/CheesecoinsCore.sol";
import "../../foundry-src/monetary/FounderVestingWallet.sol";
import "../../foundry-src/monetary/MintController.sol";
import "../../foundry-src/monetary/BurnController.sol";
import "../../foundry-src/monetary/EcosystemRevenueRouter.sol";
import "../../foundry-src/Config.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ MOCKS ============

contract MockCurdUsdPriceFeedMonetary {
    int256 private constant _PRICE = int256(Config.PEG_PRICE);

    function viewLatestPrice() external pure returns (int256 price, bool isStale) {
        return (_PRICE, false);
    }
}

/// @notice Simple ERC20 mock for USDC and revenue tokens
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

// ============ TEST CONTRACT ============

/**
 * @title MonetaryContractsTest
 * @notice Unit tests for FounderVestingWallet, MintController, BurnController, EcosystemRevenueRouter
 */
contract MonetaryContractsTest is Test {
    // Core contracts
    CheesecoinsCore public core;
    FounderVestingWallet public vestingWallet;
    MintController public mintController;
    BurnController public burnController;
    EcosystemRevenueRouter public router;

    // Mocks
    MockCurdUsdPriceFeedMonetary public priceFeed;
    MockERC20 public usdc;
    MockERC20 public revenueToken;

    // Addresses
    address public owner;
    address public dao;
    address public founder;
    address public treasuryEcosystem;
    address public treasuryFarmers;
    address public treasuryMarketing;
    address public treasuryReserve;
    address public treasuryUsdcWallet;
    address public auditor;
    address public user1;

    function setUp() public {
        owner = address(this);
        dao = makeAddr("dao");
        founder = makeAddr("founder");
        treasuryEcosystem = makeAddr("treasuryEcosystem");
        treasuryFarmers = makeAddr("treasuryFarmers");
        treasuryMarketing = makeAddr("treasuryMarketing");
        treasuryReserve = makeAddr("treasuryReserve");
        treasuryUsdcWallet = makeAddr("treasuryUsdcWallet");
        auditor = makeAddr("auditor");
        user1 = makeAddr("user1");

        // Deploy mock tokens
        priceFeed = new MockCurdUsdPriceFeedMonetary();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        revenueToken = new MockERC20("Rev Token", "REV", 18);

        // Deploy FounderVestingWallet (needs core address, deploy first as placeholder then set)
        // We'll deploy core first, then vestingWallet
        CheesecoinsCore implementation = new CheesecoinsCore();
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        // Temporary address for vesting wallet during deploy — use a placeholder
        address vestingPlaceholder = makeAddr("vestingPlaceholder");

        bytes memory initData = abi.encodeWithSelector(
            CheesecoinsCore.initialize.selector,
            treasuryEcosystem,
            treasuryFarmers,
            treasuryMarketing,
            treasuryReserve,
            auditor,
            address(this), // minter = this; will transfer to MintController after
            address(priceFeed),
            vestingPlaceholder
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
        core = CheesecoinsCore(address(proxy));

        // Deploy FounderVestingWallet with real core address
        vestingWallet = new FounderVestingWallet(address(core), founder, uint64(block.timestamp));

        // Deploy MintController
        mintController = new MintController(dao, address(core), address(usdc), treasuryUsdcWallet);

        // Wire: set authorizedMinter = mintController
        core.setAuthorizedMinter(address(mintController));

        // Deploy BurnController (burns from treasuryEcosystem)
        burnController = new BurnController(dao, address(core), address(usdc), treasuryUsdcWallet, treasuryEcosystem);

        // Deploy EcosystemRevenueRouter
        router = new EcosystemRevenueRouter(address(core), treasuryEcosystem, founder);
    }

    // ============ 1. INITIAL SUPPLY SPLIT ============

    /**
     * @notice treasury + vestingPlaceholder == INITIAL_SUPPLY (200M)
     */
    function test_initial_supply_split() public {
        address vestingPlaceholder = makeAddr("vestingPlaceholder");
        uint256 treasuryBal = core.balanceOf(treasuryEcosystem);
        uint256 vestingBal = core.balanceOf(vestingPlaceholder);

        assertEq(treasuryBal, Config.TREASURY_ALLOCATION, "Treasury should receive 180M");
        assertEq(vestingBal, Config.FOUNDER_ALLOCATION, "Vesting wallet should receive 20M");
        assertEq(treasuryBal + vestingBal, Config.INITIAL_SUPPLY, "Total genesis = 200M");
    }

    // ============ 2. VESTING LINEAR RELEASE ============

    /**
     * @notice Verify linear release at 25%, 50%, 75%, and 100% of vesting duration
     */
    function test_vesting_linear_release() public {
        // Fund the vestingWallet with 20M CURD
        uint256 allocation = Config.FOUNDER_ALLOCATION;

        // Mint directly from the treasury placeholder to vestingWallet for test isolation
        vm.prank(treasuryEcosystem);
        core.transfer(address(vestingWallet), allocation);

        assertEq(vestingWallet.totalAllocation(), allocation, "totalAllocation should be 20M");

        // At start: nothing vested
        assertEq(vestingWallet.vestedAmount(uint64(block.timestamp)), 0, "Nothing vested at start");

        // 25% through
        uint64 quarter = uint64(block.timestamp + Config.FOUNDER_VEST_DURATION / 4);
        assertEq(vestingWallet.vestedAmount(quarter), allocation / 4, "25% vested at 1/4 duration");

        // 50% through
        uint64 half = uint64(block.timestamp + Config.FOUNDER_VEST_DURATION / 2);
        assertEq(vestingWallet.vestedAmount(half), allocation / 2, "50% vested at 1/2 duration");

        // 100%: fully vested after duration
        uint64 end = uint64(block.timestamp + Config.FOUNDER_VEST_DURATION);
        assertEq(vestingWallet.vestedAmount(end), allocation, "100% vested at full duration");

        // Warp to 50% and release
        vm.warp(block.timestamp + Config.FOUNDER_VEST_DURATION / 2);
        vm.prank(founder);
        vestingWallet.release();

        assertEq(core.balanceOf(founder), allocation / 2, "Founder received 50% at half duration");
        assertEq(vestingWallet.released(), allocation / 2, "Released tracks correctly");

        // Cannot release again immediately (already released)
        vm.prank(founder);
        vm.expectRevert("NOTHING_TO_RELEASE");
        vestingWallet.release();

        // Warp to full vesting and release remainder
        vm.warp(block.timestamp + Config.FOUNDER_VEST_DURATION);
        vm.prank(founder);
        vestingWallet.release();
        assertEq(core.balanceOf(founder), allocation, "Founder received full allocation after vest");
    }

    /**
     * @notice Non-beneficiary cannot call release
     */
    function test_vesting_only_beneficiary_can_release() public {
        vm.prank(treasuryEcosystem);
        core.transfer(address(vestingWallet), Config.FOUNDER_ALLOCATION);

        vm.warp(block.timestamp + Config.FOUNDER_VEST_DURATION);

        vm.prank(user1);
        vm.expectRevert("NOT_BENEFICIARY");
        vestingWallet.release();
    }

    // ============ 3. MINT CONTROLLER GATES ============

    /**
     * @notice MintController rejects if treasury USDC < 40M
     */
    function test_mint_controller_rejects_if_usdc_lt_40m() public {
        // mintController is already wired as authorizedMinter in setUp
        // usdc starts with 0 balance in treasury → TREASURY_LT_THRESHOLD fires first

        vm.prank(dao);
        vm.expectRevert("TREASURY_LT_THRESHOLD");
        mintController.daoMint(user1, 1e18, "test");
    }

    /**
     * @notice MintController rejects if backing < 75% even when USDC >= 40M
     */
    function test_mint_controller_rejects_if_backing_lt_75() public {
        // Mint enough USDC to meet threshold but not enough for 75% backing
        // Supply = 200M CURD (18 dec). 75% backing = 150M USDC (in 18 dec) = 150M USDC (6 dec)
        // Give 40M USDC (meets threshold) but 40M / 200M = 20% backing → fails
        usdc.mint(treasuryUsdcWallet, Config.TREASURY_USDC_THRESHOLD); // exactly 40M USDC

        vm.prank(dao);
        vm.expectRevert("BACKING_BELOW_MIN");
        mintController.daoMint(user1, 1e18, "test");
    }

    /**
     * @notice MintController rejects if supply cap would be exceeded
     */
    function test_mint_controller_rejects_if_supply_cap_exceeded() public {
        // Fund enough USDC for 80% backing
        uint256 usdcNeeded = _usdcFor80PctBacking();
        usdc.mint(treasuryUsdcWallet, usdcNeeded);

        uint256 currentSupply = core.totalSupply();
        uint256 overflowAmount = Config.MAX_SUPPLY - currentSupply + 1;

        vm.prank(dao);
        vm.expectRevert("SUPPLY_CAP_EXCEEDED");
        mintController.daoMint(user1, overflowAmount, "test");
    }

    /**
     * @notice MintController succeeds when all gates pass
     */
    function test_mint_controller_succeeds_with_valid_conditions() public {
        uint256 usdcNeeded = _usdcFor80PctBacking();
        usdc.mint(treasuryUsdcWallet, usdcNeeded);

        uint256 mintAmount = 1_000_000e18;
        uint256 supplyBefore = core.totalSupply();

        vm.prank(dao);
        mintController.daoMint(user1, mintAmount, "growth");

        assertEq(core.totalSupply(), supplyBefore + mintAmount, "Supply increased by mint amount");
        assertEq(core.balanceOf(user1), mintAmount, "user1 received minted tokens");
    }

    /**
     * @notice Non-DAO cannot call daoMint
     */
    function test_mint_controller_rejects_non_dao() public {
        vm.prank(user1);
        vm.expectRevert("DAO_ONLY");
        mintController.daoMint(user1, 1e18, "test");
    }

    // ============ 4. BURN CONTROLLER ============

    /**
     * @notice BurnController rejects when backing is healthy (>= 75%)
     */
    function test_burn_controller_rejects_when_backing_healthy() public {
        uint256 usdcNeeded = _usdcFor80PctBacking();
        usdc.mint(treasuryUsdcWallet, usdcNeeded);

        vm.prank(dao);
        vm.expectRevert("BACKING_HEALTHY");
        burnController.daoBurn(1e18, "test");
    }

    /**
     * @notice BurnController succeeds when backing < 75% (with allowance)
     */
    function test_burn_controller_succeeds_when_backing_low() public {
        // 0 USDC → backing = 0% < 75%
        uint256 burnAmount = 1_000e18;
        uint256 supplyBefore = core.totalSupply();

        // treasuryEcosystem approves burnController
        vm.prank(treasuryEcosystem);
        core.approve(address(burnController), burnAmount);

        vm.prank(dao);
        burnController.daoBurn(burnAmount, "rebalance");

        assertEq(core.totalSupply(), supplyBefore - burnAmount, "Supply decreased by burn amount");
    }

    // ============ 5. REVENUE ROUTER ============

    /**
     * @notice Router sunsets founder share when totalSupply >= MAX_SUPPLY
     */
    function test_router_sunsets_founder_share_when_supply_at_max() public {
        uint256 routeAmount = 100_000e18;
        revenueToken.mint(user1, routeAmount);

        // Warp supply to MAX via a direct mint (for test only, bypassing MintController)
        // We do this by having the minter (which is mintController, but we need direct access)
        // For test isolation: deploy a fresh core where THIS contract is minter
        CheesecoinsCore impl2 = new CheesecoinsCore();
        ProxyAdmin pa2 = new ProxyAdmin();
        address vp2 = makeAddr("vp2");
        bytes memory id2 = abi.encodeWithSelector(
            CheesecoinsCore.initialize.selector,
            treasuryEcosystem,
            treasuryFarmers,
            treasuryMarketing,
            treasuryReserve,
            auditor,
            address(this), // minter = this test contract
            address(priceFeed),
            vp2
        );
        CheesecoinsCore core2 =
            CheesecoinsCore(address(new TransparentUpgradeableProxy(address(impl2), address(pa2), id2)));

        // Mint to bring supply exactly to MAX_SUPPLY
        uint256 remaining = Config.MAX_SUPPLY - core2.totalSupply();
        core2.controllerMint(treasuryEcosystem, remaining, "fill to max");

        assertEq(core2.totalSupply(), Config.MAX_SUPPLY, "Supply should be at MAX");

        // Deploy a fresh router pointing at core2 (at max supply)
        EcosystemRevenueRouter router2 = new EcosystemRevenueRouter(address(core2), treasuryEcosystem, founder);

        vm.startPrank(user1);
        revenueToken.approve(address(router2), routeAmount);
        router2.route(address(revenueToken), routeAmount);
        vm.stopPrank();

        // Founder cut should be 0 at max supply
        assertEq(router2.founderAccrued(address(revenueToken)), 0, "Founder accrual = 0 at MAX_SUPPLY");
        assertEq(revenueToken.balanceOf(treasuryEcosystem), routeAmount, "All revenue goes to treasury at MAX_SUPPLY");
    }

    /**
     * @notice Router accrues 1% founder share when supply < MAX_SUPPLY
     */
    function test_router_accrues_founder_share_below_max() public {
        uint256 routeAmount = 100_000e18;
        revenueToken.mint(user1, routeAmount);

        uint256 expectedFounderCut = (routeAmount * Config.FOUNDER_REVENUE_BPS) / Config.BASIS_POINTS;
        uint256 expectedTreasuryCut = routeAmount - expectedFounderCut;

        vm.startPrank(user1);
        revenueToken.approve(address(router), routeAmount);
        router.route(address(revenueToken), routeAmount);
        vm.stopPrank();

        assertEq(router.founderAccrued(address(revenueToken)), expectedFounderCut, "1% accrued for founder");
        assertEq(revenueToken.balanceOf(treasuryEcosystem), expectedTreasuryCut, "99% sent to treasury immediately");
    }

    /**
     * @notice Founder can claim accrued revenue
     */
    function test_router_founder_can_claim() public {
        uint256 routeAmount = 100_000e18;
        revenueToken.mint(user1, routeAmount);

        vm.startPrank(user1);
        revenueToken.approve(address(router), routeAmount);
        router.route(address(revenueToken), routeAmount);
        vm.stopPrank();

        uint256 accrued = router.founderAccrued(address(revenueToken));
        assertGt(accrued, 0, "Should have accrued amount");

        vm.prank(founder);
        router.claim(address(revenueToken));

        assertEq(revenueToken.balanceOf(founder), accrued, "Founder received accrued amount");
        assertEq(router.founderClaimed(address(revenueToken)), accrued, "Claimed tracker updated");
    }

    /**
     * @notice Non-founder cannot claim
     */
    function test_router_non_founder_cannot_claim() public {
        vm.prank(user1);
        vm.expectRevert("NOT_FOUNDER");
        router.claim(address(revenueToken));
    }

    /**
     * @notice Route with zero amount reverts
     */
    function test_router_rejects_zero_amount() public {
        vm.prank(user1);
        vm.expectRevert("ZERO_AMOUNT");
        router.route(address(revenueToken), 0);
    }

    // ============ INVARIANT-STYLE CHECKS ============

    /**
     * @notice totalSupply <= MAX_SUPPLY at all times after mint operations
     */
    function test_invariant_supply_cap() public {
        uint256 usdcNeeded = _usdcFor80PctBacking();
        usdc.mint(treasuryUsdcWallet, usdcNeeded);

        uint256 remaining = Config.MAX_SUPPLY - core.totalSupply();

        vm.prank(dao);
        mintController.daoMint(user1, remaining, "fill to max");

        assertEq(core.totalSupply(), Config.MAX_SUPPLY, "Supply at cap");

        // After filling to MAX_SUPPLY, USDC backing drops below 75%
        // (160M USDC + 40M extra) / 400M CURD = 50% < 75% → BACKING_BELOW_MIN fires first
        usdc.mint(treasuryUsdcWallet, Config.TREASURY_USDC_THRESHOLD); // extra USDC
        vm.prank(dao);
        vm.expectRevert("BACKING_BELOW_MIN");
        mintController.daoMint(user1, 1e18, "overflow");
    }

    /**
     * @notice Founder never receives more than 1% of a single route
     */
    function test_invariant_founder_share_never_exceeds_1pct(uint256 routeAmount) public {
        routeAmount = bound(routeAmount, 1e6, 1e30);
        revenueToken.mint(user1, routeAmount);

        vm.startPrank(user1);
        revenueToken.approve(address(router), routeAmount);
        router.route(address(revenueToken), routeAmount);
        vm.stopPrank();

        uint256 founderCut = router.founderAccrued(address(revenueToken));
        uint256 maxAllowed = (routeAmount * Config.FOUNDER_REVENUE_BPS) / Config.BASIS_POINTS;

        assertLe(founderCut, maxAllowed, "Founder share must not exceed 1%");
    }

    // ============ HELPERS ============

    /**
     * @notice Legacy mint path is permanently disabled under Stage 0 monetary policy
     */
    function test_legacy_mint_path_disabled() public {
        vm.prank(address(mintController));
        vm.expectRevert("MINT_PATH_DISABLED");
        core.mintNewCURDForEcosystemGrowth(1e18, "");
    }

    /// @dev Returns USDC amount (6 dec) needed for exactly 80% backing of current supply
    function _usdcFor80PctBacking() internal view returns (uint256) {
        uint256 supply = core.totalSupply(); // 18 dec
        // backing = (usdc18 * 10_000) / supply >= 8000 (80%)
        // usdc18 = supply * 8000 / 10_000
        uint256 usdc18Needed = (supply * 8000) / Config.BASIS_POINTS;
        // Convert 18 dec → 6 dec (USDC)
        return usdc18Needed / 1e12;
    }
}
