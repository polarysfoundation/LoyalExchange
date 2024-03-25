// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import {Offer, AssetType} from "../libs/Structs.sol";

interface IOfferProtocol {
        function makeOffer(Offer calldata offer, bytes calldata signature) external payable;
        function makeOfferWithERC20(Offer calldata offer, bytes calldata signature) external;
        function acceptOffer(Offer calldata offer, bytes calldata signature) external;
        function cancelOffer(Offer calldata offer, bytes calldata signature) external;
        function getOffer(address collectionAddr, uint256 tokenId, address maker) external view returns(Offer memory);
}