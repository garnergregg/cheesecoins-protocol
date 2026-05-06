// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../foundry-src/commerce/MerchantRegistry.sol";
import "../../foundry-src/commerce/MerchantSettlement.sol";

// ============ MOCKS ============

/// @dev Minimal mintable ERC20 compatible with ICheesecoinsCore (only ERC20 surface needed here)
contract MockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============ TEST SUITE ============

/**
 * @title MerchantSettlementTest
 * @notice Unit tests for MerchantRegistry + MerchantSettlement (Phase 4).
 */
contract MerchantSettlementTest is Test {
    // Contracts under test
    MerchantRegistry public registryImpl;
    MerchantRegistry public registry;

    MerchantSettlement public settlementImpl;
    MerchantSettlement public settlement;

    ProxyAdmin public proxyAdmin;

    // Mock token
    MockCURD public curd;

    // Actors
    address public owner = makeAddr("owner");
    address public payer = makeAddr("payer");
    address public merchant = makeAddr("merchant");
    address public nonMerchant = makeAddr("nonMerchant");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        curd = new MockCURD();
        proxyAdmin = new ProxyAdmin();

        // Deploy MerchantRegistry through proxy
        registryImpl = new MerchantRegistry();
        bytes memory regInit = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy regProxy =
            new TransparentUpgradeableProxy(address(registryImpl), address(proxyAdmin), regInit);
        registry = MerchantRegistry(address(regProxy));

        // Deploy MerchantSettlement through proxy
        settlementImpl = new MerchantSettlement();
        bytes memory settInit =
            abi.encodeWithSelector(MerchantSettlement.initialize.selector, address(curd), address(registry), owner);
        TransparentUpgradeableProxy settProxy =
            new TransparentUpgradeableProxy(address(settlementImpl), address(proxyAdmin), settInit);
        settlement = MerchantSettlement(address(settProxy));

        // Enable merchant in registry
        vm.prank(owner);
        registry.setMerchant(merchant, true);

        // Fund payer with CURD and approve settlement contract
        curd.mint(payer, 10_000e18);
        vm.prank(payer);
        curd.approve(address(settlement), type(uint256).max);
    }

    // ============ REGISTRY INITIALIZATION ============

    function test_registry_initialize_setsOwner() public {
        assertEq(registry.owner(), owner);
    }

    // ============ REGISTRY ACCESS CONTROL ============

    function test_registry_setMerchant_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setMerchant(nonMerchant, true);
    }

    function test_registry_setMerchant_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        registry.setMerchant(address(0), true);
    }

    function test_registry_setMerchant_enablesAndDisables() public {
        assertFalse(registry.isMerchant(nonMerchant));

        vm.prank(owner);
        registry.setMerchant(nonMerchant, true);
        assertTrue(registry.isMerchant(nonMerchant));

        vm.prank(owner);
        registry.setMerchant(nonMerchant, false);
        assertFalse(registry.isMerchant(nonMerchant));
    }

    function test_registry_setMerchant_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantStatusChanged(nonMerchant, true);
        registry.setMerchant(nonMerchant, true);
    }

    // ============ SETTLEMENT INITIALIZATION ============

    function test_settlement_initialize_setsFields() public {
        assertEq(address(settlement.curd()), address(curd));
        assertEq(address(settlement.registry()), address(registry));
        assertEq(settlement.owner(), owner);
    }

    // ============ NON-MERCHANT CANNOT RECEIVE PAYMENT ============

    function test_payMerchant_revertsForNonMerchant() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MerchantSettlement.NotAMerchant.selector, nonMerchant));
        settlement.payMerchant(nonMerchant, 100e18, bytes32("ref1"));
    }

    // ============ ZERO AMOUNT REVERTS ============

    function test_payMerchant_revertsOnZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(MerchantSettlement.ZeroAmount.selector);
        settlement.payMerchant(merchant, 0, bytes32("ref2"));
    }

    // ============ SUCCESSFUL PAYMENT ============

    function test_payMerchant_transfersCurdToMerchant() public {
        uint256 amount = 500e18;
        uint256 payerBefore = curd.balanceOf(payer);
        uint256 merchantBefore = curd.balanceOf(merchant);

        vm.prank(payer);
        settlement.payMerchant(merchant, amount, bytes32("ref3"));

        assertEq(curd.balanceOf(payer), payerBefore - amount, "Payer balance must decrease");
        assertEq(curd.balanceOf(merchant), merchantBefore + amount, "Merchant balance must increase");
    }

    function test_payMerchant_emitsMerchantPaymentEvent() public {
        uint256 amount = 100e18;
        bytes32 ref = bytes32("invoice-42");

        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit MerchantSettlement.MerchantPayment(payer, merchant, amount, ref);
        settlement.payMerchant(merchant, amount, ref);
    }

    // ============ SETTLEMENT CONTRACT NEVER HOLDS CURD ============

    function test_payMerchant_settlementBalanceRemainsZero() public {
        vm.prank(payer);
        settlement.payMerchant(merchant, 1_000e18, bytes32("ref4"));

        assertEq(curd.balanceOf(address(settlement)), 0, "Settlement must never hold CURD");
    }

    // ============ PAUSE / UNPAUSE ============

    function test_pause_blocksPayMerchant() public {
        vm.prank(owner);
        settlement.pause();

        vm.prank(payer);
        vm.expectRevert("Pausable: paused");
        settlement.payMerchant(merchant, 100e18, bytes32("ref5"));
    }

    function test_unpause_restoresPayMerchant() public {
        vm.prank(owner);
        settlement.pause();

        vm.prank(owner);
        settlement.unpause();

        uint256 merchantBefore = curd.balanceOf(merchant);
        vm.prank(payer);
        settlement.payMerchant(merchant, 100e18, bytes32("ref6"));
        assertGt(curd.balanceOf(merchant), merchantBefore);
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        settlement.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        settlement.pause();

        vm.prank(stranger);
        vm.expectRevert();
        settlement.unpause();
    }

    // ============ SET REGISTRY ============

    function test_setRegistry_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        settlement.setRegistry(address(registry));
    }

    function test_setRegistry_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MerchantSettlement.ZeroAddress.selector);
        settlement.setRegistry(address(0));
    }

    function test_setRegistry_updates() public {
        // Deploy a new registry
        MerchantRegistry newRegistryImpl = new MerchantRegistry();
        bytes memory init = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy p =
            new TransparentUpgradeableProxy(address(newRegistryImpl), address(proxyAdmin), init);
        MerchantRegistry newRegistry = MerchantRegistry(address(p));

        vm.prank(owner);
        settlement.setRegistry(address(newRegistry));

        assertEq(address(settlement.registry()), address(newRegistry));
    }

    // ============ FUZZ: RANDOM AMOUNTS + REFERENCES ============

    function testFuzz_payMerchant_settlementBalanceAlwaysZero(uint256 amount, bytes32 ref) public {
        amount = bound(amount, 1, 10_000e18);

        vm.prank(payer);
        settlement.payMerchant(merchant, amount, ref);

        assertEq(curd.balanceOf(address(settlement)), 0, "Settlement must never hold CURD");
    }

    function testFuzz_payMerchant_merchantReceivesFullAmount(uint256 amount, bytes32 ref) public {
        amount = bound(amount, 1, 10_000e18);

        uint256 merchantBefore = curd.balanceOf(merchant);

        vm.prank(payer);
        settlement.payMerchant(merchant, amount, ref);

        assertEq(curd.balanceOf(merchant), merchantBefore + amount, "Merchant must receive full amount");
    }
}
