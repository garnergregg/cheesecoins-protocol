// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../foundry-src/staking/TrancheStakingManager.sol";
import "../../foundry-src/staking/interfaces/ITrancheStakingManager.sol";
import "../../foundry-src/staking/interfaces/IAPRModel.sol";

// ============ MOCKS ============

/// @dev Minimal mintable ERC20 for CURD
contract MockCURDToken is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

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
        _tokenApprovals[tokenId] = address(0); // clear token-level approval on transfer
    }
}

/// @dev Fixed-rate APR model for testing setAprModel
contract MockAprModel is IAPRModel {
    uint32 public immutable fixedApr;

    constructor(uint32 _apr) {
        fixedApr = _apr;
    }

    function getApr(uint256, uint256) external view override returns (uint32) {
        return fixedApr;
    }
}

// ============ UNIT TESTS ============

/**
 * @title TrancheStakingManagerTest
 * @notice Unit and fuzz tests for TrancheStakingManager (Phase-3 PR1)
 */
contract TrancheStakingManagerTest is Test {
    TrancheStakingManager public impl;
    TrancheStakingManager public manager;
    ProxyAdmin public proxyAdmin;

    MockCURDToken public curd;
    MockCSANFT public nft;

    address public treasury = makeAddr("treasury");
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");
    address public operator = makeAddr("operator");

    uint256 public constant BASE_APR_BPS = 1000; // 10%
    uint256 public constant MIN_STAKE = 100e18;

    function setUp() public {
        curd = new MockCURDToken();
        nft = new MockCSANFT();

        impl = new TrancheStakingManager();
        proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(
            TrancheStakingManager.initialize.selector,
            address(curd),
            address(nft),
            treasury,
            BASE_APR_BPS,
            address(0) // no APR model
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        manager = TrancheStakingManager(address(proxy));
    }

    // ============ HELPERS ============

    function _fundRewards(uint256 amount) internal {
        curd.mint(treasury, amount);
        vm.prank(treasury);
        curd.approve(address(manager), amount);
        vm.prank(treasury);
        manager.fundRewards(amount);
    }

    function _stake(address user, uint256 nftId, uint256 amount) internal returns (uint256 trancheId) {
        curd.mint(user, amount);
        vm.prank(user);
        curd.approve(address(manager), amount);
        vm.prank(user);
        trancheId = manager.stake(nftId, amount);
    }

    function _trancheIds(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    // ============ BASIC STAKE / CLAIM / BREAK ============

    function test_stake_createsTrancheAndTracksActivePrincipal() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        ITrancheStakingManager.Tranche memory t = manager.getTranche(nftId, tid);
        assertEq(t.principal, MIN_STAKE);
        assertEq(t.aprBps, BASE_APR_BPS);
        assertFalse(t.closed);
        assertEq(manager.activePrincipal(nftId), MIN_STAKE);
        assertEq(manager.trancheCount(nftId), 1);
    }

    function test_stake_belowMinimum_reverts() public {
        uint256 nftId = nft.mint(userA);
        curd.mint(userA, MIN_STAKE);
        vm.prank(userA);
        curd.approve(address(manager), MIN_STAKE);

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.AmountBelowMinimum.selector);
        manager.stake(nftId, MIN_STAKE - 1);
    }

    function test_stake_unauthorized_reverts() public {
        uint256 nftId = nft.mint(userA);
        curd.mint(userB, MIN_STAKE);
        vm.prank(userB);
        curd.approve(address(manager), MIN_STAKE);

        vm.prank(userB);
        vm.expectRevert(TrancheStakingManager.NotAuthorized.selector);
        manager.stake(nftId, MIN_STAKE);
    }

    function test_claimMatured_paysOwner() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield);

        vm.warp(block.timestamp + 366 days);

        uint256 before = curd.balanceOf(userA);
        vm.prank(userA);
        manager.claimMatured(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA) - before, MIN_STAKE + yield);
        assertTrue(manager.getTranche(nftId, tid).closed, "Tranche must be closed");
        assertEq(manager.activePrincipal(nftId), 0);
    }

    function test_breakEarly_returnsPrincipalOnly() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        uint256 before = curd.balanceOf(userA);
        vm.prank(userA);
        manager.breakEarly(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA) - before, MIN_STAKE);
        assertTrue(manager.getTranche(nftId, tid).closed);
        assertEq(manager.activePrincipal(nftId), 0);
    }

    // ============ NFT TRANSFER: CLAIM RIGHTS FOLLOW NFT ============

    function test_nftTransfer_claimGoesToNewOwner() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield);

        // Transfer NFT A → B before maturity
        vm.prank(userA);
        nft.transferFrom(userA, userB, nftId);

        vm.warp(block.timestamp + 366 days);

        uint256 bBefore = curd.balanceOf(userB);
        // userB is now NFT owner; calling claimMatured pays userB
        vm.prank(userB);
        manager.claimMatured(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userB) - bBefore, MIN_STAKE + yield);
    }

    function test_nftTransfer_oldOwnerReceivesNothing() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield);

        vm.prank(userA);
        nft.transferFrom(userA, userB, nftId);

        vm.warp(block.timestamp + 366 days);

        // userA no longer owns NFT — should be rejected
        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.NotAuthorized.selector);
        manager.claimMatured(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA), 0, "Old owner must not receive funds");
    }

    // ============ OPERATOR APPROVAL TESTS ============

    function test_approvedOperator_canStakeRecipientIsOwner() public {
        uint256 nftId = nft.mint(userA);

        // userA approves operator for nftId
        vm.prank(userA);
        nft.approve(operator, nftId);

        // operator stakes (provides CURD themselves)
        curd.mint(operator, MIN_STAKE);
        vm.prank(operator);
        curd.approve(address(manager), MIN_STAKE);
        vm.prank(operator);
        uint256 tid = manager.stake(nftId, MIN_STAKE);

        // Verify tranche created
        assertEq(manager.getTranche(nftId, tid).principal, MIN_STAKE);

        // Fund and claim — recipient must still be userA (NFT owner)
        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield);
        vm.warp(block.timestamp + 366 days);

        uint256 aBefore = curd.balanceOf(userA);
        // userA (NFT owner) calls claim — recipient is themselves
        vm.prank(userA);
        manager.claimMatured(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA) - aBefore, MIN_STAKE + yield, "Recipient must be NFT owner");
    }

    function test_approvedForAll_operatorCanStake() public {
        uint256 nftId = nft.mint(userA);

        // userA approves operator for all NFTs
        vm.prank(userA);
        nft.setApprovalForAll(operator, true);

        curd.mint(operator, MIN_STAKE);
        vm.prank(operator);
        curd.approve(address(manager), MIN_STAKE);
        vm.prank(operator);
        uint256 tid = manager.stake(nftId, MIN_STAKE);

        assertEq(manager.getTranche(nftId, tid).principal, MIN_STAKE);
    }

    function test_approvedOperator_breakEarlyPaysOwner() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        // Approve operator
        vm.prank(userA);
        nft.approve(operator, nftId);

        uint256 aBefore = curd.balanceOf(userA);
        // operator calls breakEarly — principal goes to userA (NFT owner)
        vm.prank(operator);
        manager.breakEarly(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA) - aBefore, MIN_STAKE, "NFT owner must receive principal");
    }

    function test_approvedOperator_claimMaturedPaysOwnerNotOperator() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield);
        vm.warp(block.timestamp + 366 days);

        // Approve operator for nftId
        vm.prank(userA);
        nft.approve(operator, nftId);

        uint256 aBefore = curd.balanceOf(userA);
        uint256 opBefore = curd.balanceOf(operator);

        // operator calls claimMatured — payout must go to userA (NFT owner), not operator
        vm.prank(operator);
        manager.claimMatured(nftId, _trancheIds(tid));

        assertEq(curd.balanceOf(userA) - aBefore, MIN_STAKE + yield, "NFT owner must receive full payout");
        assertEq(curd.balanceOf(operator), opBefore, "Operator must receive nothing");
    }

    function test_closedTranche_claimReverts() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        uint256 yield = (MIN_STAKE * BASE_APR_BPS) / 10_000;
        _fundRewards(yield * 2); // fund extra so pool can't be the cause of the second revert

        vm.warp(block.timestamp + 366 days);

        vm.prank(userA);
        manager.claimMatured(nftId, _trancheIds(tid));

        // Second claim must revert
        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.TrancheClosed.selector);
        manager.claimMatured(nftId, _trancheIds(tid));
    }

    function test_closedTranche_breakEarlyReverts() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        vm.prank(userA);
        manager.breakEarly(nftId, _trancheIds(tid));

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.TrancheClosed.selector);
        manager.breakEarly(nftId, _trancheIds(tid));
    }

    // ============ MATURITY GUARD ============

    function test_breakEarly_revertsIfMatured() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        vm.warp(block.timestamp + 366 days);

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.TrancheMatured.selector);
        manager.breakEarly(nftId, _trancheIds(tid));
    }

    function test_claimMatured_revertsIfNotMatured() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.NotMatured.selector);
        manager.claimMatured(nftId, _trancheIds(tid));
    }

    // ============ INSUFFICIENT REWARDS POOL ============

    function test_claimMatured_revertsIfInsufficientRewards() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        // Do NOT fund rewards

        vm.warp(block.timestamp + 366 days);

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.InsufficientRewards.selector);
        manager.claimMatured(nftId, _trancheIds(tid));
    }

    // ============ ACTIVE PRINCIPAL INVARIANT ============

    function test_activePrincipal_sumOfOpenTranches() public {
        uint256 nftId = nft.mint(userA);
        uint256 amount1 = 100e18;
        uint256 amount2 = 250e18;

        _stake(userA, nftId, amount1);
        _stake(userA, nftId, amount2);

        assertEq(manager.activePrincipal(nftId), amount1 + amount2);
    }

    function test_activePrincipal_decreasesOnClaim() public {
        uint256 nftId = nft.mint(userA);
        uint256 t1 = _stake(userA, nftId, 100e18);
        _stake(userA, nftId, 200e18);

        uint256 yield1 = (100e18 * BASE_APR_BPS) / 10_000;
        _fundRewards(yield1);
        vm.warp(block.timestamp + 366 days);

        vm.prank(userA);
        manager.claimMatured(nftId, _trancheIds(t1));

        assertEq(manager.activePrincipal(nftId), 200e18);
    }

    function test_activePrincipal_decreasesOnBreak() public {
        uint256 nftId = nft.mint(userA);
        uint256 t1 = _stake(userA, nftId, 100e18);
        _stake(userA, nftId, 200e18);

        vm.prank(userA);
        manager.breakEarly(nftId, _trancheIds(t1));

        assertEq(manager.activePrincipal(nftId), 200e18);
    }

    // ============ PREVIEW YIELD / IS MATURED ============

    function test_previewYield_matchesExpected() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        assertEq(manager.previewYield(nftId, tid), (MIN_STAKE * BASE_APR_BPS) / 10_000);
    }

    function test_isMatured_falseBeforeMaturity() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        assertFalse(manager.isMatured(nftId, tid));
    }

    function test_isMatured_trueAfterMaturity() public {
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        vm.warp(block.timestamp + 366 days);
        assertTrue(manager.isMatured(nftId, tid));
    }

    // ============ FUND REWARDS ============

    function test_fundRewards_onlyTreasury() public {
        curd.mint(userA, 1000e18);
        vm.prank(userA);
        curd.approve(address(manager), 1000e18);

        vm.prank(userA);
        vm.expectRevert(TrancheStakingManager.NotTreasury.selector);
        manager.fundRewards(1000e18);
    }

    function test_fundRewards_zeroReverts() public {
        vm.prank(treasury);
        vm.expectRevert(TrancheStakingManager.ZeroAmount.selector);
        manager.fundRewards(0);
    }

    function test_fundRewards_updatesPool() public {
        _fundRewards(500e18);
        assertEq(manager.rewardsPool(), 500e18);
    }

    // ============ GOVERNANCE SETTERS ============

    function test_setTreasury_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        manager.setTreasury(userA);
    }

    function test_setTreasury_zeroReverts() public {
        vm.expectRevert(TrancheStakingManager.ZeroAddress.selector);
        manager.setTreasury(address(0));
    }

    function test_setTreasury_updatesAddress() public {
        manager.setTreasury(userB);
        assertEq(manager.treasury(), userB);
    }

    function test_setBaseAprBps_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        manager.setBaseAprBps(500);
    }

    function test_setBaseAprBps_updates() public {
        manager.setBaseAprBps(2000);
        assertEq(manager.baseAprBps(), 2000);
    }

    function test_setAprModel_updatesAndUsed() public {
        MockAprModel model = new MockAprModel(500);
        manager.setAprModel(address(model));
        assertEq(manager.aprModel(), address(model));

        // Stake should now use model APR (500 bps)
        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, MIN_STAKE);
        assertEq(manager.getTranche(nftId, tid).aprBps, 500);
    }

    function test_setAprModel_onlyOwner() public {
        vm.prank(userA);
        vm.expectRevert();
        manager.setAprModel(address(0));
    }

    // ============ MULTI-TRANCHE OPERATIONS ============

    function test_claimMultipleTranches() public {
        uint256 nftId = nft.mint(userA);
        uint256 t1 = _stake(userA, nftId, 100e18);
        uint256 t2 = _stake(userA, nftId, 200e18);

        uint256 y1 = (100e18 * BASE_APR_BPS) / 10_000;
        uint256 y2 = (200e18 * BASE_APR_BPS) / 10_000;
        _fundRewards(y1 + y2);

        vm.warp(block.timestamp + 366 days);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        uint256 before = curd.balanceOf(userA);
        vm.prank(userA);
        manager.claimMatured(nftId, ids);

        assertEq(curd.balanceOf(userA) - before, 100e18 + 200e18 + y1 + y2);
        assertEq(manager.activePrincipal(nftId), 0);
    }

    function test_breakMultipleTranches() public {
        uint256 nftId = nft.mint(userA);
        uint256 t1 = _stake(userA, nftId, 100e18);
        uint256 t2 = _stake(userA, nftId, 200e18);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        uint256 before = curd.balanceOf(userA);
        vm.prank(userA);
        manager.breakEarly(nftId, ids);

        assertEq(curd.balanceOf(userA) - before, 300e18);
        assertEq(manager.activePrincipal(nftId), 0);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_activePrincipal_matchesSumOfOpenTranches(uint256 count, uint256 amount) public {
        count = bound(count, 1, 10);
        amount = bound(amount, 100e18, 1_000_000e18);

        uint256 nftId = nft.mint(userA);
        uint256 expectedTotal;

        for (uint256 i = 0; i < count; i++) {
            _stake(userA, nftId, amount);
            expectedTotal += amount;
        }

        // activePrincipal must equal sum of all open tranches
        assertEq(manager.activePrincipal(nftId), expectedTotal);

        // Verify manually by iterating tranches
        uint256 sumFromTranches;
        for (uint256 i = 0; i < manager.trancheCount(nftId); i++) {
            ITrancheStakingManager.Tranche memory t = manager.getTranche(nftId, i);
            if (!t.closed) sumFromTranches += t.principal;
        }
        assertEq(manager.activePrincipal(nftId), sumFromTranches);
    }

    function testFuzz_breakEarly_activePrincipalAlwaysConsistent(uint256 amount) public {
        amount = bound(amount, 100e18, 1_000_000e18);

        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, amount);

        vm.prank(userA);
        manager.breakEarly(nftId, _trancheIds(tid));

        // After break, activePrincipal must be zero and tranche must be closed
        assertEq(manager.activePrincipal(nftId), 0);
        assertTrue(manager.getTranche(nftId, tid).closed);
    }

    function testFuzz_previewYield_formula(uint256 principal, uint32 aprBps) public {
        principal = bound(principal, 100e18, 1_000_000e18);
        aprBps = uint32(bound(aprBps, 1, 10_000));

        // Set APR model to custom rate
        MockAprModel model = new MockAprModel(aprBps);
        manager.setAprModel(address(model));

        uint256 nftId = nft.mint(userA);
        uint256 tid = _stake(userA, nftId, principal);

        uint256 expected = (principal * uint256(aprBps)) / 10_000;
        assertEq(manager.previewYield(nftId, tid), expected);
    }
}

// ============ INVARIANT TESTS ============

/// @dev Handler that drives invariant testing for TrancheStakingManager
contract TrancheInvariantHandler is Test {
    TrancheStakingManager public manager;
    MockCURDToken public curd;
    MockCSANFT public nft;

    address public user = makeAddr("inv_user");
    uint256 public nftId;

    constructor(TrancheStakingManager _manager, MockCURDToken _curd, MockCSANFT _nft) {
        manager = _manager;
        curd = _curd;
        nft = _nft;
        nftId = nft.mint(user);
    }

    function stakeTokens(uint256 amount) external {
        amount = bound(amount, 100e18, 10_000e18);
        curd.mint(user, amount);
        vm.prank(user);
        curd.approve(address(manager), amount);
        vm.prank(user);
        manager.stake(nftId, amount);
    }

    function breakTranche(uint256 idx) external {
        uint256 count = manager.trancheCount(nftId);
        if (count == 0) return;
        idx = idx % count;
        ITrancheStakingManager.Tranche memory t = manager.getTranche(nftId, idx);
        if (t.closed || block.timestamp >= t.maturityTime) return;

        uint256[] memory ids = new uint256[](1);
        ids[0] = idx;
        vm.prank(user);
        manager.breakEarly(nftId, ids);
    }
}

/**
 * @title TrancheStakingManagerInvariantTest
 * @notice Invariant: activePrincipal always equals sum of non-closed tranche principals
 */
contract TrancheStakingManagerInvariantTest is Test {
    TrancheStakingManager public manager;
    TrancheInvariantHandler public handler;
    MockCURDToken public curd;
    MockCSANFT public nft;

    address public treasury = makeAddr("inv_treasury");

    function setUp() public {
        curd = new MockCURDToken();
        nft = new MockCSANFT();

        TrancheStakingManager impl = new TrancheStakingManager();
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(
            TrancheStakingManager.initialize.selector, address(curd), address(nft), treasury, uint32(1000), address(0)
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        manager = TrancheStakingManager(address(proxy));

        handler = new TrancheInvariantHandler(manager, curd, nft);
        targetContract(address(handler));
    }

    function invariant_activePrincipalMatchesOpenTranches() public {
        uint256 nftId = handler.nftId();
        uint256 count = manager.trancheCount(nftId);

        uint256 sumFromTranches;
        for (uint256 i = 0; i < count; i++) {
            ITrancheStakingManager.Tranche memory t = manager.getTranche(nftId, i);
            if (!t.closed) sumFromTranches += t.principal;
        }

        assertEq(
            manager.activePrincipal(nftId), sumFromTranches, "activePrincipal must equal sum of open tranche principals"
        );
    }

    function invariant_rewardsPoolNeverNegative() public view {
        // rewardsPool is uint256 so can't underflow; just verify it's accessible
        manager.rewardsPool();
    }
}
