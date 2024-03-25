// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {Royalty} from "../libs/Structs.sol";

interface IRoyaltyProtocol {
    function getRoyaltyInfo(address collectionAddr) external view returns(Royalty memory);
    function updateRoyaltyInfo(address collectionAddr, uint256 newFeePercentage, address newFeeRecipient) external;
    function addRoyaltyInfo(address collectionAddr, uint256 feePercentage, address feeRecipient) external;
}