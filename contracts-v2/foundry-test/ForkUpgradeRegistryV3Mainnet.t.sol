// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MerchantRegistryV3} from "../foundry-src/commerce/MerchantRegistryV3.sol";

/**
 * @notice Mainnet-fork simulation of the V2 -> V3 upgrade.
 *         Forks Arbitrum One at the latest block, deploys V3 impl, prank-calls the
 *         Gnosis Safe to execute upgradeAndCall, then asserts both existing merchants
 *         survive the upgrade with default Tier.Merchant and that V3 functions work.
 *
 *         Run only when MAINNET_RPC_URL is set:
 *           MAINNET_RPC_URL="..." forge test --match-contract ForkUpgradeRegistryV3Mainnet -vvv
 */
contract ForkUpgradeRegistryV3Mainnet is Test {
    address constant B3_PROXY_ADMIN = 0xFB099D1c91d3edD29Ddab69cce452EB873ebEd0d;
    address constant MERCHANT_REGISTRY_PROXY = 0xCA7f73aCb86a8aCEf897c06eE23Adf8cDf8709bA;
    address constant GNOSIS_SAFE = 0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2;

    address constant NUBIANS_NORTH = 0x95F37A7A81EC031d993849c494b8B37553450385;
    address constant FIRST_MERCHANT_TEST = 0xa4cC8b68125b504910dCbf5e0e3b3CA81B2A1718;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
    }

    function test_PreUpgradeSanity() public view {
        // Sanity: confirm the fork sees the world we expect before doing anything
        bytes32 initSlot = vm.load(MERCHANT_REGISTRY_PROXY, bytes32(uint256(0)));
        assertEq(uint256(initSlot) & 0xff, 2, "Mainnet must be at V2 pre-upgrade");

        (bool okOwner, bytes memory ownerData) = MERCHANT_REGISTRY_PROXY.staticcall(abi.encodeWithSignature("owner()"));
        require(okOwner, "owner() call failed");
        assertEq(abi.decode(ownerData, (address)), GNOSIS_SAFE, "Registry owner must be Safe");

        assertEq(ProxyAdmin(B3_PROXY_ADMIN).owner(), GNOSIS_SAFE, "ProxyAdmin owner must be Safe");

        (bool okN, bytes memory dataN) =
            MERCHANT_REGISTRY_PROXY.staticcall(abi.encodeWithSignature("isMerchant(address)", NUBIANS_NORTH));
        require(okN, "isMerchant call failed");
        assertTrue(abi.decode(dataN, (bool)), "Nubians North must be merchant pre-upgrade");

        (bool okT, bytes memory dataT) =
            MERCHANT_REGISTRY_PROXY.staticcall(abi.encodeWithSignature("isMerchant(address)", FIRST_MERCHANT_TEST));
        require(okT, "isMerchant call failed");
        assertTrue(abi.decode(dataT, (bool)), "First test merchant must be merchant pre-upgrade");
    }

    function test_FullUpgradeFlow() public {
        // 1. Deploy V3 impl exactly as the deployer Ledger would
        MerchantRegistryV3 implV3 = new MerchantRegistryV3();

        // 2. Build the exact Safe calldata
        address[] memory addrs = new address[](0);
        MerchantRegistryV3.Tier[] memory tiers = new MerchantRegistryV3.Tier[](0);
        bytes memory v3InitData = abi.encodeWithSelector(MerchantRegistryV3.initializeV3.selector, addrs, tiers);

        // 3. Prank the Safe and execute the upgrade — this is the exact tx Greg will sign
        vm.prank(GNOSIS_SAFE);
        ProxyAdmin(B3_PROXY_ADMIN)
            .upgradeAndCall(ITransparentUpgradeableProxy(MERCHANT_REGISTRY_PROXY), address(implV3), v3InitData);

        // 4. Post-upgrade assertions — V3 features work
        MerchantRegistryV3 reg = MerchantRegistryV3(MERCHANT_REGISTRY_PROXY);

        bytes32 initSlot = vm.load(MERCHANT_REGISTRY_PROXY, bytes32(uint256(0)));
        assertEq(uint256(initSlot) & 0xff, 3, "_initialized must advance to 3");

        // 5. Both existing merchants survive
        assertTrue(reg.isMerchant(NUBIANS_NORTH), "Nubians North must still be merchant");
        assertTrue(reg.isMerchant(FIRST_MERCHANT_TEST), "Test merchant must still be merchant");

        // 6. Both default to Tier.Merchant (no migration was passed)
        assertEq(uint8(reg.merchantTier(NUBIANS_NORTH)), uint8(MerchantRegistryV3.Tier.Merchant));
        assertEq(uint8(reg.merchantTier(FIRST_MERCHANT_TEST)), uint8(MerchantRegistryV3.Tier.Merchant));

        // 7. New tier setter works post-upgrade — operator path
        address operatorEoa = reg.operator();
        vm.prank(operatorEoa);
        reg.setTier(NUBIANS_NORTH, MerchantRegistryV3.Tier.Producer);
        assertEq(uint8(reg.merchantTier(NUBIANS_NORTH)), uint8(MerchantRegistryV3.Tier.Producer));

        // 8. Adding a new merchant with a tier works
        address newMerchant = makeAddr("simulatedNewMerchant");
        vm.prank(operatorEoa);
        reg.setMerchantWithTier(newMerchant, true, MerchantRegistryV3.Tier.Distributor);
        assertTrue(reg.isMerchant(newMerchant));
        assertEq(uint8(reg.merchantTier(newMerchant)), uint8(MerchantRegistryV3.Tier.Distributor));

        // 9. Reinitialization is blocked
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert();
        reg.initializeV3(addrs, tiers);
    }
}
