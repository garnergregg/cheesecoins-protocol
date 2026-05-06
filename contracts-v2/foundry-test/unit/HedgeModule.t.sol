// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../foundry-src/stability/BurnAuthority.sol";
import "../../foundry-src/stability/HedgeModule.sol";
import "../../foundry-src/stability/interfaces/IHedgeModule.sol";

// ============ MOCKS ============

/// @dev Minimal mintable/burnable ERC20 for CURD
contract HMockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Minimal ERC20 with 6 decimals for USDC
contract HMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev Mock Uniswap v3 SwapRouter.
 *      On exactInputSingle, takes tokenIn from caller and mints tokenOut to recipient.
 *      `curdPerUsdc` is the fixed exchange rate: how many CURD units per USDC unit.
 */
contract MockSwapRouter {
    uint256 public curdPerUsdc; // e.g. 1e12 means 1 USDC (1e6) → 1e12 * 1e6 / 1e6 CURD...

    HMockCURD internal _curdToken;
    HMockUSDC internal _usdcToken;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    constructor(address curd_, address usdc_, uint256 _curdPerUsdc) {
        _curdToken = HMockCURD(curd_);
        _usdcToken = HMockUSDC(usdc_);
        curdPerUsdc = _curdPerUsdc;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        // Pull USDC from caller
        ERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Compute amountOut: amountIn USDC (6 dec) → CURD (18 dec)
        // Rate: curdPerUsdc CURD wei per USDC wei
        amountOut = params.amountIn * curdPerUsdc;

        require(amountOut >= params.amountOutMinimum, "MockRouter: slippage");

        // Mint CURD to recipient
        _curdToken.mint(params.recipient, amountOut);
    }
}

// ============ TEST BASE ============

/**
 * @title HedgeModuleTest
 * @notice Full unit test suite for HedgeModule (Phase-3 PR3).
 */
contract HedgeModuleTest is Test {
    // Contracts under test
    BurnAuthority public burnAuth;
    HedgeModule public hedge;

    ProxyAdmin public proxyAdmin;

    // Mocks
    HMockCURD public curd;
    HMockUSDC public usdc;
    MockSwapRouter public router;

    // Actors
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public coordinator = makeAddr("coordinator");
    address public anyone = makeAddr("anyone");

    // Parameters
    uint256 constant COOLDOWN = 1 hours;
    uint256 constant MAX_PER_EXEC = 5_000e6; // 5 000 USDC
    uint256 constant DAILY_BUDGET = 10_000e6; // 10 000 USDC
    uint24 constant POOL_FEE = 3000;
    // 1 USDC (1e6 wei) → 1e12 CURD wei  (so 1 USDC buys 1 CURD at 1:1 human rate)
    uint256 constant CURD_PER_USDC = 1e12;

    function setUp() public {
        curd = new HMockCURD();
        usdc = new HMockUSDC();
        router = new MockSwapRouter(address(curd), address(usdc), CURD_PER_USDC);
        proxyAdmin = new ProxyAdmin();

        // Deploy BurnAuthority proxy
        BurnAuthority burnImpl = new BurnAuthority();
        bytes memory baInit = abi.encodeWithSelector(BurnAuthority.initialize.selector, address(curd), owner);
        TransparentUpgradeableProxy baProxy =
            new TransparentUpgradeableProxy(address(burnImpl), address(proxyAdmin), baInit);
        burnAuth = BurnAuthority(address(baProxy));

        // Deploy HedgeModule proxy
        HedgeModule hedgeImpl = new HedgeModule();
        bytes memory hmInit = abi.encodeWithSelector(
            HedgeModule.initialize.selector,
            address(usdc),
            address(curd),
            address(burnAuth),
            treasury,
            coordinator,
            address(router),
            POOL_FEE,
            COOLDOWN,
            MAX_PER_EXEC,
            DAILY_BUDGET,
            owner
        );
        TransparentUpgradeableProxy hmProxy =
            new TransparentUpgradeableProxy(address(hedgeImpl), address(proxyAdmin), hmInit);
        hedge = HedgeModule(address(hmProxy));

        // Authorize HedgeModule to burn via BurnAuthority
        vm.prank(owner);
        burnAuth.setAuthorizedCaller(address(hedge), true);
    }

    // ============ HELPERS ============

    /// @dev Fund HedgeModule with USDC (prefunded model: no pull from treasury)
    function _fundHedge(uint256 usdcAmount) internal {
        usdc.mint(address(hedge), usdcAmount);
    }

    // ============ INITIALIZATION ============

    function test_initialize_setsFields() public {
        assertEq(address(hedge.usdc()), address(usdc));
        assertEq(address(hedge.curd()), address(curd));
        assertEq(address(hedge.burnAuthority()), address(burnAuth));
        assertEq(hedge.treasury(), treasury);
        assertEq(hedge.coordinator(), coordinator);
        assertEq(address(hedge.swapRouter()), address(router));
        assertEq(hedge.poolFee(), POOL_FEE);
        assertEq(hedge.cooldownSeconds(), COOLDOWN);
        assertEq(hedge.maxUsdcPerExecution(), MAX_PER_EXEC);
        assertEq(hedge.dailyBudget(), DAILY_BUDGET);
        assertEq(hedge.owner(), owner);
    }

    function test_initialize_zeroAddress_reverts() public {
        HedgeModule impl = new HedgeModule();
        bytes memory data = abi.encodeWithSelector(
            HedgeModule.initialize.selector,
            address(0), // usdc = 0 → revert
            address(curd),
            address(burnAuth),
            treasury,
            coordinator,
            address(router),
            POOL_FEE,
            COOLDOWN,
            MAX_PER_EXEC,
            DAILY_BUDGET,
            owner
        );
        vm.expectRevert(HedgeModule.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), data);
    }

    // ============ ONLY COORDINATOR ============

    function test_executeBuyback_revertsIfNotCoordinator() public {
        _fundHedge(1_000e6);
        vm.prank(anyone);
        vm.expectRevert(HedgeModule.NotCoordinator.selector);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);
    }

    // ============ COOLDOWN ============

    function test_executeBuyback_cooldownEnforced() public {
        _fundHedge(2_000e6);

        vm.prank(coordinator);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);

        // Attempt immediately — cooldown not elapsed
        vm.prank(coordinator);
        vm.expectRevert(HedgeModule.CooldownActive.selector);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);
    }

    function test_executeBuyback_allowsAfterCooldown() public {
        _fundHedge(2_000e6);

        vm.prank(coordinator);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);

        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 supplyBefore = curd.totalSupply();
        vm.prank(coordinator);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);

        // Net supply unchanged: mock router mints CURD, BurnAuthority burns it
        assertEq(curd.totalSupply(), supplyBefore, "Net CURD supply must be unchanged");
        assertEq(curd.balanceOf(address(hedge)), 0, "HedgeModule must not retain CURD");
    }

    // ============ MAX PER EXECUTION ============

    function test_executeBuyback_maxPerExecEnforced() public {
        _fundHedge(MAX_PER_EXEC + 1e6);

        vm.prank(coordinator);
        vm.expectRevert(HedgeModule.ExceedsMaxPerExecution.selector);
        hedge.executeBuyback(MAX_PER_EXEC + 1e6, 0, block.timestamp + 1);
    }

    function test_executeBuyback_exactlyMaxPerExec_succeeds() public {
        _fundHedge(MAX_PER_EXEC);

        vm.prank(coordinator);
        hedge.executeBuyback(MAX_PER_EXEC, 0, block.timestamp + 1);
    }

    // ============ DAILY BUDGET ============

    function test_executeBuyback_dailyBudgetEnforced() public {
        _fundHedge(DAILY_BUDGET + 1e6);

        uint256 t0 = block.timestamp;

        // First execution: MAX_PER_EXEC
        vm.prank(coordinator);
        hedge.executeBuyback(MAX_PER_EXEC, 0, t0 + 1);

        vm.warp(t0 + COOLDOWN + 2);

        // Second execution: MAX_PER_EXEC again → total = 10 000, within budget
        vm.prank(coordinator);
        hedge.executeBuyback(MAX_PER_EXEC, 0, t0 + COOLDOWN + 3);

        vm.warp(t0 + 2 * COOLDOWN + 4);

        // Third execution: would exceed 10 000 USDC daily
        vm.prank(coordinator);
        vm.expectRevert(HedgeModule.DailyBudgetExceeded.selector);
        hedge.executeBuyback(1e6, 0, t0 + 2 * COOLDOWN + 5);
    }

    function test_executeBuyback_dailyBudgetResetsAfter24h() public {
        _fundHedge(DAILY_BUDGET * 2);

        // Exhaust daily budget
        vm.prank(coordinator);
        hedge.executeBuyback(MAX_PER_EXEC, 0, block.timestamp + 1);

        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(coordinator);
        hedge.executeBuyback(MAX_PER_EXEC, 0, block.timestamp + 1);

        vm.warp(block.timestamp + COOLDOWN + 1);

        // Budget should be exhausted
        vm.prank(coordinator);
        vm.expectRevert(HedgeModule.DailyBudgetExceeded.selector);
        hedge.executeBuyback(1e6, 0, block.timestamp + 1);

        // Advance 1 day — budget resets
        vm.warp(block.timestamp + 1 days);

        vm.prank(coordinator);
        hedge.executeBuyback(1e6, 0, block.timestamp + 1); // must succeed
    }

    // ============ BURN PATH ============

    function test_executeBuyback_burnAuthorityInvoked() public {
        uint256 usdcAmount = 1_000e6;
        _fundHedge(usdcAmount);

        uint256 supplyBefore = curd.totalSupply();

        vm.prank(coordinator);
        hedge.executeBuyback(usdcAmount, 0, block.timestamp + 1);

        // Net supply unchanged: mock router mints CURD, BurnAuthority burns it
        assertEq(curd.totalSupply(), supplyBefore, "Net CURD supply unchanged in mock swap+burn");
        assertEq(curd.balanceOf(address(hedge)), 0, "No CURD retained");
    }

    function test_executeBuyback_hedgeDoesNotRetainCurd() public {
        _fundHedge(1_000e6);

        vm.prank(coordinator);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);

        assertEq(curd.balanceOf(address(hedge)), 0, "HedgeModule must not retain CURD");
    }

    // ============ BURN AUTHORITY ALLOWLIST REQUIRED ============

    function test_executeBuyback_revertsIfHedgeNotAuthorized() public {
        // Remove authorization
        vm.prank(owner);
        burnAuth.setAuthorizedCaller(address(hedge), false);

        _fundHedge(1_000e6);

        vm.prank(coordinator);
        vm.expectRevert(BurnAuthority.NotAuthorized.selector);
        hedge.executeBuyback(1_000e6, 0, block.timestamp + 1);
    }

    // ============ EVENT ============

    function test_executeBuyback_emitsBuybackExecuted() public {
        uint256 usdcAmount = 1_000e6;
        _fundHedge(usdcAmount);

        vm.expectEmit(false, false, false, false);
        emit IHedgeModule.BuybackExecuted(0, 0, 0, 0);

        vm.prank(coordinator);
        hedge.executeBuyback(usdcAmount, 0, block.timestamp + 1);
    }

    // ============ OWNER SETTERS ============

    function test_setCoordinator_onlyOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        hedge.setCoordinator(anyone);
    }

    function test_setCoordinator_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(HedgeModule.ZeroAddress.selector);
        hedge.setCoordinator(address(0));
    }

    function test_setCoordinator_updates() public {
        vm.prank(owner);
        hedge.setCoordinator(anyone);
        assertEq(hedge.coordinator(), anyone);
    }

    function test_setTreasury_updates() public {
        vm.prank(owner);
        hedge.setTreasury(anyone);
        assertEq(hedge.treasury(), anyone);
    }

    function test_setBurnAuthority_updates() public {
        address newBA = makeAddr("newBA");
        vm.prank(owner);
        hedge.setBurnAuthority(newBA);
        assertEq(address(hedge.burnAuthority()), newBA);
    }

    function test_setSwapRouter_updates() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(owner);
        hedge.setSwapRouter(newRouter);
        assertEq(address(hedge.swapRouter()), newRouter);
    }

    function test_setPoolFee_updates() public {
        vm.prank(owner);
        hedge.setPoolFee(500);
        assertEq(hedge.poolFee(), 500);
    }

    function test_setCooldown_updates() public {
        vm.prank(owner);
        hedge.setCooldown(2 hours);
        assertEq(hedge.cooldownSeconds(), 2 hours);
    }

    function test_setMaxUsdcPerExecution_updates() public {
        vm.prank(owner);
        hedge.setMaxUsdcPerExecution(2_000e6);
        assertEq(hedge.maxUsdcPerExecution(), 2_000e6);
    }

    function test_setDailyBudget_updates() public {
        vm.prank(owner);
        hedge.setDailyBudget(20_000e6);
        assertEq(hedge.dailyBudget(), 20_000e6);
    }

    // ============ ZERO AMOUNT ============

    function test_executeBuyback_zeroAmountReverts() public {
        vm.prank(coordinator);
        vm.expectRevert(HedgeModule.ZeroAmount.selector);
        hedge.executeBuyback(0, 0, block.timestamp + 1);
    }

    // ============ FUZZ ============

    function testFuzz_executeBuyback_curdAlwaysBurned(uint256 usdcAmount) public {
        usdcAmount = bound(usdcAmount, 1e6, MAX_PER_EXEC);
        _fundHedge(usdcAmount);

        uint256 supplyBefore = curd.totalSupply();

        vm.prank(coordinator);
        hedge.executeBuyback(usdcAmount, 0, block.timestamp + 1);

        assertEq(curd.totalSupply(), supplyBefore, "Net CURD supply must be unchanged: all minted CURD was burned");
        assertEq(curd.balanceOf(address(hedge)), 0, "HedgeModule must not retain CURD");
    }
}
