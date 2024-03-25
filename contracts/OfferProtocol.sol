// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RoyaltyProtocol/interfaces/IRProtocol.sol";
import {Royalty} from "./RoyaltyProtocol/libs/Structs.sol";
import "./libs/SignatureVerifier.sol";
import "./interfaces/ITransferHelper.sol";
import "./interfaces/IOfferProtocol.sol";
import "./libs/BytesToString.sol";


contract OfferProtocol is IOfferProtocol, ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using Bytes32Utils for bytes32;

    uint256 private constant MAX_FEE_RATE = 10000;

    address public admin;
    address public feeAddress;

    uint256 public feeRate;
    uint256 public ordersFilled;

    
    ITransferHelper public transferHelper;
    IRoyaltyProtocol public royaltyVault;

    mapping(bytes32 => bool) private _royaltySupported;
    mapping(bytes32 => bool) private _ordersFilled;
    
    // Mapping para ofertas
    mapping(address => mapping(uint256 => mapping(bytes32 => bytes))) private _offers;
    mapping(address => bytes32) private _offersId;

    event OfferCreated(Offer offer);
    event OfferAccepted(Offer offer);
    event OfferCanceled(Offer offer);

    modifier onlyAdmin() {
        require(admin == msg.sender, "only admin can call this method");
        _;
    }

    modifier nonZeroAddress(address newAddr) {
        require(newAddr != address(0), "Non-zero address");
        _;
    }

    /********************* Functions *********************/

    function updateRoyaltyProtocol(address newRoyaltyAddress) external onlyAdmin {
        royaltyVault = IRoyaltyProtocol(newRoyaltyAddress);
    }

    function updateTransferHelper(address newTransferHelper) external onlyAdmin {
        transferHelper = ITransferHelper(newTransferHelper);
    }

    function updateFeeAddress(address newFeeAddress) external onlyAdmin {
        feeAddress = newFeeAddress;
    }

    function updateFeeRate(uint256 newFeeRate) external onlyAdmin {
        feeRate = newFeeRate;
    }

    function updateAdmin(address newAdminAddress) external onlyOwner nonZeroAddress(newAdminAddress) {
        admin = newAdminAddress;
    }

    function makeOffer(Offer calldata offer, bytes calldata signature) external payable override nonReentrant {
        uint256 value = msg.value;

        bytes32 id = _generateOfferId(offer);

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkOfferParams(offer, id), "Invalid parameters");
        require(value > 0 && offer.price > 0 && value == offer.price, "Non-zero value");

        bytes memory  b = _encodeOffer(offer, id);

        _offers[offer.collectionAddr][offer.tokenId][id] = b;
        _offersId[msg.sender] = id;

        emit OfferCreated(offer);

    }

    function makeOfferWithERC20(Offer calldata offer, bytes calldata signature) external override nonReentrant {

        bytes32 id = _generateOfferId(offer);

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkOfferParams(offer, id), "Invalid offer parameters");
        require(offer.currency != address(0), "Non-zero address");
        require(offer.price > 0, "Non-zero value");

        bytes memory  b = _encodeOffer(offer, id);

        _offers[offer.collectionAddr][offer.tokenId][id] = b;
        _offersId[msg.sender] = id;

        transferHelper.erc20TransferFrom(offer.currency, msg.sender, address(this), offer.price);

        emit OfferCreated(offer);
    }

    function acceptOffer(Offer calldata offer, bytes calldata signature) external override nonReentrant {
        bytes32 id = _offersId[offer.maker];
        uint256 value = offer.price;

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnershipAndTokenApproval(offer.collectionAddr, offer.tokenId, offer.asset), "Only owner can take this offer");
        require(_checkOfferParams(offer, id), "Offer accepted or does not exist");

        if(offer.royaltySupport){
            value = _distributeRoyalties(offer.collectionAddr, value, id, offer.currency);
        }

        uint256 feeToSend = value.mul(feeRate).div(MAX_FEE_RATE);

        if(offer.currency == address(0)){
            _safeSendETH(msg.sender, value.sub(feeToSend));

            if(feeAddress != address(0)){
                _safeSendETH(feeAddress, feeToSend);
            }
        }

        delete _offers[offer.collectionAddr][offer.tokenId][id];
        delete _offersId[offer.maker];
        _ordersFilled[id];

        _addOrderFilled();

        _transferAsset(offer.collectionAddr, offer.tokenId, offer.taker, offer.maker, offer.supply, offer.asset);

        if(offer.currency != address(0) ){
            IERC20(offer.currency).transfer(msg.sender, value.sub(feeToSend));

            if(feeAddress != address(0)){
                IERC20(offer.currency).transfer(feeAddress, feeToSend);
            }
        } 

        emit OfferAccepted(offer);
    }

    function cancelOffer(Offer calldata offer, bytes calldata signature) external override nonReentrant {
        bytes32 id = _offersId[msg.sender];

        require(_checkOfferParams(offer, id), "Offer filled or does not exist");
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");

        delete _offers[offer.collectionAddr][offer.tokenId][id];
        delete _offersId[msg.sender];

        if(offer.currency != address(0)){
            _safeSendETH(msg.sender, offer.price);
        } else {
            IERC20(offer.currency).transfer(msg.sender, offer.price);
        }

        emit OfferCanceled(offer);
    }

    /********************* Query Functions *********************/

    function marketplace() external pure returns(string memory) {
        return bytes32("TAG Web3 Marketplace").bytes32ToString();
    }

    function version() external pure returns(string memory) {
        return bytes32("V1.0").bytes32ToString();
    }

    function getOffer(address collectionAddr, uint256 tokenId, address maker) external override view returns(Offer memory) {
        bytes32 id = _offersId[maker];
        return _decodeOffer(_offers[collectionAddr][tokenId][id], id);
    }

    /********************* Internal Functions *********************/

    function _generateOfferId(Offer calldata offer) internal pure returns(bytes32){
        return (
            keccak256(
                abi.encodePacked(
                    offer.collectionAddr,
                    offer.tokenId,
                    offer.price,
                    offer.maker,
                    offer.createdAt
                )
            )
        );
    }

    function _checkOfferParams(Offer calldata offer, bytes32 id) internal view returns(bool) {
        return 
            offer.collectionAddr != address(0) && 
            offer.price != 0 &&
            offer.maker != address(0) && 
            !_ordersFilled[id] && 
            offer.taker == msg.sender ||
            offer.maker == msg.sender;
    }

    function _verifyOwnershipAndTokenApproval(address collection, uint256 tokenId, AssetType asset) internal view returns (bool) {
        if (asset == AssetType.erc721) {
            return IERC721(collection).ownerOf(tokenId) == msg.sender && 
            (IERC721(collection).getApproved(tokenId) == address(transferHelper) ||
            IERC721(collection).isApprovedForAll(msg.sender, address(transferHelper)));
        } 
        else if (asset == AssetType.erc1155) {
            return IERC1155(collection).balanceOf(msg.sender, tokenId) > 0 && 
            IERC1155(collection).isApprovedForAll(msg.sender, address(transferHelper));
        }
        // Si el tipo de activo no es ni ERC721 ni ERC1155, devuelve false
        return false;
    }

    function _decodeOffer(bytes memory encodedOffer, bytes32 id) internal view returns (Offer memory) {
        address collectionAddr;
        uint256 tokenId;
        uint256 price;
        address maker;
        address taker;
        address currency;
        uint256 createdAt;
        uint256 supply;
        AssetType asset;


        assembly {
            // Carga los valores almacenados en la memoria del contrato
            collectionAddr := mload(add(encodedOffer, 32))
            tokenId := mload(add(encodedOffer, 64))
            price := mload(add(encodedOffer, 96))
            maker := mload(add(encodedOffer, 128))
            taker := mload(add(encodedOffer, 160))
            currency := mload(add(encodedOffer, 192))
            createdAt := mload(add(encodedOffer, 224))
            supply := mload(add(encodedOffer, 256))
            asset := mload(add(encodedOffer, 288))
        }

        bool royaltySupport = _royaltySupported[id];

        Offer memory offer = Offer(
            collectionAddr,
            tokenId,
            price,
            maker,
            taker,
            currency,
            royaltySupport,
            createdAt,
            supply,
            asset
        );

        return offer;
    }

    function _encodeOffer(Offer memory offer, bytes32 id) internal returns (bytes memory) {
        bytes memory b = new bytes(224);

        address collectionAddr = offer.collectionAddr;
        uint256 tokenId = offer.tokenId;
        uint256 price = offer.price;
        address maker = offer.maker;
        address taker = offer.taker;
        address currency = offer.currency;
        uint256 createdAt = offer.createdAt;

        _royaltySupported[id] = true;

        assembly {
            mstore(add(b, 32), collectionAddr)
            mstore(add(b, 64), tokenId)
            mstore(add(b, 96), price)
            mstore(add(b, 128), maker)
            mstore(add(b, 160), taker)
            mstore(add(b, 192), currency)
            mstore(add(b, 224), createdAt)
        }

        return b;
    }

    function _safeSendETH(address recipient, uint256 amount) private {
        require(
            address(this).balance >= amount,
            "Insufficient contract balance"
        );

        (bool success, ) = payable(recipient).call{value: amount}("");
        require(success, "Failed to send ETH");
    }

    function _distributeRoyalties(address collectionAddr, uint256 value, bytes32 id, address currency) internal returns(uint256) {
        Royalty memory r = royaltyVault.getRoyaltyInfo(collectionAddr);
        uint256 royaltyFee = value.mul(r.feeRate).div(MAX_FEE_RATE);

        uint256 rest = value.sub(royaltyFee);
        delete _royaltySupported[id];
        if(r.feeRecipient != address(0)) {
            if(currency != address(0)){
                _safeSendETH(r.feeRecipient, royaltyFee);
            } else {
                _transferToken(currency, royaltyFee, msg.sender, r.feeRecipient);
            }
        }
        return rest;
    }

    function _transferToken(address erc20Addr, uint256 amount, address from, address to) internal {
        transferHelper.erc20TransferFrom(erc20Addr, from, to, amount);
    }

    function _transferAsset(address collectionAddr, uint256 tokenId, address from, address to, uint256 supply, AssetType asset) internal {
        if(asset == AssetType.erc721) {
            transferHelper.erc721TransferFrom(collectionAddr, from, to, tokenId);
        } else {
            transferHelper.erc1155TransferFrom(collectionAddr, from, to, tokenId, supply);
        }
    }

    function _addOrderFilled() internal {
        ordersFilled = ordersFilled.add(1);
    }


        
}