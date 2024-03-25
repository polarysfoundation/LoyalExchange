// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


import "./RoyaltyProtocol/interfaces/IRProtocol.sol";
import {Royalty} from "./RoyaltyProtocol/libs/Structs.sol";
import "./libs/SignatureVerifier.sol";
import "./interfaces/ITransferHelper.sol";
import "./interfaces/ILoyalProtocol.sol";

contract LoyalProtocol is ILoyalProtocol, ReentrancyGuard {
    using SafeMath for uint256;

    bytes32 private constant NAME = "TAG Web3 Marketplace";
    bytes32 private constant PROTOCOL_VERSION = "V0.1";

    uint256 private constant MAX_FEE_RATE = 10000;

    uint256 public feeRate;

    address public feeAddress;
    IRoyaltyProtocol public royaltyVault;
    ITransferHelper public transferHelper;
    address public admin;

    // mapping para ordenes activas y llenas
    // Key order id
    // result data encoded
    mapping(bytes32 => bytes) private _order;

    mapping(bytes32 => bool) private _ordersFilled;

    // Identificador para soporte de regalias
    mapping(bytes32 => bool) private _royaltySupported;

    // Mapping para ofertas
    mapping(address => mapping(uint256 => mapping(bytes32 => bytes))) private _offers;
    mapping(address => bytes32) private _offersId;
    
    mapping(bytes32 => bytes) private _auctions;
    mapping(bytes32 => address) private _highestBidder;
    mapping(bytes32 => uint256) private _highestBid; 
    mapping(bytes32 => bool) private _claimable;

    mapping(address => mapping(address => mapping(uint256 => bytes32))) private _id;

    uint256 public ordersFilled;

    event OrderCreated(BasicOrder order);
    event OrderFilled(BasicOrder order);
    event OrderCanceled(BasicOrder order);
    event OfferCreated(Offer offer);
    event OfferAccepted(Offer offer);
    event OfferCanceled(Offer offer);
    event AuctionCreated(BasicAuction auction);
    event NewBidCreated(BasicAuction auction);
    event AuctionCanceled(BasicAuction auction);
    event AuctionClaimed(BasicAuction auction);

    modifier onlyAdmin() {
        require(admin == msg.sender, "only admin can call this method");
        _;
    }

    /********************** Functions **********************/

    function updateRoyaltyProtocol(address newRoyaltyAddress) external override onlyAdmin {
        royaltyVault = IRoyaltyProtocol(newRoyaltyAddress);
    }

    function updateTransferHelper(address newTransferHelper) external override onlyAdmin {
        transferHelper = ITransferHelper(newTransferHelper);
    }

    function updateFeeAddress(address newFeeAddress) external override onlyAdmin {
        feeAddress = newFeeAddress;
    }

    function updateFeeRate(uint256 newFeeRate) external override onlyAdmin {
        feeRate = newFeeRate;
    }

    function updateAdmin(address newAdminAddress) external override onlyAdmin {
        require(newAdminAddress != address(0), "Non-zero admin address");
        admin = newAdminAddress;
    }

    function createBasicOrder(BasicOrder calldata order, bytes calldata signature) external override nonReentrant {
        bytes32 id;
        address seller = msg.sender;

        id = _id[seller][order.collectionAddr][order.tokenId];


        if(id != bytes32(0)){
            BasicOrder memory o = _decodeOrder(_order[id], id);
            require(o.expirationTime > block.timestamp || o.seller != seller, "An active order exist");
        }

        id = _generateOrderHash(order);

        require(SignatureVerifier.verifySignature(id, signature, seller), "Invalid signature");
        require(_verifyOwnerShip(order.collectionAddr, order.tokenId, order.asset), "Only owner can create order");
        require(_verifyTokenApproval(order.collectionAddr, order.tokenId, order.asset), "Must approve transferhelper");
        require(_checkOrderParams(order, id), "Invalid order parameters");

        bytes memory b = _encodeOrder(order, id);

        _order[id] = b;
        _id[order.collectionAddr][order.tokenId] = id;

        emit OrderCreated(order);
    }

    function cancelBasicOrder(address collectionAddr, uint256 tokenId, bytes memory signature) external override nonReentrant {
        address orderOwner = msg.sender;
        bytes32 id = _id[orderOwner][collectionAddr][tokenId];
        BasicOrder memory order = _decodeOrder(_order[id], id);

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnerShip(order.collectionAddr, order.tokenId, order.asset), "Only owner can cancel");
        require(_checkOrderParams(order, id), "Order filled or not does exist");


        delete _order[id];
        delete _id[collectionAddr][tokenId];

        if(order.royaltySupport){
            delete _royaltySupported[id];
        }

        emit OrderCanceled(order);
    }

    function fillBasicOrder(address collectionAddr, uint256 tokenId, AssetType asset, uint256 supply, bytes memory signature) external override nonReentrant payable {
        address buyer = msg.sender;
        bytes32 id = _id[collectionAddr][tokenId];

        BasicOrder memory order = _decodeOrder(_order[id], id);
        order.buyer = buyer;
        uint256 price = msg.value;

        if(asset == AssetType.erc1155){
            price == price.mul(supply);
        }

        require(SignatureVerifier.verifySignature(id, signature, buyer), "Invalid signature");
        require(_checkOrderParams(order, id), "order already filled or expired");
        require(order.currency == address(0), "order must be filled with erc20");
        require(order.seller == IERC721(collectionAddr).ownerOf(tokenId), "seller must be owner");

        if(asset == AssetType.erc1155) {
            require(price == order.price.mul(supply), bytes32ToString(bytes32("value must be equal to order price multiplied by supply")));
        } else {
            require(price == order.price, "value must be equal to order price");
        }


        if(_royaltySupported[id]){
            price = _distributeRoyalties(order.collectionAddr, price, id, order.currency); 
        }

        _transferAsset(order.collectionAddr, order.tokenId, order.buyer, order.seller, order.supply, order.asset);


        uint256 feeToSend = price.mul(feeRate).div(MAX_FEE_RATE);
        payable(order.seller).transfer(price.sub(feeToSend));

        if(feeAddress != address(0)){
            payable(feeAddress).transfer(feeToSend);
        }

        delete _order[id];
        delete _id[order.collectionAddr][order.tokenId];
        _ordersFilled[id] = true;

        emit OrderFilled(order);

        _addOrderFilled();

    }

    function fillBasicOrderWithERC20(address collectionAddr, uint256 tokenId, AssetType asset, uint256 supply, bytes memory signature) external override nonReentrant {
        address buyer = msg.sender;
        bytes32 id = _id[collectionAddr][tokenId];

        BasicOrder memory order = _decodeOrder(_order[id], id);
        order.buyer = buyer;

        uint256 price = order.price;

        if(asset == AssetType.erc1155){
            price == price.mul(supply);
        }

        require(SignatureVerifier.verifySignature(id, signature, buyer), "Invalid signature");
        require(_checkOrderParams(order, id), "order already filled or expired");
        require(order.currency != address(0), "Order must be filled without erc20");

        if(asset == AssetType.erc1155) {
            require(price == order.price.mul(supply), "value must be same than order price");
        } else {
            require(price == order.price, "value must be same than order price");
        }

        if(_royaltySupported[id]){
            price = _distributeRoyalties(order.collectionAddr, price, id, order.currency);
        }

        _transferAsset(order.collectionAddr, order.tokenId, order.buyer, order.seller, order.supply, order.asset);


        uint256 feeToSend = price.mul(feeRate).div(MAX_FEE_RATE);

        _transferToken(order.currency, price.sub(feeToSend), order.buyer, order.seller);

        if(feeAddress != address(0)){
            _transferToken(order.currency, feeToSend, order.buyer, feeAddress);
        }

        delete _order[id];
        _ordersFilled[id] = true;

        emit OrderFilled(order);

        _addOrderFilled();

    }

    function makeOffer(Offer calldata offer, bytes memory signature) external payable override nonReentrant {
        address maker = msg.sender;
        uint256 value = msg.value;

        bytes32 id = _generateOfferId(offer);

        require(SignatureVerifier.verifySignature(id, signature, maker), "Invalid signature");
        require(_checkOfferParams(offer, id), "Invalid parameters");
        require(value > 0 && offer.price > 0 && value == offer.price, "Non-zero value");

        bytes memory  b = _encodeOffer(offer, id);

        _offers[offer.collectionAddr][offer.tokenId][id] = b;
        _offersId[maker] = id;

        emit OfferCreated(offer);

    }

    function cancelOffer(address collectionAddr, uint256 tokenId) external override nonReentrant {
        address maker = msg.sender;
        bytes32 id = _offersId[maker];
        Offer memory offer = _decodeOffer(_offers[collectionAddr][tokenId][id], id);

        require(_checkOfferParams(offer, id), "Offer filled or does not exist");

        _safeSendETH(maker, offer.price);

        delete _offers[collectionAddr][tokenId][id];
        delete _offersId[maker];


        emit OfferCanceled(offer);
    }

    function makeOfferWithERC20(Offer calldata offer, bytes memory signature) external override nonReentrant {
        address maker = msg.sender;

        bytes32 id = _generateOfferId(offer);

        require(SignatureVerifier.verifySignature(id, signature, maker), "Invalid signature");
        require(_checkOfferParams(offer, id), "Invalid offer parameters");
        require(offer.currency != address(0), "Non-zero address");
        require(offer.price > 0, "Non-zero value");

        bytes memory  b = _encodeOffer(offer, id);

        _offers[offer.collectionAddr][offer.tokenId][id] = b;
        _offersId[maker] = id;

        emit OfferCreated(offer);
    }

    function acceptOffer(address collectionAddr, uint256 tokenId, address maker, bool royaltySupport, bytes memory signature) external override nonReentrant {
        bytes32 id = _offersId[maker];
        bytes memory b = _offers[collectionAddr][tokenId][id];
        Offer memory offer = _decodeOffer(b, id);

        address taker = msg.sender;
        uint256 value = offer.price;

        offer.taker = taker;

        require(SignatureVerifier.verifySignature(id, signature, taker), "Invalid signature");
        require(_verifyOwnerShip(offer.collectionAddr, offer.tokenId, offer.asset), "Only owner can take this offer");
        require(_checkOfferParams(offer, id), "Offer accepted or does not exist");
        require(_verifyTokenApproval(offer.collectionAddr, offer.tokenId, offer.asset), "Must approve transferhelper");



        if(royaltySupport){
            value = _distributeRoyalties(offer.collectionAddr, value, id, offer.currency);
        }

        _transferAsset(offer.collectionAddr, offer.tokenId, offer.taker, offer.maker, offer.supply, offer.asset);

        offer.royaltySupport = royaltySupport;

        uint256 feeToSend = value.mul(feeRate).div(MAX_FEE_RATE);

        if(offer.currency != address(0) ){
            IERC20(offer.currency).transfer(taker, value.sub(feeToSend));

            if(feeAddress != address(0)){
                IERC20(offer.currency).transfer(feeAddress, feeToSend);
            }
        } 

        if(offer.currency == address(0)){
            _safeSendETH(taker, value.sub(feeToSend));

            if(feeAddress != address(0)){
                _safeSendETH(feeAddress, feeToSend);
            }
        }

        delete _offers[offer.collectionAddr][offer.tokenId][id];
        delete _offersId[offer.maker];
        _ordersFilled[id];

        emit OfferAccepted(offer);

        _addOrderFilled();

    }

    function createAuction(BasicAuction calldata auction, bytes memory signature) external override nonReentrant {
        address seller = msg.sender;
        bytes32 id;

        id = _id[auction.collectionAddr][auction.tokenId];

        if(id != bytes32(0)){
            BasicAuction memory a = _decodeAuction(_auctions[id], id);
            require(a.endedAt < block.timestamp && _highestBid[id] == 0 && !_claimable[id] || a.seller != seller, "An active order exist");
        }

        id = _generateAuctionHash(auction);

        require(SignatureVerifier.verifySignature(id, signature, seller), "Invalid signature");
        require(_verifyOwnerShip(auction.collectionAddr, auction.tokenId, AssetType.erc721), "Only owner can create a auction");
        require(_verifyTokenApproval(auction.collectionAddr, auction.tokenId, AssetType.erc721), "Must approve transferhelper");
        require(_checkAuctionParams(auction, id), "Invalid auction parameters");

        bytes memory b = _encodeAuction(auction, id);

        _auctions[id] = b;
        _id[auction.collectionAddr][auction.tokenId] = id;

        emit AuctionCreated(auction);
    }

    function cancelAuction(address collectionAddr, uint256 tokenId, bytes memory signature) external override nonReentrant {
        bytes32 id = _id[collectionAddr][tokenId];
        address seller = msg.sender;

        BasicAuction memory auction = _decodeAuction(_auctions[id], id);
        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];

        require(SignatureVerifier.verifySignature(id, signature, seller), "Invalid signature");
        require(_isOrderOwner(id), "Only owner can cancel");
        require(_verifyOwnerShip(auction.collectionAddr, auction.tokenId, AssetType.erc721), "Only owner can cancel this auction");
        require(previousBid == 0 && previousBidder == address(0), "Auction started");
        require(_checkAuctionParams(auction, id), "Auction does not exist or started");
        
        delete _auctions[id];
        delete _id[collectionAddr][tokenId];

        emit AuctionCanceled(auction);

    }

    function sendBidWithETH(address collectionAddr, uint256 tokenId, uint256 bid, bytes memory signature) external payable override nonReentrant {
        bytes32 id = _id[collectionAddr][tokenId];

        uint256 value = msg.value;
        address bidder = msg.sender;

        BasicAuction memory auction = _decodeAuction(_auctions[id], id);

        require(SignatureVerifier.verifySignature(id, signature, bidder), "Invalid signature");
        require(_checkAuctionParams(auction, id), "Invalid parameters");
        require(auction.currency == address(0), "Currency unsupported");
        require(value == bid, "Value and bid must be equal");

        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];
        if(previousBid != 0 && previousBidder != address(0)){

            require(value > previousBid.mul(2).div(100), "Invalid bid amount");
            _safeSendETH(previousBidder, previousBid);

            _highestBid[id] = value;
            _highestBidder[id] = bidder;
        } else {
            require(value == auction.initialPrice, "Invalid bid amount");
            auction.endedAt = _calculateAuctionEndTime();
            _highestBid[id] = value;
            _highestBidder[id] = bidder; 
        }

        bytes memory b = _encodeAuction(auction, id);
        _auctions[id] = b;
        _claimable[id] = true;

        emit NewBidCreated(auction);
    }

    function sendBidWithERC20(address collectionAddr, uint256 tokenId, uint256 bid, bytes memory signature) external override nonReentrant {
        bytes32 id = _id[collectionAddr][tokenId];

        uint256 value = bid;
        address bidder = msg.sender;

        BasicAuction memory auction = _decodeAuction(_auctions[id], id);

        require(_checkAuctionParams(auction, id), "Invalid parameters");
        require(auction.currency != address(0), "Currency unsupported");
        require(SignatureVerifier.verifySignature(id, signature, bidder), "Invalid signature");

        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];
        if(previousBid != 0 && previousBidder != address(0)){


            require(value > previousBid.mul(2).div(100), "Invalid bid amount");
            IERC20(auction.currency).transfer(previousBidder, previousBid);

            _highestBid[id] = value;
            _highestBidder[id] = bidder;
        } else {
            require(value == auction.initialPrice, "Invalid bid amount");
            auction.endedAt = _calculateAuctionEndTime();
            _highestBid[id] = value;
            _highestBidder[id] = bidder; 
        }

        bytes memory b = _encodeAuction(auction, id);
        _auctions[id] = b;
        _claimable[id] = true;

        emit NewBidCreated(auction);
    }

    function claimAuction(address collectionAddr, uint256 tokenId, bytes memory signature) external override nonReentrant {
        bytes32 id = _id[collectionAddr][tokenId];

        address operator = msg.sender;

        BasicAuction memory auction = _decodeAuction(_auctions[id], id);

        uint256 currentBid = _highestBid[id];
        address currentBidder = _highestBidder[id];

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkAuctionParams(auction, id), "Auction already filled");
        require(currentBid != 0 && currentBidder != address(0), "Auction has not begun");
        require(_verifyOwnerShip(auction.collectionAddr, auction.tokenId, AssetType.erc721) || currentBidder == operator, "Invalid claimer");

        if(auction.royaltySupport) {
            currentBid = _distributeRoyalties(auction.collectionAddr, currentBid, id, auction.currency);
        }

        _transferAsset(auction.collectionAddr, auction.tokenId, auction.seller, auction.highestBidder, 1, AssetType.erc721);

        uint256 feeToSend = currentBid.mul(feeRate).div(MAX_FEE_RATE);

        if(auction.currency != address(0) ){
            IERC20(auction.currency).transfer(auction.seller, currentBid.sub(feeToSend));

            if(feeAddress != address(0)){
                IERC20(auction.currency).transfer(feeAddress, feeToSend);
            }
        } 

        if(auction.currency == address(0)){
            _safeSendETH(auction.seller, currentBid.sub(feeToSend));

            if(feeAddress != address(0)){
                _safeSendETH(feeAddress, feeToSend);
            }
        }

        delete _auctions[id];
        delete _claimable[id];
        delete _id[auction.collectionAddr][auction.tokenId];
        delete _highestBid[id];
        delete _highestBidder[id];

        _ordersFilled[id] = true;

        emit AuctionClaimed(auction);

        _addOrderFilled();


    }

    function auctionRefund(address collectionAddr, uint256 tokenId, bytes32 id, bytes memory signature) external override nonReentrant {
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkRefundCondition(collectionAddr, tokenId, id), "Auction cannot be refunded");

        address bidder = _highestBidder[id];
        uint256 amount = _highestBid[id];

        delete _id[collectionAddr][tokenId];
        delete _auctions[id];
        delete _claimable[id];
        delete _highestBid[id];
        delete _highestBidder[id];

        _safeSendETH(bidder, amount);

    }

    /********************** Query Functions **********************/

    function marketplace() external override pure returns(string memory) {
        return bytes32ToString(NAME);
    }

    function version() external override pure returns(string memory) {
        return bytes32ToString(PROTOCOL_VERSION);
    }

    function getHighestBid(bytes32 id) external override view returns (uint256) {
        return _highestBid[id];
    }

    function getHighestBidder(bytes32 id) external override view returns(address) {
        return _highestBidder[id];
    }

    function getAuctionByToken(address collectionAddr, uint256 tokenId) external override view returns(BasicAuction memory){
        bytes32 id = _id[collectionAddr][tokenId];
        return _decodeAuction(_auctions[id], id);
    }

    function getAuctionById(bytes32 id) external override view returns(BasicAuction memory) {
        return _decodeAuction(_auctions[id], id);
    }

    function getOffer(address collectionAddr, uint256 tokenId, address maker) external override view returns(Offer memory) {
        bytes32 id = _offersId[maker];
        return _decodeOffer(_offers[collectionAddr][tokenId][id], id);
    }

    function getOrderByTokenId(address collectionAddr, uint256 tokenId) external override view returns(BasicOrder memory) {
        bytes32 id = _id[collectionAddr][tokenId];
        return _decodeOrder(_order[id], id);
    }

    function getOrderById(bytes32 id) external override view returns(BasicOrder memory) {
        return _decodeOrder(_order[id], id);
    } 

    function activeOrder(address collectionAddr, uint256 tokenId) external view override returns(bytes32) {
        bytes32 id = _id[collectionAddr][tokenId];
        return id;
    }

    function getExpirationTime(address collectionAddr, uint256 tokenId) external override view returns(uint256) {
        bytes32 id = _id[collectionAddr][tokenId];
        return _decodeOrder(_order[id], id).expirationTime;
    }


    /********************** Internal Functions **********************/

    function _isOrderOwner(bytes32 id) internal view returns(bool) {
        return _decodeOrder(_order[id], id).seller == msg.sender || 
        _decodeAuction(_auctions[id], id).seller == msg.sender; 
    }

    function _checkRefundCondition(address collectionAddr, uint256 tokenId, bytes32 id) internal view returns(bool) {
        BasicAuction memory a = _decodeAuction(_auctions[id], id);
        return
            a.seller != IERC721(collectionAddr).ownerOf(tokenId) && 
            a.endedAt < block.timestamp &&
            _highestBidder[id] == msg.sender &&
            _id[collectionAddr][tokenId] == id &&
            !_ordersFilled[id] && 
            a.highestBidder == msg.sender
        ;
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

    function _calculateAuctionEndTime() private view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 endTime = currentTime + 86400; // 86400 seconds in 24 hours
        return endTime;
    }

    function _addOrderFilled() internal {
        ordersFilled++;
    }

    function _generateAuctionHash(BasicAuction memory auction) internal pure returns(bytes32) {
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

    function _generateOfferId(Offer memory offer) internal pure returns(bytes32){
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

    function _generateOrderHash(BasicOrder memory order) internal pure returns (bytes32) {
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

    function _decodeAuction(bytes memory encodedAuction, bytes32 id) internal view returns (BasicAuction memory) {
        address collectionAddr;
        uint256 tokenId;
        uint256 initialPrice;
        uint256 highestBid;
        address seller;
        address highestBidder;
        address currency;
        uint256 startedAt;
        uint256 endedAt;

        assembly {
            // Carga los valores almacenados en la memoria del contrato
            collectionAddr := mload(add(encodedAuction, 32))
            tokenId := mload(add(encodedAuction, 64))
            initialPrice := mload(add(encodedAuction, 96))
            highestBid := mload(add(encodedAuction, 128))
            seller := mload(add(encodedAuction, 160))
            highestBidder := mload(add(encodedAuction, 192))
            currency := mload(add(encodedAuction, 224))
            startedAt := mload(add(encodedAuction, 256))
            endedAt := mload(add(encodedAuction, 288))
        }

        bool royaltySupport = _royaltySupported[id];

        BasicAuction memory auction = BasicAuction(
            collectionAddr,
            tokenId,
            initialPrice,
            highestBid,
            seller,
            highestBidder,
            currency,
            startedAt,
            endedAt,
            royaltySupport
        );

        return auction;
    }

    function _encodeAuction(BasicAuction memory auction, bytes32 id) internal returns (bytes memory) {
        bytes memory b = new bytes(288);

        address collectionAddr = auction.collectionAddr;
        uint256 tokenId = auction.tokenId;
        uint256 initialPrice = auction.initialPrice;
        uint256 highestBid = auction.highestBid;
        address seller = auction.seller;
        address highestBidder = auction.highestBidder;
        address currency = auction.currency;
        uint256 startedAt = auction.startedAt;
        uint256 endedAt = auction.endedAt;

        _royaltySupported[id] = auction.royaltySupport;

        assembly {
            mstore(add(b, 32), collectionAddr)
            mstore(add(b, 64), tokenId)
            mstore(add(b, 96), initialPrice)
            mstore(add(b, 128), highestBid)
            mstore(add(b, 160), seller)
            mstore(add(b, 192), highestBidder)
            mstore(add(b, 224), currency)
            mstore(add(b, 256), startedAt)
            mstore(add(b, 288), endedAt)
        }

        return b;
    }

    function _decodeOrder(bytes memory encodedOrder, bytes32 id) internal view returns (BasicOrder memory) {
        address collectionAddr;
        uint256 tokenId;
        address seller;
        address buyer;
        uint256 price;
        uint256 supply;
        uint256 expirationTime;
        address currency;
        AssetType asset;

        assembly {
            // Carga los valores almacenados en la memoria del contrato
            collectionAddr := mload(add(encodedOrder, 32))
            tokenId := mload(add(encodedOrder, 64))
            seller := mload(add(encodedOrder, 96))
            buyer := mload(add(encodedOrder, 128))
            price := mload(add(encodedOrder, 160))
            supply := mload(add(encodedOrder, 192))
            expirationTime := mload(add(encodedOrder, 224))
            currency := mload(add(encodedOrder, 256))
            asset := mload(add(encodedOrder, 288))
        }

        bool royaltySupport = _royaltySupported[id];

        BasicOrder memory order = BasicOrder(
            collectionAddr,
            tokenId,
            seller,
            buyer,
            price,
            supply,
            expirationTime,
            royaltySupport,
            currency,
            asset
        );

        return order;
    }

    function _encodeOrder(BasicOrder memory order, bytes32 id) internal returns (bytes memory) {
        bytes memory b = new bytes(256);

        address collectionAddr = order.collectionAddr;
        uint256 tokenId = order.tokenId;
        address seller = order.seller;
        address buyer = order.buyer;
        uint256 price = order.price;
        uint256 supply = order.supply;
        uint256 expirationTime = order.expirationTime;
        address currency = order.currency;

        _ordersFilled[id] = order.royaltySupport;

        assembly {
            mstore(add(b, 32), collectionAddr)
            mstore(add(b, 64), tokenId)
            mstore(add(b, 96), seller)
            mstore(add(b, 128), buyer)
            mstore(add(b, 160), price)
            mstore(add(b, 192), supply)
            mstore(add(b, 224), expirationTime)
            mstore(add(b, 256), currency)
        }

        return b;
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

    function _verifyOwnerShip(address collection, uint256 tokenId, AssetType asset) internal view returns (bool) {
        if (asset == AssetType.erc721) {
            return IERC721(collection).ownerOf(tokenId) == msg.sender;
        } 
        else if (asset == AssetType.erc1155) {
            return IERC1155(collection).balanceOf(msg.sender, tokenId) > 0;
        }
        // Si el tipo de activo no es ni ERC721 ni ERC1155, devuelve false
        return false;
    }

    function _checkAuctionParams(BasicAuction memory auction, bytes32 id) internal view returns(bool) {
        // Verificar que la dirección de la colección, el precio inicial y el vendedor sean válidos
        bool validParams = (auction.collectionAddr != address(0) &&
                            auction.initialPrice != 0 &&
                            auction.seller != address(0));

        // Verificar que la subasta no haya sido llenada y que no haya terminado o que el tiempo de finalización sea en el futuro
        bool validAuctionStatus = (!_ordersFilled[id]) &&
                                (auction.endedAt == 0 || auction.endedAt > block.timestamp);

        // Devolver verdadero solo si todos los parámetros y el estado de la subasta son válidos
        return validParams && validAuctionStatus;
    }

    function _checkOrderParams(BasicOrder memory order, bytes32 id) internal view returns (bool) {
        return
            order.collectionAddr != address(0) &&
            order.price > 0 &&
            order.seller != address(0) &&
            order.expirationTime > 0 &&
            order.expirationTime > block.timestamp && 
            !_ordersFilled[id];
    }

    function _checkOfferParams(Offer memory offer, bytes32 id) internal view returns(bool) {
        return 
            offer.collectionAddr != address(0) && 
            offer.price != 0 &&
            offer.maker != address(0) && 
            !_ordersFilled[id];
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }

    function _verifyTokenApproval(address collectionAddr, uint256 tokenId, AssetType asset) private view returns (bool) {
        if (asset == AssetType.erc721) {
            IERC721 collection = IERC721(collectionAddr);
            return (collection.getApproved(tokenId) == address(transferHelper) ||
                collection.isApprovedForAll(msg.sender, address(transferHelper)));
        } 
        else if (asset == AssetType.erc1155) {
            IERC1155 collection = IERC1155(collectionAddr);
            return (collection.isApprovedForAll(msg.sender, address(transferHelper)));
        }
        // Manejar el caso en que el tipo de activo no sea ni ERC721 ni ERC1155
        return false;
    }


    function _safeSendETH(address recipient, uint256 amount) private {
        require(
            address(this).balance >= amount,
            "Insufficient contract balance"
        );

        (bool success, ) = payable(recipient).call{value: amount}("");
        require(success, "Failed to send ETH");
    }
}
