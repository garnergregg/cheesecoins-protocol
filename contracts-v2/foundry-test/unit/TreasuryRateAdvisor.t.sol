// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "../../foundry-src/staking/TreasuryRateAdvisor.sol";

// ============ MOCKS ============

/// @dev Minimal StakingManager mock that records setBaseAPY calls
contract MockStakingManager {
    uint256 public baseAPY;
    address public owner_;

    constructor(address _owner) {
        owner_ = _owner;
    }

    function setBaseAPY(uint256 newAPY) external {
        require(msg.sender == owner_, "MockSM: not owner");
        baseAPY = newAPY;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner_, "MockSM: not owner");
        owner_ = newOwner;
    }
}

// ============ TEST ============

contract TreasuryRateAdvisorTest is Test {
    TreasuryRateAdvisor public advisorImpl;
    TreasuryRateAdvisor public advisor;
    ProxyAdmin public proxyAdmin;
    MockStakingManager public sm;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public userA = makeAddr("userA");
    address public automation = makeAddr("automation");

    function setUp() public {
        proxyAdmin = new ProxyAdmin();
        advisorImpl = new TreasuryRateAdvisor();

        bytes memory init = abi.encodeWithSelector(
            TreasuryRateAdvisor.initialize.selector,
            treasury,
            address(0), // stakingManager set later
            owner
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(advisorImpl), address(proxyAdmin), init);
        advisor = TreasuryRateAdvisor(address(proxy));

        // Deploy mock staking manager owned by advisor (so applyToStakingManager works)
        sm = new MockStakingManager(address(advisor));

        vm.prank(owner);
        advisor.setStakingManager(address(sm));
    }

    // ============ INITIALIZE ============

    function test_initialize_setsFields() public {
        assertEq(advisor.treasury(), treasury);
        assertEq(advisor.stakingManager(), address(sm));
        assertEq(advisor.owner(), owner);
        assertEq(advisor.decisionCount(), 0);
    }

    function test_initialize_zeroTreasuryReverts() public {
        TreasuryRateAdvisor impl2 = new TreasuryRateAdvisor();
        bytes memory init =
            abi.encodeWithSelector(TreasuryRateAdvisor.initialize.selector, address(0), address(0), owner);
        vm.expectRevert(TreasuryRateAdvisor.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl2), address(proxyAdmin), init);
    }

    // ============ POST RATE DECISION ============

    function test_postRateDecision_onlyTreasury() public {
        vm.prank(userA);
        vm.expectRevert(TreasuryRateAdvisor.NotTreasury.selector);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");
    }

    function test_postRateDecision_storesDecision() public {
        vm.prank(treasury);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");

        assertEq(advisor.decisionCount(), 1);

        TreasuryRateAdvisor.RateDecision memory d = advisor.currentDecision();
        assertEq(d.fedFundsRateBps, 525);
        assertEq(d.spreadBps, 25);
        assertEq(d.effectiveRateBps, 550);
        assertEq(d.source, "FOMC 2026-03-19");
        assertGt(d.timestamp, 0);
    }

    function test_postRateDecision_emitsEvent() public {
        vm.prank(treasury);
        vm.expectEmit(true, false, false, true);
        emit TreasuryRateAdvisor.RateDecisionPosted(0, 525, 25, 550, block.timestamp, "FOMC 2026-03-19");
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");
    }

    function test_postRateDecision_fedRateTooHighReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRateAdvisor.FedRateTooHigh.selector, 2001, 2000));
        advisor.postRateDecision(2001, 0, "extreme");
    }

    function test_postRateDecision_spreadTooHighReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRateAdvisor.SpreadTooHigh.selector, 501, 500));
        advisor.postRateDecision(500, 501, "extreme");
    }

    function test_postRateDecision_zeroRate_allowed() public {
        // Fed rate of 0 is historically valid (2020-2022)
        vm.prank(treasury);
        advisor.postRateDecision(0, 25, "FOMC 2020-03-15");
        assertEq(advisor.currentEffectiveRateBps(), 25);
    }

    function test_postRateDecision_buildsHistory() public {
        vm.startPrank(treasury);
        advisor.postRateDecision(500, 25, "FOMC 2026-01-29");
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");
        advisor.postRateDecision(500, 25, "FOMC 2026-05-07");
        vm.stopPrank();

        assertEq(advisor.decisionCount(), 3);

        TreasuryRateAdvisor.RateDecision[] memory history = advisor.getRateHistory();
        assertEq(history.length, 3);
        assertEq(history[0].fedFundsRateBps, 500);
        assertEq(history[1].fedFundsRateBps, 525);
        assertEq(history[2].fedFundsRateBps, 500);

        // currentDecision always returns the latest
        assertEq(advisor.currentDecision().source, "FOMC 2026-05-07");
    }

    function test_getDecision_byIndex() public {
        vm.startPrank(treasury);
        advisor.postRateDecision(500, 25, "first");
        advisor.postRateDecision(525, 25, "second");
        vm.stopPrank();

        assertEq(advisor.getDecision(0).source, "first");
        assertEq(advisor.getDecision(1).source, "second");
    }

    // ============ APPLY TO STAKING MANAGER ============

    function test_applyToStakingManager_onlyAuthorized() public {
        vm.prank(treasury);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");

        vm.prank(userA);
        vm.expectRevert(TreasuryRateAdvisor.NotAuthorized.selector);
        advisor.applyToStakingManager();
    }

    function test_applyToStakingManager_byTreasury() public {
        vm.prank(treasury);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");

        vm.prank(treasury);
        advisor.applyToStakingManager();

        assertEq(sm.baseAPY(), 550);
    }

    function test_applyToStakingManager_byOwner() public {
        vm.prank(treasury);
        advisor.postRateDecision(400, 50, "FOMC 2026-05-07");

        vm.prank(owner);
        advisor.applyToStakingManager();

        assertEq(sm.baseAPY(), 450);
    }

    function test_applyToStakingManager_byAutomation() public {
        vm.prank(owner);
        advisor.grantAutomationRole(automation, true);

        vm.prank(treasury);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");

        vm.prank(automation);
        advisor.applyToStakingManager();

        assertEq(sm.baseAPY(), 550);
    }

    function test_applyToStakingManager_noDecisionReverts() public {
        vm.prank(treasury);
        vm.expectRevert(TreasuryRateAdvisor.NoDecisionPosted.selector);
        advisor.applyToStakingManager();
    }

    function test_applyToStakingManager_noSmReverts() public {
        // Deploy fresh advisor with no SM
        TreasuryRateAdvisor impl2 = new TreasuryRateAdvisor();
        bytes memory init = abi.encodeWithSelector(TreasuryRateAdvisor.initialize.selector, treasury, address(0), owner);
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(address(impl2), address(proxyAdmin), init);
        TreasuryRateAdvisor advisor2 = TreasuryRateAdvisor(address(proxy2));

        vm.prank(treasury);
        advisor2.postRateDecision(525, 25, "FOMC 2026-03-19");

        vm.prank(treasury);
        vm.expectRevert(TreasuryRateAdvisor.StakingManagerNotSet.selector);
        advisor2.applyToStakingManager();
    }

    function test_applyToStakingManager_emitsEvent() public {
        vm.prank(treasury);
        advisor.postRateDecision(525, 25, "FOMC 2026-03-19");

        vm.prank(treasury);
        vm.expectEmit(true, false, true, true);
        emit TreasuryRateAdvisor.RateApplied(address(sm), 550, treasury);
        advisor.applyToStakingManager();
    }

    function test_applyToStakingManager_appliesLatestRate() public {
        vm.startPrank(treasury);
        advisor.postRateDecision(500, 25, "first");
        advisor.postRateDecision(525, 25, "second");
        vm.stopPrank();

        vm.prank(treasury);
        advisor.applyToStakingManager();

        // Should apply the LATEST decision (525 + 25 = 550)
        assertEq(sm.baseAPY(), 550);
    }

    // ============ AUTOMATION ROLE ============

    function test_grantAutomationRole_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        advisor.grantAutomationRole(automation, true);
    }

    function test_grantAutomationRole_grantsAndRevokes() public {
        assertFalse(advisor.automationRole(automation));

        vm.prank(owner);
        advisor.grantAutomationRole(automation, true);
        assertTrue(advisor.automationRole(automation));

        vm.prank(owner);
        advisor.grantAutomationRole(automation, false);
        assertFalse(advisor.automationRole(automation));
    }

    function test_grantAutomationRole_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryRateAdvisor.ZeroAddress.selector);
        advisor.grantAutomationRole(address(0), true);
    }

    // ============ OWNER SETTERS ============

    function test_setTreasury_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        advisor.setTreasury(userA);
    }

    function test_setTreasury_updates() public {
        vm.prank(owner);
        advisor.setTreasury(userA);
        assertEq(advisor.treasury(), userA);
    }

    function test_setStakingManager_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        advisor.setStakingManager(userA);
    }

    function test_setStakingManager_updates() public {
        address newSm = makeAddr("newSm");
        vm.prank(owner);
        advisor.setStakingManager(newSm);
        assertEq(advisor.stakingManager(), newSm);
    }

    // ============ FUZZ ============

    function test_fuzz_postRateDecision_validRange(uint256 fedBps, uint256 spreadBps) public {
        fedBps = bound(fedBps, 0, 2000);
        spreadBps = bound(spreadBps, 0, 500);

        vm.prank(treasury);
        advisor.postRateDecision(fedBps, spreadBps, "fuzz");

        assertEq(advisor.currentEffectiveRateBps(), fedBps + spreadBps);
    }
}
