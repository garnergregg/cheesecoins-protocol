// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {SuperHolderGovernance} from "../foundry-src/governance/SuperHolderGovernance.sol";
import {ProtocolTimelock} from "../foundry-src/governance/ProtocolTimelock.sol";
import {StakingManager} from "../foundry-src/staking/StakingManager.sol";
import {SceneTracker} from "../foundry-src/nft/extensions/SceneTracker.sol";
import {GovernanceWeighting} from "../foundry-src/governance/GovernanceWeighting.sol";
import {IGovernance} from "../foundry-src/governance/interfaces/IGovernance.sol";

/**
 * @title TestGovernanceFork
 * @notice Fork test for the full governance pipeline on Arbitrum Sepolia.
 *
 * Run with:
 *   forge test --match-contract TestGovernanceFork --fork-url $RPC_URL -vvv
 *
 * Prerequisites (must be done on-chain before running):
 *   1. ExecuteUpgrades.s.sol has been run (StakingManager upgraded, NNN registered under project 2)
 *   2. Founder holds a full NubiansNorthNFT collection (hasFullCollection = true)
 *
 * What this tests:
 *   1. Stake CURD -> stake attributed to project 2
 *   2. warp 24 weeks -> founder becomes eligible proposer
 *   3. Seed currentPotentialVotes via notifyPotentialVotingPowerChange (pranked as StakingManager)
 *   4. Grant SuperHolderGovernance PROPOSER_ROLE on timelock (pranked as founder)
 *   5. propose() -> vote() -> warp past voting period -> queueToProtocolTimelock()
 *   6. warp past timelock delay -> executeQueued()
 *   7. Verify proposal executed
 */
contract TestGovernanceFork is Test {
    address constant FOUNDER = 0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2;
    address constant NNN_NFT = 0x14c9c50e8ca7ff6B97E60949975F644E5F06dD4C;
    address constant STAKING_PROXY = 0x32528EF3ec91fa5Ed40b8a1845B13829141273CE;
    address constant SCENE_TRACKER = 0xF77072A3beDeA3A2e69D30f517eA93F95932bdBE;
    address constant SUPER_HOLDER_GOV = 0x74e4943736bb73195FcF1AF066f509Fe9f96AA03;
    address constant CURD_TOKEN = 0x3f6Be674ce67f4AC5FcDBB9839ab46fF8A6df6d9;
    address constant TIMELOCK = 0x4208a39a84264761B6B5e5655EB58DE4aF6ce152;
    uint256 constant PROJECT_ID = 2;
    uint256 constant STAKE_NFT_ID = 2;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant LOCK_MONTHS = 12;

    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    SuperHolderGovernance gov;
    ProtocolTimelock timelock;
    StakingManager staking;
    SceneTracker sceneTracker;

    function setUp() public {
        // Skip if not running against a fork — the hardcoded Sepolia addresses
        // have no code in default `forge test` mode, so any call against them reverts.
        // Run with `forge test --match-contract TestGovernanceFork --fork-url $RPC_URL`.
        if (SUPER_HOLDER_GOV.code.length == 0) {
            vm.skip(true);
            return;
        }
        gov = SuperHolderGovernance(SUPER_HOLDER_GOV);
        timelock = ProtocolTimelock(payable(TIMELOCK));
        staking = StakingManager(STAKING_PROXY);
        sceneTracker = SceneTracker(SCENE_TRACKER);
    }

    function test_fullGovernancePipeline() public {
        // STEP 1: VERIFY PRE-CONDITIONS

        assertTrue(sceneTracker.hasFullCollection(FOUNDER), "founder must have full collection");
        assertEq(
            staking.nftToProject(NNN_NFT), PROJECT_ID, "NNN must be mapped to project 2 - run ExecuteUpgrades first"
        );

        // STEP 2: STAKE

        vm.startPrank(FOUNDER);
        (bool approveOk,) =
            CURD_TOKEN.call(abi.encodeWithSignature("approve(address,uint256)", STAKING_PROXY, STAKE_AMOUNT));
        assertTrue(approveOk, "approve failed");
        staking.stake(STAKE_NFT_ID, STAKE_AMOUNT, LOCK_MONTHS);
        vm.stopPrank();

        assertGt(staking.getUserProjectStaked(FOUNDER, PROJECT_ID), 0, "stake not attributed to project 2");
        console.log("Stake attributed to project 2:", staking.getUserProjectStaked(FOUNDER, PROJECT_ID) / 1e18, "CURD");

        // STEP 3: SEED POTENTIAL VOTES ACCUMULATOR
        // notifyPotentialVotingPowerChange can only be called by stakingManager or sceneTracker.
        // After the upgrade StakingManager calls this automatically on stake().
        // We seed it manually here in case governanceNotifier is not yet set on StakingManager.

        if (gov.currentPotentialVotes() == 0) {
            vm.prank(STAKING_PROXY);
            gov.notifyPotentialVotingPowerChange(FOUNDER);
        }
        assertGt(gov.currentPotentialVotes(), 0, "currentPotentialVotes must be > 0 before proposing");
        console.log("currentPotentialVotes:", gov.currentPotentialVotes());

        // STEP 4: WARP 24 WEEKS FOR STAKE AGE

        vm.warp(block.timestamp + 24 weeks + 1);
        uint256 votingPower = gov.getVotingPower(FOUNDER);
        assertGt(votingPower, 0, "founder not eligible after 24 weeks");
        console.log("Founder voting power after warp:", votingPower);

        // STEP 5: GRANT PROPOSER_ROLE TO SuperHolderGovernance
        // In production this is the Stage 1 gate.
        // Here we simulate it as founder who holds TIMELOCK_ADMIN_ROLE in Stage 0.

        vm.startPrank(FOUNDER);
        timelock.grantRole(PROPOSER_ROLE, SUPER_HOLDER_GOV);
        timelock.grantRole(EXECUTOR_ROLE, SUPER_HOLDER_GOV);
        vm.stopPrank();
        assertTrue(timelock.hasRole(PROPOSER_ROLE, SUPER_HOLDER_GOV), "PROPOSER_ROLE not granted");
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, SUPER_HOLDER_GOV), "EXECUTOR_ROLE not granted");
        console.log("PROPOSER_ROLE and EXECUTOR_ROLE granted to SuperHolderGovernance");

        // STEP 6: PROPOSE
        // Dummy proposal: call getMinDelay() on the timelock (safe no-op read)

        bytes memory callData = abi.encodeWithSignature("getMinDelay()");
        vm.prank(FOUNDER);
        uint256 proposalId =
            gov.propose("Test proposal: verify full governance pipeline end-to-end", TIMELOCK, callData);
        assertEq(proposalId, 1, "proposalId should be 1");
        console.log("Proposal created:", proposalId);

        // STEP 7: VOTE

        vm.prank(FOUNDER);
        gov.vote(proposalId, true);
        IGovernance.Proposal memory p = gov.getProposal(proposalId);
        assertGt(p.forVotes, 0, "no votes recorded");
        console.log("Vote cast. forVotes:", p.forVotes);

        // STEP 8: WARP PAST VOTING PERIOD (30 days)

        vm.warp(block.timestamp + 30 days + 1);

        // STEP 9: QUEUE TO PROTOCOL TIMELOCK

        gov.queueToProtocolTimelock(proposalId);
        assertNotEq(gov.timelockOperationId(proposalId), bytes32(0), "operation not queued in timelock");
        console.log("Proposal queued in ProtocolTimelock");

        // STEP 10: WARP PAST TIMELOCK DELAY

        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        // STEP 11: EXECUTE

        gov.executeQueued(proposalId);
        assertTrue(gov.getProposal(proposalId).executed, "proposal not executed");
        console.log("Proposal executed via ProtocolTimelock");

        console.log("\n=== GOVERNANCE PIPELINE: ALL 11 STEPS PASSED ===");
    }
}
