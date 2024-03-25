// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

enum AssetType {
    erc721,
    erc1155
}

struct BasicOrder {
    address collectionAddr;
    uint256 tokenId;
    address seller;
    address buyer;
    uint256 price;
    uint256 supply;
    uint256 expirationTime;
    bool royaltySupport;
    address currency;
    AssetType asset;
}

struct Offer {
    address collectionAddr;
    uint256 tokenId;
    uint256 price;
    address maker;
    address taker;
    address currency;
    bool royaltySupport;
    uint256 createdAt;
    uint256 supply;
    AssetType asset;
}

struct BasicAuction {
    address collectionAddr;
    uint256 tokenId;
    uint256 initialPrice;
    uint256 highestBid;
    address seller;
    address highestBidder;
    address currency;
    uint256 startedAt;
    uint256 endedAt;
    bool royaltySupport;
}
