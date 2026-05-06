// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IHarvestOracle} from "../core/interfaces/IHarvestOracle.sol";
import {Config} from "../Config.sol";
import {ValidationLibrary} from "../libraries/ValidationLibrary.sol";

/**
 * @title HarvestOracle
 * @notice Per-project herd production data oracle for 10K+ agricultural projects
 * @dev Tracks herd size (totalDoes) and production value (USD) for yield calculations
 *
 * ARCHITECTURE:
 * - Scalable to 10K+ projects (mapping-based storage)
 * - Per-project staleness tracking
 * - Manual or Chainlink Automation update support
 * - Verification flag for audited data
 *
 * DATA FLOW:
 * 1. Authorized updaters (IoT devices, auditors, Chainlink) submit herd data
 * 2. Data includes: totalDoes (herd size), productionValue (USD in 8 decimals)
 * 3. Timestamp and verification flag stored per project
 * 4. CheesecoinsCore queries fresh data for yield distribution
 * 5. Stale data (>24h) triggers warnings but doesn't block system
 *
 * SECURITY:
 * - Only authorized updaters can submit data
 * - Staleness checks prevent using outdated data
 * - Verification flag indicates audited/certified data
 * - Per-project access control
 *
 * USAGE:
 * 1. Owner authorizes updaters (IoT gateways, Chainlink nodes, auditors)
 * 2. Updaters call updateHerdData(projectId, totalDoes, productionValue)
 * 3. Core contract calls getHerdData() to calculate yields
 * 4. Monitor HerdDataUpdated events for production changes
 */
contract HarvestOracle is OwnableUpgradeable, IHarvestOracle {
    // ============ STATE VARIABLES ============

    /// @notice Mapping from project ID to herd data
    mapping(uint256 => HerdData) private _herdData;

    /// @notice Authorized data updaters (IoT, Chainlink, auditors)
    mapping(address => bool) public authorizedUpdaters;

    /// @notice Staleness threshold (from Config)
    uint256 public constant STALENESS_THRESHOLD = Config.ORACLE_STALENESS_THRESHOLD;

    /// @notice Price decimals (8 for USD values)
    uint8 public constant DECIMALS = uint8(Config.PRICE_DECIMALS);

    // ============ EVENTS ============

    event UpdaterAuthorized(address indexed updater, bool authorized);
    event DataVerified(uint256 indexed projectId, address indexed verifier);

    // ============ ERRORS ============

    error UnauthorizedUpdater();
    error InvalidProjectId();
    error InvalidHerdSize();
    error InvalidProductionValue();
    error DataNotFound();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize HarvestOracle
     * @dev Owner is authorized updater by default
     */
    constructor() {
        authorizedUpdaters[msg.sender] = true;
    }

    // ============ DATA UPDATES ============

    /**
     * @notice Update herd production data for a project
     * @dev Only authorized updaters can call
     * @param projectId Project ID (1-based)
     * @param totalDoes Total number of does (female goats) in herd
     * @param productionValue Monthly production value in USD (8 decimals)
     */
    function updateHerdData(uint256 projectId, uint256 totalDoes, uint256 productionValue) external override {
        if (!authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        if (projectId == 0) revert InvalidProjectId();
        if (totalDoes == 0) revert InvalidHerdSize();
        if (productionValue == 0) revert InvalidProductionValue();

        // Store herd data
        _herdData[projectId] = HerdData({
            projectId: projectId,
            totalDoes: totalDoes,
            productionValue: productionValue,
            timestamp: block.timestamp,
            verified: false // Requires separate verification
        });

        emit HerdDataUpdated(projectId, totalDoes, productionValue);
    }

    /**
     * @notice Update and verify herd data (single call for auditors)
     * @dev Only authorized updaters can call
     * @param projectId Project ID
     * @param totalDoes Total does in herd
     * @param productionValue Production value in USD (8 decimals)
     */
    function updateAndVerifyHerdData(uint256 projectId, uint256 totalDoes, uint256 productionValue) external {
        if (!authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        if (projectId == 0) revert InvalidProjectId();
        if (totalDoes == 0) revert InvalidHerdSize();
        if (productionValue == 0) revert InvalidProductionValue();

        // Store verified herd data
        _herdData[projectId] = HerdData({
            projectId: projectId,
            totalDoes: totalDoes,
            productionValue: productionValue,
            timestamp: block.timestamp,
            verified: true
        });

        emit HerdDataUpdated(projectId, totalDoes, productionValue);
        emit DataVerified(projectId, msg.sender);
    }

    /**
     * @notice Mark existing data as verified
     * @dev Only authorized updaters can verify
     * @param projectId Project ID to verify
     */
    function verifyData(uint256 projectId) external {
        if (!authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        // slither-disable-next-line incorrect-equality -- timestamp == 0 is EVM default sentinel for "no data"
        if (_herdData[projectId].timestamp == 0) revert DataNotFound();

        _herdData[projectId].verified = true;
        emit DataVerified(projectId, msg.sender);
    }

    // ============ DATA QUERIES ============

    /**
     * @notice Get herd data for a project
     * @param projectId Project ID to query
     * @return Herd data struct
     */
    function getHerdData(uint256 projectId) external view override returns (HerdData memory) {
        // slither-disable-next-line incorrect-equality -- timestamp == 0 is EVM default sentinel for "no data recorded yet"
        if (_herdData[projectId].timestamp == 0) revert DataNotFound();
        return _herdData[projectId];
    }

    /**
     * @notice Check if project data is fresh (within staleness threshold)
     * @param projectId Project ID to check
     * @return True if data is fresh
     */
    function isDataFresh(uint256 projectId) external view override returns (bool) {
        HerdData memory data = _herdData[projectId];
        // slither-disable-next-line incorrect-equality -- timestamp == 0 is EVM default sentinel for "no data"
        if (data.timestamp == 0) return false;

        return ValidationLibrary.isOracleFresh(data.timestamp, STALENESS_THRESHOLD);
    }

    /**
     * @notice Get latest production value for a project
     * @dev Returns 0 if no data exists
     * @param projectId Project ID to query
     * @return Production value in USD (8 decimals)
     */
    function getLatestProductionValue(uint256 projectId) external view override returns (uint256) {
        return _herdData[projectId].productionValue;
    }

    /**
     * @notice Get herd size for a project
     * @param projectId Project ID to query
     * @return Total does in herd
     */
    function getHerdSize(uint256 projectId) external view returns (uint256) {
        return _herdData[projectId].totalDoes;
    }

    /**
     * @notice Check if project data is verified
     * @param projectId Project ID to check
     * @return True if data is verified by auditor
     */
    function isDataVerified(uint256 projectId) external view returns (bool) {
        return _herdData[projectId].verified;
    }

    /**
     * @notice Get data age in seconds
     * @param projectId Project ID to check
     * @return Age of data in seconds
     */
    function getDataAge(uint256 projectId) external view returns (uint256) {
        HerdData memory data = _herdData[projectId];
        // slither-disable-next-line incorrect-equality -- timestamp == 0 is EVM default sentinel; max returned to signal "never updated"
        if (data.timestamp == 0) return type(uint256).max;

        return block.timestamp - data.timestamp;
    }

    /**
     * @notice Batch query multiple projects
     * @dev Gas-efficient for querying multiple projects
     * @param projectIds Array of project IDs
     * @return Array of herd data
     */
    function batchGetHerdData(uint256[] calldata projectIds) external view returns (HerdData[] memory) {
        HerdData[] memory results = new HerdData[](projectIds.length);

        for (uint256 i = 0; i < projectIds.length; i++) {
            results[i] = _herdData[projectIds[i]];
        }

        return results;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Authorize or revoke data updater
     * @dev Only owner can manage updaters
     * @param updater Updater address (IoT gateway, Chainlink node, auditor)
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        ValidationLibrary.requireNonZeroAddress(updater, "HarvestOracle: zero address");
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorized(updater, authorized);
    }

    /**
     * @notice Batch authorize multiple updaters
     * @dev Gas-efficient for setting up multiple updaters
     * @param updaters Array of updater addresses
     * @param authorized True to authorize all, false to revoke all
     */
    function batchSetAuthorizedUpdaters(address[] calldata updaters, bool authorized) external onlyOwner {
        for (uint256 i = 0; i < updaters.length; i++) {
            ValidationLibrary.requireNonZeroAddress(updaters[i], "HarvestOracle: zero address");
            authorizedUpdaters[updaters[i]] = authorized;
            emit UpdaterAuthorized(updaters[i], authorized);
        }
    }

    /**
     * @notice Check if address is authorized updater
     * @param updater Address to check
     * @return True if authorized
     */
    function isAuthorizedUpdater(address updater) external view returns (bool) {
        return authorizedUpdaters[updater];
    }

    /**
     * @notice Emergency data correction (only owner)
     * @dev Use only in case of data entry errors
     * @param projectId Project ID to correct
     * @param totalDoes Corrected herd size
     * @param productionValue Corrected production value
     */
    function emergencyCorrectData(uint256 projectId, uint256 totalDoes, uint256 productionValue) external onlyOwner {
        if (projectId == 0) revert InvalidProjectId();
        if (totalDoes == 0) revert InvalidHerdSize();
        if (productionValue == 0) revert InvalidProductionValue();

        _herdData[projectId].totalDoes = totalDoes;
        _herdData[projectId].productionValue = productionValue;
        _herdData[projectId].timestamp = block.timestamp;

        emit HerdDataUpdated(projectId, totalDoes, productionValue);
    }
}
