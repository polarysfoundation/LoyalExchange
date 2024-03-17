// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

struct BasicOrder {
    address collectionAddr;
    uint256 tokenId;
    address seller;
    address buyer;
    uint256 price;
    uint256 supply;
    bytes32 orderId;
    uint256 expirationTime;
    uint256 royaltyRate;
    address royaltyRecipient;
    bool royaltySupport;
    address currency;
}
