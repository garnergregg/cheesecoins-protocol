// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {INFTTransferHook} from "../interfaces/INFTTransferHook.sol";
import {ISceneNFT} from "../interfaces/ISceneNFT.sol";

/// @dev Minimal interface for notifying governance of potential voting power changes.
interface ISuperHolderGovernance {
    function notifyPotentialVotingPowerChange(address user) external;
}

/// @dev Minimal interface used to query the NFT's own configured transfer hook.
///      Querying the NFT (not the caller) ensures the router identity is anchored
///      to the NFT's state, preventing any contract from self-asserting router status.
interface INFTWithHook {
    function transferHook() external view returns (address);
}

/**
 * @title SceneTracker
 * @notice Tracks per-user scene ownership and Super Holder eligibility.
 * @dev Implements INFTTransferHook so NubiansNorthNFT can call it on every
 *      token transfer AND every mint (from == address(0)) without isContract gating.
 *
 * SUPER HOLDER MECHANICS:
 * - A user is a Super Holder when they own at least one token from every scene (1..100).
 * - Tracked via a 100-bit bitmask: bit (scene-1) is set when userSceneCounts[user][scene] > 0.
 * - hasFullCollection(user) returns true when all bits 0..99 are set.
 *
 * SECURITY:
 * - Only the registered NFT contract (nftContract) OR its configured transfer hook can call
 *   afterNFTTransfer / beforeNFTTransfer.  Router identity is verified by querying
 *   nftContract.transferHook() — not by trusting the caller's self-assertion.
 * - Owner can update nftContract address.
 * - No isContract() gating — works correctly for EOAs.
 *
 * PORT NOTE:
 * - Ported from reference/legacy-contracts/NubiansNorthExtensions.sol (super holder logic only).
 * - YT-vesting, badge-minting, and external governance badge calls are out of scope for PR1.
 *
 * @custom:security-contact security@cheesecoins.io
 */
contract SceneTracker is INFTTransferHook, Ownable {
    // ============ CONSTANTS ============

    /// @notice Number of distinct scenes (must collect one of each to become Super Holder)
    uint16 public constant TOTAL_SCENES = 100;

    // ============ STATE VARIABLES ============

    /// @notice The NFT contract that is allowed to call this hook
    address public nftContract;

    /// @notice Address of the SuperHolderGovernance contract to notify on full-collection transitions.
    /// @dev Set by owner via setGovernanceNotifier. Zero address disables notifications.
    address public governanceNotifier;

    /// @notice Per-user bitmask: bit (scene-1) is 1 if the user owns >= 1 token of that scene
    mapping(address => uint256) private _sceneBitmask;

    /// @notice Per-user, per-scene token count
    mapping(address => mapping(uint16 => uint256)) public userSceneCounts;

    /// @notice Number of wallets that currently hold a full collection.
    /// @dev Incremented when a wallet gains super-holder status; decremented on loss.
    ///      Read by MaturityOracle to gate governance stage transitions.
    uint256 public superHolderCount;

    // ============ EVENTS ============

    event SceneAdded(address indexed user, uint16 indexed scene, uint256 newCount);
    event SceneRemoved(address indexed user, uint16 indexed scene, uint256 newCount);
    event SuperHolderStatusChanged(address indexed user, bool isSuper);
    event NFTContractUpdated(address indexed nftContract);

    // ============ ERRORS ============

    error OnlyNFTContract();
    error ZeroAddress();
    error ZeroGovernanceNotifier();

    // ============ CONSTRUCTOR ============

    /**
     * @param _owner Contract owner
     * @param _nftContract NubiansNorthNFT address (the contract whose hook calls we accept)
     */
    constructor(address _owner, address _nftContract) {
        if (_owner == address(0) || _nftContract == address(0)) revert ZeroAddress();
        _transferOwnership(_owner);
        nftContract = _nftContract;
    }

    // ============ INFTTransferHook ============

    /**
     * @notice Called before a transfer — always allows (returns true).
     * @dev SceneTracker never blocks transfers.
     */
    function beforeNFTTransfer(
        uint256,
        /*nftId*/
        address,
        /*from*/
        address /*to*/
    )
        external
        view
        override
        returns (bool)
    {
        if (!_isAuthorizedCaller()) revert OnlyNFTContract();
        return true;
    }

    /**
     * @notice Called after each token transfer (including mints and sends).
     * @dev NubiansNorthNFT loops over every token in an ERC721A batch and calls this
     *      once per tokenId. `from == address(0)` signals a mint; `to == address(0)` a burn.
     *      Scene number is looked up from the NFT contract.
     * @param nftId Token ID that was transferred
     * @param from Previous owner (address(0) for mint)
     * @param to New owner (address(0) for burn)
     */
    function afterNFTTransfer(uint256 nftId, address from, address to) external override {
        if (!_isAuthorizedCaller()) revert OnlyNFTContract();

        uint16 scene = ISceneNFT(nftContract).tokenScene(nftId);
        if (scene == 0) return; // unmapped token — skip

        bool fromWasSuper;
        bool toWasSuper;
        bool fromLostSuper = false;
        bool toGainedSuper = false;

        // Remove scene credit from sender (not on mint)
        if (from != address(0)) {
            fromWasSuper = _isFullCollection(from);
            _removeScene(from, scene);
            bool fromIsSuper = _isFullCollection(from);
            if (fromWasSuper && !fromIsSuper) {
                emit SuperHolderStatusChanged(from, false);
                superHolderCount--;
                fromLostSuper = true;
            }
        }

        // Add scene credit to recipient (not on burn)
        if (to != address(0)) {
            toWasSuper = _isFullCollection(to);
            _addScene(to, scene);
            bool toIsSuper = _isFullCollection(to);
            if (!toWasSuper && toIsSuper) {
                emit SuperHolderStatusChanged(to, true);
                superHolderCount++;
                toGainedSuper = true;
            }
        }

        // External notifications last (CEI)
        if (governanceNotifier != address(0)) {
            if (fromLostSuper) {
                ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(from);
            }
            if (toGainedSuper) {
                ISuperHolderGovernance(governanceNotifier).notifyPotentialVotingPowerChange(to);
            }
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns true if `user` owns at least one token from every scene 1..100
     * @param user Address to check
     * @return True if user has a full collection (Super Holder eligible)
     */
    function hasFullCollection(address user) external view returns (bool) {
        return _isFullCollection(user);
    }

    /**
     * @notice Get user's scene bitmask (bit i = owns >= 1 of scene i+1)
     * @param user Address to query
     * @return 256-bit mask; bits 0..99 used for scenes 1..100
     */
    function getSceneBitmask(address user) external view returns (uint256) {
        return _sceneBitmask[user];
    }

    /**
     * @notice Get user's token count for a specific scene
     * @param user Address to query
     * @param scene Scene number (1-100)
     * @return count Number of tokens owned
     */
    function getUserSceneCount(address user, uint16 scene) external view returns (uint256 count) {
        return userSceneCounts[user][scene];
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Update the authorized NFT contract address
     * @param _nftContract New NFT contract address
     */
    function setNFTContract(address _nftContract) external onlyOwner {
        if (_nftContract == address(0)) revert ZeroAddress();
        nftContract = _nftContract;
        emit NFTContractUpdated(_nftContract);
    }

    /**
     * @notice Set the governance notifier address.
     * @param _gov SuperHolderGovernance contract address.
     */
    function setGovernanceNotifier(address _gov) external onlyOwner {
        if (_gov == address(0)) revert ZeroGovernanceNotifier();
        governanceNotifier = _gov;
    }

    // ============ INTERNAL HELPERS ============

    /**
     * @notice Returns true if msg.sender is authorized to call hook functions.
     * @dev Accepts:
     *   1. The NFT contract itself (direct call path), OR
     *   2. The address that the NFT has configured as its transfer hook (router path).
     *
     * Security: router identity is verified by querying nftContract.transferHook()
     * (the NFT's own state), NOT by trusting the caller's self-assertion.  A malicious
     * contract cannot bypass this check by implementing a matching interface because
     * the authoritative value comes from the NFT, not from msg.sender.
     */
    function _isAuthorizedCaller() internal view returns (bool) {
        if (msg.sender == nftContract) return true;
        // Accept msg.sender only if the NFT itself has configured it as the transfer hook.
        try INFTWithHook(nftContract).transferHook() returns (address configuredHook) {
            return configuredHook != address(0) && configuredHook == msg.sender;
        } catch {
            return false;
        }
    }

    function _isFullCollection(address user) internal view returns (bool) {
        uint256 fullMask = (uint256(1) << TOTAL_SCENES) - 1;
        return (_sceneBitmask[user] & fullMask) == fullMask;
    }

    function _addScene(address user, uint16 scene) internal {
        uint256 prev = userSceneCounts[user][scene];
        userSceneCounts[user][scene] = prev + 1;
        if (prev == 0) {
            _sceneBitmask[user] |= (uint256(1) << (scene - 1));
        }
        emit SceneAdded(user, scene, prev + 1);
    }

    function _removeScene(address user, uint16 scene) internal {
        uint256 count = userSceneCounts[user][scene];
        if (count == 0) return;
        userSceneCounts[user][scene] = count - 1;
        if (count == 1) {
            _sceneBitmask[user] &= ~(uint256(1) << (scene - 1));
        }
        emit SceneRemoved(user, scene, count - 1);
    }
}
