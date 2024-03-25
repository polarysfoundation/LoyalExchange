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
import "./interfaces/ILoyalProtocol.sol";
import "./libs/BytesToString.sol";


contract LoyalProtocol is ILoyalProtocol, ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using Bytes32Utils for bytes32;

    uint256 private constant MAX_FEE_RATE = 10000;

    address public admin;
    address public feeAddress;

    IRoyaltyProtocol public royaltyVault;
    ITransferHelper public transferHelper;

    // mapping para ordenes activas y llenas
    // Key order id
    // result data encoded
    mapping(bytes32 => bytes) private _order;

    mapping(bytes32 => bool) private _ordersFilled;

    // Identificador para soporte de regalias
    mapping(bytes32 => bool) private _royaltySupported;
    
    mapping(bytes32 => bytes) private _auctions;
    mapping(bytes32 => address) private _highestBidder;
    mapping(bytes32 => uint256) private _highestBid; 
    mapping(bytes32 => bool) private _claimable;

    mapping(address => mapping(address => mapping(uint256 => bytes32))) private _id;

    uint256 public ordersFilled;
    uint256 public feeRate;

    event OrderCreated(BasicOrder order);
    event OrderFilled(BasicOrder order);
    event OrderCanceled(BasicOrder order);
    event AuctionCreated(BasicAuction auction);
    event NewBidCreated(BasicAuction auction);
    event AuctionCanceled(BasicAuction auction);
    event AuctionClaimed(BasicAuction auction);
    
    modifier onlyAdmin() {
        require(admin == msg.sender, "only admin can call this method");
        _;
    }

    modifier nonZeroAddress(address newAddr) {
        require(newAddr != address(0), "Non-zero address");
        _;
    }

    /********************** Functions **********************/

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

    function createBasicOrder(BasicOrder calldata order, bytes calldata signature) external override nonReentrant {
        bytes32 id;

        id = _id[msg.sender][order.collectionAddr][order.tokenId];


        if(id != bytes32(0)){
            BasicOrder memory o = _decodeOrder(_order[id], id);
            require(o.expirationTime > block.timestamp || o.seller != msg.sender, "An active order exist");
        }

        id = _generateOrderHash(order);

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnershipAndTokenApproval(order.collectionAddr, order.tokenId, order.asset), "Only owner can create order");
        require(_checkOrderParams(order, id), "Invalid order parameters");

        bytes memory b = _encodeOrder(order, id);

        _order[id] = b;
        _id[msg.sender][order.collectionAddr][order.tokenId] = id;

        emit OrderCreated(order);
    }

    function cancelBasicOrder(BasicOrder calldata order, bytes calldata signature) external override nonReentrant {
        bytes32 id = _id[msg.sender][order.collectionAddr][order.tokenId];

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnershipAndTokenApproval(order.collectionAddr, order.tokenId, order.asset), "Only owner can cancel");
        require(_checkOrderParams(order, id), "Order filled or not does exist");

        delete _order[id];
        delete _id[msg.sender][order.collectionAddr][order.tokenId];

        if(order.royaltySupport){
            delete _royaltySupported[id];
        }

        emit OrderCanceled(order);
    }

    function fillBasicOrder(BasicOrder calldata order, bytes calldata signature) external override payable nonReentrant {
        bytes32 id = _id[order.seller][order.collectionAddr][order.tokenId];

        uint256 price = msg.value;

        if(order.asset == AssetType.erc1155){
            price == price.mul(order.supply);
        }

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkOrderParams(order, id), "order already filled or expired");
        require(order.currency == address(0), "order must be filled with erc20");
        require(_checkPrice(order, price), "invalid amount");

        uint256 feeToSend = price.mul(feeRate).div(MAX_FEE_RATE);

        if(order.seller != address(0)) {
            payable(order.seller).transfer(price.sub(feeToSend));
        }

        if(feeAddress != address(0)){
            payable(feeAddress).transfer(feeToSend);
        }

        delete _order[id];
        delete _id[order.seller][order.collectionAddr][order.tokenId];
        _ordersFilled[id] = true;

        _addOrderFilled();

        if(_royaltySupported[id]){
            price = _distributeRoyalties(order.collectionAddr, price, id, order.currency); 
        }

        _transferAsset(order.collectionAddr, order.tokenId, order.buyer, order.seller, order.supply, order.asset);

        emit OrderFilled(order);
    }

    function fillBasicOrderWithERC20(BasicOrder calldata order, bytes calldata signature) external override nonReentrant {
        bytes32 id = _id[order.seller][order.collectionAddr][order.tokenId];

        uint256 price = order.price;

        if(order.asset == AssetType.erc1155){
            price == price.mul(order.supply);
        }

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkOrderParams(order, id), "order already filled or expired");
        require(order.currency != address(0), "Order must be filled without erc20");
        require(_checkPrice(order, price), "invalid amount");


        delete _order[id];
        delete _id[order.seller][order.collectionAddr][order.tokenId];
        _ordersFilled[id] = true;

        _addOrderFilled();

        if(_royaltySupported[id]){
            price = _distributeRoyalties(order.collectionAddr, price, id, order.currency);
        }

        _transferAsset(order.collectionAddr, order.tokenId, order.buyer, order.seller, order.supply, order.asset);

        uint256 feeToSend = price.mul(feeRate).div(MAX_FEE_RATE);

        if(order.seller != address(0)) {
            _transferToken(order.currency, price.sub(feeToSend), order.buyer, order.seller);
        } 

        if(feeAddress != address(0)){
            _transferToken(order.currency, feeToSend, order.buyer, feeAddress);
        }

        emit OrderFilled(order);
    }

    function createAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant {
        bytes32 id;

        id = _id[msg.sender][auction.collectionAddr][auction.tokenId];

        if(id != bytes32(0)){
            BasicAuction memory a = _decodeAuction(_auctions[id], id);
            require(a.endedAt < block.timestamp && _highestBid[id] == 0 && !_claimable[id] || a.seller != msg.sender, "An active order exist");
        }

        id = _generateAuctionHash(auction);

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnershipAndTokenApproval(auction.collectionAddr, auction.tokenId, AssetType.erc721), "Only owner can create a auction");
        require(_checkAuctionParams(auction, id), "Invalid auction parameters");

        bytes memory b = _encodeAuction(auction, id);

        _auctions[id] = b;
        _id[msg.sender][auction.collectionAddr][auction.tokenId] = id;

        emit AuctionCreated(auction);
    }

    function cancelAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant {
        bytes32 id = _id[msg.sender][auction.collectionAddr][auction.tokenId];

        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_verifyOwnershipAndTokenApproval(auction.collectionAddr, auction.tokenId, AssetType.erc721), "Only owner can cancel this auction");
        require(previousBid == 0 && previousBidder == address(0), "Auction started");
        require(_checkAuctionParams(auction, id), "Auction does not exist or started");
        
        delete _auctions[id];
        delete _id[auction.seller][auction.collectionAddr][auction.tokenId];

        emit AuctionCanceled(auction);

    }

    function sendBidWithETH(BasicAuction calldata auction, bytes calldata signature) external payable override nonReentrant {
        bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];

        uint256 value = msg.value;

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkAuctionParams(auction, id), "Invalid parameters");
        require(auction.currency == address(0), "Currency unsupported");

        BasicAuction memory a = auction;

        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];
    
        if(previousBid != 0 && previousBidder != address(0)){

            require(value > previousBid.mul(2).div(100) && value == auction.highestBid, "Invalid bid amount");
            _safeSendETH(previousBidder, previousBid);

            _highestBid[id] = value;
            _highestBidder[id] = msg.sender;
        } else {
            require(value == auction.initialPrice && value == auction.highestBid, "Invalid bid amount");
            a.endedAt = _calculateAuctionEndTime();
            _highestBid[id] = value;
            _highestBidder[id] = msg.sender; 
        }

        bytes memory b = _encodeAuction(a, id);
        _auctions[id] = b;
        _claimable[id] = true;

        emit NewBidCreated(auction);
    }

    function sendBidWithERC20(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant {
        bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];

        uint256 value = auction.highestBid;

        require(_checkAuctionParams(auction, id), "Invalid parameters");
        require(auction.currency != address(0), "Currency unsupported");
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");

        BasicAuction memory a = auction;

        uint256 previousBid = _highestBid[id];
        address previousBidder = _highestBidder[id];
        if(previousBid != 0 && previousBidder != address(0)){
            require(value > previousBid.mul(2).div(100) && value == auction.highestBid, "Invalid bid amount");

            _highestBid[id] = value;
            _highestBidder[id] = msg.sender;

            IERC20(auction.currency).transfer(previousBidder, previousBid);
            _transferToken(auction.currency, value, msg.sender, address(this));
        } else {
            require(value == auction.initialPrice && value == auction.highestBid, "Invalid bid amount");

            a.endedAt = _calculateAuctionEndTime();
            _highestBid[id] = value;
            _highestBidder[id] = msg.sender; 

            _transferToken(auction.currency, value, msg.sender, address(this));
        }

        bytes memory b = _encodeAuction(a, id);
        _auctions[id] = b;
        _claimable[id] = true;

        emit NewBidCreated(auction);
    }

    function claimAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant {

        bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];

        uint256 currentBid = _highestBid[id];
        address currentBidder = _highestBidder[id];

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkAuctionParams(auction, id), "Auction already filled or expired");
        require(currentBid != 0 && currentBidder != address(0), "Auction has not begun");
        require(_verifyOwnershipAndTokenApproval(auction.collectionAddr, auction.tokenId, AssetType.erc721) && auction.seller == msg.sender || currentBidder == msg.sender , "Invalid claimer");

        delete _auctions[id];
        delete _claimable[id];
        delete _id[auction.seller][auction.collectionAddr][auction.tokenId];
        delete _highestBid[id];
        delete _highestBidder[id];

        _ordersFilled[id] = true;

        _addOrderFilled();

        if(auction.royaltySupport) {
            currentBid = _distributeRoyalties(auction.collectionAddr, currentBid, id, auction.currency);
        }

        _transferAsset(auction.collectionAddr, auction.tokenId, auction.seller, auction.highestBidder, 1, AssetType.erc721);

        uint256 feeToSend = currentBid.mul(feeRate).div(MAX_FEE_RATE);

        if(auction.currency == address(0)){
            _safeSendETH(auction.seller, currentBid.sub(feeToSend));

            if(feeAddress != address(0)){
                _safeSendETH(feeAddress, feeToSend);
            }
        }

        if(auction.currency != address(0) ){
            require(IERC20(auction.currency).balanceOf(address(this)) >= currentBid.sub(feeToSend), "Insufficient contract balance"); // Additional check
            IERC20(auction.currency).transfer(auction.seller, currentBid.sub(feeToSend));

            if(feeAddress != address(0)){
                IERC20(auction.currency).transfer(feeAddress, feeToSend);
            }
        } 

        emit AuctionClaimed(auction);

    }

    function auctionRefund(address collectionAddr, uint256 tokenId, bytes32 id, bytes calldata signature) external override nonReentrant {
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkRefundCondition(collectionAddr, tokenId, id), "Auction cannot be refunded");

        address bidder = _highestBidder[id];
        uint256 amount = _highestBid[id];

        BasicAuction memory a  = _decodeAuction(_auctions[id], id);

        delete _id[a.seller][collectionAddr][tokenId];
        delete _auctions[id];
        delete _claimable[id];
        delete _highestBid[id];
        delete _highestBidder[id];

        if(a.currency != address(0)) {
            _safeSendETH(bidder, amount);
        } else {
            IERC20(a.currency).transfer(bidder, amount);
        }

    }

    /********************** Query Functions **********************/

    function marketplace() external pure returns(string memory) {
        return bytes32("TAG Web3 Marketplace").bytes32ToString();
    }

    function version() external pure returns(string memory) {
        return bytes32("V1.0").bytes32ToString();
    }

    function getHighestBid(bytes32 id) external override view returns (uint256) {
        return _highestBid[id];
    }

    function getHighestBidder(bytes32 id) external override view returns(address) {
        return _highestBidder[id];
    }

    function getAuctionByToken(address seller, address collectionAddr, uint256 tokenId) external override view returns(BasicAuction memory){
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return _decodeAuction(_auctions[id], id);
    }

    function getAuctionById(bytes32 id) external override view returns(BasicAuction memory) {
        return _decodeAuction(_auctions[id], id);
    }

    function getOrderByTokenId(address seller, address collectionAddr, uint256 tokenId) external override view returns(BasicOrder memory) {
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return _decodeOrder(_order[id], id);
    }

    function getOrderById(bytes32 id) external override view returns(BasicOrder memory) {
        return _decodeOrder(_order[id], id);
    } 

    function activeOrder(address seller, address collectionAddr, uint256 tokenId) external view override returns(bytes32) {
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return id;
    }

    function getExpirationTime(address seller, address collectionAddr, uint256 tokenId) external override view returns(uint256) {
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return _decodeOrder(_order[id], id).expirationTime;
    }


    /********************** Internal Functions **********************/

    function _isOrderOwner(bytes32 id) internal view returns(bool) {
        return _decodeOrder(_order[id], id).seller == msg.sender || 
        _decodeAuction(_auctions[id], id).seller == msg.sender; 
    }

    function _checkPrice(BasicOrder calldata order, uint256 price) internal pure returns(bool) {
        if(order.asset == AssetType.erc1155) {
            return (price == order.price.mul(order.supply));
        } 

        if(order.asset == AssetType.erc721) {
            return (price == order.price);
        }

        return false;
    }

    function _checkRefundCondition(address collectionAddr, uint256 tokenId, bytes32 id) internal view returns(bool) {
        BasicAuction memory a = _decodeAuction(_auctions[id], id);
        return
            a.seller != IERC721(collectionAddr).ownerOf(tokenId) && 
            a.endedAt < block.timestamp &&
            _highestBidder[id] == msg.sender &&
            _id[a.seller][collectionAddr][tokenId] == id &&
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
        ordersFilled = ordersFilled.add(1);
    }

    function _generateAuctionHash(BasicAuction calldata auction) internal pure returns(bytes32) {
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

    function _generateOrderHash(BasicOrder calldata order) internal pure returns (bytes32) {
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

    function _checkAuctionParams(BasicAuction calldata auction, bytes32 id) internal view returns(bool) {
        // Verificar que la dirección de la colección, el precio inicial y el vendedor sean válidos
        bool validParams = (auction.collectionAddr != address(0) &&
                            auction.initialPrice != 0 &&
                            auction.seller != address(0)) && 
                            auction.seller == IERC721(auction.collectionAddr).ownerOf(auction.tokenId) || 
                            IERC1155(auction.collectionAddr).balanceOf(auction.seller, auction.tokenId) > 0;

        // Verificar que la subasta no haya sido llenada y que no haya terminado o que el tiempo de finalización sea en el futuro
        bool validAuctionStatus = (!_ordersFilled[id]) &&
                                (auction.endedAt == 0 || auction.endedAt > block.timestamp);

        bool validOperator = (auction.seller == msg.sender || auction.highestBidder == msg.sender);

        // Devolver verdadero solo si todos los parámetros y el estado de la subasta son válidos
        return validParams && validAuctionStatus && validOperator;
    }

    function _checkOrderParams(BasicOrder calldata order, bytes32 id) internal view returns (bool) {
        return
            order.collectionAddr != address(0) &&
            order.price > 0 &&
            order.seller != address(0) &&
            order.expirationTime > 0 &&
            order.expirationTime > block.timestamp &&
            !_ordersFilled[id] && 
            (order.seller == msg.sender ||
            order.buyer == msg.sender) && 
            (IERC1155(order.collectionAddr).balanceOf(order.seller, order.tokenId) > 0 && 
            order.seller == IERC721(order.collectionAddr).ownerOf(order.tokenId));
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
