// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "./interfaces/ITransferHelper.sol";

/**
 * @title TransferHelper
 * @dev This contract provides helper functions for securely transferring ERC20, ERC721, and ERC1155 tokens.
 */
contract TransferHelper is ITransferHelper {
    
    address public admin;

    mapping(address => bool) private _operators;

    /**
     * @dev Modifier to allow only the admin to call a function.
     */
    modifier onlyAdmin() {
        require(admin == msg.sender, "only admin can call this method");
        _;
    }

    /**
     * @dev Modifier to allow only an operator to call a function.
     */
    modifier onlyOperator() {
        require(_operators[msg.sender], "only operator can call this method");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /********************** Functions **********************/

    /**
     * @dev Updates the contract's admin address.
     * @param adminAddr The new admin address.
     */
    function updateAdmin(address adminAddr) external override onlyAdmin {
        admin = adminAddr;
    }

    /**
     * @dev Adds an authorized operator to call functions of this contract.
     * @param operator The address of the operator to add.
     */
    function addOperator(address operator) external override onlyAdmin {
        _operators[operator] = true;
    }

    /**
     * @dev Removes an authorized operator.
     * @param operator The address of the operator to remove.
     */
    function removeOperator(address operator) external override onlyAdmin {
        delete _operators[operator];
    }

    /**
     * @dev Transfers ERC20 tokens from one account to another.
     * @param erc20Addr The address of the ERC20 contract.
     * @param from The address from which tokens are transferred.
     * @param to The address to which tokens are transferred.
     * @param amount The amount of tokens to transfer.
     */
    function erc20TransferFrom(address erc20Addr, address from, address to, uint256 amount) external override onlyOperator {
        require(erc20Addr != address(0) && from != address(0) && to != address(0) && amount != 0, "invalid parameters");
        IERC20(erc20Addr).transferFrom(from, to, amount);
    }

    /**
     * @dev Transfers ERC20 tokens to an account.
     * @param erc20Addr The address of the ERC20 contract.
     * @param to The address to which tokens are transferred.
     * @param amount The amount of tokens to transfer.
     */
    function erc20Transfer(address erc20Addr, address to, uint256 amount) external override onlyOperator {
        require(erc20Addr != address(0) && to != address(0) && amount != 0, "invalid parameters");
        IERC20(erc20Addr).transfer(to, amount);
    }

    /**
     * @dev Transfers an ERC721 token from one account to another.
     * @param erc721Addr The address of the ERC721 contract.
     * @param from The address from which the token is transferred.
     * @param to The address to which the token is transferred.
     * @param tokenId The ID of the ERC721 token to transfer.
     */
    function erc721TransferFrom(address erc721Addr, address from, address to, uint256 tokenId) external override onlyOperator {
        require(erc721Addr != address(0) && from != address(0) && to != address(0), "invalid parameters");
        IERC721(erc721Addr).transferFrom(from, to, tokenId);
    }

    /**
     * @dev Transfers ERC1155 tokens from one account to another.
     * @param erc1155Addr The address of the ERC1155 contract.
     * @param from The address from which tokens are transferred.
     * @param to The address to which tokens are transferred.
     * @param id The ID of the ERC1155 token to transfer.
     * @param amount The amount of ERC1155 tokens to transfer.
     */
    function erc1155TransferFrom(address erc1155Addr, address from, address to, uint256 id, uint256 amount) external override onlyOperator {
        require(erc1155Addr != address(0) && from != address(0) && to != address(0) && amount != 0, "invalid parameters");
        IERC1155(erc1155Addr).safeTransferFrom(from, to, id, amount, "");
    }

    /********************** Query Functions **********************/

    /**
     * @dev Checks if an address is an authorized operator.
     * @param operator The address of the operator to check.
     * @return Returns true if the address is an operator, false otherwise.
     */
    function isOperator(address operator) external view override returns (bool) {
        return _operators[operator];
    }
}
