// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./Structs.sol";

contract Encoder {

    function _generateAuctionHash(BasicAuction calldata auction) public pure returns(bytes32) {
        return (
            keccak256(
                abi.encodePacked(
                    auction.collectionAddr,
                    auction.tokenId,
                    auction.initialPrice,
                    auction.seller,
                    auction.startedAt
                )
            )
        );
    }

    function _generateOrderHash(BasicOrder calldata order) public pure returns (bytes32) {
        return (
            keccak256(
                abi.encodePacked(
                    order.collectionAddr,
                    order.tokenId,
                    order.expirationTime,
                    order.price,
                    order.seller
                )
            )
        );
    }

}