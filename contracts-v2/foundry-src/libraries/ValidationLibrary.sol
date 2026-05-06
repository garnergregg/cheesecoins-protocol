// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title ValidationLibrary
 * @notice Input validation and verification functions
 * @dev Provides KYC checks, audit verification, and data validation
 */
library ValidationLibrary {
    /**
     * @notice Validate address is not zero
     */
    function requireNonZeroAddress(address addr, string memory message) internal pure {
        require(addr != address(0), message);
    }

    /**
     * @notice Validate amount is non-zero
     */
    function requireNonZeroAmount(uint256 amount, string memory message) internal pure {
        require(amount > 0, message);
    }

    /**
     * @notice Validate array lengths match
     */
    function requireEqualLength(uint256 length1, uint256 length2, string memory message) internal pure {
        require(length1 == length2, message);
    }

    /**
     * @notice Validate value is within range
     */
    function requireInRange(uint256 value, uint256 min, uint256 max, string memory message) internal pure {
        require(value >= min && value <= max, message);
    }

    /**
     * @notice Validate percentage is valid (0-100%)
     */
    function requireValidPercentage(uint256 percentage) internal pure {
        require(percentage <= 10000, "ValidationLib: percentage > 100%");
    }

    /**
     * @notice Validate timestamp is not in the future
     */
    function requirePastTimestamp(uint256 timestamp) internal view {
        require(timestamp <= block.timestamp, "ValidationLib: future timestamp");
    }

    /**
     * @notice Validate timestamp is in the future
     */
    function requireFutureTimestamp(uint256 timestamp) internal view {
        require(timestamp > block.timestamp, "ValidationLib: past timestamp");
    }

    /**
     * @notice Validate NFT ownership
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param owner Expected owner
     * @return True if owner owns the NFT
     */
    function validateNFTOwnership(address nftContract, uint256 tokenId, address owner) internal view returns (bool) {
        try IERC721(nftContract).ownerOf(tokenId) returns (address actualOwner) {
            return actualOwner == owner;
        } catch {
            return false;
        }
    }

    /**
     * @notice Validate oracle data freshness
     * @param lastUpdate Last update timestamp
     * @param stalenessThreshold Maximum acceptable age
     * @return True if data is fresh
     */
    function isOracleFresh(uint256 lastUpdate, uint256 stalenessThreshold) internal view returns (bool) {
        return block.timestamp - lastUpdate <= stalenessThreshold;
    }

    /**
     * @notice Validate Merkle proof
     * @param proof Merkle proof array
     * @param root Merkle root
     * @param leaf Leaf to verify
     * @return True if proof is valid
     */
    function verifyMerkleProof(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];

            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }

        return computedHash == root;
    }

    /**
     * @notice Validate project registration requirements
     * @dev Checks onboarding checklist items
     */
    function validateProjectRegistration(
        address nftAddress,
        address oracleAddress,
        uint256 initialDoes,
        uint256 minInitialDoes
    ) internal pure {
        requireNonZeroAddress(nftAddress, "ValidationLib: invalid NFT address");
        requireNonZeroAddress(oracleAddress, "ValidationLib: invalid oracle address");
        require(initialDoes >= minInitialDoes, "ValidationLib: insufficient initial herd");
    }

    /**
     * @notice Validate staking parameters
     */
    function validateStakingParams(uint256 amount, uint256 lockMonths, uint256 minStake, uint256 maxLockMonths)
        internal
        pure
    {
        require(amount >= minStake, "ValidationLib: amount below minimum");
        require(lockMonths > 0 && lockMonths <= maxLockMonths, "ValidationLib: invalid lock period");
    }

    /**
     * @notice Validate governance vote parameters
     */
    function validateVoteParams(uint256 votingPeriod, uint256 minVotingPeriod, uint256 maxVotingPeriod) internal pure {
        require(
            votingPeriod >= minVotingPeriod && votingPeriod <= maxVotingPeriod, "ValidationLib: invalid voting period"
        );
    }

    /**
     * @notice Calculate hash of project data for verification
     */
    function hashProjectData(uint256 projectId, uint256 actualValue, uint256 actualDoes, uint256 timestamp)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(projectId, actualValue, actualDoes, timestamp));
    }
}

/**
 * @notice Minimal ERC721 interface for validation
 */
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}
