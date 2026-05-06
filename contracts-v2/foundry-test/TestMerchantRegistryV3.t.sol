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
import {MerchantRegistryV3} from "../foundry-src/commerce/MerchantRegistryV3.sol";

contract TestMerchantRegistryV3 is Test {
    ProxyAdmin proxyAdmin;
    TransparentUpgradeableProxy proxy;
    MerchantRegistryV3 registryV3;

    address owner = makeAddr("owner"); // Gnosis Safe
    address operator = makeAddr("operator"); // Founder EOA
    address merchant = makeAddr("merchant"); // V2-era merchant — should default to Tier.Merchant
    address producer = makeAddr("producer");
    address vendor = makeAddr("vendor");
    address stranger = makeAddr("stranger");

    // Slot positions (verified via forge inspect MerchantRegistryV3 storage-layout)
    uint256 constant SLOT_INITIALIZED = 0;
    uint256 constant SLOT_MERCHANT_TIER = 202;

    // Reinitializer expected progression
    bytes32 constant INITIALIZED_AFTER_V1 = bytes32(uint256(1));
    bytes32 constant INITIALIZED_AFTER_V2 = bytes32(uint256(2));
    bytes32 constant INITIALIZED_AFTER_V3 = bytes32(uint256(3));

    // ── Setup: V1 → V2 → V3 full proxy upgrade chain ─────────────────────────

    function setUp() public {
        // 1. Deploy V1 + init
        MerchantRegistry implV1 = new MerchantRegistry();
        proxyAdmin = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        proxy = new TransparentUpgradeableProxy(address(implV1), address(proxyAdmin), initData);

        // Confirm V1 init progression: slot 0 = 1
        bytes32 raw = vm.load(address(proxy), bytes32(SLOT_INITIALIZED));
        assertEq(raw & bytes32(uint256(0xffff)), INITIALIZED_AFTER_V1, "V1 init must set _initialized=1");

        // Set a V1-era merchant so we can verify storage preservation across two upgrades
        vm.prank(owner);
        MerchantRegistry(address(proxy)).setMerchant(merchant, true);

        // 2. Upgrade to V2 + initializeV2
        MerchantRegistryV2 implV2 = new MerchantRegistryV2();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(proxy)), address(implV2));
        vm.prank(owner);
        MerchantRegistryV2(address(proxy)).initializeV2(operator);

        // Confirm V2 init progression: slot 0 = 2
        raw = vm.load(address(proxy), bytes32(SLOT_INITIALIZED));
        assertEq(raw & bytes32(uint256(0xffff)), INITIALIZED_AFTER_V2, "V2 init must set _initialized=2");

        // 3. Upgrade to V3 + initializeV3 (with sample tier migration)
        MerchantRegistryV3 implV3 = new MerchantRegistryV3();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(proxy)), address(implV3));

        address[] memory addrs = new address[](2);
        addrs[0] = producer;
        addrs[1] = vendor;
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](2);
        tiers[0] = MerchantRegistryV3.Tier.Producer;
        tiers[1] = MerchantRegistryV3.Tier.Vendor;

        vm.prank(owner);
        MerchantRegistryV3(address(proxy)).initializeV3(addrs, tiers);
        registryV3 = MerchantRegistryV3(address(proxy));

        // Confirm V3 init progression: slot 0 = 3
        raw = vm.load(address(proxy), bytes32(SLOT_INITIALIZED));
        assertEq(raw & bytes32(uint256(0xffff)), INITIALIZED_AFTER_V3, "V3 init must set _initialized=3");
    }

    // ── Storage preservation across V1 → V2 → V3 ─────────────────────────────

    function test_V1Storage_IsMerchantPreserved() public view {
        // merchant was set true under V1; must still read true under V3
        assertTrue(registryV3.isMerchant(merchant));
    }

    function test_V1Storage_OwnerPreserved() public view {
        assertEq(registryV3.owner(), owner);
    }

    function test_V2Storage_OperatorPreserved() public view {
        assertEq(registryV3.operator(), operator);
    }

    // ── Tier defaults ────────────────────────────────────────────────────────

    function test_TierDefault_UnsetMerchantReadsAsMerchant() public view {
        // V1-era merchant — never had tier explicitly set — must read Tier.Merchant (0)
        assertEq(uint8(registryV3.merchantTier(merchant)), uint8(MerchantRegistryV3.Tier.Merchant));
        assertEq(uint8(registryV3.tierOf(merchant)), uint8(MerchantRegistryV3.Tier.Merchant));
    }

    function test_TierEnum_MerchantIsZero() public pure {
        // Enum encoding contract: Tier.Merchant MUST be value 0 for backwards-compat default.
        assertEq(uint8(MerchantRegistryV3.Tier.Merchant), 0);
        assertEq(uint8(MerchantRegistryV3.Tier.Vendor), 1);
        assertEq(uint8(MerchantRegistryV3.Tier.Producer), 2);
        assertEq(uint8(MerchantRegistryV3.Tier.Processor), 3);
        assertEq(uint8(MerchantRegistryV3.Tier.Distributor), 4);
    }

    // ── initializeV3 migration assignment ────────────────────────────────────

    function test_InitializeV3_AssignsTiersFromMigration() public view {
        assertEq(uint8(registryV3.merchantTier(producer)), uint8(MerchantRegistryV3.Tier.Producer));
        assertEq(uint8(registryV3.merchantTier(vendor)), uint8(MerchantRegistryV3.Tier.Vendor));
    }

    function test_InitializeV3_StorageEncoding_ViaVmLoad() public view {
        // Direct slot read of merchantTier mapping at slot 202.
        // mapping(address => Tier) → keccak256(abi.encode(producer, 202)) holds Tier value.
        bytes32 producerSlot = keccak256(abi.encode(producer, SLOT_MERCHANT_TIER));
        bytes32 raw = vm.load(address(proxy), producerSlot);
        assertEq(uint256(raw), uint256(uint8(MerchantRegistryV3.Tier.Producer)));

        bytes32 vendorSlot = keccak256(abi.encode(vendor, SLOT_MERCHANT_TIER));
        raw = vm.load(address(proxy), vendorSlot);
        assertEq(uint256(raw), uint256(uint8(MerchantRegistryV3.Tier.Vendor)));
    }

    // ── setMerchantWithTier ──────────────────────────────────────────────────

    function test_SetMerchantWithTier_OwnerCanCall() public {
        address m = makeAddr("newProducer");
        vm.prank(owner);
        registryV3.setMerchantWithTier(m, true, MerchantRegistryV3.Tier.Producer);
        assertTrue(registryV3.isMerchant(m));
        assertEq(uint8(registryV3.merchantTier(m)), uint8(MerchantRegistryV3.Tier.Producer));
    }

    function test_SetMerchantWithTier_OperatorCanCall() public {
        address m = makeAddr("newProcessor");
        vm.prank(operator);
        registryV3.setMerchantWithTier(m, true, MerchantRegistryV3.Tier.Processor);
        assertTrue(registryV3.isMerchant(m));
        assertEq(uint8(registryV3.merchantTier(m)), uint8(MerchantRegistryV3.Tier.Processor));
    }

    function test_SetMerchantWithTier_StrangerCannotCall() public {
        vm.prank(stranger);
        vm.expectRevert(MerchantRegistryV2.NotAuthorized.selector);
        registryV3.setMerchantWithTier(stranger, true, MerchantRegistryV3.Tier.Vendor);
    }

    function test_SetMerchantWithTier_RejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        registryV3.setMerchantWithTier(address(0), true, MerchantRegistryV3.Tier.Vendor);
    }

    function test_SetMerchantWithTier_EmitsBothEvents() public {
        address m = makeAddr("newDistributor");
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantStatusChanged(m, true);
        vm.expectEmit(true, true, false, false);
        emit MerchantRegistryV3.MerchantTierSet(m, MerchantRegistryV3.Tier.Distributor);

        vm.prank(operator);
        registryV3.setMerchantWithTier(m, true, MerchantRegistryV3.Tier.Distributor);
    }

    // ── setTier ──────────────────────────────────────────────────────────────

    function test_SetTier_RevertsIfNotMerchant() public {
        address m = makeAddr("notRegistered");
        vm.prank(owner);
        vm.expectRevert(MerchantRegistryV3.NotAMerchant.selector);
        registryV3.setTier(m, MerchantRegistryV3.Tier.Producer);
    }

    function test_SetTier_OwnerCanUpdateExistingMerchant() public {
        // merchant is already enabled (set in setUp via V1)
        vm.prank(owner);
        registryV3.setTier(merchant, MerchantRegistryV3.Tier.Processor);
        assertEq(uint8(registryV3.merchantTier(merchant)), uint8(MerchantRegistryV3.Tier.Processor));
    }

    function test_SetTier_OperatorCanUpdateExistingMerchant() public {
        vm.prank(operator);
        registryV3.setTier(merchant, MerchantRegistryV3.Tier.Distributor);
        assertEq(uint8(registryV3.merchantTier(merchant)), uint8(MerchantRegistryV3.Tier.Distributor));
    }

    function test_SetTier_StrangerCannotCall() public {
        vm.prank(stranger);
        vm.expectRevert(MerchantRegistryV2.NotAuthorized.selector);
        registryV3.setTier(merchant, MerchantRegistryV3.Tier.Vendor);
    }

    function test_SetTier_RejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        registryV3.setTier(address(0), MerchantRegistryV3.Tier.Vendor);
    }

    // ── initializeV3 input validation ────────────────────────────────────────

    function test_InitializeV3_RevertsOnLengthMismatch() public {
        // Spin up a fresh proxy chain to test initializeV3 freshly
        MerchantRegistry implV1 = new MerchantRegistry();
        ProxyAdmin pa = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(address(implV1), address(pa), initData);

        MerchantRegistryV2 implV2 = new MerchantRegistryV2();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV2));
        vm.prank(owner);
        MerchantRegistryV2(address(p)).initializeV2(operator);

        MerchantRegistryV3 implV3 = new MerchantRegistryV3();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV3));

        address[] memory addrs = new address[](2);
        addrs[0] = producer;
        addrs[1] = vendor;
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](1);
        tiers[0] = MerchantRegistryV3.Tier.Producer;

        vm.prank(owner);
        vm.expectRevert(MerchantRegistryV3.LengthMismatch.selector);
        MerchantRegistryV3(address(p)).initializeV3(addrs, tiers);
    }

    function test_InitializeV3_AcceptsEmptyArrays() public {
        // Fresh chain — no migration — initializeV3 with empty arrays is the no-op path
        MerchantRegistry implV1 = new MerchantRegistry();
        ProxyAdmin pa = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(address(implV1), address(pa), initData);

        MerchantRegistryV2 implV2 = new MerchantRegistryV2();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV2));
        vm.prank(owner);
        MerchantRegistryV2(address(p)).initializeV2(operator);

        MerchantRegistryV3 implV3 = new MerchantRegistryV3();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV3));

        address[] memory addrs = new address[](0);
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](0);

        vm.prank(owner);
        MerchantRegistryV3(address(p)).initializeV3(addrs, tiers);

        // No tier writes happened
        assertEq(uint8(MerchantRegistryV3(address(p)).merchantTier(producer)), uint8(MerchantRegistryV3.Tier.Merchant));
    }

    function test_InitializeV3_RejectsZeroAddress() public {
        MerchantRegistry implV1 = new MerchantRegistry();
        ProxyAdmin pa = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(MerchantRegistry.initialize.selector, owner);
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(address(implV1), address(pa), initData);

        MerchantRegistryV2 implV2 = new MerchantRegistryV2();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV2));
        vm.prank(owner);
        MerchantRegistryV2(address(p)).initializeV2(operator);

        MerchantRegistryV3 implV3 = new MerchantRegistryV3();
        pa.upgrade(ITransparentUpgradeableProxy(address(p)), address(implV3));

        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](1);
        tiers[0] = MerchantRegistryV3.Tier.Producer;

        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        MerchantRegistryV3(address(p)).initializeV3(addrs, tiers);
    }

    // ── reinitializer(3) replay protection ───────────────────────────────────

    function test_CannotReinitializeV3() public {
        address[] memory addrs = new address[](0);
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](0);

        vm.prank(owner);
        vm.expectRevert();
        registryV3.initializeV3(addrs, tiers);
    }

    function test_CannotReinitializeV2() public {
        vm.prank(owner);
        vm.expectRevert();
        registryV3.initializeV2(operator);
    }

    function test_CannotReinitializeV1() public {
        vm.prank(owner);
        vm.expectRevert();
        registryV3.initialize(owner);
    }

    // ── V2 behaviors still work under V3 ─────────────────────────────────────

    function test_V2Path_OperatorCanStillSetMerchant() public {
        address m = makeAddr("legacyPath");
        vm.prank(operator);
        registryV3.setMerchant(m, true);
        assertTrue(registryV3.isMerchant(m));
        // Tier defaults to Merchant since setMerchant doesn't touch tier
        assertEq(uint8(registryV3.merchantTier(m)), uint8(MerchantRegistryV3.Tier.Merchant));
    }

    function test_V2Path_OwnerCanChangeOperator() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        registryV3.setOperator(newOp);
        assertEq(registryV3.operator(), newOp);
    }
}
