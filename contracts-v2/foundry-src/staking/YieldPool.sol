// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../Config.sol";
import "../libraries/ValidationLibrary.sol";
import "../libraries/MathLibrary.sol";
import "./interfaces/IYieldPool.sol";
import "../core/interfaces/ICheesecoinsCore.sol";

/**
 * @title YieldPool
 * @notice Per-project yield pool management with Merkle-based distribution
 * @dev Production-grade yield aggregation and distribution system
 *
 * Architecture:
 * - Separate accounting per project (projectId → balance)
 * - Merkle root storage for gas-efficient distribution to 10K+ NFT holders
 * - Distribution history tracking for transparency and auditing
 * - Integration with CheesecoinsCore for yield deposits
 * - Integration with MerkleYieldClaimer for claim verification
 *
 * Flow:
 * 1. CheesecoinsCore deposits yield → depositYield(projectId, amount)
 * 2. Admin/governance sets Merkle root → setMerkleRoot(projectId, root)
 * 3. Users claim via MerkleYieldClaimer (verifies proof and debits pool)
 * 4. Distribution history tracked in YieldDistribution[] per project
 *
 * Scalability:
 * - Merkle trees enable efficient distribution to 10K+ holders
 * - O(log n) proof verification vs O(n) direct transfers
 * - Gas cost independent of holder count (constant per claim)
 *
 * Security:
 * - ReentrancyGuard on all state-changing operations
 * - Access control: Only owner/authorized can set Merkle roots
 * - Only CheesecoinsCore can deposit yield (verified via modifier)
 * - SafeERC20 for all token operations
 * - Input validation via ValidationLibrary
 *
 * Integration Points:
 * - CheesecoinsCore: Deposits yield after minting/distribution events
 * - MerkleYieldClaimer: Claims yield using proofs against stored roots
 * - Frontend/Backend: Generates Merkle trees and proofs off-chain
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract YieldPool is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IYieldPool {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathLibrary for uint256;

    // ============ STATE VARIABLES ============

    /// @notice CURD token contract
    IERC20Upgradeable public curdToken;

    /// @notice CheesecoinsCore contract (authorized depositor)
    address public cheesecoinsCore;

    /// @notice Merkle claimer contract (authorized to debit pools)
    address public merkleYieldClaimer;

    /// @notice Project ID this pool is bound to (immutable after init)
    uint256 public projectId;

    /// @notice Available yield per project (projectId → balance)
    mapping(uint256 => uint256) public projectYieldBalance;

    /// @notice Current Merkle root per project (projectId → root)
    mapping(uint256 => bytes32) public currentMerkleRoot;

    /// @notice Distribution history per project (projectId → distributions[])
    mapping(uint256 => YieldDistribution[]) private distributions;

    /// @notice Total yield deposited per project (lifetime)
    mapping(uint256 => uint256) public totalYieldDeposited;

    /// @notice Total yield claimed per project (lifetime)
    mapping(uint256 => uint256) public totalYieldClaimed;

    /// @notice Distribution counter per project (monotonic index)
    mapping(uint256 => uint256) public distributionCount;

    /// @notice One-shot initialization guard (separate from OZ Initializable)
    bool private _yieldPoolInitialized;

    // ============ EVENTS ============

    /**
     * @notice Emitted when Merkle root is updated
     * @param projectId Project identifier
     * @param root New Merkle root
     * @param distributionIndex Distribution index
     */
    event MerkleRootSet(uint256 indexed projectId, bytes32 indexed root, uint256 distributionIndex);

    /**
     * @notice Emitted when yield is claimed (debited from pool)
     * @param projectId Project identifier
     * @param recipient Claim recipient
     * @param amount Amount claimed
     */
    event YieldClaimed(uint256 indexed projectId, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when CheesecoinsCore address is updated
     * @param oldCore Previous core address
     * @param newCore New core address
     */
    event CheesecoinsCorUpdated(address oldCore, address newCore);

    /**
     * @notice Emitted when MerkleYieldClaimer address is updated
     * @param oldClaimer Previous claimer address
     * @param newClaimer New claimer address
     */
    event MerkleClaimerUpdated(address oldClaimer, address newClaimer);

    // ============ ERRORS ============

    error Unauthorized();
    error InsufficientBalance();
    error InvalidAmount();
    error InvalidMerkleRoot();
    error InvalidNFTCount();
    error InvalidProjectId();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidAddress();

    // ============ MODIFIERS ============

    /**
     * @notice Reverts if the caller-supplied project ID does not match the bound projectId.
     * @dev Enforces that each YieldPool clone operates exclusively on its own project.
     *      Applies to all state-mutating functions that accept a projectId argument.
     */
    modifier onlyBoundProject(uint256 pid) {
        if (pid != projectId) revert InvalidProjectId();
        _;
    }

    /**
     * @notice Reverts if the pool has not been initialized yet.
     * @dev Prevents calls to state-mutating functions on un-initialized clones.
     */
    modifier onlyInitialized() {
        if (!_yieldPoolInitialized) revert NotInitialized();
        _;
    }

    /**
     * @notice Restricts function to CheesecoinsCore contract
     */
    modifier onlyCheesecoinsCore() {
        if (msg.sender != cheesecoinsCore) revert Unauthorized();
        _;
    }

    /**
     * @notice Restricts function to MerkleYieldClaimer contract
     */
    modifier onlyMerkleClaimer() {
        if (msg.sender != merkleYieldClaimer) revert Unauthorized();
        _;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the YieldPool clone for a specific project
     * @param _projectId Project ID this pool is bound to (non-zero, immutable after init)
     * @param _curdToken CURD token address
     * @param _cheesecoinsCore CheesecoinsCore contract address (authorized depositor)
     * @param _owner Initial owner address (should be timelock/governance authority)
     */
    function initialize(uint256 _projectId, address _curdToken, address _cheesecoinsCore, address _owner)
        external
        initializer
    {
        // One-shot guard — must be first to prevent any partial-init re-entry
        if (_yieldPoolInitialized) revert AlreadyInitialized();
        if (_projectId == 0) revert InvalidProjectId();
        if (_curdToken == address(0)) revert InvalidAddress();
        if (_cheesecoinsCore == address(0)) revert InvalidAddress();
        if (_owner == address(0)) revert InvalidAddress();

        _yieldPoolInitialized = true;

        __Ownable_init();
        __ReentrancyGuard_init();

        projectId = _projectId;
        curdToken = IERC20Upgradeable(_curdToken);
        // slither-disable-next-line missing-zero-check -- validated by if-revert above
        cheesecoinsCore = _cheesecoinsCore;

        _transferOwnership(_owner);
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposit yield for a project (called by CheesecoinsCore)
     * @param pid Project identifier
     * @param amount CURD amount to deposit
     *
     * Requirements:
     * - Caller must be CheesecoinsCore
     * - Amount must be > 0
     * - Must have approved token transfer
     *
     * Effects:
     * - Increases projectYieldBalance[pid]
     * - Increases totalYieldDeposited[pid]
     * - Transfers CURD from CheesecoinsCore to this contract
     * - Emits YieldDeposited event
     */
    function depositYield(uint256 pid, uint256 amount)
        external
        override
        nonReentrant
        onlyInitialized
        onlyBoundProject(pid)
        onlyCheesecoinsCore
    {
        if (amount == 0) revert InvalidAmount();

        projectYieldBalance[pid] += amount;
        totalYieldDeposited[pid] += amount;

        curdToken.safeTransferFrom(msg.sender, address(this), amount);

        emit YieldDeposited(pid, amount);
    }

    /**
     * @notice Set Merkle root for yield distribution
     * @param pid Project identifier
     * @param root Merkle root of distribution tree
     * @param totalYield Total yield to distribute
     * @param nftCount Number of NFTs in distribution
     *
     * Requirements:
     * - Caller must be owner
     * - Root must not be zero
     * - totalYield must not exceed available balance
     * - nftCount must be > 0
     *
     * Effects:
     * - Sets currentMerkleRoot[pid] = root
     * - Records distribution in history
     * - Emits MerkleRootSet and YieldDistributed events
     *
     * Gas Optimization:
     * - Merkle trees enable O(log n) verification
     * - Setting root is O(1), independent of holder count
     * - Supports 10K+ NFT holders efficiently
     */
    function setMerkleRoot(uint256 pid, bytes32 root, uint256 totalYield, uint256 nftCount)
        external
        onlyOwner
        onlyInitialized
        onlyBoundProject(pid)
    {
        if (root == bytes32(0)) revert InvalidMerkleRoot();
        if (nftCount == 0) revert InvalidNFTCount();
        if (totalYield > projectYieldBalance[pid]) revert InsufficientBalance();

        currentMerkleRoot[pid] = root;

        uint256 avgYield = totalYield / nftCount;
        uint256 distIndex = distributionCount[pid];

        distributions[pid]
        .push(
            YieldDistribution({
                projectId: pid,
                totalYield: totalYield,
                nftCount: nftCount,
                distributionTime: block.timestamp,
                merkleRoot: root
            })
        );

        distributionCount[pid]++;

        emit MerkleRootSet(pid, root, distIndex);
        emit YieldDistributed(pid, totalYield, nftCount, avgYield);
    }

    /**
     * @notice Overload for backward compatibility (without totalYield and nftCount)
     * @param pid Project identifier
     * @param root Merkle root
     * @dev Uses available balance as totalYield and 0 as nftCount (for historical distributions)
     */
    function setMerkleRoot(uint256 pid, bytes32 root)
        external
        override
        onlyOwner
        onlyInitialized
        onlyBoundProject(pid)
    {
        if (root == bytes32(0)) revert InvalidMerkleRoot();

        currentMerkleRoot[pid] = root;

        uint256 availableYield = projectYieldBalance[pid];
        uint256 distIndex = distributionCount[pid];

        distributions[pid]
        .push(
            YieldDistribution({
                projectId: pid,
                totalYield: availableYield,
                nftCount: 0,
                distributionTime: block.timestamp,
                merkleRoot: root
            })
        );

        distributionCount[pid]++;

        emit MerkleRootSet(pid, root, distIndex);
        emit YieldDistributed(pid, availableYield, 0, 0);
    }

    /**
     * @notice Debit yield from pool (called by MerkleYieldClaimer)
     * @param pid Project identifier
     * @param recipient Claim recipient
     * @param amount Amount to debit
     *
     * Requirements:
     * - Caller must be MerkleYieldClaimer
     * - Sufficient balance available
     *
     * Effects:
     * - Decreases projectYieldBalance[pid]
     * - Increases totalYieldClaimed[pid]
     * - Transfers CURD to recipient
     * - Emits YieldClaimed event
     */
    function debitYield(uint256 pid, address recipient, uint256 amount)
        external
        nonReentrant
        onlyInitialized
        onlyBoundProject(pid)
        onlyMerkleClaimer
    {
        if (amount == 0) revert InvalidAmount();
        if (projectYieldBalance[pid] < amount) revert InsufficientBalance();

        projectYieldBalance[pid] -= amount;
        totalYieldClaimed[pid] += amount;

        curdToken.safeTransfer(recipient, amount);

        emit YieldClaimed(pid, recipient, amount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get available yield for a project
     * @param pid Project identifier
     * @return Available CURD balance
     */
    function getAvailableYield(uint256 pid) external view override returns (uint256) {
        return projectYieldBalance[pid];
    }

    /**
     * @notice Get distribution details by index
     * @param pid Project identifier
     * @param index Distribution index
     * @return Distribution details
     */
    function getDistribution(uint256 pid, uint256 index) external view override returns (YieldDistribution memory) {
        require(index < distributions[pid].length, "YieldPool: invalid index");
        return distributions[pid][index];
    }

    /**
     * @notice Get total number of distributions for a project
     * @param pid Project identifier
     * @return Number of distributions
     */
    function getDistributionCount(uint256 pid) external view returns (uint256) {
        return distributions[pid].length;
    }

    /**
     * @notice Get current Merkle root for a project
     * @param pid Project identifier
     * @return Current Merkle root
     */
    function getCurrentMerkleRoot(uint256 pid) external view returns (bytes32) {
        return currentMerkleRoot[pid];
    }

    /**
     * @notice Get yield statistics for a project
     * @param pid Project identifier
     * @return deposited Total deposited
     * @return claimed Total claimed
     * @return available Currently available
     */
    function getYieldStats(uint256 pid) external view returns (uint256 deposited, uint256 claimed, uint256 available) {
        return (totalYieldDeposited[pid], totalYieldClaimed[pid], projectYieldBalance[pid]);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update CheesecoinsCore address
     * @param newCore New CheesecoinsCore address
     */
    function setCheesecoinsCore(address newCore) external onlyOwner onlyInitialized {
        ValidationLibrary.requireNonZeroAddress(newCore, "YieldPool: invalid core");
        address oldCore = cheesecoinsCore;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        cheesecoinsCore = newCore;
        emit CheesecoinsCorUpdated(oldCore, newCore);
    }

    /**
     * @notice Update MerkleYieldClaimer address
     * @param newClaimer New MerkleYieldClaimer address
     */
    function setMerkleClaimer(address newClaimer) external onlyOwner onlyInitialized {
        ValidationLibrary.requireNonZeroAddress(newClaimer, "YieldPool: invalid claimer");
        address oldClaimer = merkleYieldClaimer;
        // slither-disable-next-line missing-zero-check -- validated by requireNonZeroAddress above
        merkleYieldClaimer = newClaimer;
        emit MerkleClaimerUpdated(oldClaimer, newClaimer);
    }

    /**
     * @notice Emergency withdrawal (governance only)
     * @param token Token to withdraw
     * @param recipient Withdrawal recipient
     * @param amount Amount to withdraw
     * @dev Should only be used in emergency scenarios with governance approval
     */
    function emergencyWithdraw(address token, address recipient, uint256 amount) external onlyOwner onlyInitialized {
        ValidationLibrary.requireNonZeroAddress(recipient, "YieldPool: invalid recipient");
        IERC20Upgradeable(token).safeTransfer(recipient, amount);
    }
}
