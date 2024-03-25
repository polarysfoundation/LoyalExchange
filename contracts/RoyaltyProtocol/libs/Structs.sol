// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

struct Royalty {
    uint256 feeRate;
    address feeRecipient;
    address collectionAddr;
    address admin;
}