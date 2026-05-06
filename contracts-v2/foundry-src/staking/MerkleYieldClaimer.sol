// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../Config.sol";
import "../libraries/ValidationLibrary.sol";
import "./interfaces/IYieldPool.sol";

/**
 * @title MerkleYieldClaimer
 * @notice Merkle-proof based yield claiming system for scalable distributions
 * @dev Production-grade claiming mechanism supporting 10K+ NFT holders
 *
 * Architecture:
 * - Merkle tree verification for gas-efficient claim validation
 * - Bitmap tracking to prevent double-claiming (one bit per claim)
 * - Claim window enforcement (Config.MERKLE_CLAIM_WINDOW = 30 days)
 * - Integration with YieldPool for balance management
 *
 * Flow:
 * 1. Backend generates Merkle tree with (projectId, nftId, amount, claimIndex)
 * 2. YieldPool stores Merkle root via setMerkleRoot()
 * 3. User submits claim with proof → claimYield()
 * 4. Contract verifies proof against stored root
 * 5. Contract checks claim window and bitmap
 * 6. Contract debits YieldPool and transfers CURD to user
 * 7. Contract marks claim as complete in bitmap
 *
 * Scalability:
 * - Merkle proofs: O(log n) verification, ~10 hashes for 1000 holders, ~14 for 10K
 * - Bitmap storage: 1 bit per claim = 32 claims per uint256 slot
 * - Gas cost: Constant per claim, independent of total holder count
 * - Theoretical limit: Millions of holders with same gas cost per claim
 *
 * Security:
 * - ReentrancyGuard on claim operations
 * - Double-claim prevention via bitmap (projectId → claimIndex → claimed)
 * - Claim window validation (must be within 30 days of distribution)
 * - Merkle proof verification using ValidationLibrary
 * - Input validation for all parameters
 *
 * Claim Window:
 * - Distribution timestamp → distribution timestamp + 30 days
 * - After window expires, funds remain in YieldPool
 * - Governance can extend windows or redistribute unclaimed yield
 *
 * Integration Points:
 * - YieldPool: Debits yield and tracks distribution history
 * - ValidationLibrary: Merkle proof verification
 * - Backend: Generates Merkle trees and proofs off-chain
 * - Frontend: Fetches proofs and submits claims
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract MerkleYieldClaimer is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ============ STATE VARIABLES ============

    /// @notice YieldPool contract reference
    IYieldPool public yieldPool;

    /// @notice Claimed status per project and claim index (projectId → claimIndex → claimed)
    /// @dev Uses bitmap for gas efficiency: 256 claims per mapping slot
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitmap;

    /// @notice Distribution timestamp per project (projectId → distributionIndex → timestamp)
    mapping(uint256 => mapping(uint256 => uint256)) public distributionTimestamps;

    /// @notice Total claims processed per project (lifetime counter)
    mapping(uint256 => uint256) public totalClaimsProcessed;

    /// @notice Total amount claimed per project (lifetime total)
    mapping(uint256 => uint256) public totalAmountClaimed;

    /// @notice Claim window duration (from Config)
    uint256 public constant CLAIM_WINDOW = Config.MERKLE_CLAIM_WINDOW;

    // ============ EVENTS ============

    /**
     * @notice Emitted when yield is successfully claimed
     * @param projectId Project identifier
     * @param nftId NFT token identifier
     * @param recipient Claim recipient address
     * @param amount CURD amount claimed
     * @param claimIndex Unique claim index (prevents double-claims)
     */
    event YieldClaimed(
        uint256 indexed projectId, uint256 indexed nftId, address indexed recipient, uint256 amount, uint256 claimIndex
    );

    /**
     * @notice Emitted when a new Merkle root distribution begins
     * @param projectId Project identifier
     * @param distributionIndex Distribution index
     * @param merkleRoot Merkle root for verification
     * @param timestamp Distribution start timestamp
     */
    event MerkleRootSet(
        uint256 indexed projectId, uint256 distributionIndex, bytes32 indexed merkleRoot, uint256 timestamp
    );

    /**
     * @notice Emitted when distribution timestamp is recorded
     * @param projectId Project identifier
     * @param distributionIndex Distribution index
     * @param timestamp Distribution timestamp
     */
    event DistributionRecorded(uint256 indexed projectId, uint256 distributionIndex, uint256 timestamp);

    /**
     * @notice Emitted when YieldPool address is updated
     * @param oldPool Previous YieldPool address
     * @param newPool New YieldPool address
     */
    event YieldPoolUpdated(address oldPool, address newPool);

    // ============ ERRORS ============

    error AlreadyClaimed();
    error InvalidProof();
    error ClaimWindowExpired();
    error InvalidAmount();
    error InvalidClaimIndex();
    error InvalidDistributionIndex();
    error InvalidMerkleRoot();
    error NotNFTOwner();

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the MerkleYieldClaimer contract
     * @param _yieldPool YieldPool contract address
     * @param _owner Initial owner address
     */
    function initialize(address _yieldPool, address _owner) external initializer {
        ValidationLibrary.requireNonZeroAddress(_yieldPool, "MerkleClaimer: invalid pool");
        ValidationLibrary.requireNonZeroAddress(_owner, "MerkleClaimer: invalid owner");

        __Ownable_init();
        __ReentrancyGuard_init();

        yieldPool = IYieldPool(_yieldPool);

        _transferOwnership(_owner);
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Claim yield using Merkle proof
     * @param projectId Project identifier
     * @param nftContract NFT contract address (must match the leaf and be the contract ownerOf(nftId) is called on)
     * @param nftId NFT token identifier
     * @param amount CURD amount to claim
     * @param claimIndex Unique claim index (prevents double-claims)
     * @param distributionIndex Distribution index (for timestamp lookup; also embedded in leaf to prevent cross-epoch replay)
     * @param merkleProof Merkle proof array (sibling hashes)
     *
     * Leaf format (NFT-bound, Option A):
     *   keccak256(abi.encode(projectId, distributionIndex, nftContract, nftId, amount, claimIndex))
     *
     * Requirements:
     * - msg.sender must be the current owner of nftId on nftContract (position follows NFT)
     * - Proof must be valid against stored Merkle root
     * - Claim must not have been processed (bitmap check)
     * - Must be within claim window (30 days from distribution)
     * - Amount must be > 0
     * - YieldPool must have sufficient balance
     *
     * Effects:
     * - Marks claim as completed in bitmap
     * - Debits YieldPool balance
     * - Transfers CURD to msg.sender (current NFT owner)
     * - Increments totalClaimsProcessed and totalAmountClaimed
     * - Emits YieldClaimed event
     *
     * Gas Optimization:
     * - Bitmap storage: 256 claims per slot
     * - Merkle verification: O(log n) complexity
     * - ~50K-100K gas per claim (constant regardless of holder count)
     */
    function claimYield(
        uint256 projectId,
        address nftContract,
        uint256 nftId,
        uint256 amount,
        uint256 claimIndex,
        uint256 distributionIndex,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        // Check if already claimed early (cheap bitmap read — avoids wasting gas on known-bad state)
        if (isClaimed(projectId, claimIndex)) revert AlreadyClaimed();

        // Verify claim window (must be within 30 days of distribution)
        // Also caches distributionTime from YieldPool if not already stored
        uint256 distributionTime = distributionTimestamps[projectId][distributionIndex];
        if (distributionTime == 0) {
            // If not set, use distribution from YieldPool
            IYieldPool.YieldDistribution memory dist = yieldPool.getDistribution(projectId, distributionIndex);
            distributionTime = dist.distributionTime;
            distributionTimestamps[projectId][distributionIndex] = distributionTime;
        }

        if (block.timestamp > distributionTime + CLAIM_WINDOW) {
            revert ClaimWindowExpired();
        }

        // Construct leaf: keccak256(abi.encode(projectId, distributionIndex, nftContract, nftId, amount, claimIndex))
        //
        // Field purposes (all uint256 except nftContract which is address):
        //   projectId        — prevents cross-project replay
        //   distributionIndex — identifies the distribution epoch; prevents cross-epoch replay.
        //                       This is distinct from claimIndex: distributionIndex is the round
        //                       number shared across all NFTs in one snapshot; claimIndex is the
        //                       per-NFT position in the bitmap that prevents double-claim within
        //                       the same epoch.
        //   nftContract      — prevents cross-collection replay (e.g., a proof for collection A
        //                       cannot be submitted against collection B's Merkle root)
        //   nftId            — identifies which NFT holds entitlement
        //   amount           — the yield amount awarded to this NFT in this epoch
        //   claimIndex       — unique index within the distribution; drives the bitmap so that the
        //                       same (projectId, claimIndex) pair can only be claimed once even if
        //                       the same NFT appears in multiple epochs
        //
        // IMPORTANT: the off-chain Merkle generator MUST produce leaves using exactly this tuple,
        // type-order, and abi.encode (NOT abi.encodePacked). See foundry-docs/MERKLE_LEAF_FORMAT.md.
        bytes32 leaf = keccak256(abi.encode(projectId, distributionIndex, nftContract, nftId, amount, claimIndex));

        // Get current Merkle root from YieldPool
        bytes32 root = yieldPool.getCurrentMerkleRoot(projectId);
        if (root == bytes32(0)) revert InvalidMerkleRoot();

        // Verify Merkle proof — deterministic check with no external calls.
        // This is intentionally placed BEFORE the ownership check so that:
        // (a) cryptographic proof is the primary gate, and
        // (b) a wrong nftContract fails here (leaf mismatch → InvalidProof) rather than relying on
        //     the external ownerOf() call, which could behave unexpectedly on an arbitrary address.
        if (!ValidationLibrary.verifyMerkleProof(merkleProof, root, leaf)) {
            revert InvalidProof();
        }

        // Require caller to be the current NFT owner (position follows NFT).
        // Placed after proof verification to avoid unnecessary external calls on forged inputs.
        if (!ValidationLibrary.validateNFTOwnership(nftContract, nftId, msg.sender)) revert NotNFTOwner();

        // Mark as claimed (set bit in bitmap)
        _setClaimed(projectId, claimIndex);

        // Update statistics
        totalClaimsProcessed[projectId]++;
        totalAmountClaimed[projectId] += amount;

        // Debit YieldPool and transfer to current NFT owner (msg.sender)
        yieldPool.debitYield(projectId, msg.sender, amount);

        emit YieldClaimed(projectId, nftId, msg.sender, amount, claimIndex);
    }

    /**
     * @notice Record distribution timestamp (admin function)
     * @param projectId Project identifier
     * @param distributionIndex Distribution index
     * @param timestamp Distribution timestamp
     * @dev Used to set claim windows for new distributions
     */
    function recordDistribution(uint256 projectId, uint256 distributionIndex, uint256 timestamp) external onlyOwner {
        ValidationLibrary.requirePastTimestamp(timestamp);

        distributionTimestamps[projectId][distributionIndex] = timestamp;

        emit DistributionRecorded(projectId, distributionIndex, timestamp);
    }

    /**
     * @notice Batch record distributions (gas optimization)
     * @param projectIds Array of project IDs
     * @param distributionIndices Array of distribution indices
     * @param timestamps Array of timestamps
     */
    function batchRecordDistributions(
        uint256[] calldata projectIds,
        uint256[] calldata distributionIndices,
        uint256[] calldata timestamps
    ) external onlyOwner {
        ValidationLibrary.requireEqualLength(
            projectIds.length, distributionIndices.length, "MerkleClaimer: length mismatch"
        );
        ValidationLibrary.requireEqualLength(projectIds.length, timestamps.length, "MerkleClaimer: length mismatch");

        for (uint256 i = 0; i < projectIds.length; i++) {
            ValidationLibrary.requirePastTimestamp(timestamps[i]);
            distributionTimestamps[projectIds[i]][distributionIndices[i]] = timestamps[i];
            emit DistributionRecorded(projectIds[i], distributionIndices[i], timestamps[i]);
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check if a claim has been processed
     * @param projectId Project identifier
     * @param claimIndex Claim index to check
     * @return True if claimed, false otherwise
     *
     * Implementation:
     * - Uses bitmap for gas-efficient storage (1 bit per claim)
     * - claimIndex / 256 = slot, claimIndex % 256 = bit position
     * - 256 claims per storage slot (uint256)
     */
    function isClaimed(uint256 projectId, uint256 claimIndex) public view returns (bool) {
        uint256 slot = claimIndex / 256;
        uint256 bit = claimIndex % 256;
        uint256 bitmap = claimedBitmap[projectId][slot];
        return (bitmap & (1 << bit)) != 0;
    }

    /**
     * @notice Check claim eligibility (verifies proof without claiming)
     * @param projectId Project identifier
     * @param nftContract NFT contract address
     * @param nftId NFT token identifier
     * @param amount CURD amount
     * @param claimIndex Claim index
     * @param distributionIndex Distribution index
     * @param merkleProof Merkle proof
     * @return eligible True if eligible to claim
     * @return reason Reason if not eligible
     */
    function checkClaimEligibility(
        uint256 projectId,
        address nftContract,
        uint256 nftId,
        uint256 amount,
        uint256 claimIndex,
        uint256 distributionIndex,
        bytes32[] calldata merkleProof
    ) external view returns (bool eligible, string memory reason) {
        // Check if already claimed
        if (isClaimed(projectId, claimIndex)) {
            return (false, "Already claimed");
        }

        // Check claim window
        uint256 distributionTime = distributionTimestamps[projectId][distributionIndex];
        if (distributionTime == 0) {
            try yieldPool.getDistribution(projectId, distributionIndex) returns (
                IYieldPool.YieldDistribution memory dist
            ) {
                distributionTime = dist.distributionTime;
            } catch {
                return (false, "Invalid distribution");
            }
        }

        if (block.timestamp > distributionTime + CLAIM_WINDOW) {
            return (false, "Claim window expired");
        }

        // Verify proof before the external ownership call (mirrors claimYield ordering)
        bytes32 leaf = keccak256(abi.encode(projectId, distributionIndex, nftContract, nftId, amount, claimIndex));
        bytes32 root = yieldPool.getCurrentMerkleRoot(projectId);

        if (root == bytes32(0)) {
            return (false, "No Merkle root set");
        }

        if (!ValidationLibrary.verifyMerkleProof(merkleProof, root, leaf)) {
            return (false, "Invalid proof");
        }

        // Check NFT ownership (external call — placed after deterministic proof check)
        if (!ValidationLibrary.validateNFTOwnership(nftContract, nftId, msg.sender)) {
            return (false, "Not NFT owner");
        }

        // Check YieldPool balance
        if (yieldPool.getAvailableYield(projectId) < amount) {
            return (false, "Insufficient pool balance");
        }

        return (true, "Eligible");
    }

    /**
     * @notice Get claim statistics for a project
     * @param projectId Project identifier
     * @return claimsProcessed Total claims processed
     * @return amountClaimed Total CURD claimed
     */
    function getClaimStats(uint256 projectId) external view returns (uint256 claimsProcessed, uint256 amountClaimed) {
        return (totalClaimsProcessed[projectId], totalAmountClaimed[projectId]);
    }

    /**
     * @notice Get distribution details with claim window info
     * @param projectId Project identifier
     * @param distributionIndex Distribution index
     * @return distributionTime Timestamp of distribution
     * @return claimDeadline Claim window deadline
     * @return isActive True if claim window is still open
     */
    function getDistributionInfo(uint256 projectId, uint256 distributionIndex)
        external
        view
        returns (uint256 distributionTime, uint256 claimDeadline, bool isActive)
    {
        distributionTime = distributionTimestamps[projectId][distributionIndex];
        if (distributionTime == 0) {
            try yieldPool.getDistribution(projectId, distributionIndex) returns (
                IYieldPool.YieldDistribution memory dist
            ) {
                distributionTime = dist.distributionTime;
            } catch {
                return (0, 0, false);
            }
        }

        claimDeadline = distributionTime + CLAIM_WINDOW;
        isActive = block.timestamp <= claimDeadline;
    }

    /**
     * @notice Check multiple claim statuses (batch query)
     * @param projectId Project identifier
     * @param claimIndices Array of claim indices
     * @return statuses Array of claim statuses (true = claimed)
     */
    function batchCheckClaimed(uint256 projectId, uint256[] calldata claimIndices)
        external
        view
        returns (bool[] memory statuses)
    {
        statuses = new bool[](claimIndices.length);
        for (uint256 i = 0; i < claimIndices.length; i++) {
            statuses[i] = isClaimed(projectId, claimIndices[i]);
        }
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Mark a claim as processed in the bitmap
     * @param projectId Project identifier
     * @param claimIndex Claim index
     * @dev Sets the bit at position (claimIndex % 256) in slot (claimIndex / 256)
     */
    function _setClaimed(uint256 projectId, uint256 claimIndex) internal {
        uint256 slot = claimIndex / 256;
        uint256 bit = claimIndex % 256;
        claimedBitmap[projectId][slot] |= (1 << bit);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update YieldPool address
     * @param newPool New YieldPool address
     * @dev Should only be used during upgrades or migrations
     */
    function setYieldPool(address newPool) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(newPool, "MerkleClaimer: invalid pool");
        address oldPool = address(yieldPool);
        yieldPool = IYieldPool(newPool);
        emit YieldPoolUpdated(oldPool, newPool);
    }
}
