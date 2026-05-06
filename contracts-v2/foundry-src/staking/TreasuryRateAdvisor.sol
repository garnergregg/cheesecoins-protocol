// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev Minimal interface for any contract that exposes setBaseAPY(uint256).
///      Avoids a circular import of StakingManager while keeping typed calls.
interface IBaseAPYTarget {
    function setBaseAPY(uint256 bps) external;
}

/**
 * @title TreasuryRateAdvisor
 * @notice On-chain governance record of protocol staking rate decisions.
 *
 *         The treasury posts a new rate after each FOMC meeting (8× per year),
 *         citing the Fed Funds rate, a protocol spread, and the source announcement.
 *         This creates a fully transparent, auditable history of every rate decision.
 *
 *         The effective staker APY = fedFundsRateBps + spreadBps.
 *         The spread (e.g. 25 bps = 0.25%) represents the agricultural premium —
 *         CURD is backed by real farm production, so stakers earn slightly above
 *         the risk-free rate.
 *
 * @dev Integration with StakingManager:
 *      applyToStakingManager() calls StakingManager.setBaseAPY(effectiveRateBps).
 *      This requires the caller to own (or be authorized by) the StakingManager.
 *      On testnet: treasury EOA owns StakingManager — call directly.
 *      On mainnet: Gnosis Safe owns StakingManager — execute via Safe transaction.
 *
 *      Chainlink Automation integration (optional):
 *      Register an Automation upkeep that calls applyToStakingManager() when
 *      a RateDecisionPosted event is emitted. The upkeep address must be
 *      granted AUTOMATION_ROLE via grantAutomationRole().
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract TreasuryRateAdvisor is Initializable, OwnableUpgradeable {
    // ============ TYPES ============

    /**
     * @notice A single FOMC-aligned rate decision
     * @param fedFundsRateBps  The Fed Funds effective rate in basis points (e.g. 525 = 5.25%)
     * @param spreadBps        Protocol spread above Fed rate (e.g. 25 = 0.25%)
     * @param effectiveRateBps Total staker APY = fedFunds + spread
     * @param timestamp        Block timestamp when posted
     * @param source           Human-readable source citation (e.g. "FOMC 2026-03-19")
     */
    struct RateDecision {
        uint256 fedFundsRateBps;
        uint256 spreadBps;
        uint256 effectiveRateBps;
        uint256 timestamp;
        string source;
    }

    // ============ STATE ============

    /// @notice Treasury address — only address allowed to post rate decisions
    address public treasury;

    /// @notice Optional StakingManager target for applyToStakingManager()
    address public stakingManager;

    /// @notice Addresses authorized to call applyToStakingManager() (e.g. Chainlink Automation)
    mapping(address => bool) public automationRole;

    /// @notice Full history of rate decisions — max 8/year, bounded in practice
    RateDecision[] private _history;

    // ============ LIMITS ============

    /// @notice Maximum Fed Funds rate accepted (2000 bps = 20%) — sanity guard
    uint256 public constant MAX_FED_FUNDS_BPS = 2_000;

    /// @notice Maximum protocol spread (500 bps = 5%)
    uint256 public constant MAX_SPREAD_BPS = 500;

    // ============ ERRORS ============

    error ZeroAddress();
    error NotTreasury();
    error NotAuthorized();
    error FedRateTooHigh(uint256 provided, uint256 max);
    error SpreadTooHigh(uint256 provided, uint256 max);
    error NoDecisionPosted();
    error StakingManagerNotSet();

    // ============ EVENTS ============

    /**
     * @notice Emitted every time the treasury posts a new rate decision.
     *         Chainlink Automation should watch for this event to trigger applyToStakingManager().
     */
    event RateDecisionPosted(
        uint256 indexed decisionIndex,
        uint256 fedFundsRateBps,
        uint256 spreadBps,
        uint256 effectiveRateBps,
        uint256 timestamp,
        string source
    );

    /// @notice Emitted when the advisory rate is applied to StakingManager
    event RateApplied(address indexed stakingManager, uint256 effectiveRateBps, address indexed appliedBy);

    /// @notice Emitted when the treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when the StakingManager target is updated
    event StakingManagerUpdated(address indexed oldSM, address indexed newSM);

    /// @notice Emitted when Automation role is granted or revoked
    event AutomationRoleUpdated(address indexed account, bool granted);

    // ============ MODIFIERS ============

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    modifier onlyTreasuryOrOwnerOrAutomation() {
        if (msg.sender != treasury && msg.sender != owner() && !automationRole[msg.sender]) {
            revert NotAuthorized();
        }
        _;
    }

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize TreasuryRateAdvisor
     * @param _treasury       Address authorized to post rate decisions
     * @param _stakingManager StakingManager to apply rates to (address(0) = configure later)
     * @param _owner          Contract owner (governance)
     */
    function initialize(address _treasury, address _stakingManager, address _owner) external initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();

        treasury = _treasury;
        stakingManager = _stakingManager; // may be address(0) at deploy

        _transferOwnership(_owner);
    }

    // ============ CORE: POST RATE DECISION ============

    /**
     * @notice Post a new rate decision after an FOMC meeting (treasury only).
     *         Records the Fed Funds rate, protocol spread, and source citation
     *         on-chain. Emits RateDecisionPosted for Chainlink Automation to detect.
     *
     * @param fedFundsRateBps  Fed Funds effective rate in bps (e.g. 525 = 5.25%)
     * @param spreadBps        Protocol spread above Fed rate in bps (e.g. 25 = 0.25%)
     * @param source           FOMC meeting identifier (e.g. "FOMC 2026-03-19")
     */
    function postRateDecision(uint256 fedFundsRateBps, uint256 spreadBps, string calldata source)
        external
        onlyTreasury
    {
        if (fedFundsRateBps > MAX_FED_FUNDS_BPS) revert FedRateTooHigh(fedFundsRateBps, MAX_FED_FUNDS_BPS);
        if (spreadBps > MAX_SPREAD_BPS) revert SpreadTooHigh(spreadBps, MAX_SPREAD_BPS);

        uint256 effectiveRateBps = fedFundsRateBps + spreadBps;

        _history.push(
            RateDecision({
                fedFundsRateBps: fedFundsRateBps,
                spreadBps: spreadBps,
                effectiveRateBps: effectiveRateBps,
                timestamp: block.timestamp,
                source: source
            })
        );

        uint256 decisionIndex = _history.length - 1;

        emit RateDecisionPosted(decisionIndex, fedFundsRateBps, spreadBps, effectiveRateBps, block.timestamp, source);
    }

    // ============ CORE: APPLY TO STAKING MANAGER ============

    /**
     * @notice Apply the current advisory rate to StakingManager.setBaseAPY().
     *         Callable by treasury, owner, or any address granted automationRole
     *         (e.g. a Chainlink Automation upkeep address).
     *
     * @dev Requires stakingManager to be set and the caller / this contract
     *      to be authorized to call StakingManager.setBaseAPY().
     *      On testnet: treasury EOA owns StakingManager — treasury calls directly.
     *      On mainnet: Gnosis Safe calls via Safe transaction.
     *      With Automation: register upkeep, grant automationRole, wire up.
     */
    function applyToStakingManager() external onlyTreasuryOrOwnerOrAutomation {
        // slither-disable-next-line incorrect-equality
        // (intentional: array length is exact, not approximate.)
        if (_history.length == 0) revert NoDecisionPosted();
        if (stakingManager == address(0)) revert StakingManagerNotSet();

        uint256 effectiveRate = _history[_history.length - 1].effectiveRateBps;

        // Emit before external call (CEI order) to satisfy reentrancy-events checker.
        // setBaseAPY() is a simple setter with no callbacks into this contract.
        emit RateApplied(stakingManager, effectiveRate, msg.sender);

        // Call StakingManager.setBaseAPY(effectiveRate) via typed interface.
        // The caller of this function must be the owner of StakingManager,
        // OR StakingManager must have granted this contract an appropriate role.
        IBaseAPYTarget(stakingManager).setBaseAPY(effectiveRate);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns the most recent rate decision
     */
    function currentDecision() external view returns (RateDecision memory) {
        // slither-disable-next-line incorrect-equality
        // (intentional: array length is exact, not approximate.)
        if (_history.length == 0) revert NoDecisionPosted();
        return _history[_history.length - 1];
    }

    /**
     * @notice Returns the current effective staker APY in basis points
     */
    function currentEffectiveRateBps() external view returns (uint256) {
        // slither-disable-next-line incorrect-equality
        // (intentional: array length is exact, not approximate.)
        if (_history.length == 0) revert NoDecisionPosted();
        return _history[_history.length - 1].effectiveRateBps;
    }

    /**
     * @notice Returns the number of rate decisions posted
     */
    function decisionCount() external view returns (uint256) {
        return _history.length;
    }

    /**
     * @notice Returns the full rate history
     */
    function getRateHistory() external view returns (RateDecision[] memory) {
        return _history;
    }

    /**
     * @notice Returns a single rate decision by index
     */
    function getDecision(uint256 index) external view returns (RateDecision memory) {
        return _history[index];
    }

    // ============ OWNER SETTERS ============

    /**
     * @notice Update the treasury address (owner only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /**
     * @notice Set or update the StakingManager target (owner only)
     */
    function setStakingManager(address _stakingManager) external onlyOwner {
        if (_stakingManager == address(0)) revert ZeroAddress();
        emit StakingManagerUpdated(stakingManager, _stakingManager);
        stakingManager = _stakingManager;
    }

    /**
     * @notice Grant or revoke Chainlink Automation role (owner only)
     * @param account  The Automation upkeep forwarder address
     * @param granted  True to grant, false to revoke
     */
    function grantAutomationRole(address account, bool granted) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        automationRole[account] = granted;
        emit AutomationRoleUpdated(account, granted);
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
