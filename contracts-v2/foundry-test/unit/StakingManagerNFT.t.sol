// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../foundry-src/staking/MerkleYieldClaimer.sol";
import "../../foundry-src/staking/StakingManager.sol";
import "../../foundry-src/staking/interfaces/IStakingManager.sol";
import "../../foundry-src/staking/interfaces/IYieldPool.sol";
import "../../foundry-src/nft/TransferHookRouter.sol";
import "../../foundry-src/Config.sol";

// ============ MOCKS ============

/// @dev Minimal ERC20 that also implements ICheesecoinsCore.burn() for StakingManager
contract MockCURD is ERC20 {
    constructor() ERC20("Mock CURD", "CURD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev burn() is called by StakingManager on its own balance during early unstake
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Minimal ERC721 with ownerOf, transfer, getProjectId for StakingManager tests
contract MockNFT {
    mapping(uint256 => address) private _owners;
    uint256 public constant PROJECT_ID = 1;
    uint256 private _nextId = 1;

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "MockNFT: nonexistent token");
        return owner;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "MockNFT: not owner");
        _owners[tokenId] = to;
    }

    function getProjectId() external pure returns (uint256) {
        return PROJECT_ID;
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Minimal IYieldPool for MerkleYieldClaimer tests
contract MockYieldPool is IYieldPool {
    mapping(uint256 => bytes32) private _roots;
    mapping(uint256 => uint256) private _balances;
    mapping(uint256 => YieldDistribution[]) private _distributions;

    address public token;

    constructor(address _token) {
        token = _token;
    }

    function fund(uint256 projectId, uint256 amount) external {
        _balances[projectId] += amount;
        MockCURD(token).mint(address(this), amount);
    }

    function setRoot(uint256 projectId, bytes32 root, uint256 distributionTime) external {
        _roots[projectId] = root;
        _distributions[projectId]
        .push(
            YieldDistribution({
                projectId: projectId,
                totalYield: _balances[projectId],
                nftCount: 1,
                distributionTime: distributionTime,
                merkleRoot: root
            })
        );
    }

    function depositYield(uint256 projectId, uint256 amount) external override {
        _balances[projectId] += amount;
    }

    function setMerkleRoot(uint256 projectId, bytes32 root) external override {
        _roots[projectId] = root;
    }

    function getAvailableYield(uint256 projectId) external view override returns (uint256) {
        return _balances[projectId];
    }

    function getDistribution(uint256 projectId, uint256 index)
        external
        view
        override
        returns (YieldDistribution memory)
    {
        require(index < _distributions[projectId].length, "MockYieldPool: invalid index");
        return _distributions[projectId][index];
    }

    function debitYield(uint256 projectId, address recipient, uint256 amount) external override {
        require(_balances[projectId] >= amount, "MockYieldPool: insufficient balance");
        _balances[projectId] -= amount;
        IERC20(token).transfer(recipient, amount);
    }

    function getCurrentMerkleRoot(uint256 projectId) external view override returns (bytes32) {
        return _roots[projectId];
    }
}

// ============ TEST CONTRACTS ============

/**
 * @title StakingManagerNFTTest
 * @notice Tests for isEligibleForRewards and NFT-bound staking positions
 */
contract StakingManagerNFTTest is Test {
    StakingManager public stakingManagerImpl;
    StakingManager public stakingManager;
    ProxyAdmin public proxyAdmin;

    MockCURD public curd;
    MockNFT public nft;
    address public treasury = makeAddr("treasury");

    address public owner;
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");

    uint256 public constant BASE_APY = 1000; // 10%

    function setUp() public {
        owner = address(this);

        curd = new MockCURD();
        nft = new MockNFT();

        // Deploy StakingManager through proxy (matches production pattern)
        stakingManagerImpl = new StakingManager();
        proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(
            StakingManager.initialize.selector,
            address(curd),
            makeAddr("yieldPool"), // YieldPool not used in these tests
            treasury,
            BASE_APY
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(stakingManagerImpl), address(proxyAdmin), initData);
        stakingManager = StakingManager(address(proxy));

        // Register NFT IDs 1 and 2 to the mock NFT contract (project 1, total 10 NFTs)
        stakingManager.registerNFT(address(nft), 1, 1, 10);
        stakingManager.registerNFT(address(nft), 2, 1, 0);
    }

    // ============ isEligibleForRewards TESTS ============

    function test_isEligibleForRewards_noPosition() public view {
        // NFT 1 has no staking position → not eligible
        assertFalse(stakingManager.isEligibleForRewards(1));
    }

    function test_isEligibleForRewards_activePosition() public {
        // Mint NFT 1 to userA and stake MIN_STAKE_PER_NFT
        vm.prank(address(this));
        nft.mint(userA); // tokenId 1

        uint256 stakeAmount = Config.MIN_STAKE_PER_NFT; // 100e18
        curd.mint(userA, stakeAmount);

        vm.startPrank(userA);
        curd.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(1, stakeAmount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertTrue(stakingManager.isEligibleForRewards(1));
    }

    function test_rewardsAccrue_atOrAboveMinStake() public {
        // Stake exactly at threshold → eligible; stake above → also eligible
        nft.mint(userA); // tokenId 1
        nft.mint(userA); // tokenId 2

        uint256 atThreshold = Config.MIN_STAKE_PER_NFT;
        uint256 aboveThreshold = Config.MIN_STAKE_PER_NFT * 2;

        curd.mint(userA, atThreshold + aboveThreshold);

        vm.startPrank(userA);
        curd.approve(address(stakingManager), atThreshold + aboveThreshold);
        stakingManager.stake(1, atThreshold, Config.LOCK_1_YEAR_MONTHS);
        stakingManager.stake(2, aboveThreshold, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertTrue(stakingManager.isEligibleForRewards(1), "At threshold should be eligible");
        assertTrue(stakingManager.isEligibleForRewards(2), "Above threshold should be eligible");
    }

    function test_rewardsZero_belowMinStake() public {
        // Stake 200 CURD, then do a mature partial unstake leaving 50 CURD (below 100 min)
        nft.mint(userA); // tokenId 1

        uint256 stakeAmount = 200e18;
        curd.mint(userA, stakeAmount);

        vm.startPrank(userA);
        curd.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(1, stakeAmount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertTrue(stakingManager.isEligibleForRewards(1), "Should be eligible after staking");

        // Warp past maturity so unstake doesn't burn (mature path)
        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        // Partial unstake: remove 150 CURD, leaving 50 CURD (below MIN_STAKE_PER_NFT)
        uint256 unstakeAmount = 150e18;
        vm.prank(userA);
        stakingManager.unstake(1, unstakeAmount);

        assertFalse(stakingManager.isEligibleForRewards(1), "Below threshold should not be eligible");
    }

    function test_transferNft_newOwnerCanUnstake() public {
        // Owner A stakes → transfers NFT → Owner B unstakes
        nft.mint(userA); // tokenId 1

        uint256 stakeAmount = Config.MIN_STAKE_PER_NFT;
        curd.mint(userA, stakeAmount);

        vm.startPrank(userA);
        curd.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(1, stakeAmount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        // Transfer NFT 1 from A to B
        vm.prank(userA);
        nft.transferFrom(userA, userB, 1);

        assertEq(nft.ownerOf(1), userB, "NFT should be owned by B");

        // Warp past maturity
        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        // B (new NFT owner) can unstake
        vm.prank(userB);
        stakingManager.unstake(1, stakeAmount);

        // Position should be closed
        IStakingManager.StakingPosition memory pos = stakingManager.getStakingPosition(1);
        assertFalse(pos.active, "Position should be inactive after full unstake");
    }

    function test_oldOwnerCannotUnstakeAfterTransfer() public {
        // Owner A stakes → transfers NFT → A cannot unstake (position follows NFT)
        nft.mint(userA); // tokenId 1

        uint256 stakeAmount = Config.MIN_STAKE_PER_NFT;
        curd.mint(userA, stakeAmount);

        vm.startPrank(userA);
        curd.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(1, stakeAmount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        // Transfer NFT 1 from A to B
        vm.prank(userA);
        nft.transferFrom(userA, userB, 1);

        // Warp past maturity
        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        // A (old owner) should be rejected
        vm.prank(userA);
        vm.expectRevert(StakingManager.NotNFTOwner.selector);
        stakingManager.unstake(1, stakeAmount);
    }
}

/**
 * @title MerkleYieldClaimerNFTTest
 * @notice Tests for NFT-bound Merkle yield claims (Option A: position follows NFT)
 */
contract MerkleYieldClaimerNFTTest is Test {
    MerkleYieldClaimer public claimerImpl;
    MerkleYieldClaimer public claimer;
    ProxyAdmin public proxyAdmin;

    MockCURD public curd;
    MockNFT public nft;
    MockYieldPool public yieldPool;

    address public owner;
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");

    uint256 public constant PROJECT_ID = 1;
    uint256 public constant DIST_INDEX = 0;
    uint256 public constant CLAIM_INDEX = 0;
    uint256 public constant YIELD_AMOUNT = 500e18;

    function setUp() public {
        owner = address(this);

        curd = new MockCURD();
        nft = new MockNFT();
        yieldPool = new MockYieldPool(address(curd));

        // Deploy MerkleYieldClaimer through proxy
        claimerImpl = new MerkleYieldClaimer();
        proxyAdmin = new ProxyAdmin();

        bytes memory initData =
            abi.encodeWithSelector(MerkleYieldClaimer.initialize.selector, address(yieldPool), owner);
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(claimerImpl), address(proxyAdmin), initData);
        claimer = MerkleYieldClaimer(address(proxy));
    }

    /// @dev Computes a two-leaf Merkle root compatible with ValidationLibrary.verifyMerkleProof
    function _computeMerkleRoot(bytes32 leafA, bytes32 leafB) private pure returns (bytes32) {
        if (leafA <= leafB) {
            return keccak256(abi.encodePacked(leafA, leafB));
        } else {
            return keccak256(abi.encodePacked(leafB, leafA));
        }
    }

    /// @dev Build a leaf using the new NFT-bound leaf format
    function _buildLeaf(
        uint256 projectId,
        uint256 distIndex,
        address nftContract,
        uint256 nftId,
        uint256 amount,
        uint256 claimIdx
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(projectId, distIndex, nftContract, nftId, amount, claimIdx));
    }

    /// @dev Setup a distribution: fund pool, set Merkle root, record timestamp
    function _setupDistribution(bytes32 root) internal {
        uint256 distTime = block.timestamp - 1; // just in the past
        yieldPool.fund(PROJECT_ID, YIELD_AMOUNT);
        yieldPool.setRoot(PROJECT_ID, root, distTime);
        claimer.recordDistribution(PROJECT_ID, DIST_INDEX, distTime);
    }

    // ============ BASIC CLAIM TESTS ============

    function test_ownerCanClaim() public {
        // Mint NFT 1 to userA
        nft.mint(userA); // tokenId 1

        // Build single-leaf tree: root == leaf, proof == []
        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        uint256 balanceBefore = curd.balanceOf(userA);

        vm.prank(userA);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));

        assertEq(curd.balanceOf(userA) - balanceBefore, YIELD_AMOUNT, "Owner should receive yield");
    }

    function test_claimReverts_notNFTOwner() public {
        // Mint NFT 1 to userA; userB attempts to claim
        nft.mint(userA); // tokenId 1

        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        vm.prank(userB);
        vm.expectRevert(MerkleYieldClaimer.NotNFTOwner.selector);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));
    }

    // ============ NFT TRANSFER TESTS ============

    function test_transferNft_movesClaimRightsToNewOwner() public {
        // Setup: owner A has NFT at snapshot time; yield is allocated to nftId
        nft.mint(userA); // tokenId 1

        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        // Transfer NFT 1 from A to B
        vm.prank(userA);
        nft.transferFrom(userA, userB, 1);
        assertEq(nft.ownerOf(1), userB);

        uint256 bBalanceBefore = curd.balanceOf(userB);

        // B (new owner) claims successfully
        vm.prank(userB);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));

        assertEq(curd.balanceOf(userB) - bBalanceBefore, YIELD_AMOUNT, "New owner should receive yield");
    }

    function test_transferNft_oldOwnerCannotClaim() public {
        // A had NFT at snapshot, transfers to B; A must not receive funds
        nft.mint(userA); // tokenId 1

        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        // Transfer to B
        vm.prank(userA);
        nft.transferFrom(userA, userB, 1);

        // A attempts to claim — should revert because A no longer owns the NFT
        vm.prank(userA);
        vm.expectRevert(MerkleYieldClaimer.NotNFTOwner.selector);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));

        // Confirm A received nothing
        assertEq(curd.balanceOf(userA), 0, "Old owner must not receive funds");
    }

    function test_transferNft_doesNotBreakAccounting() public {
        // Two NFTs in the tree; NFT 1 transferred; each claimed once — no double-claim, no negative debt
        nft.mint(userA); // tokenId 1
        nft.mint(userB); // tokenId 2

        uint256 amountA = 300e18;
        uint256 amountB = 200e18;
        uint256 totalYield = amountA + amountB;

        bytes32 leafA = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, amountA, 0);
        bytes32 leafB = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 2, amountB, 1);

        bytes32 root = _computeMerkleRoot(leafA, leafB);

        uint256 distTime = block.timestamp - 1;
        yieldPool.fund(PROJECT_ID, totalYield);
        yieldPool.setRoot(PROJECT_ID, root, distTime);
        claimer.recordDistribution(PROJECT_ID, DIST_INDEX, distTime);

        // Build proofs
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;

        // Transfer NFT 1 from A to userB before claiming
        vm.prank(userA);
        nft.transferFrom(userA, userB, 1);

        // B now owns both NFT 1 and NFT 2 — claims both
        vm.startPrank(userB);
        claimer.claimYield(PROJECT_ID, address(nft), 1, amountA, 0, DIST_INDEX, proofA);
        claimer.claimYield(PROJECT_ID, address(nft), 2, amountB, 1, DIST_INDEX, proofB);
        vm.stopPrank();

        assertEq(curd.balanceOf(userB), totalYield, "B should receive full yield for both NFTs");
        assertEq(yieldPool.getAvailableYield(PROJECT_ID), 0, "Pool should be empty after all claims");
    }

    function test_doubleClaim_reverts() public {
        nft.mint(userA); // tokenId 1

        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        // First claim succeeds
        vm.prank(userA);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));

        // Second claim for same claimIndex reverts
        vm.prank(userA);
        vm.expectRevert(MerkleYieldClaimer.AlreadyClaimed.selector);
        claimer.claimYield(PROJECT_ID, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));
    }

    function test_claimWithWrongNFTContract_reverts() public {
        nft.mint(userA); // tokenId 1

        bytes32 leaf = _buildLeaf(PROJECT_ID, DIST_INDEX, address(nft), 1, YIELD_AMOUNT, CLAIM_INDEX);
        _setupDistribution(leaf);

        // userA passes a wrong nftContract — the leaf constructed on-chain will differ from the
        // stored root (nftContract is in the leaf), so proof verification fails first.
        // This is the stronger cryptographic protection against cross-collection replay.
        address fakeContract = makeAddr("fakeNFT");
        vm.prank(userA);
        vm.expectRevert(MerkleYieldClaimer.InvalidProof.selector);
        claimer.claimYield(PROJECT_ID, fakeContract, 1, YIELD_AMOUNT, CLAIM_INDEX, DIST_INDEX, new bytes32[](0));
    }
}

// ============ PHASE 6C STEP 2 TESTS — "Stake Follows NFT" ============

/**
 * @title StakingManagerStep2Test
 * @notice Validates Phase 6C Step 2: stake attribution follows the NFT via the
 *         TransferHookRouter → StakingManager.beforeNFTTransfer path.
 *
 * Setup:
 *   TransferHookRouter(routerOwner, address(nft))
 *   router.setHooks([address(stakingManager)])
 *
 * Transfer simulation:
 *   router.beforeNFTTransfer(nftId, from, to) is called directly to simulate
 *   the NFT calling the router on transfer.  StakingManager sees msg.sender ==
 *   router, so ITransferHookRouter(msg.sender).nftContract() resolves correctly.
 */
contract StakingManagerStep2Test is Test {
    StakingManager public stakingManagerImpl;
    StakingManager public stakingManager;
    ProxyAdmin public proxyAdmin;
    TransferHookRouter public router;

    MockCURD public curd;
    MockNFT public nft;
    address public treasury = makeAddr("treasury");
    address public routerOwner = makeAddr("routerOwner");

    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant PROJECT_ID = 1; // matches MockNFT.PROJECT_ID
    uint256 public constant BASE_APY = 1000;

    function setUp() public {
        owner = address(this);

        curd = new MockCURD();
        nft = new MockNFT();

        // Deploy StakingManager through proxy
        stakingManagerImpl = new StakingManager();
        proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(
            StakingManager.initialize.selector, address(curd), makeAddr("yieldPool"), treasury, BASE_APY
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(stakingManagerImpl), address(proxyAdmin), initData);
        stakingManager = StakingManager(address(proxy));

        // Deploy TransferHookRouter with the NFT collection address
        router = new TransferHookRouter(routerOwner, address(nft));

        // Wire StakingManager as the hook in the router
        address[] memory hooks = new address[](1);
        hooks[0] = address(stakingManager);
        vm.prank(routerOwner);
        router.setHooks(hooks);

        // Register NFT IDs 1 and 2 with the StakingManager
        stakingManager.registerNFT(address(nft), 1, PROJECT_ID, 10);
        stakingManager.registerNFT(address(nft), 2, PROJECT_ID, 0);
    }

    // ── userProjectStaked updates on stake ────────────────────────────────

    function test_stake_incrementsUserProjectStaked() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), amount);
    }

    // ── stake follows NFT transfer via router ─────────────────────────────

    function test_stakeFollowsTransfer_viaRouter() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), amount, "alice has stake before transfer");

        // Simulate NFT transfer through the router (must prank as nftContract)
        vm.prank(address(nft));
        router.beforeNFTTransfer(1, alice, bob);

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), 0, "alice attribution zeroed after transfer");
        assertEq(stakingManager.userProjectStaked(bob, PROJECT_ID), amount, "bob attribution updated after transfer");
    }

    // ── transferring unstaked NFT does not change accounting ──────────────

    function test_transferUnstakedNFT_noAccountingChange() public {
        nft.mint(alice); // tokenId 1 — no stake

        vm.prank(address(nft));
        router.beforeNFTTransfer(1, alice, bob);

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), 0);
        assertEq(stakingManager.userProjectStaked(bob, PROJECT_ID), 0);
    }

    // ── new owner can unstake after transfer ──────────────────────────────

    function test_newOwnerCanUnstake_afterTransfer() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        // Move stake attribution via router, then transfer NFT ownership
        vm.prank(address(nft));
        router.beforeNFTTransfer(1, alice, bob);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        // Warp past maturity so Bob can unstake without penalty
        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        vm.prank(bob);
        stakingManager.unstake(1, amount);

        assertEq(stakingManager.userProjectStaked(bob, PROJECT_ID), 0, "bob attribution zeroed after unstake");
        IStakingManager.StakingPosition memory pos = stakingManager.getStakingPosition(1);
        assertFalse(pos.active, "position closed after full unstake");
    }

    // ── old owner cannot unstake after transfer ───────────────────────────

    function test_oldOwnerCannotUnstake_afterTransfer() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        // Move stake attribution, then transfer NFT ownership
        vm.prank(address(nft));
        router.beforeNFTTransfer(1, alice, bob);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        vm.prank(alice);
        vm.expectRevert(StakingManager.NotNFTOwner.selector);
        stakingManager.unstake(1, amount);
    }

    // ── burn with active stake reverts ────────────────────────────────────

    function test_burnWithActiveStake_reverts() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        // Simulate burn (to == address(0)) through the router — must revert
        vm.prank(address(nft));
        vm.expectRevert(StakingManager.ActiveStakeOnBurn.selector);
        router.beforeNFTTransfer(1, alice, address(0));
    }

    // ── userProjectStaked updates on unstake ──────────────────────────────

    function test_unstake_decrementsUserProjectStaked() public {
        nft.mint(alice); // tokenId 1
        uint256 amount = Config.MIN_STAKE_PER_NFT;
        curd.mint(alice, amount);

        vm.startPrank(alice);
        curd.approve(address(stakingManager), amount);
        stakingManager.stake(1, amount, Config.LOCK_1_YEAR_MONTHS);
        vm.stopPrank();

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), amount);

        vm.warp(block.timestamp + Config.LOCK_1_YEAR_MONTHS * Config.ONE_MONTH + 1);

        vm.prank(alice);
        stakingManager.unstake(1, amount);

        assertEq(stakingManager.userProjectStaked(alice, PROJECT_ID), 0);
    }
}
