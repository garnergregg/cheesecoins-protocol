// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IMarketplaceHook
 * @notice Interface for marketplace integration
 */
interface IMarketplaceHook {
    struct MarketplaceData {
        uint256 nftId;
        uint256 stakedAmount;
        uint256 maturityTime;
        uint256 accruedYield;
        address seller;
        uint256 listPrice;
    }

    event NFTTransferredWithStaking(
        uint256 indexed nftId, address indexed seller, address indexed buyer, uint256 stakedAmount, uint256 price
    );

    function getSecondaryMarketData(uint256 nftId) external returns (MarketplaceData memory);

    function recordSecondaryMarketSale(uint256 nftId, address seller, address buyer, uint256 price) external;
}
