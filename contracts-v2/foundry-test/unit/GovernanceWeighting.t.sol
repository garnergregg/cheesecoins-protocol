// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/Config.sol";
import "../../foundry-src/governance/GovernanceWeighting.sol";
import {IProjectRegistry} from "../../foundry-src/platform/interfaces/IProjectRegistry.sol";

/**
 * @title GovernanceWeightingTest
 * @notice Unit tests for GovernanceWeighting — Phase 6C Step 3.
 *         Validates that calculateVotingPower uses per-wallet userProjectStaked
 *         rather than the project-total totalStaked proxy.
 */
contract GovernanceWeightingTest is Test {
    // ── Mocks ────────────────────────────────────────────────────────────────

    StubStakingManager internal stubStaking;
    StubProjectRegistry internal stubRegistry;

    // ── Contract under test ──────────────────────────────────────────────────

    GovernanceWeighting internal weighting;

    // ── Actors ───────────────────────────────────────────────────────────────

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant PROJECT_ID = 1;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        stubStaking = new StubStakingManager();
        stubRegistry = new StubProjectRegistry();
        weighting = new GovernanceWeighting(address(stubStaking), address(stubRegistry));
    }

    // ── calculateVotingPower uses per-wallet stake ────────────────────────────

    /// @dev Alice has stake; Bob has zero. Their voting powers must differ.
    function test_calculateVotingPower_usesPerWalletStake() public {
        uint256 aliceStake = 1_000 * 1e18;
        uint256 bobStake = 0;

        stubStaking.setUserProjectStaked(alice, PROJECT_ID, aliceStake);
        stubStaking.setUserProjectStaked(bob, PROJECT_ID, bobStake);

        uint256 alicePower = weighting.calculateVotingPower(alice, PROJECT_ID, false);
        uint256 bobPower = weighting.calculateVotingPower(bob, PROJECT_ID, false);

        assertGt(alicePower, 0, "alice should have positive voting power");
        assertEq(bobPower, 0, "bob with zero stake should have zero voting power");
    }

    /// @dev Two voters with different per-wallet stakes must get different power.
    function test_calculateVotingPower_differentStakes_differentPower() public {
        uint256 smallStake = 100 * 1e18;
        uint256 largeStake = 100_000 * 1e18;

        stubStaking.setUserProjectStaked(alice, PROJECT_ID, smallStake);
        stubStaking.setUserProjectStaked(bob, PROJECT_ID, largeStake);

        uint256 alicePower = weighting.calculateVotingPower(alice, PROJECT_ID, false);
        uint256 bobPower = weighting.calculateVotingPower(bob, PROJECT_ID, false);

        assertLt(alicePower, bobPower, "larger personal stake should yield more voting power");
    }

    /// @dev Super holder multiplier (2x) is applied on top of per-wallet stake.
    function test_calculateVotingPower_superHolderMultiplier() public {
        uint256 stake = 1_000 * 1e18;
        stubStaking.setUserProjectStaked(alice, PROJECT_ID, stake);

        uint256 regular = weighting.calculateVotingPower(alice, PROJECT_ID, false);
        uint256 superHolder = weighting.calculateVotingPower(alice, PROJECT_ID, true);

        assertEq(superHolder, regular * Config.SUPER_HOLDER_MULTIPLIER, "super holder must get 2x multiplier");
    }

    /// @dev Zero voter address reverts.
    function test_calculateVotingPower_revertsOnZeroAddress() public {
        vm.expectRevert();
        weighting.calculateVotingPower(address(0), PROJECT_ID, false);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stubs
// ═══════════════════════════════════════════════════════════════════════════

contract StubStakingManager {
    mapping(address => mapping(uint256 => uint256)) internal _userStake;

    function setUserProjectStaked(address user, uint256 projectId, uint256 amount) external {
        _userStake[user][projectId] = amount;
    }

    function getUserProjectStaked(address user, uint256 projectId) external view returns (uint256) {
        return _userStake[user][projectId];
    }
}

contract StubProjectRegistry {
    function getProjectCount() external pure returns (uint256) {
        return 1;
    }

    function getProjectMetrics(uint256 projectId) external pure returns (IProjectRegistry.ProjectMetrics memory) {
        return IProjectRegistry.ProjectMetrics({
            projectId: projectId,
            growthRate: 100,
            totalStaked: 0,
            totalYieldDistributed: 0,
            nftHolders: 0,
            graduationWeight: 10000
        });
    }
}
