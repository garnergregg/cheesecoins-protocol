// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {INFTTransferHook} from "../interfaces/INFTTransferHook.sol";

/// @notice Safe default hook for deployments.
///         Always allows transfers and performs no post-transfer action.
/// @dev Used as the "sceneTracker" hook in ProjectFactory until per-project SceneTracker
///      instances are installed via router.setHooks by governance/timelock.
contract NoOpTransferHook is INFTTransferHook {
    function beforeNFTTransfer(uint256, address, address) external pure override returns (bool) {
        return true;
    }

    function afterNFTTransfer(uint256, address, address) external pure override {}
}
