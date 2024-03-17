// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {BasicOrder} from "./libs/Structs.sol";

contract LoyalExchange {
    uint256 public fee;

    address public feeAddress;
    address public royaltyVault;
    address public transferHelper;
    address public admin;

    mapping(bytes32 => uint256) private _expirationTime;
    mapping(address => mapping(uint256 => bytes32)) private _order;
    mapping(bytes32 => bool) private _orderActive;

    /********************** Functions **********************/

    function createBasicOrder() public {
        
    }
}
