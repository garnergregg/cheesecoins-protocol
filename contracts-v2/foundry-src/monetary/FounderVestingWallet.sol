// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Config.sol";

/**
 * @title FounderVestingWallet
 * @notice Linear vesting wallet for the founder's 20M CURD allocation (4-year vest)
 * @dev Non-upgradeable. No clawbacks. Pure linear vesting from start over Config.FOUNDER_VEST_DURATION.
 */
contract FounderVestingWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ IMMUTABLES ============

    /// @notice The CURD token
    IERC20 public immutable curd;

    /// @notice Beneficiary of the vested tokens (founder)
    address public immutable beneficiary;

    /// @notice Vesting start timestamp
    uint64 public immutable start;

    /// @notice Vesting duration (Config.FOUNDER_VEST_DURATION = 4 * 365 days)
    uint64 public immutable duration;

    // ============ STATE ============

    /// @notice Total tokens already released to the beneficiary
    uint256 public released;

    // ============ EVENTS ============

    event Released(uint256 amount);

    // ============ CONSTRUCTOR ============

    /**
     * @param _curd Address of the CURD token contract
     * @param _beneficiary Founder address that receives vested tokens
     * @param _start Vesting start timestamp (use block.timestamp at deploy)
     */
    constructor(address _curd, address _beneficiary, uint64 _start) {
        require(_curd != address(0), "FounderVestingWallet: zero curd");
        require(_beneficiary != address(0), "FounderVestingWallet: zero beneficiary");

        curd = IERC20(_curd);
        beneficiary = _beneficiary;
        start = _start;
        duration = Config.FOUNDER_VEST_DURATION;
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Total allocation assigned to this wallet (balance + already released)
     * @return Total CURD allocated to this vesting schedule
     */
    function totalAllocation() public view returns (uint256) {
        return curd.balanceOf(address(this)) + released;
    }

    /**
     * @notice Amount of CURD vested as of the given timestamp
     * @param timestamp Point in time to evaluate (unix seconds)
     * @return Vested amount (capped at totalAllocation)
     */
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint256 total = totalAllocation();
        if (timestamp < start) return 0;
        if (timestamp >= start + duration) return total;
        return (total * (timestamp - start)) / duration;
    }

    /**
     * @notice Amount currently releasable to the beneficiary
     * @return Releasable CURD (vested minus already released)
     */
    function releasable() public view returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    // ============ RELEASE ============

    /**
     * @notice Transfer all currently releasable tokens to the beneficiary
     * @dev Only callable by the beneficiary.
     */
    function release() external nonReentrant {
        require(msg.sender == beneficiary, "NOT_BENEFICIARY");
        uint256 amount = releasable();
        require(amount > 0, "NOTHING_TO_RELEASE");

        released += amount;
        emit Released(amount);

        curd.safeTransfer(beneficiary, amount);
    }
}
