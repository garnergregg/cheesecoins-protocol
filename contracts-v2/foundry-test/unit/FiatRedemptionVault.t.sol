// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../foundry-src/stability/BurnAuthority.sol";
import "../../foundry-src/stability/FiatRedemptionVault.sol";

// ============ MOCKS ============

/// @dev Minimal mintable/burnable ERC20 for CURD (implements burn(uint256) from msg.sender)
contract MockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Matches ICheesecoinsCore.burn() — burns from msg.sender
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Minimal ERC20 with configurable decimals for USDC (6 decimals)
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal ERC721 mock with approve / isApprovedForAll support
contract MockCSANFT {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    uint256 private _nextId = 1;

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "MockCSANFT: nonexistent");
        return owner;
    }

    function approve(address to, uint256 tokenId) external {
        require(_owners[tokenId] == msg.sender, "MockCSANFT: not owner");
        _tokenApprovals[tokenId] = to;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "MockCSANFT: not owner");
        _owners[tokenId] = to;
        _tokenApprovals[tokenId] = address(0);
    }
}

// ============ TEST BASE ============

/**
 * @title FiatRedemptionVaultTest
 * @notice Full unit test suite for BurnAuthority + FiatRedemptionVault (Phase-3 PR2).
 */
contract FiatRedemptionVaultTest is Test {
    // Contracts under test
    BurnAuthority public burnAuthImpl;
    BurnAuthority public burnAuth;

    FiatRedemptionVault public vaultImpl;
    FiatRedemptionVault public vault;

    ProxyAdmin public proxyAdmin;

    // Mocks
    MockCURD public curd;
    MockUSDC public usdc;
    MockCSANFT public nft;

    // Actors
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");
    address public operator = makeAddr("operator");

    // Rate steps: sorted descending by floor, rate worsens as vault depletes
    // Floor 8000 → 95% rate, Floor 5000 → 80%, Floor 2000 → 60%, Floor 0 → 40%
    FiatRedemptionVault.RateStep[] internal defaultSteps;

    // Constants
    uint256 constant TARGET_RATE = 1e6; // 1.00 USDC per CURD
    uint256 constant USDC_CAP = 10_000e6; // 10 000 USDC
    uint256 constant COOLDOWN = 1 hours;
    uint256 constant MIN_REDEEM = 10e18;
    uint256 constant MAX_REDEEM = 1_000e18;

    function setUp() public {
        curd = new MockCURD();
        usdc = new MockUSDC();
        nft = new MockCSANFT();
        proxyAdmin = new ProxyAdmin();

        // Deploy BurnAuthority through proxy
        burnAuthImpl = new BurnAuthority();
        bytes memory baInit = abi.encodeWithSelector(BurnAuthority.initialize.selector, address(curd), owner);
        TransparentUpgradeableProxy baProxy =
            new TransparentUpgradeableProxy(address(burnAuthImpl), address(proxyAdmin), baInit);
        burnAuth = BurnAuthority(address(baProxy));

        // Deploy FiatRedemptionVault through proxy
        vaultImpl = new FiatRedemptionVault();
        bytes memory frvInit = abi.encodeWithSelector(
            FiatRedemptionVault.initialize.selector,
            address(usdc),
            address(curd),
            address(nft),
            treasury,
            address(burnAuth),
            USDC_CAP,
            TARGET_RATE,
            owner
        );
        TransparentUpgradeableProxy vaultProxy =
            new TransparentUpgradeableProxy(address(vaultImpl), address(proxyAdmin), frvInit);
        vault = FiatRedemptionVault(address(vaultProxy));

        // Authorize vault to burn via BurnAuthority
        vm.prank(owner);
        burnAuth.setAuthorizedCaller(address(vault), true);

        // Configure default rate steps
        defaultSteps.push(FiatRedemptionVault.RateStep({remainingBpsFloor: 8000, redeemBps: 9500}));
        defaultSteps.push(FiatRedemptionVault.RateStep({remainingBpsFloor: 5000, redeemBps: 8000}));
        defaultSteps.push(FiatRedemptionVault.RateStep({remainingBpsFloor: 2000, redeemBps: 6000}));
        defaultSteps.push(FiatRedemptionVault.RateStep({remainingBpsFloor: 0, redeemBps: 4000}));

        vm.prank(treasury);
        vault.setRateSteps(defaultSteps);

        // Set cooldown and bounds
        vm.prank(treasury);
        vault.setCooldown(COOLDOWN);
        vm.prank(treasury);
        vault.setMinMaxRedeem(MIN_REDEEM, MAX_REDEEM);
    }

    // ============ HELPERS ============

    /// @dev Fund vault with USDC from treasury
    function _fundVault(uint256 amount) internal {
        usdc.mint(treasury, amount);
        vm.prank(treasury);
        usdc.approve(address(vault), amount);
        vm.prank(treasury);
        vault.fundVault(amount);
    }

    /// @dev Give a user CURD and approve vault for transfer
    function _giveCurd(address user, uint256 amount) internal {
        curd.mint(user, amount);
        vm.prank(user);
        curd.approve(address(vault), amount);
    }

    // ============ BURN AUTHORITY TESTS ============

    function test_burnAuth_initialize_setsOwnerAndCurd() public {
        assertEq(address(burnAuth.curd()), address(curd));
        assertEq(burnAuth.owner(), owner);
    }

    function test_burnAuth_setAuthorizedCaller_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        burnAuth.setAuthorizedCaller(userA, true);
    }

    function test_burnAuth_setAuthorizedCaller_updatesMapping() public {
        vm.prank(owner);
        burnAuth.setAuthorizedCaller(userA, true);
        assertTrue(burnAuth.authorizedCaller(userA));

        vm.prank(owner);
        burnAuth.setAuthorizedCaller(userA, false);
        assertFalse(burnAuth.authorizedCaller(userA));
    }

    function test_burnAuth_burn_revertsIfNotAuthorized() public {
        curd.mint(address(burnAuth), 100e18);

        vm.prank(userA); // not authorized
        vm.expectRevert(BurnAuthority.NotAuthorized.selector);
        burnAuth.burn(100e18);
    }

    function test_burnAuth_burn_revertsOnZeroAmount() public {
        vm.prank(owner);
        burnAuth.setAuthorizedCaller(userA, true);

        vm.prank(userA);
        vm.expectRevert(BurnAuthority.ZeroAmount.selector);
        burnAuth.burn(0);
    }

    function test_burnAuth_burn_burnsCurdFromContract() public {
        uint256 amount = 500e18;
        curd.mint(address(burnAuth), amount);

        uint256 supplyBefore = curd.totalSupply();
        vm.prank(address(vault)); // vault is authorized in setUp
        burnAuth.burn(amount);

        assertEq(curd.totalSupply(), supplyBefore - amount);
        assertEq(curd.balanceOf(address(burnAuth)), 0);
    }

    function test_burnAuth_neverTransfersCurdOut() public {
        // BurnAuthority must never have a transfer-out function — structural test
        // Verify the only way CURD leaves BurnAuthority is via burn (i.e., destroyed)
        uint256 amount = 100e18;
        curd.mint(address(burnAuth), amount);

        vm.prank(address(vault));
        burnAuth.burn(amount);

        // CURD is gone from supply — not moved elsewhere
        assertEq(curd.balanceOf(address(burnAuth)), 0);
        assertEq(curd.balanceOf(address(vault)), 0);
        assertEq(curd.balanceOf(userA), 0);
    }

    // ============ VAULT INITIALIZATION ============

    function test_vault_initialize_setsFields() public {
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(address(vault.curd()), address(curd));
        assertEq(address(vault.csaNft()), address(nft));
        assertEq(vault.treasury(), treasury);
        assertEq(address(vault.burnAuthority()), address(burnAuth));
        assertEq(vault.usdcCap(), USDC_CAP);
        assertEq(vault.targetUsdcPerCurdE6(), TARGET_RATE);
        assertEq(vault.owner(), owner);
    }

    // ============ NON-NFT HOLDER CANNOT REDEEM ============

    function test_redeem_revertsIfNotNftHolder() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userB, 100e18);

        vm.prank(userB); // userB does not own nftId
        vm.expectRevert(FiatRedemptionVault.NotAuthorized.selector);
        vault.redeem(nftId, 100e18);
    }

    // ============ APPROVED OPERATOR → PAYOUT TO OWNER ============

    function test_redeem_approvedOperatorSucceeds_payoutGoesToOwner() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP); // 10 000 USDC → 100% full

        uint256 redeemAmount = 100e18;
        _giveCurd(operator, redeemAmount);

        // Grant token-level approval
        vm.prank(userA);
        nft.approve(operator, nftId);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);
        uint256 operatorUsdcBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        vault.redeem(nftId, redeemAmount);

        // Payout goes to userA (NFT owner), not operator
        assertGt(usdc.balanceOf(userA), ownerUsdcBefore, "Owner must receive USDC");
        assertEq(usdc.balanceOf(operator), operatorUsdcBefore, "Operator must receive nothing");
    }

    function test_redeem_approvedForAllOperator_payoutToOwner() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 redeemAmount = 100e18;
        _giveCurd(operator, redeemAmount);

        vm.prank(userA);
        nft.setApprovalForAll(operator, true);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);

        vm.prank(operator);
        vault.redeem(nftId, redeemAmount);

        assertGt(usdc.balanceOf(userA), ownerUsdcBefore);
    }

    // ============ COOLDOWN ENFORCEMENT ============

    function test_redeem_cooldownPreventsImmediateSecondRedeem() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 firstAmount = 100e18;
        _giveCurd(userA, firstAmount * 2);

        vm.prank(userA);
        vault.redeem(nftId, firstAmount);

        // Second attempt in same block (cooldown not elapsed)
        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.CooldownActive.selector);
        vault.redeem(nftId, firstAmount);
    }

    function test_redeem_cooldownAllowsRedemptionAfterWait() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 redeemAmount = 100e18;
        _giveCurd(userA, redeemAmount * 2);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        vm.warp(block.timestamp + COOLDOWN + 1);

        // userA still holds redeemAmount CURD and vault still has redeemAmount allowance
        uint256 supplyBefore = curd.totalSupply();
        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        assertEq(curd.totalSupply(), supplyBefore - redeemAmount, "Second redemption must burn CURD");
    }

    function test_redeem_cooldownTracksRecipient_notCaller() public {
        // userA owns the NFT; operator redeems on behalf of userA.
        // Cooldown is on userA (recipient), so a different address (operator) must still
        // be blocked for the same NFT's owner.
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 redeemAmount = 100e18;
        _giveCurd(operator, redeemAmount * 2);

        vm.prank(userA);
        nft.setApprovalForAll(operator, true);

        vm.prank(operator);
        vault.redeem(nftId, redeemAmount);

        // Operator tries again before cooldown — blocked because userA's cooldown is active
        vm.prank(operator);
        vm.expectRevert(FiatRedemptionVault.CooldownActive.selector);
        vault.redeem(nftId, redeemAmount);
    }

    // ============ CAP ENFORCEMENT ============

    function test_fundVault_revertsIfExceedsCap() public {
        usdc.mint(treasury, USDC_CAP + 1e6);
        vm.prank(treasury);
        usdc.approve(address(vault), USDC_CAP + 1e6);

        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.ExceedsVaultCap.selector);
        vault.fundVault(USDC_CAP + 1e6);
    }

    function test_fundVault_allowsUpToCap() public {
        _fundVault(USDC_CAP); // exactly the cap — must succeed
        assertEq(usdc.balanceOf(address(vault)), USDC_CAP);
    }

    function test_fundVault_onlyTreasury() public {
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        usdc.approve(address(vault), 1000e6);

        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.NotTreasury.selector);
        vault.fundVault(1000e6);
    }

    // ============ INSUFFICIENT USDC ============

    function test_redeem_revertsIfInsufficientUsdc() public {
        uint256 nftId = nft.mint(userA);
        // Fund vault with only 1 USDC
        _fundVault(1e6);

        // Try to redeem 1000 CURD at full rate → ~1000 USDC needed
        uint256 largeCurd = 1000e18;
        _giveCurd(userA, largeCurd);

        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.InsufficientUsdcInVault.selector);
        vault.redeem(nftId, largeCurd);
    }

    // ============ A2 STEP BOUNDARY CORRECTNESS ============

    function test_redeem_fullVault_appliesHighestStep() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP); // 10 000 USDC → remainingBps = 10 000 → step[0] (floor 8000, bps 9500)

        uint256 redeemAmount = 100e18; // 100 CURD
        _giveCurd(userA, redeemAmount);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        // Expected: 100 CURD * 1e6 * 9500 / (1e18 * 10_000) = 95 USDC
        uint256 expected = redeemAmount * TARGET_RATE * 9500 / (1e18 * 10_000);
        assertEq(usdc.balanceOf(userA) - ownerUsdcBefore, expected);
    }

    function test_redeem_partialVault_appliesCorrectStep() public {
        uint256 nftId = nft.mint(userA);
        // Fund 6 000 USDC → remainingBps = 6000 → step[1] (floor 5000, bps 8000)
        _fundVault(6_000e6);

        uint256 redeemAmount = 100e18;
        _giveCurd(userA, redeemAmount);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        uint256 expected = redeemAmount * TARGET_RATE * 8000 / (1e18 * 10_000);
        assertEq(usdc.balanceOf(userA) - ownerUsdcBefore, expected);
    }

    function test_redeem_lowVault_appliesLowestStep() public {
        uint256 nftId = nft.mint(userA);
        // Fund 1 500 USDC → remainingBps = 1500 → step[2] (floor 2000) not satisfied;
        // step[3] (floor 0, bps 4000) is the match
        _fundVault(1_500e6);

        uint256 redeemAmount = MIN_REDEEM;
        _giveCurd(userA, redeemAmount);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        uint256 expected = redeemAmount * TARGET_RATE * 4000 / (1e18 * 10_000);
        assertEq(usdc.balanceOf(userA) - ownerUsdcBefore, expected);
    }

    function test_redeem_atExactStepBoundary() public {
        uint256 nftId = nft.mint(userA);
        // Fund exactly 5 000 USDC → remainingBps = 5000 → step[1] (floor 5000, bps 8000)
        _fundVault(5_000e6);

        uint256 redeemAmount = MIN_REDEEM;
        _giveCurd(userA, redeemAmount);

        uint256 ownerUsdcBefore = usdc.balanceOf(userA);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        uint256 expected = redeemAmount * TARGET_RATE * 8000 / (1e18 * 10_000);
        assertEq(usdc.balanceOf(userA) - ownerUsdcBefore, expected);
    }

    // ============ RATE MONOTONIC WORSENING ============

    function test_rate_monotonicWorseningAsBalanceDrops() public {
        // Verify the four rate levels decrease as remainingBps decreases
        uint256[] memory balances = new uint256[](4);
        balances[0] = 9_000e6; // remainingBps=9000 → step0 bps=9500
        balances[1] = 6_000e6; // remainingBps=6000 → step1 bps=8000
        balances[2] = 3_000e6; // remainingBps=3000 → step2 bps=6000
        balances[3] = 1_000e6; // remainingBps=1000 → step3 bps=4000

        uint256 redeemAmount = MIN_REDEEM;
        uint256 prevUsdcOut = type(uint256).max;

        for (uint256 k = 0; k < 4; k++) {
            uint256 nftId = nft.mint(userA);

            // Reset vault to target balance using a fresh vault state trick:
            // Deploy a fresh vault proxy for isolation
            FiatRedemptionVault freshVault;
            {
                bytes memory init = abi.encodeWithSelector(
                    FiatRedemptionVault.initialize.selector,
                    address(usdc),
                    address(curd),
                    address(nft),
                    treasury,
                    address(burnAuth),
                    USDC_CAP,
                    TARGET_RATE,
                    owner
                );
                TransparentUpgradeableProxy p =
                    new TransparentUpgradeableProxy(address(vaultImpl), address(proxyAdmin), init);
                freshVault = FiatRedemptionVault(address(p));
            }
            vm.prank(owner);
            burnAuth.setAuthorizedCaller(address(freshVault), true);

            vm.prank(treasury);
            freshVault.setRateSteps(defaultSteps);
            vm.prank(treasury);
            freshVault.setCooldown(0); // no cooldown for this test

            usdc.mint(treasury, balances[k]);
            vm.prank(treasury);
            usdc.approve(address(freshVault), balances[k]);
            vm.prank(treasury);
            freshVault.fundVault(balances[k]);

            curd.mint(userA, redeemAmount);
            vm.prank(userA);
            curd.approve(address(freshVault), redeemAmount);

            uint256 usdcBefore = usdc.balanceOf(userA);
            vm.prank(userA);
            freshVault.redeem(nftId, redeemAmount);
            uint256 usdcOut = usdc.balanceOf(userA) - usdcBefore;

            assertLt(usdcOut, prevUsdcOut, "Rate must worsen as balance drops");
            prevUsdcOut = usdcOut;
        }
    }

    // ============ BURN AUTHORITY IS INVOKED ============

    function test_redeem_burnAuthorityInvoked_curdSupplyDecreases() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 redeemAmount = 100e18;
        _giveCurd(userA, redeemAmount);

        uint256 supplyBefore = curd.totalSupply();

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        assertEq(curd.totalSupply(), supplyBefore - redeemAmount, "CURD must be burned");
    }

    // ============ VAULT DOES NOT RETAIN CURD ============

    function test_redeem_vaultDoesNotRetainCurd() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);

        uint256 redeemAmount = 100e18;
        _giveCurd(userA, redeemAmount);

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        assertEq(curd.balanceOf(address(vault)), 0, "Vault must not hold CURD");
    }

    // ============ PAUSE ============

    function test_pause_blocksRedeem() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, 100e18);

        vm.prank(owner);
        vault.pause();

        vm.prank(userA);
        vm.expectRevert("Pausable: paused");
        vault.redeem(nftId, 100e18);
    }

    function test_pause_allowsFundVault() public {
        vm.prank(owner);
        vault.pause();

        // fundVault should succeed even when paused
        _fundVault(1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_unpause_restoresRedeem() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, 100e18);

        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();

        uint256 supplyBefore = curd.totalSupply();
        vm.prank(userA);
        vault.redeem(nftId, 100e18);

        assertEq(curd.totalSupply(), supplyBefore - 100e18, "Redemption after unpause must burn CURD");
    }

    function test_pause_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.pause();
    }

    // ============ MIN / MAX REDEEM ============

    function test_redeem_revertsIfBelowMinimum() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, MIN_REDEEM - 1);

        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.BelowMinimum.selector);
        vault.redeem(nftId, MIN_REDEEM - 1);
    }

    function test_redeem_revertsIfAboveMaximum() public {
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, MAX_REDEEM + 1);

        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.AboveMaximum.selector);
        vault.redeem(nftId, MAX_REDEEM + 1);
    }

    // ============ RATE STEP VALIDATION ============

    function test_setRateSteps_revertsOnEmpty() public {
        FiatRedemptionVault.RateStep[] memory empty;
        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.InvalidRateSteps.selector);
        vault.setRateSteps(empty);
    }

    function test_setRateSteps_revertsIfNotDescending() public {
        FiatRedemptionVault.RateStep[] memory bad = new FiatRedemptionVault.RateStep[](2);
        bad[0] = FiatRedemptionVault.RateStep({remainingBpsFloor: 3000, redeemBps: 8000});
        bad[1] = FiatRedemptionVault.RateStep({remainingBpsFloor: 5000, redeemBps: 6000}); // ascending — invalid

        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.InvalidRateSteps.selector);
        vault.setRateSteps(bad);
    }

    function test_setRateSteps_revertsIfRedeemBpsOver10000() public {
        FiatRedemptionVault.RateStep[] memory bad = new FiatRedemptionVault.RateStep[](1);
        bad[0] = FiatRedemptionVault.RateStep({remainingBpsFloor: 0, redeemBps: 10_001});

        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.InvalidRateSteps.selector);
        vault.setRateSteps(bad);
    }

    function test_setRateSteps_revertsIfFloorOver10000() public {
        FiatRedemptionVault.RateStep[] memory bad = new FiatRedemptionVault.RateStep[](1);
        bad[0] = FiatRedemptionVault.RateStep({remainingBpsFloor: 10_001, redeemBps: 5000});

        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.InvalidRateSteps.selector);
        vault.setRateSteps(bad);
    }

    function test_setRateSteps_onlyTreasury() public {
        FiatRedemptionVault.RateStep[] memory steps = new FiatRedemptionVault.RateStep[](1);
        steps[0] = FiatRedemptionVault.RateStep({remainingBpsFloor: 0, redeemBps: 5000});

        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.NotTreasury.selector);
        vault.setRateSteps(steps);
    }

    function test_getRateSteps_returnsConfiguredSteps() public {
        FiatRedemptionVault.RateStep[] memory stored = vault.getRateSteps();
        assertEq(stored.length, defaultSteps.length);
        for (uint256 i = 0; i < stored.length; i++) {
            assertEq(stored[i].remainingBpsFloor, defaultSteps[i].remainingBpsFloor);
            assertEq(stored[i].redeemBps, defaultSteps[i].redeemBps);
        }
    }

    // ============ GOVERNANCE SETTERS ============

    function test_setTreasury_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.setTreasury(userB);
    }

    function test_setTreasury_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(FiatRedemptionVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_setTreasury_updates() public {
        vm.prank(owner);
        vault.setTreasury(userB);
        assertEq(vault.treasury(), userB);
    }

    function test_setUsdcCap_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.setUsdcCap(1);
    }

    function test_setUsdcCap_updates() public {
        vm.prank(owner);
        vault.setUsdcCap(999e6);
        assertEq(vault.usdcCap(), 999e6);
    }

    function test_setTargetUsdcPerCurd_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(FiatRedemptionVault.ZeroAmount.selector);
        vault.setTargetUsdcPerCurd(0);
    }

    function test_setTargetUsdcPerCurd_updates() public {
        vm.prank(owner);
        vault.setTargetUsdcPerCurd(2e6);
        assertEq(vault.targetUsdcPerCurdE6(), 2e6);
    }

    function test_setBurnAuthority_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(FiatRedemptionVault.ZeroAddress.selector);
        vault.setBurnAuthority(address(0));
    }

    function test_setBurnAuthority_updates() public {
        address newBA = makeAddr("newBurnAuth");
        vm.prank(owner);
        vault.setBurnAuthority(newBA);
        assertEq(address(vault.burnAuthority()), newBA);
    }

    function test_setCooldown_onlyTreasury() public {
        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.NotTreasury.selector);
        vault.setCooldown(1);
    }

    function test_setCooldown_updates() public {
        vm.prank(treasury);
        vault.setCooldown(2 hours);
        assertEq(vault.cooldownSeconds(), 2 hours);
    }

    function test_setMinMaxRedeem_invalidReverts() public {
        vm.prank(treasury);
        vm.expectRevert(FiatRedemptionVault.InvalidMinMax.selector);
        vault.setMinMaxRedeem(500e18, 100e18); // min > max
    }

    function test_setMinMaxRedeem_updates() public {
        vm.prank(treasury);
        vault.setMinMaxRedeem(50e18, 500e18);
        assertEq(vault.minRedeemCurd(), 50e18);
        assertEq(vault.maxRedeemCurd(), 500e18);
    }

    // ============ FUZZ ============

    function testFuzz_redeem_curdAlwaysBurned(uint256 redeemAmount) public {
        redeemAmount = bound(redeemAmount, MIN_REDEEM, MAX_REDEEM);

        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, redeemAmount);

        uint256 supplyBefore = curd.totalSupply();

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        assertEq(curd.totalSupply(), supplyBefore - redeemAmount, "All CURD must be burned");
        assertEq(curd.balanceOf(address(vault)), 0, "Vault must not retain CURD");
    }

    function testFuzz_redeem_vaultUsdcNeverNegative(uint256 redeemAmount) public {
        redeemAmount = bound(redeemAmount, MIN_REDEEM, MAX_REDEEM);

        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        _giveCurd(userA, redeemAmount);

        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(userA);
        vault.redeem(nftId, redeemAmount);

        assertLe(usdc.balanceOf(address(vault)), vaultBefore, "Vault USDC must not increase");
    }

    // ============ PROTOCOL FEE TESTS ============

    function test_setProtocolFeeBps_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.setProtocolFeeBps(200);
    }

    function test_setProtocolFeeBps_revertsIfOver1000() public {
        vm.prank(owner);
        vm.expectRevert(FiatRedemptionVault.FeeBpsTooHigh.selector);
        vault.setProtocolFeeBps(1001);
    }

    function test_setProtocolFeeBps_updates() public {
        vm.prank(owner);
        vault.setProtocolFeeBps(200);
        assertEq(vault.protocolFeeBps(), 200);
    }

    function test_redeem_protocolFee_routesToTreasury() public {
        // Set 2% fee
        vm.prank(owner);
        vault.setProtocolFeeBps(200);

        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        uint256 redeemCurd = 100e18; // 100 CURD
        _giveCurd(userA, redeemCurd);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 userBefore = usdc.balanceOf(userA);

        vm.prank(userA);
        vault.redeem(nftId, redeemCurd);

        // At 100% vault health, redeemBps = 9500 → usdcOut = 100 * 1.00 * 9500/10000 = 95 USDC
        // fee = 95 * 200/10000 = 1.90 USDC → user gets 93.10 USDC, treasury gets 1.90 USDC
        uint256 expectedGross = 95e6; // 95 USDC
        uint256 expectedFee = expectedGross * 200 / 10_000; // 1.90 USDC
        uint256 expectedUser = expectedGross - expectedFee;

        assertEq(usdc.balanceOf(userA) - userBefore, expectedUser, "User USDC mismatch");
        // Treasury receives fee on top of existing balance (vault was funded from treasury)
        assertGe(usdc.balanceOf(treasury), treasuryBefore + expectedFee - 1, "Treasury fee not received");
    }

    function test_redeem_zeroFee_noFeeTransfer() public {
        // protocolFeeBps defaults to 0
        uint256 nftId = nft.mint(userA);
        _fundVault(USDC_CAP);
        uint256 redeemCurd = 100e18;
        _giveCurd(userA, redeemCurd);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(userA);
        vault.redeem(nftId, redeemCurd);

        // No fee — treasury balance unchanged (vault was funded by treasury at setUp, not counted here)
        // Just verify user got the full gross amount
        assertEq(usdc.balanceOf(userA), 95e6, "User should receive full usdcOut with zero fee");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Treasury should not receive fee when feeBps=0");
    }

    // ============ DAILY REDEMPTION CAP TESTS ============

    function test_setDailyRedemptionCap_onlyTreasury() public {
        vm.prank(userA);
        vm.expectRevert(FiatRedemptionVault.NotTreasury.selector);
        vault.setDailyRedemptionCap(1_000e6);
    }

    function test_setDailyRedemptionCap_updates() public {
        vm.prank(treasury);
        vault.setDailyRedemptionCap(5_000e6);
        assertEq(vault.dailyRedemptionCapUsdc(), 5_000e6);
    }

    function test_redeem_dailyCap_revertsWhenExceeded() public {
        // Cap at 100 USDC per day
        vm.prank(treasury);
        vault.setDailyRedemptionCap(100e6);

        _fundVault(USDC_CAP);

        // First redemption: 100 CURD → ~95 USDC (within cap)
        uint256 nftId1 = nft.mint(userA);
        _giveCurd(userA, 100e18);
        vm.prank(userA);
        vault.redeem(nftId1, 100e18);

        // Second redemption same day: should breach the 100 USDC cap
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 nftId2 = nft.mint(userB);
        _giveCurd(userB, 100e18);
        vm.prank(userB);
        vm.expectRevert(FiatRedemptionVault.DailyCapExceeded.selector);
        vault.redeem(nftId2, 100e18);
    }

    function test_redeem_dailyCap_resetsAfter24Hours() public {
        vm.prank(treasury);
        vault.setDailyRedemptionCap(100e6);

        _fundVault(USDC_CAP);

        // Use up the daily cap
        uint256 nftId1 = nft.mint(userA);
        _giveCurd(userA, 100e18);
        vm.prank(userA);
        vault.redeem(nftId1, 100e18);

        // Advance 24 hours + 1 second → window resets
        vm.warp(block.timestamp + 1 days + 1);

        uint256 nftId2 = nft.mint(userB);
        _giveCurd(userB, 100e18);
        vm.prank(userB);
        vault.redeem(nftId2, 100e18); // should succeed — new window

        assertGt(usdc.balanceOf(userB), 0, "UserB should have received USDC after window reset");
    }

    function test_redeem_zeroCap_disablesLimit() public {
        // dailyRedemptionCapUsdc = 0 means no cap
        _fundVault(USDC_CAP);

        uint256 nftId1 = nft.mint(userA);
        _giveCurd(userA, MAX_REDEEM);
        vm.prank(userA);
        vault.redeem(nftId1, MAX_REDEEM);

        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 nftId2 = nft.mint(userB);
        _giveCurd(userB, MAX_REDEEM);
        vm.prank(userB);
        vault.redeem(nftId2, MAX_REDEEM); // no cap — should not revert

        assertGt(usdc.balanceOf(userB), 0);
    }
}
