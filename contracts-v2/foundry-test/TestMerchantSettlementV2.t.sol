// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerchantRegistry} from "../foundry-src/commerce/MerchantRegistry.sol";
import {MerchantSettlement} from "../foundry-src/commerce/MerchantSettlement.sol";
import {MerchantSettlementV2} from "../foundry-src/commerce/MerchantSettlementV2.sol";

contract MockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TestMerchantSettlementV2 is Test {
    ProxyAdmin proxyAdmin;
    TransparentUpgradeableProxy proxy;
    MerchantSettlement settlementV1;
    MerchantSettlementV2 settlementV2;

    MerchantRegistry registry;
    MockCURD curd;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address merchant = makeAddr("merchant");
    address payer = makeAddr("payer");
    address stranger = makeAddr("stranger");

    // ── Setup: deploy V1, upgrade to V2 ──────────────────────────────────────

    function setUp() public {
        curd = new MockCURD();

        // Deploy registry and enable merchant
        MerchantRegistry regImpl = new MerchantRegistry();
        ProxyAdmin regAdmin = new ProxyAdmin();
        bytes memory regInit = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy regProxy =
            new TransparentUpgradeableProxy(address(regImpl), address(regAdmin), regInit);
        registry = MerchantRegistry(address(regProxy));
        vm.prank(owner);
        registry.setMerchant(merchant, true);

        // Deploy Settlement V1
        MerchantSettlement implV1 = new MerchantSettlement();
        proxyAdmin = new ProxyAdmin();
        bytes memory settInit =
            abi.encodeWithSelector(MerchantSettlement.initialize.selector, address(curd), address(registry), owner);
        proxy = new TransparentUpgradeableProxy(address(implV1), address(proxyAdmin), settInit);
        settlementV1 = MerchantSettlement(address(proxy));

        // Fund payer
        curd.mint(payer, 10_000e18);
        vm.prank(payer);
        curd.approve(address(proxy), type(uint256).max);

        // Upgrade to V2
        MerchantSettlementV2 implV2 = new MerchantSettlementV2();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(proxy)), address(implV2));
        settlementV2 = MerchantSettlementV2(address(proxy));

        // initializeV2 — sets operator
        vm.prank(owner);
        settlementV2.initializeV2(operator);
    }

    // ── Storage preservation ──────────────────────────────────────────────────

    function test_V1StoragePreserved_Curd() public view {
        assertEq(address(settlementV2.curd()), address(curd));
    }

    function test_V1StoragePreserved_Registry() public view {
        assertEq(address(settlementV2.registry()), address(registry));
    }

    function test_V1StoragePreserved_Owner() public view {
        assertEq(settlementV2.owner(), owner);
    }

    function test_OperatorStoredCorrectly() public view {
        assertEq(settlementV2.operator(), operator);
    }

    // ── payMerchant unchanged ─────────────────────────────────────────────────

    function test_PayMerchantStillWorks() public {
        uint256 amount = 500e18;
        uint256 before = curd.balanceOf(merchant);

        vm.prank(payer);
        settlementV2.payMerchant(merchant, amount, bytes32("ref-1"));

        assertEq(curd.balanceOf(merchant), before + amount);
        assertEq(curd.balanceOf(address(settlementV2)), 0);
    }

    function test_PayMerchantBlockedWhenPaused() public {
        vm.prank(operator);
        settlementV2.pause();

        vm.prank(payer);
        vm.expectRevert("Pausable: paused");
        settlementV2.payMerchant(merchant, 100e18, bytes32("ref"));
    }

    // ── pause — operator path ─────────────────────────────────────────────────

    function test_OperatorCanPause() public {
        vm.prank(operator);
        settlementV2.pause();
        assertTrue(settlementV2.paused());
    }

    function test_OperatorCanUnpause() public {
        vm.prank(operator);
        settlementV2.pause();

        vm.prank(operator);
        settlementV2.unpause();
        assertFalse(settlementV2.paused());
    }

    // ── pause — owner path still works ───────────────────────────────────────

    function test_OwnerCanPause() public {
        vm.prank(owner);
        settlementV2.pause();
        assertTrue(settlementV2.paused());
    }

    function test_OwnerCanUnpause() public {
        vm.prank(owner);
        settlementV2.pause();

        vm.prank(owner);
        settlementV2.unpause();
        assertFalse(settlementV2.paused());
    }

    // ── pause — unauthorized ──────────────────────────────────────────────────

    function test_StrangerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(MerchantSettlementV2.NotAuthorized.selector);
        settlementV2.pause();
    }

    function test_StrangerCannotUnpause() public {
        vm.prank(owner);
        settlementV2.pause();

        vm.prank(stranger);
        vm.expectRevert(MerchantSettlementV2.NotAuthorized.selector);
        settlementV2.unpause();
    }

    // ── setOperator ───────────────────────────────────────────────────────────

    function test_OwnerCanChangeOperator() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        settlementV2.setOperator(newOp);
        assertEq(settlementV2.operator(), newOp);

        vm.prank(newOp);
        settlementV2.pause();
        assertTrue(settlementV2.paused());
    }

    function test_OwnerCanRemoveOperator() public {
        vm.prank(owner);
        settlementV2.setOperator(address(0));
        assertEq(settlementV2.operator(), address(0));

        vm.prank(operator);
        vm.expectRevert(MerchantSettlementV2.NotAuthorized.selector);
        settlementV2.pause();
    }

    function test_SetOperatorEmitsEvent() public {
        address newOp = makeAddr("newOp");
        vm.expectEmit(true, true, false, false);
        emit MerchantSettlementV2.OperatorSet(operator, newOp);

        vm.prank(owner);
        settlementV2.setOperator(newOp);
    }

    function test_StrangerCannotSetOperator() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        settlementV2.setOperator(stranger);
    }

    function test_OperatorCannotSetOperator() public {
        vm.prank(operator);
        vm.expectRevert("Ownable: caller is not the owner");
        settlementV2.setOperator(stranger);
    }

    // ── setRegistry — stays onlyOwner ─────────────────────────────────────────

    function test_OwnerCanSetRegistry() public {
        MerchantRegistry newRegImpl = new MerchantRegistry();
        ProxyAdmin newAdmin = new ProxyAdmin();
        bytes memory init = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy newRegProxy =
            new TransparentUpgradeableProxy(address(newRegImpl), address(newAdmin), init);
        vm.prank(owner);
        settlementV2.setRegistry(address(newRegProxy));
        assertEq(address(settlementV2.registry()), address(newRegProxy));
    }

    function test_OperatorCannotSetRegistry() public {
        vm.prank(operator);
        vm.expectRevert("Ownable: caller is not the owner");
        settlementV2.setRegistry(makeAddr("newReg"));
    }

    function test_StrangerCannotSetRegistry() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        settlementV2.setRegistry(makeAddr("newReg"));
    }

    // ── initializeV2 replay protection ───────────────────────────────────────

    function test_CannotReinitializeV2() public {
        vm.prank(owner);
        vm.expectRevert();
        settlementV2.initializeV2(operator);
    }

    function test_CannotReinitializeV1() public {
        vm.prank(owner);
        vm.expectRevert();
        settlementV2.initialize(address(curd), address(registry), owner);
    }
}
