// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "./interfaces/ITrancheStakingManager.sol";
import "./interfaces/IAPRModel.sol";

/**
 * @title TrancheStakingManager
 * @notice Phase-3 tranche-based NFT-keyed CURD staking
 * @dev Stakes are owned by nftId (not wallet). Claim/break always pays ownerOf(nftId).
 *      Each stake creates an individual tranche with locked APR and fixed 365-day maturity.
 *      Yield is funded externally by treasury via fundRewards(); yield is not minted.
 *
 * Key Features:
 * - NFT-gated staking: only CSA NFT owner or approved operator may call stake/claim/break
 * - Recipient is always the current ownerOf(nftId) for claim and breakEarly payouts
 * - Minimum 100 CURD per tranche; 365-day fixed maturity; APR locked at stake time
 * - Pluggable APR model (IAPRModel) or static baseAprBps fallback
 * - Treasury-funded rewards pool covers yield; principal held from staker deposits
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract TrancheStakingManager is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ITrancheStakingManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============ CONSTANTS ============

    /// @notice Minimum CURD required per tranche
    uint256 public constant MIN_TRANCHE_AMOUNT = 100e18;

    /// @notice Fixed maturity duration (365 days)
    uint256 public constant MATURITY_DURATION = 365 days;

    // ============ STATE VARIABLES ============

    /// @notice CURD ERC20 token
    IERC20Upgradeable public curdToken;

    /// @notice CSA NFT contract
    IERC721Upgradeable public csaNft;

    /// @notice Treasury address — operational authority for fundRewards()
    address public treasury;

    /// @notice Base APR in basis points; used when aprModel is address(0)
    uint32 public baseAprBps;

    /// @notice Optional pluggable APR model; address(0) means use baseAprBps
    address public aprModel;

    /// @notice CURD rewards pool funded by treasury; covers yield payouts
    uint256 public rewardsPool;

    /// @notice Tranches indexed by NFT ID
    mapping(uint256 => Tranche[]) private _tranches;

    /// @notice Cached active (non-closed) principal per NFT ID
    mapping(uint256 => uint256) private _activePrincipal;

    // ============ ERRORS ============

    error ZeroAddress();
    error ZeroAmount();
    error AmountBelowMinimum();
    error NotAuthorized();
    error NotTreasury();
    error TrancheClosed();
    error NotMatured();
    error TrancheMatured();
    error InsufficientRewards();

    // ============ MODIFIERS ============

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the TrancheStakingManager
     * @param _curdToken CURD ERC20 token address
     * @param _csaNft CSA NFT contract address
     * @param _treasury Treasury address (operational authority)
     * @param _baseAprBps Base APR in basis points (e.g. 1000 = 10%)
     * @param _aprModel Optional APR model address (address(0) to use baseAprBps)
     */
    function initialize(address _curdToken, address _csaNft, address _treasury, uint32 _baseAprBps, address _aprModel)
        external
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_curdToken == address(0)) revert ZeroAddress();
        if (_csaNft == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        curdToken = IERC20Upgradeable(_curdToken);
        csaNft = IERC721Upgradeable(_csaNft);
        treasury = _treasury;
        baseAprBps = _baseAprBps;
        // slither-disable-next-line missing-zero-check -- address(0) intentionally allowed: reverts to baseAprBps flat rate
        aprModel = _aprModel;
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Stake CURD for a CSA NFT, creating a new tranche
     * @dev Caller must be the NFT owner or an approved operator. CURD is transferred
     *      from msg.sender. Payouts from future claim/break go to the current ownerOf(nftId).
     * @param nftId CSA NFT token ID
     * @param amount CURD amount to stake (minimum 100e18)
     * @return trancheId Index of the newly created tranche
     */
    function stake(uint256 nftId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 trancheId)
    {
        _requireNftAuthorized(nftId);
        if (amount < MIN_TRANCHE_AMOUNT) revert AmountBelowMinimum();

        uint32 apr = _resolveApr(nftId, amount);
        uint256 maturityTime = block.timestamp + MATURITY_DURATION;

        curdToken.safeTransferFrom(msg.sender, address(this), amount);

        trancheId = _tranches[nftId].length;
        _tranches[nftId]
        .push(
            Tranche({
                principal: amount, startTime: block.timestamp, maturityTime: maturityTime, aprBps: apr, closed: false
            })
        );

        _activePrincipal[nftId] += amount;

        emit TrancheStaked(nftId, trancheId, msg.sender, amount, apr, maturityTime);
    }

    /**
     * @notice Claim matured tranches; pays principal + yield to ownerOf(nftId)
     * @dev Reverts if any tranche in the list is not yet matured or is already closed.
     *      Reverts if the rewards pool cannot cover total yield across all listed tranches.
     * @param nftId CSA NFT token ID
     * @param trancheIds Indices of tranches to claim
     */
    function claimMatured(uint256 nftId, uint256[] calldata trancheIds) external override nonReentrant whenNotPaused {
        _requireNftAuthorized(nftId);
        address recipient = csaNft.ownerOf(nftId);

        uint256 totalPrincipal = 0;
        uint256 totalYield = 0;

        for (uint256 i = 0; i < trancheIds.length; i++) {
            Tranche storage t = _tranches[nftId][trancheIds[i]];
            if (t.closed) revert TrancheClosed();
            if (block.timestamp < t.maturityTime) revert NotMatured();

            uint256 yld = _computeYield(t);
            totalPrincipal += t.principal;
            totalYield += yld;
            t.closed = true;

            emit TrancheClaimed(nftId, trancheIds[i], recipient, t.principal, yld);
        }

        if (totalYield > rewardsPool) revert InsufficientRewards();

        rewardsPool -= totalYield;
        _activePrincipal[nftId] -= totalPrincipal;

        curdToken.safeTransfer(recipient, totalPrincipal + totalYield);
    }

    /**
     * @notice Break tranches early; returns principal only, forfeits yield
     * @dev Reverts if any tranche is already matured (use claimMatured instead) or closed.
     *      Principal is returned to the current ownerOf(nftId), not necessarily the caller.
     * @param nftId CSA NFT token ID
     * @param trancheIds Indices of tranches to break early
     */
    function breakEarly(uint256 nftId, uint256[] calldata trancheIds) external override nonReentrant whenNotPaused {
        _requireNftAuthorized(nftId);
        address recipient = csaNft.ownerOf(nftId);

        uint256 totalPrincipal = 0;

        for (uint256 i = 0; i < trancheIds.length; i++) {
            Tranche storage t = _tranches[nftId][trancheIds[i]];
            if (t.closed) revert TrancheClosed();
            if (block.timestamp >= t.maturityTime) revert TrancheMatured();

            totalPrincipal += t.principal;
            t.closed = true;

            emit TrancheBroken(nftId, trancheIds[i], recipient, t.principal);
        }

        _activePrincipal[nftId] -= totalPrincipal;

        curdToken.safeTransfer(recipient, totalPrincipal);
    }

    /**
     * @notice Fund the CURD rewards pool (treasury only)
     * @dev Treasury transfers CURD into this contract to cover future yield payouts.
     * @param amount CURD amount to deposit into the rewards pool
     */
    function fundRewards(uint256 amount) external override nonReentrant onlyTreasury {
        if (amount == 0) revert ZeroAmount();
        rewardsPool += amount;
        curdToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(msg.sender, amount);
    }

    // ============ GOVERNANCE SETTERS ============

    /**
     * @notice Update the pluggable APR model (owner only)
     * @param newModel New APR model address; address(0) reverts to baseAprBps
     */
    function setAprModel(address newModel) external override onlyOwner {
        emit AprModelUpdated(aprModel, newModel);
        // slither-disable-next-line missing-zero-check -- address(0) intentionally allowed: disables model and reverts to baseAprBps flat rate
        aprModel = newModel;
    }

    /**
     * @notice Update the base APR in basis points (owner only)
     * @param newBps New base APR in basis points
     */
    function setBaseAprBps(uint32 newBps) external override onlyOwner {
        emit BaseAprBpsUpdated(baseAprBps, newBps);
        baseAprBps = newBps;
    }

    /**
     * @notice Update the treasury address (owner only)
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @notice Pause or unpause all state-changing functions (owner only)
     * @param paused_ True to pause, false to unpause
     */
    function setPaused(bool paused_) external onlyOwner {
        if (paused_) _pause();
        else _unpause();
    }

    // ============ VIEW FUNCTIONS ============

    /// @inheritdoc ITrancheStakingManager
    function trancheCount(uint256 nftId) external view override returns (uint256) {
        return _tranches[nftId].length;
    }

    /// @inheritdoc ITrancheStakingManager
    function getTranche(uint256 nftId, uint256 trancheId) external view override returns (Tranche memory) {
        return _tranches[nftId][trancheId];
    }

    /// @inheritdoc ITrancheStakingManager
    function activePrincipal(uint256 nftId) external view override returns (uint256) {
        return _activePrincipal[nftId];
    }

    /// @inheritdoc ITrancheStakingManager
    function previewYield(uint256 nftId, uint256 trancheId) external view override returns (uint256) {
        return _computeYield(_tranches[nftId][trancheId]);
    }

    /// @inheritdoc ITrancheStakingManager
    function isMatured(uint256 nftId, uint256 trancheId) external view override returns (bool) {
        return block.timestamp >= _tranches[nftId][trancheId].maturityTime;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Require that msg.sender is the NFT owner or an approved operator
     * @dev Checks ownerOf, getApproved, and isApprovedForAll
     * @param nftId CSA NFT token ID
     */
    function _requireNftAuthorized(uint256 nftId) internal view {
        address nftOwner = csaNft.ownerOf(nftId);
        if (
            msg.sender != nftOwner && csaNft.getApproved(nftId) != msg.sender
                && !csaNft.isApprovedForAll(nftOwner, msg.sender)
        ) revert NotAuthorized();
    }

    /**
     * @notice Resolve the APR for a new tranche using the model or fallback
     * @param nftId CSA NFT token ID
     * @param amount Stake principal
     * @return apr APR in basis points
     */
    function _resolveApr(uint256 nftId, uint256 amount) internal view returns (uint32 apr) {
        if (aprModel != address(0)) {
            return IAPRModel(aprModel).getApr(nftId, amount);
        }
        return baseAprBps;
    }

    /**
     * @notice Compute yield for a tranche at maturity
     * @dev yield = principal * aprBps / 10_000 (fixed 365-day maturity)
     * @param t Tranche to compute yield for
     * @return Yield amount in CURD
     */
    function _computeYield(Tranche storage t) internal view returns (uint256) {
        return (t.principal * uint256(t.aprBps)) / 10_000;
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades (upgrade-safe gap)
    uint256[50] private __gap;
}
