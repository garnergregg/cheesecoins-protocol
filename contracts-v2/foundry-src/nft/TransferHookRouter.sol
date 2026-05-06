// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {INFTTransferHook} from "./interfaces/INFTTransferHook.sol";

/**
 * @title TransferHookRouter
 * @notice Multiplexes NFT transfer hooks to an ordered list of receivers.
 * @dev Implements INFTTransferHook so any project NFT (ProjectNFTTemplate,
 *      NubiansNorthNFT, etc.) can point its transferHook at this router and
 *      have multiple downstream hooks (e.g. SceneTracker + StakingManager)
 *      notified atomically in a single call.
 *
 * ORDERING:
 * - beforeNFTTransfer: hooks called in order; first false return short-circuits.
 * - afterNFTTransfer:  hooks called in order; reverts propagate.
 *
 * PHASE 6C STEP 2:
 * - Exposes nftContract so downstream hooks can identify the originating NFT
 *   collection without it being passed in the hook call signature.
 */
contract TransferHookRouter is INFTTransferHook, Ownable {
    // ============ STATE ============

    /// @notice The NFT collection this router is associated with.
    /// @dev Downstream hooks (e.g. StakingManager) read this to identify the
    ///      originating NFT collection when msg.sender is the router.
    address public immutable nftContract;

    /// @notice Ordered list of downstream hook contracts
    address[] private _hooks;

    // ============ EVENTS ============

    event HooksSet(address[] hooks);

    // ============ ERRORS ============

    error ZeroAddress();
    error CallerNotNFTContract(address caller, address expected);

    // ============ CONSTRUCTOR ============

    /**
     * @param owner_ Initial owner (admin) of the router
     * @param nftContract_ NFT collection address this router handles
     */
    constructor(address owner_, address nftContract_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (nftContract_ == address(0)) revert ZeroAddress();
        _transferOwnership(owner_);
        nftContract = nftContract_;
    }

    // ============ ADMIN ============

    /**
     * @notice Replace the entire ordered hook list.
     * @dev Only owner can call.  Zero-address entries are rejected.
     * @param hooks New ordered array of INFTTransferHook addresses
     */
    function setHooks(address[] calldata hooks) external onlyOwner {
        delete _hooks;
        for (uint256 i = 0; i < hooks.length; i++) {
            if (hooks[i] == address(0)) revert ZeroAddress();
            _hooks.push(hooks[i]);
        }
        emit HooksSet(hooks);
    }

    // ============ VIEW ============

    /**
     * @notice Return the current ordered hook list.
     * @return hooks Ordered array of INFTTransferHook addresses
     */
    function getHooks() external view returns (address[] memory hooks) {
        return _hooks;
    }

    // ============ INFTTransferHook ============

    /**
     * @notice Forward beforeNFTTransfer to every hook in order.
     * @dev Only callable by the registered nftContract. Any other caller could spoof
     *      transfer events and manipulate governance voting weight attribution in StakingManager
     *      (which trusts msg.sender == this router). Restricting to nftContract closes that vector.
     * @param nftId Token ID being transferred
     * @param from Previous owner
     * @param to New owner
     * @return True if all hooks allow the transfer
     */
    function beforeNFTTransfer(uint256 nftId, address from, address to) external override returns (bool) {
        if (msg.sender != nftContract) revert CallerNotNFTContract(msg.sender, nftContract);
        address[] memory hooks = _hooks;
        for (uint256 i = 0; i < hooks.length; i++) {
            // slither-disable-next-line calls-loop
            if (!INFTTransferHook(hooks[i]).beforeNFTTransfer(nftId, from, to)) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Forward afterNFTTransfer to every hook in order.
     * @dev Only callable by the registered nftContract — same spoofing risk as beforeNFTTransfer.
     * @param nftId Token ID that was transferred
     * @param from Previous owner (address(0) on mint)
     * @param to New owner
     */
    function afterNFTTransfer(uint256 nftId, address from, address to) external override {
        if (msg.sender != nftContract) revert CallerNotNFTContract(msg.sender, nftContract);
        address[] memory hooks = _hooks;
        for (uint256 i = 0; i < hooks.length; i++) {
            // slither-disable-next-line calls-loop
            INFTTransferHook(hooks[i]).afterNFTTransfer(nftId, from, to);
        }
    }
}
