// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../core/interfaces/ICheesecoinsCore.sol";

/**
 * @title BurnAuthority
 * @notice Centralized controlled burn executor for Phase-3 stability mechanics.
 * @dev Only authorized modules (e.g. FiatRedemptionVault) may invoke burn().
 *      CURD must be transferred into this contract before burn() is called.
 *      This contract never transfers CURD back out — all supply contraction is permanent.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract BurnAuthority is Initializable, OwnableUpgradeable {
    // ============ STATE ============

    /// @notice CURD token — burn() is called on msg.sender (this contract)
    ICheesecoinsCore public curd;

    /// @notice Addresses authorized to trigger burns (e.g. FiatRedemptionVault, HedgeModule)
    mapping(address => bool) public authorizedCaller;

    // ============ ERRORS ============

    error ZeroAddress();
    error NotAuthorized();
    error ZeroAmount();

    // ============ EVENTS ============

    event CallerAuthorized(address indexed caller, bool allowed);
    event Burned(address indexed initiator, uint256 amount);

    // ============ INITIALIZATION ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize BurnAuthority
     * @param _curd  CURD token address
     * @param _owner Contract owner address
     */
    function initialize(address _curd, address _owner) external initializer {
        if (_curd == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init();

        curd = ICheesecoinsCore(_curd);

        _transferOwnership(_owner);
    }

    // ============ GOVERNANCE ============

    /**
     * @notice Authorize or deauthorize a caller to invoke burn()
     * @param caller  Address to update
     * @param allowed Authorization status
     */
    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        authorizedCaller[caller] = allowed;
        emit CallerAuthorized(caller, allowed);
    }

    // ============ BURN ============

    /**
     * @notice Burn CURD held in this contract
     * @dev Caller must be authorized. CURD must already be in this contract's balance.
     *      Calls ICheesecoinsCore.burn(amount) which burns from msg.sender (this contract).
     *      No CURD is ever transferred back out of this contract.
     * @param amount Amount of CURD to burn
     */
    function burn(uint256 amount) external {
        if (!authorizedCaller[msg.sender]) revert NotAuthorized();
        if (amount == 0) revert ZeroAmount();

        // curd.burn() burns from msg.sender, which is this contract
        curd.burn(amount);

        emit Burned(msg.sender, amount);
    }

    // ============ STORAGE GAP ============

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
