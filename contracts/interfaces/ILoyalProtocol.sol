// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {BasicOrder, Offer, BasicAuction, AssetType} from "../libs/Structs.sol";

interface ILoyalProtocol {
    function updateFeeAddress(address newRecipient) external;
    function updateFeeRate(uint256 newFeeRate) external;
    function updateAdmin(address newAdmin) external;
    function createBasicOrder(BasicOrder calldata order, bytes calldata signature) external;
    function cancelBasicOrder(address collectionAddr, uint256 tokenId, bytes memory signature) external;
    function fillBasicOrder(address collectionAddr, uint256 tokenId, AssetType asset, uint256 supply, bytes memory signature) external payable;
    function fillBasicOrderWithERC20(address collectionAddr, uint256 tokenId, AssetType asset, uint256 supply, bytes memory signature) external;
    function makeOffer(Offer calldata offer, bytes memory signature) external payable;
    function cancelOffer(address collectionAddr, uint256 tokenId) external;
    function makeOfferWithERC20(Offer calldata offer, bytes memory signature) external;
    function acceptOffer(address collectionAddr, uint256 tokenId, address maker, bool royaltySupport, bytes memory signature) external;
    function createAuction(BasicAuction calldata auction, bytes memory signature) external;
    function cancelAuction(address collectionAddr, uint256 tokenId, bytes memory signature) external;
    function sendBidWithETH(address collectionAddr, uint256 tokenId, uint256 bid, bytes memory signature) external payable;
    function sendBidWithERC20(address collectionAddr, uint256 tokenId, uint256 bid, bytes memory signature) external;
    function claimAuction(address collectionAddr, uint256 tokenId, bytes memory signature) external;
    function auctionRefund(address collectionAddr, uint256 tokenId, bytes32 id, bytes memory signature) external;
    function getHighestBid(bytes32 id) external view returns (uint256);
    function getHighestBidder(bytes32 id) external view returns(address);
    function getAuctionByToken(address collectionAddr, uint256 tokenId) external view returns(BasicAuction memory);
    function getAuctionById(bytes32 id) external view returns(BasicAuction memory);
    function getOffer(address collectionAddr, uint256 tokenId, address maker) external view returns(Offer memory);
    function getOrderByTokenId(address collectionAddr, uint256 tokenId) external view returns(BasicOrder memory);
    function getOrderById(bytes32 id) external view returns(BasicOrder memory);
    function activeOrder(address collectionAddr, uint256 tokenId) external view returns(bytes32);
    function getExpirationTime(address collectionAddr, uint256 tokenId) external view returns(uint256);
    function updateTransferHelper(address newTransferHelper) external;
    function updateRoyaltyProtocol(address newRoyaltyAddress) external;
    function version() external view returns(string memory);
    function marketplace() external view returns(string memory);
}