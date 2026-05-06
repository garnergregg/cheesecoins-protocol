// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../Config.sol";
import "./interfaces/IDomainAlphaEvents.sol";

/**
 * @title EventAggregator
 * @notice Central event bus for all protocol events with Domain Alpha integration
 * @dev Pure event emission contract - no storage, no state, just structured logs
 *
 * Purpose: Domain Alpha Social Media Bot Integration
 * ====================================================
 * The EventAggregator acts as a centralized event hub that the Domain Alpha bot monitors.
 * When events are emitted, the bot automatically posts to Twitter/Discord with formatted messages.
 *
 * Example Flow:
 * 1. User mints NFT → NubiansNorthNFT calls eventAggregator.emitNFTMinted()
 * 2. EventAggregator emits NFTMinted event with structured data
 * 3. Domain Alpha bot detects event via blockchain logs
 * 4. Bot posts: "🧀 Scene #25 unlocked by user! Total staked: 5,000 CURD"
 *
 * Why Centralized Events?
 * =======================
 * - Single contract to monitor (Domain Alpha only watches one address)
 * - Standardized event formats across all protocol modules
 * - Easy to add new event types without modifying module contracts
 * - Event filtering and analytics simplified (one ABI to track)
 * - Gas efficient (no storage, pure event emission)
 *
 * Event Categories:
 * =================
 * - NFT Events: Minting, scene unlocks, transfers with staking
 * - Staking Events: New stakes, unstakes, maturity reached
 * - Yield Events: Distribution, claims, seasonal multipliers
 * - Governance Events: Super holder status, votes, proposals
 * - Project Events: Registration, milestones, audits
 * - Milestone Events: 90% community staking, growth bonuses
 * - Decentralization Events: Founder weight reduction countdown
 *
 * Security Model:
 * ===============
 * - Only authorized contracts can emit events (prevents spam)
 * - Owner can add/remove authorized emitters
 * - No reentrancy risk (no state changes, no token transfers)
 * - No storage means no data corruption risk
 * - Immutable event schema (IDomainAlphaEvents interface)
 *
 * Integration Points:
 * ===================
 * - NubiansNorthNFT: NFT minting and transfers
 * - StakingManager: Staking lifecycle events
 * - YieldPool: Yield distribution events
 * - SuperHolderGovernance: Super holder creation and votes
 * - ProjectRegistry: Project registration and milestones
 * - HarvestOracle: Audit completion events
 * - FounderDecentralization: Countdown and weight updates
 * - NFTMarketplaceHooks: Secondary market sales
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract EventAggregator is Initializable, OwnableUpgradeable, IDomainAlphaEvents {
    // ============ STATE VARIABLES ============

    /// @notice Mapping of authorized contracts that can emit events
    mapping(address => bool) public authorizedEmitters;

    /// @notice Total events emitted (for analytics)
    uint256 public totalEventsEmitted;

    // ============ ERRORS ============

    error UnauthorizedEmitter();
    error ZeroAddress();
    error AlreadyAuthorized();
    error NotAuthorized();

    // ============ EVENTS (Admin) ============

    event EmitterAuthorized(address indexed emitter, uint256 timestamp);
    event EmitterDeauthorized(address indexed emitter, uint256 timestamp);

    // ============ MODIFIERS ============

    /**
     * @notice Ensures only authorized contracts can emit events
     */
    modifier onlyAuthorized() {
        if (!authorizedEmitters[msg.sender]) revert UnauthorizedEmitter();
        _;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the event aggregator
     * @dev No parameters needed - pure event emission contract
     */
    function initialize() external initializer {
        __Ownable_init();
    }

    // ============ NFT EVENTS ============

    /**
     * @notice Emit NFT minting event
     * @param projectId Project ID
     * @param nftId NFT token ID
     * @param sceneNumber Scene number unlocked (1-100)
     * @param user Address of minter
     *
     * Domain Alpha Post Example:
     * "🧀 Scene #42 unlocked by 0x1234...5678! Progress: 42% complete"
     */
    function emitNFTMinted(uint256 projectId, uint256 nftId, uint16 sceneNumber, address user) external onlyAuthorized {
        emit NFTMinted(projectId, nftId, sceneNumber, user, block.timestamp);
        totalEventsEmitted += 1;
    }

    // ============ STAKING EVENTS ============

    /**
     * @notice Emit staking created event
     * @param nftId NFT token ID
     * @param projectId Project ID
     * @param amount CURD amount staked
     * @param lockMonths Lock period in months
     * @param user Address of staker
     *
     * Domain Alpha Post Example:
     * "🔒 5,000 CURD staked for 36 months! APY: 15% (1.5x multiplier)"
     */
    function emitStakingCreated(uint256 nftId, uint256 projectId, uint256 amount, uint256 lockMonths, address user)
        external
        onlyAuthorized
    {
        emit StakingCreated(nftId, projectId, amount, lockMonths, user);
        totalEventsEmitted += 1;
    }

    // ============ YIELD EVENTS ============

    /**
     * @notice Emit yield distribution event
     * @param projectId Project ID
     * @param totalValue Total yield value distributed
     * @param nftCount Number of NFTs receiving yield
     * @param avgYield Average yield per NFT
     *
     * Domain Alpha Post Example:
     * "💰 100,000 CURD distributed! Avg: 1,000 CURD/NFT across 100 holders"
     */
    function emitYieldDistributed(uint256 projectId, uint256 totalValue, uint256 nftCount, uint256 avgYield)
        external
        onlyAuthorized
    {
        emit YieldDistributed(projectId, totalValue, nftCount, avgYield);
        totalEventsEmitted += 1;
    }

    // ============ GOVERNANCE EVENTS ============

    /**
     * @notice Emit super holder created event
     * @param user Address of new super holder
     * @param projectId Project ID
     * @param votingPower Voting power granted (2x multiplier)
     *
     * Domain Alpha Post Example:
     * "👑 New Super Holder! User completed all 100 scenes. Voting power: 2x"
     */
    function emitSuperHolderCreated(address user, uint256 projectId, uint256 votingPower) external onlyAuthorized {
        emit SuperHolderCreated(user, projectId, votingPower);
        totalEventsEmitted += 1;
    }

    // ============ PROJECT EVENTS ============

    /**
     * @notice Emit project registration event
     * @param projectId Project ID
     * @param name Project name (e.g., "Nubians North Farm")
     * @param ownerName Farm owner name
     * @param initialDoes Initial DOE allocation
     *
     * Domain Alpha Post Example:
     * "🚜 New Farm: Nubians North! Owner: John Smith | Initial: 50 DOE"
     */
    function emitProjectRegistered(
        uint256 projectId,
        string calldata name,
        string calldata ownerName,
        uint256 initialDoes
    ) external onlyAuthorized {
        emit ProjectRegistered(projectId, name, ownerName, initialDoes);
        totalEventsEmitted += 1;
    }

    // ============ AUDIT EVENTS ============

    /**
     * @notice Emit harvest audit completion event
     * @param projectId Project ID
     * @param actualGrowth Actual DOE growth achieved
     * @param projectedGrowth Projected DOE growth expected
     * @param value Total value audited
     *
     * Domain Alpha Post Example:
     * "✅ Audit complete: 120% growth vs 100% projected! +10% bonus unlocked"
     */
    function emitHarvestAuditCompleted(uint256 projectId, uint256 actualGrowth, uint256 projectedGrowth, uint256 value)
        external
        onlyAuthorized
    {
        emit HarvestAuditCompleted(projectId, actualGrowth, projectedGrowth, value);
        totalEventsEmitted += 1;
    }

    // ============ MILESTONE EVENTS ============

    /**
     * @notice Emit community 90% milestone achieved event
     * @param projectId Project ID
     * @param bonusAPY Bonus APY granted (25% from Config.COMMUNITY_90_PERCENT_BONUS)
     *
     * Domain Alpha Post Example:
     * "🎉 90% Community Milestone! Bonus APY: +25% for all stakers"
     */
    function emitCommunity90PercentAchieved(uint256 projectId, uint256 bonusAPY) external onlyAuthorized {
        emit Community90PercentAchieved(projectId, bonusAPY);
        totalEventsEmitted += 1;
    }

    // ============ MARKETPLACE EVENTS ============

    /**
     * @notice Emit NFT transferred with staking event
     * @param nftId NFT token ID
     * @param seller Original owner
     * @param buyer New owner
     * @param stakedAmount CURD amount staked (inherited by buyer)
     *
     * Domain Alpha Post Example:
     * "🔄 NFT #123 sold! Buyer inherits 5,000 CURD staked (matures: Dec 2025)"
     */
    function emitNFTTransferredWithStaking(uint256 nftId, address seller, address buyer, uint256 stakedAmount)
        external
        onlyAuthorized
    {
        emit NFTTransferredWithStaking(nftId, seller, buyer, stakedAmount);
        totalEventsEmitted += 1;
    }

    // ============ DECENTRALIZATION EVENTS ============

    /**
     * @notice Emit founder decentralization countdown event
     * @param yearRemaining Years remaining in 5-year decentralization
     * @param currentWeight Current founder weight percentage
     *
     * Domain Alpha Post Example:
     * "⏳ Year 3/5 complete. Founder weight: 30% → 20% next year"
     */
    function emitFounderDecentralization(uint256 yearRemaining, uint256 currentWeight) external onlyAuthorized {
        emit FounderDecentralization(yearRemaining, currentWeight);
        totalEventsEmitted += 1;
    }

    // ============ GROWTH BONUS EVENTS ============

    /**
     * @notice Emit growth bonus triggered event
     * @param projectCount Number of projects achieving growth threshold
     * @param bonusPercent Bonus percentage granted
     *
     * Domain Alpha Post Example:
     * "📈 5 farms hit 120% growth! Bonus: +20% for entire ecosystem"
     */
    function emitGrowthBonusTriggered(uint256 projectCount, uint256 bonusPercent) external onlyAuthorized {
        emit GrowthBonusTriggered(projectCount, bonusPercent);
        totalEventsEmitted += 1;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Authorize contract to emit events
     * @dev Only authorized contracts can call emit functions
     * @param emitter Address of contract to authorize
     *
     * Typical Authorized Emitters:
     * - NubiansNorthNFT (NFT minting)
     * - StakingManager (staking lifecycle)
     * - YieldPool (yield distribution)
     * - SuperHolderGovernance (governance events)
     * - ProjectRegistry (project registration)
     * - HarvestOracle (audit events)
     * - FounderDecentralization (countdown events)
     * - NFTMarketplaceHooks (marketplace events)
     */
    function authorizeEmitter(address emitter) external onlyOwner {
        if (emitter == address(0)) revert ZeroAddress();
        if (authorizedEmitters[emitter]) revert AlreadyAuthorized();

        authorizedEmitters[emitter] = true;
        emit EmitterAuthorized(emitter, block.timestamp);
    }

    /**
     * @notice Deauthorize contract from emitting events
     * @param emitter Address of contract to deauthorize
     */
    function deauthorizeEmitter(address emitter) external onlyOwner {
        if (!authorizedEmitters[emitter]) revert NotAuthorized();

        authorizedEmitters[emitter] = false;
        emit EmitterDeauthorized(emitter, block.timestamp);
    }

    /**
     * @notice Batch authorize multiple emitters (gas efficient)
     * @param emitters Array of contract addresses to authorize
     */
    function batchAuthorizeEmitters(address[] calldata emitters) external onlyOwner {
        for (uint256 i = 0; i < emitters.length; i++) {
            address emitter = emitters[i];
            if (emitter == address(0)) revert ZeroAddress();
            if (authorizedEmitters[emitter]) continue; // Skip already authorized

            authorizedEmitters[emitter] = true;
            emit EmitterAuthorized(emitter, block.timestamp);
        }
    }

    /**
     * @notice Batch deauthorize multiple emitters (gas efficient)
     * @param emitters Array of contract addresses to deauthorize
     */
    function batchDeauthorizeEmitters(address[] calldata emitters) external onlyOwner {
        for (uint256 i = 0; i < emitters.length; i++) {
            address emitter = emitters[i];
            if (!authorizedEmitters[emitter]) continue; // Skip not authorized

            authorizedEmitters[emitter] = false;
            emit EmitterDeauthorized(emitter, block.timestamp);
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check if contract is authorized to emit events
     * @param emitter Contract address to check
     * @return bool True if authorized, false otherwise
     */
    function isAuthorizedEmitter(address emitter) external view returns (bool) {
        return authorizedEmitters[emitter];
    }

    /**
     * @notice Get total events emitted count (analytics)
     * @return uint256 Total events emitted since deployment
     */
    function getTotalEventsEmitted() external view returns (uint256) {
        return totalEventsEmitted;
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Emit multiple events in single transaction (batch emission)
     * @dev Useful for complex operations that trigger multiple event types
     *
     * Example Use Case:
     * Unstaking triggers: StakingCreated event + YieldDistributed event + NFTTransferredWithStaking
     *
     * Note: This is a placeholder for future batch event patterns.
     * Implement specific batch functions as protocol needs evolve.
     */
    function batchEmitEvents(bytes[] calldata eventData) external onlyAuthorized {
        // Future implementation: decode eventData and emit multiple events
        // Current version: reserved for future use
        totalEventsEmitted += eventData.length;
    }
}
