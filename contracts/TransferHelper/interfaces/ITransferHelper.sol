// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ITransferHelper {
    function updateAdmin(address adminAddr) external;
    function addOperator(address operator) external;
    function removeOperator(address operator) external;
    function erc20TransferFrom(address erc20Addr, address from, address to, uint256 amount) external;
    function erc20Transfer(address erc20Addr, address to, uint256 amount) external;
    function erc721TransferFrom(address erc721Addr, address from, address to, uint256 tokenId) external;
    function erc1155TransferFrom(address erc1155Addr, address from, address to, uint256 id, uint256 amount) external;
    function isOperator(address operator) external view returns (bool);
}
