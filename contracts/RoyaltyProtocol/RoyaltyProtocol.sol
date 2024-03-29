// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IRProtocol.sol";

contract RoyaltyProtocol is IRoyaltyProtocol, Ownable {
    using SafeMath for uint256;

    mapping(address => Royalty) private _royalty;

    event RoyaltyInfoAdded(address collection, address admin );
    event RoyaltyInfoUpdated(address collection, uint256 feeRate);

    /********************** Functions **********************/

    function getRoyaltyInfo(address collectionAddr) public override view returns (Royalty memory) {
        return _royalty[collectionAddr];
    }

    function updateRoyaltyInfo(address collectionAddr, uint256 newFeePercentage, address newFeeRecipient) external override {
        address admin = msg.sender;
        require(admin == _royalty[collectionAddr].admin,"only admin collection can call this method");

        _royalty[collectionAddr].feeRate = newFeePercentage;
        _royalty[collectionAddr].feeRecipient = newFeeRecipient;

        emit RoyaltyInfoUpdated(collectionAddr, newFeePercentage);
    }

    function addRoyaltyInfo(address collectionAddr, uint256 feePercentage, address feeRecipient) external override {
        address admin = msg.sender;
        require(Ownable(collectionAddr).owner() == admin || owner() == admin, "Only owner can add royalty info");

        Royalty memory royalty = Royalty(
            feePercentage,
            feeRecipient,
            collectionAddr,
            admin
        );

        _royalty[collectionAddr] = royalty;

        emit RoyaltyInfoAdded(collectionAddr, admin);

    }

    function removeRoyaltyInfo(address collectionAddr) external {
        require(Ownable(collectionAddr).owner() == msg.sender || owner() == msg.sender, "Only owner can delete royalty info");
        delete _royalty[collectionAddr];
    }
}
