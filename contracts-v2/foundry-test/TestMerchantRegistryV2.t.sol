// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {MerchantRegistry} from "../foundry-src/commerce/MerchantRegistry.sol";
import {MerchantRegistryV2} from "../foundry-src/commerce/MerchantRegistryV2.sol";

contract TestMerchantRegistryV2 is Test {
    ProxyAdmin proxyAdmin;
    TransparentUpgradeableProxy proxy;
    MerchantRegistry registryV1; // V1 interface pre-upgrade
    MerchantRegistryV2 registryV2; // V2 interface post-upgrade

    address owner = makeAddr("owner"); // Gnosis Safe
    address operator = makeAddr("operator"); // Founder EOA
    address merchant = makeAddr("merchant");
    address stranger = makeAddr("stranger");

    // ── Setup: deploy V1, simulate upgrade ────────────────────────────────────

    function setUp() public {
        // 1. Deploy V1
        MerchantRegistry implV1 = new MerchantRegistry();
        proxyAdmin = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        proxy = new TransparentUpgradeableProxy(address(implV1), address(proxyAdmin), initData);
        registryV1 = MerchantRegistry(address(proxy));

        // 2. Confirm V1 works — owner can setMerchant
        vm.prank(owner);
        registryV1.setMerchant(merchant, true);
        assertTrue(registryV1.isMerchant(merchant));

        vm.prank(owner);
        registryV1.setMerchant(merchant, false);
        assertFalse(registryV1.isMerchant(merchant));

        // 3. Deploy V2 impl and upgrade proxy
        MerchantRegistryV2 implV2 = new MerchantRegistryV2();
        // proxyAdmin.owner() == address(this) (test contract deployed it)
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(proxy)), address(implV2));
        registryV2 = MerchantRegistryV2(address(proxy));

        // 4. initializeV2 — sets operator (owner calls this via Safe after upgrade)
        vm.prank(owner);
        registryV2.initializeV2(operator);
    }

    // ── Post-upgrade storage integrity ────────────────────────────────────────

    function test_V1StoragePreserved_IsMerchantMapping() public view {
        assertFalse(registryV2.isMerchant(merchant)); // was set false at end of setup
    }

    function test_V1StoragePreserved_OwnerUnchanged() public view {
        assertEq(registryV2.owner(), owner);
    }

    function test_OperatorStoredCorrectly() public view {
        assertEq(registryV2.operator(), operator);
    }

    // ── setMerchant — operator path ───────────────────────────────────────────

    function test_OperatorCanEnableMerchant() public {
        vm.prank(operator);
        registryV2.setMerchant(merchant, true);
        assertTrue(registryV2.isMerchant(merchant));
    }

    function test_OperatorCanDisableMerchant() public {
        vm.prank(operator);
        registryV2.setMerchant(merchant, true);

        vm.prank(operator);
        registryV2.setMerchant(merchant, false);
        assertFalse(registryV2.isMerchant(merchant));
    }

    function test_OperatorSetMerchantEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantStatusChanged(merchant, true);

        vm.prank(operator);
        registryV2.setMerchant(merchant, true);
    }

    function test_OperatorCannotSetZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        registryV2.setMerchant(address(0), true);
    }

    // ── setMerchant — owner path still works ──────────────────────────────────

    function test_OwnerCanStillSetMerchant() public {
        vm.prank(owner);
        registryV2.setMerchant(merchant, true);
        assertTrue(registryV2.isMerchant(merchant));
    }

    // ── setMerchant — unauthorized ────────────────────────────────────────────

    function test_StrangerCannotSetMerchant() public {
        vm.prank(stranger);
        vm.expectRevert(MerchantRegistryV2.NotAuthorized.selector);
        registryV2.setMerchant(merchant, true);
    }

    // ── setOperator — only owner ──────────────────────────────────────────────

    function test_OwnerCanChangeOperator() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        registryV2.setOperator(newOp);
        assertEq(registryV2.operator(), newOp);

        // new operator can set merchants
        vm.prank(newOp);
        registryV2.setMerchant(merchant, true);
        assertTrue(registryV2.isMerchant(merchant));
    }

    function test_OwnerCanRemoveOperator() public {
        vm.prank(owner);
        registryV2.setOperator(address(0));
        assertEq(registryV2.operator(), address(0));

        // old operator can no longer set merchants
        vm.prank(operator);
        vm.expectRevert(MerchantRegistryV2.NotAuthorized.selector);
        registryV2.setMerchant(merchant, true);
    }

    function test_SetOperatorEmitsEvent() public {
        address newOp = makeAddr("newOp");
        vm.expectEmit(true, true, false, false);
        emit MerchantRegistryV2.OperatorSet(operator, newOp);

        vm.prank(owner);
        registryV2.setOperator(newOp);
    }

    function test_StrangerCannotSetOperator() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registryV2.setOperator(stranger);
    }

    function test_OperatorCannotSetOperator() public {
        vm.prank(operator);
        vm.expectRevert("Ownable: caller is not the owner");
        registryV2.setOperator(stranger);
    }

    // ── initializeV2 replay protection ───────────────────────────────────────

    function test_CannotReinitializeV2() public {
        vm.prank(owner);
        vm.expectRevert(); // reinitializer(2) blocks second call
        registryV2.initializeV2(operator);
    }

    // ── V1 initializeV1 replay protection still holds ─────────────────────────

    function test_CannotReinitializeV1() public {
        vm.prank(owner);
        vm.expectRevert(); // initializer only runs once
        registryV2.initialize(owner);
    }

    // ── Multiple merchants ────────────────────────────────────────────────────

    function test_OperatorCanOnboardMultipleMerchants() public {
        address m1 = makeAddr("m1");
        address m2 = makeAddr("m2");
        address m3 = makeAddr("m3");
        address m4 = makeAddr("m4");

        vm.startPrank(operator);
        registryV2.setMerchant(m1, true);
        registryV2.setMerchant(m2, true);
        registryV2.setMerchant(m3, true);
        registryV2.setMerchant(m4, true);
        vm.stopPrank();

        assertTrue(registryV2.isMerchant(m1));
        assertTrue(registryV2.isMerchant(m2));
        assertTrue(registryV2.isMerchant(m3));
        assertTrue(registryV2.isMerchant(m4));
    }
}
