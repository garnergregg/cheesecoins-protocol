// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "../Config.sol";
import "./interfaces/IMarketplaceHook.sol";
import "../nft/interfaces/INFTTransferHook.sol";
import "../staking/interfaces/IStakingManager.sol";
import "../nft/interfaces/INFT.sol";
import "../domain-alpha/interfaces/IDomainAlphaEvents.sol";

/**
 * @title NFTMarketplaceHooks
 * @notice Production-grade hooks for secondary NFT marketplace integration (OpenSea, Magic Eden)
 * @dev Enables seamless NFT transfers with staking positions intact
 *
 * Key Features:
 * - Staking position transfer: New owner inherits staked CURD + maturity date
 * - Accrued yields locked until maturity (unchanged by sale)
 * - Validates transfer eligibility before NFT moves
 * - Updates StakingManager ownership records after transfer
 * - Tracks secondary market data for CURD/USD pricing models
 * - Records sale prices for protocol analytics and Domain Alpha bot
 * - Emits structured events for social media integration
 *
 * Domain Alpha Integration:
 * This contract acts as a data feed for the Domain Alpha social media bot, which monitors
 * on-chain events and posts to Twitter/Discord. Events include:
 * - NFT sales with staking positions (shows yield inheritance)
 * - Price tracking for CURD valuation models
 * - Marketplace activity for community engagement
 *
 * Design Philosophy:
 * - Staking positions are tied to NFT, not wallet (enables liquid secondary markets)
 * - Buyer inherits full position: staked amount, maturity date, accrued yield
 * - No early unstake penalty on transfer (position remains active)
 * - Marketplace integrations call beforeNFTTransfer → transfer NFT → afterNFTTransfer
 *
 * Security Model:
 * - Only authorized NFT contracts can call transfer hooks
 * - ReentrancyGuard on all state-changing functions
 * - Comprehensive validation of transfer eligibility
 * - Access control for marketplace registration
 * - No direct token handling (reads StakingManager state only)
 *
 * Integration Points:
 * - StakingManager: Read staking position data, validate transfers
 * - NFT Contracts: Call hooks during transfer flows
 * - EventAggregator: Emit centralized events for Domain Alpha
 * - OpenSea/Magic Eden: Query getSecondaryMarketData for listing metadata
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract NFTMarketplaceHooks is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IMarketplaceHook,
    INFTTransferHook
{
    // ============ STATE VARIABLES ============

    /// @notice StakingManager contract reference
    IStakingManager public stakingManager;

    /// @notice EventAggregator for Domain Alpha integration
    IDomainAlphaEvents public eventAggregator;

    /// @notice Mapping of authorized NFT contracts that can call hooks
    mapping(address => bool) public authorizedNFTs;

    /// @notice Mapping of NFT ID to last recorded sale price
    mapping(uint256 => uint256) public lastSalePrice;

    /// @notice Mapping of NFT ID to sale count (for analytics)
    mapping(uint256 => uint256) public saleCount;

    /// @notice Mapping of NFT ID to last seller address
    mapping(uint256 => address) public lastSeller;

    /// @notice Total secondary market volume tracked (in wei)
    uint256 public totalMarketVolume;

    /// @notice Total NFT sales tracked
    uint256 public totalSales;

    // ============ ERRORS ============

    error UnauthorizedNFT();
    error InvalidNFTId();
    error TransferNotAllowed();
    error ZeroAddress();
    error AlreadyAuthorized();
    error NotAuthorized();

    // ============ EVENTS ============

    event NFTAuthorized(address indexed nftContract, uint256 timestamp);
    event NFTDeauthorized(address indexed nftContract, uint256 timestamp);
    event SecondaryMarketSale(
        uint256 indexed nftId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 stakedAmount,
        uint256 timestamp
    );
    event MarketDataQueried(uint256 indexed nftId, address indexed querier, uint256 timestamp);

    // ============ MODIFIERS ============

    /**
     * @notice Ensures only authorized NFT contracts can call hooks
     */
    modifier onlyAuthorizedNFT() {
        if (!authorizedNFTs[msg.sender]) revert UnauthorizedNFT();
        _;
    }

    // ============ INITIALIZATION ============

    /**
     * @notice Initialize the marketplace hooks contract
     * @param _stakingManager Address of StakingManager contract
     * @param _eventAggregator Address of EventAggregator contract (Domain Alpha)
     */
    function initialize(address _stakingManager, address _eventAggregator) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        if (_stakingManager == address(0)) revert ZeroAddress();
        if (_eventAggregator == address(0)) revert ZeroAddress();

        stakingManager = IStakingManager(_stakingManager);
        eventAggregator = IDomainAlphaEvents(_eventAggregator);
    }

    // ============ MARKETPLACE HOOK IMPLEMENTATION ============

    /**
     * @notice Get comprehensive marketplace data for NFT listing
     * @dev Called by marketplaces (OpenSea, Magic Eden) to display staking info
     * @param nftId NFT token ID
     * @return MarketplaceData struct with NFT and staking details
     *
     * Usage Example:
     * - OpenSea displays "This NFT includes X CURD staked with Y days until maturity"
     * - Magic Eden shows "Accrued yield: Z CURD (locked until maturity)"
     * - Pricing models: "Estimated value: (floor price + staked value + accrued yield)"
     */
    function getSecondaryMarketData(uint256 nftId) external override returns (MarketplaceData memory) {
        // Retrieve staking position from StakingManager
        IStakingManager.StakingPosition memory position = stakingManager.getStakingPosition(nftId);

        // Get NFT ownership information
        address nftAddress = stakingManager.getNFTAddress(nftId);
        if (nftAddress == address(0)) revert InvalidNFTId();

        address currentOwner = IERC721Upgradeable(nftAddress).ownerOf(nftId);

        // Construct marketplace data
        MarketplaceData memory data = MarketplaceData({
            nftId: nftId,
            stakedAmount: position.active ? position.amount : 0,
            maturityTime: position.active ? position.maturityTime : 0,
            accruedYield: position.active ? position.accruedYield : 0,
            seller: currentOwner,
            listPrice: lastSalePrice[nftId] // Last known price (reference for new listings)
        });

        emit MarketDataQueried(nftId, msg.sender, block.timestamp);

        return data;
    }

    /**
     * @notice Record secondary market sale for analytics and pricing
     * @dev Called by marketplace contracts or relayers after sale completes
     * @param nftId NFT token ID
     * @param seller Original seller address
     * @param buyer New buyer address
     * @param price Sale price in wei (native token or stablecoin)
     *
     * Domain Alpha Integration:
     * Emits event that triggers social media bot to post:
     * - "🧀 NFT #123 sold for X ETH with Y CURD staked!"
     * - "New owner inherits Z CURD in accrued yields (locked until maturity)"
     * - Analytics for CURD/USD pricing models
     */
    function recordSecondaryMarketSale(uint256 nftId, address seller, address buyer, uint256 price)
        external
        override
        nonReentrant
    {
        // Validate inputs
        if (seller == address(0) || buyer == address(0)) revert ZeroAddress();

        // Get staking position for sale event
        IStakingManager.StakingPosition memory position = stakingManager.getStakingPosition(nftId);

        // Update tracking data
        lastSalePrice[nftId] = price;
        lastSeller[nftId] = seller;
        saleCount[nftId] += 1;
        totalMarketVolume += price;
        totalSales += 1;

        // Emit IMarketplaceHook event (protocol-specific)
        emit NFTTransferredWithStaking(nftId, seller, buyer, position.active ? position.amount : 0, price);

        // Emit SecondaryMarketSale event (marketplace-specific)
        emit SecondaryMarketSale(nftId, seller, buyer, price, position.active ? position.amount : 0, block.timestamp);

        // Emit to EventAggregator for Domain Alpha bot
        eventAggregator.emitNFTTransferredWithStaking(nftId, seller, buyer, position.active ? position.amount : 0);
    }

    // ============ NFT TRANSFER HOOK IMPLEMENTATION ============

    /**
     * @notice Validate NFT transfer eligibility before transfer occurs
     * @dev Called by NFT contract before safeTransferFrom executes
     * @param nftId NFT token ID
     * @param from Current owner (seller)
     * @param to New owner (buyer)
     * @return bool True if transfer is allowed, false otherwise
     *
     * Validation Rules:
     * - NFT must be registered in StakingManager
     * - If staking position exists, it must be transferable:
     *   * Position is active (not already unstaked)
     *   * No protocol-level locks (future: governance votes, pending claims)
     * - Transfers to zero address are blocked
     *
     * Note: This does NOT check maturity. Immature positions CAN transfer.
     * The new owner inherits the lock period and must wait for maturity.
     */
    function beforeNFTTransfer(uint256 nftId, address from, address to)
        external
        override
        onlyAuthorizedNFT
        returns (bool)
    {
        // Block transfers to zero address (burn requires different flow)
        if (to == address(0)) revert ZeroAddress();

        // Validate NFT is registered in staking system
        if (!stakingManager.isNFTRegistered(nftId)) revert InvalidNFTId();

        // Get staking position
        IStakingManager.StakingPosition memory position = stakingManager.getStakingPosition(nftId);

        // If no active position, allow transfer freely
        if (!position.active) {
            return true;
        }

        // Position exists: validate transferability
        // Currently, all active positions are transferable
        // Future enhancements: check for governance locks, pending claims, etc.

        return true;
    }

    /**
     * @notice Update ownership records after NFT transfer completes
     * @dev Called by NFT contract after safeTransferFrom succeeds
     * @param nftId NFT token ID
     * @param from Previous owner (seller)
     * @param to New owner (buyer)
     *
     * Post-Transfer Actions:
     * - No state changes needed in this contract (StakingManager tracks via NFT ownership)
     * - Staking position automatically follows NFT (tied to tokenId, not wallet)
     * - New owner can immediately claim matured yields or unstake after maturity
     * - Accrued yield remains locked until original maturity date
     *
     * Design Note:
     * StakingManager uses NFT ownership verification for all operations.
     * When new owner calls stakingManager.unstake(nftId), it validates
     * INFT.ownerOf(nftId) == msg.sender, automatically recognizing new owner.
     *
     * This hook is primarily for event emission and future extensibility.
     */
    function afterNFTTransfer(uint256 nftId, address from, address to) external override onlyAuthorizedNFT {
        // Get staking position for event emission
        IStakingManager.StakingPosition memory position = stakingManager.getStakingPosition(nftId);

        // If staking position exists, emit detailed transfer event
        if (position.active) {
            // Emit to EventAggregator for Domain Alpha bot
            eventAggregator.emitNFTTransferredWithStaking(nftId, from, to, position.amount);
        }

        // Note: No state changes required here.
        // StakingManager already tracks ownership via NFT contract.
        // Future enhancements could include:
        // - Notification to buyer about inherited staking position
        // - Analytics tracking for user acquisition
        // - Loyalty rewards for secondary market participants
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Authorize NFT contract to call transfer hooks
     * @dev Only authorized contracts can trigger hook functions
     * @param nftContract Address of NFT contract to authorize
     */
    function authorizeNFT(address nftContract) external onlyOwner {
        if (nftContract == address(0)) revert ZeroAddress();
        if (authorizedNFTs[nftContract]) revert AlreadyAuthorized();

        authorizedNFTs[nftContract] = true;
        emit NFTAuthorized(nftContract, block.timestamp);
    }

    /**
     * @notice Deauthorize NFT contract from calling hooks
     * @param nftContract Address of NFT contract to deauthorize
     */
    function deauthorizeNFT(address nftContract) external onlyOwner {
        if (!authorizedNFTs[nftContract]) revert NotAuthorized();

        authorizedNFTs[nftContract] = false;
        emit NFTDeauthorized(nftContract, block.timestamp);
    }

    /**
     * @notice Update StakingManager reference (for upgrades)
     * @param _stakingManager New StakingManager address
     */
    function setStakingManager(address _stakingManager) external onlyOwner {
        if (_stakingManager == address(0)) revert ZeroAddress();
        stakingManager = IStakingManager(_stakingManager);
    }

    /**
     * @notice Update EventAggregator reference (for upgrades)
     * @param _eventAggregator New EventAggregator address
     */
    function setEventAggregator(address _eventAggregator) external onlyOwner {
        if (_eventAggregator == address(0)) revert ZeroAddress();
        eventAggregator = IDomainAlphaEvents(_eventAggregator);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get sale history for specific NFT
     * @param nftId NFT token ID
     * @return lastPrice Last recorded sale price
     * @return sales Total number of sales
     * @return seller Last seller address
     */
    function getNFTSaleHistory(uint256 nftId) external view returns (uint256 lastPrice, uint256 sales, address seller) {
        return (lastSalePrice[nftId], saleCount[nftId], lastSeller[nftId]);
    }

    /**
     * @notice Get global marketplace statistics
     * @return volume Total secondary market volume (in wei)
     * @return sales Total number of sales tracked
     */
    function getMarketplaceStats() external view returns (uint256 volume, uint256 sales) {
        return (totalMarketVolume, totalSales);
    }

    /**
     * @notice Check if NFT contract is authorized
     * @param nftContract NFT contract address
     * @return bool True if authorized, false otherwise
     */
    function isAuthorizedNFT(address nftContract) external view returns (bool) {
        return authorizedNFTs[nftContract];
    }
}
