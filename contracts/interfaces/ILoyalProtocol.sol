// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {BasicOrder, BasicAuction, AssetType} from "../libs/Structs.sol";

interface ILoyalProtocol {
    function createBasicOrder(BasicOrder calldata order, bytes calldata signature) external;
    function cancelBasicOrder(BasicOrder calldata order, bytes calldata signature) external;
    function fillBasicOrder(BasicOrder calldata order, bytes calldata signature) external payable;
    function fillBasicOrderWithERC20(BasicOrder calldata order, bytes calldata signature) external;
    function createAuction(BasicAuction calldata auction, bytes calldata signature) external;
    function cancelAuction(BasicAuction calldata auction, bytes calldata signature) external;
    function sendBidWithETH(BasicAuction calldata auction, bytes calldata signature) external payable;
    function sendBidWithERC20(BasicAuction calldata auction, bytes calldata signature) external;
    function claimAuction(BasicAuction calldata auction, bytes calldata signature) external;
    function auctionRefund(address collectionAddr, uint256 tokenId, bytes32 id, bytes calldata signature) external;
    function getHighestBid(bytes32 id) external view returns (uint256);
    function getHighestBidder(bytes32 id) external view returns(address);
    function getAuctionByToken(address seller, address collectionAddr, uint256 tokenId) external view returns(BasicAuction memory);
    function getAuctionById(bytes32 id) external view returns(BasicAuction memory);
    function getOrderByTokenId(address seller, address collectionAddr, uint256 tokenId) external view returns(BasicOrder memory);
    function getOrderById(bytes32 id) external view returns(BasicOrder memory);
    function activeOrder(address seller, address collectionAddr, uint256 tokenId) external view returns(bytes32);
    function getExpirationTime(address seller, address collectionAddr, uint256 tokenId) external view returns(uint256);
}