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

/**
 * @title LoyalProtocol
 * @author Uranus Dev
 * @notice The following contract handles buying and selling protocols, as well as auctions for ERC721 and ERC1155 tokens
 * @dev This contract handles loyalty tokens and rewards for the Loyal protocol
 */
contract LoyalProtocol is ILoyalProtocol, ReentrancyGuard, Ownable {

    using SafeMath for uint256;
    using Bytes32Utils for bytes32;

    uint256 private constant MAX_FEE_RATE = 10000;

    address public admin;
    address public feeAddress;
    bool public paused;

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
    mapping(bytes32 => uint256) private _expirationTime;

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

    modifier isPaused() {
        require(!paused, "Protocol is paused");
        _;
    }

    /********************** Functions **********************/

    /**
     * @dev Pauses the contract.
     */
    function pause() external onlyOwner {
        paused = true;
    }


    /**
     * @dev Unpauses the contract.
     */
    function unpause() external onlyOwner {
        paused = false;
    }

    /**
     * @dev Updates the royalty protocol contract address
     * @param newRoyaltyAddress The address of the new royalty protocol contract
     */
    function updateRoyaltyProtocol(address newRoyaltyAddress) external onlyAdmin isPaused {
        royaltyVault = IRoyaltyProtocol(newRoyaltyAddress);
    }


    /**
     * @dev Updates the transfer helper contract address
     * @param newTransferHelper The address of the new transfer helper contract
     */
    function updateTransferHelper(address newTransferHelper) external onlyAdmin isPaused {
        transferHelper = ITransferHelper(newTransferHelper);
    }


    /**
     * @dev Updates the fee address 
     * @param newFeeAddress The address of the new fee recipient
     */
    function updateFeeAddress(address newFeeAddress) external onlyAdmin isPaused {
        feeAddress = newFeeAddress;
    }


    /**
     * @dev Updates the fee rate
     * @param newFeeRate The new fee rate to set
     */
    function updateFeeRate(uint256 newFeeRate) external onlyAdmin isPaused {
        feeRate = newFeeRate;
    }


    /**
     * @dev Updates the admin address
     * @param newAdminAddress The address of the new admin
     */
    function updateAdmin(address newAdminAddress) external onlyOwner nonZeroAddress(newAdminAddress) {
        admin = newAdminAddress;
    }


    /**
    * @dev Creates a new basic order 
    * @param order The BasicOrder struct containing order details
    * @param signature The signature of the order hash, signed by seller
    */
    function createBasicOrder(BasicOrder calldata order, bytes calldata signature) external override nonReentrant isPaused {
        bytes32 id;

        id = _id[msg.sender][order.collectionAddr][order.tokenId];


        if(id != bytes32(0)){
            BasicOrder memory o = _decodeOrder(_order[id], id);
            require(o.expirationTime < block.timestamp || o.seller != msg.sender, "An active order exist");
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


    /**
     * @dev Cancels a basic order
     * @param order The BasicOrder struct to cancel
     * @param signature The signature to verify the caller
     */
    function cancelBasicOrder(BasicOrder calldata order, bytes calldata signature) external override nonReentrant isPaused {
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


    /**
    * @dev Fills a basic order
    * @param order - The BasicOrder struct to fill
    * @param signature - Signature to verify caller can fill order
    */
    function fillBasicOrder(BasicOrder calldata order, bytes calldata signature) external override payable nonReentrant isPaused {
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

        delete _order[id];
        delete _id[order.seller][order.collectionAddr][order.tokenId];
        _ordersFilled[id] = true;

        _addOrderFilled();

        if(_royaltySupported[id]){
            Royalty memory r = royaltyVault.getRoyaltyInfo(order.collectionAddr);
            uint256 royaltyFee = price.mul(r.feeRate).div(MAX_FEE_RATE);

            delete _royaltySupported[id];
            if(r.feeRecipient != address(0)) {
                if(order.currency == address(0)){
                    payable(r.feeRecipient).transfer(royaltyFee);
                } else {
                    _transferToken(order.currency, royaltyFee, msg.sender, r.feeRecipient);
                }
            }
            price = price.sub(royaltyFee);
        }

        if(order.seller != address(0)) {
            payable(order.seller).transfer(price.sub(feeToSend));
        }

        if(feeAddress != address(0)){
            payable(feeAddress).transfer(feeToSend);
        }

        _transferAsset(order.collectionAddr, order.tokenId, order.seller, order.buyer, order.supply, order.asset);

        emit OrderFilled(order);
    }


    /**
    * @title Fill Basic Order With ERC20
    * @dev Allows to fill a basic order paying with an ERC20 token
    * @param order Order object with details of the order 
    * @param signature Signature to validate the order
    */
    function fillBasicOrderWithERC20(BasicOrder calldata order, bytes calldata signature) external override nonReentrant isPaused {
        
        // Get order id
        bytes32 id = _id[order.seller][order.collectionAddr][order.tokenId];

        // Get order price
        uint256 price = order.price;

        // Adjust price if order is for multiple tokens
        if(order.asset == AssetType.erc1155){
            price == price.mul(order.supply); 
        }

        // Validate signature
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        
        // Check order is valid
        require(_checkOrderParams(order, id), "order already filled or expired");
        
        // Require order currency is not ETH
        require(order.currency != address(0), "Order must be filled without erc20");
        
        // Check price is valid
        require(_checkPrice(order, price), "invalid amount");

        // Delete order data
        delete _order[id];
        delete _id[order.seller][order.collectionAddr][order.tokenId];
        _ordersFilled[id] = true;

        // Increment orders filled
        _addOrderFilled();

        // Handle royalty if enabled
        if(_royaltySupported[id]){
            Royalty memory r = royaltyVault.getRoyaltyInfo(order.collectionAddr);
            uint256 royaltyFee = price.mul(r.feeRate).div(MAX_FEE_RATE);

            delete _royaltySupported[id];
            if(r.feeRecipient != address(0)) {
                if(order.currency == address(0)){
                    payable(r.feeRecipient).transfer(royaltyFee);
                } else {
                    _transferToken(order.currency, royaltyFee, msg.sender, r.feeRecipient);
                }
            }
            // Adjust price after royalty
            price = price.sub(royaltyFee);
        }

        // Transfer asset
        _transferAsset(order.collectionAddr, order.tokenId, order.seller, order.buyer, order.supply, order.asset);

        // Calculate fee
        uint256 feeToSend = price.mul(feeRate).div(MAX_FEE_RATE);

        // Send payment to seller
        if(order.seller != address(0)) {
            _transferToken(order.currency, price.sub(feeToSend), order.buyer, order.seller);
        }
        
        // Send fee to fee address
        if(feeAddress != address(0)){
            _transferToken(order.currency, feeToSend, order.buyer, feeAddress);
        }

        // Emit event
        emit OrderFilled(order);
    }


    /**
     * @dev Creates a new auction
     * @param auction Auction parameters
     * @param signature Signature to verify auction creator
     */
    function createAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant isPaused {
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


    /**
     * @dev Cancels an auction
     * @param auction Auction parameters
     * @param signature Signature to verify auction creator
     */
    function cancelAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant isPaused {
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


    /**
    * @dev Allows a bidder to send a bid with ETH 
    * @param auction Auction parameters 
    * @param signature Signature to verify auction validity
    */
    function sendBidWithETH(BasicAuction calldata auction, bytes calldata signature) external payable override nonReentrant isPaused {
        bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];

        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        require(_checkAuctionParams(auction, id), "Invalid parameters");
        require(auction.currency == address(0), "Currency unsupported");
        require(_isActive(auction), "Auction Expired");


        BasicAuction memory a = auction;

        if(_highestBid[id] != 0 && _highestBidder[id] != address(0)){
            uint256 previousBid = _highestBid[id];
            address previousBidder = _highestBidder[id];
            uint256 requiredBid = (previousBid * 10200) / 10000; // Calculamos el 102% de la puja anterior

            require(msg.value > requiredBid && msg.value == auction.highestBid, "Invalid bid amount"); // Solo requerimos que sea mayor

            _safeSendETH(previousBidder, previousBid);

            _highestBid[id] = msg.value;
            _highestBidder[id] = msg.sender;
        } else {
            require(msg.value == auction.initialPrice && msg.value == auction.highestBid, "Invalid bid amount");
            _expirationTime[id] = _calculateAuctionEndTime();
            _highestBid[id] = msg.value;
            _highestBidder[id] = msg.sender; 
        }

        a.endedAt = _expirationTime[id];
        bytes memory b = _encodeAuction(a, id);
        _auctions[id] = b;
        _claimable[id] = true;

        emit NewBidCreated(auction);
    }


    /**
    * @dev Allows a bidder to send a bid with ERC20 token
    * @param auction Auction parameters
    * @param signature Signature to verify auction validity  
    */
    function sendBidWithERC20(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant isPaused {

        // Verify auction validity with signature
        bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];
        require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
        
        // Check auction parameters
        require(_checkAuctionParams(auction, id), "Invalid parameters");
        
        // Currency must be ERC20, not ETH
        require(auction.currency != address(0), "Currency unsupported"); 
        
        // Auction must be active
        require(_isActive(auction), "Auction Expired");

        // Store auction in memory
        BasicAuction memory a = auction;

        // If there is a previous bid
        if(_highestBid[id] != 0 && _highestBidder[id] != address(0)){

            // Calculate 102% of previous bid 
            uint256 previousBid = _highestBid[id];
            address previousBidder = _highestBidder[id];
            uint256 requiredBid = (previousBid * 10200) / 10000;

            // New bid must be higher
            require(auction.highestBid > requiredBid, "Invalid bid amount");
            
            // Update highest bid and bidder
            _highestBid[id] = auction.highestBid;
            _highestBidder[id] = msg.sender;

            // Return previous bid to previous bidder
            IERC20(auction.currency).transfer(previousBidder, previousBid);
            
            // Transfer bid amount from bidder to contract
            _transferToken(auction.currency, auction.highestBid, msg.sender, address(this));

        } else {

            // Initial bid must match auction initial price
            require(auction.highestBid == auction.initialPrice, "Invalid bid amount");

            // Set auction end time
            _expirationTime[id] = _calculateAuctionEndTime();
            
            // Set initial highest bid and bidder
            _highestBid[id] = auction.highestBid;
            _highestBidder[id] = msg.sender;

            // Transfer initial bid amount from bidder to contract
            _transferToken(auction.currency, auction.highestBid, msg.sender, address(this));
        }

        // Update auction end time
        a.endedAt = _expirationTime[id];
        
        // Encode updated auction
        bytes memory b = _encodeAuction(a, id);
        _auctions[id] = b;
        
        // Mark auction as having a claimable bid
        _claimable[id] = true;

        // Emit event for new bid
        emit NewBidCreated(auction);
    }


    /**
    * @title Claim Auction
    * @dev Allows seller or highest bidder to claim auction after it ends
    * Checks auction parameters, bidder signatures, auction expiration
    * Transfers NFT asset, sends bid amount to seller minus platform fees
    * Deletes auction storage mappings after transfer
    * @param auction Auction parameters struct
    * @param signature Bidder's signature for authentication 
    */
    function claimAuction(BasicAuction calldata auction, bytes calldata signature) external override nonReentrant isPaused {

            bytes32 id = _id[auction.seller][auction.collectionAddr][auction.tokenId];

            uint256 currentBid = _highestBid[id];
            address currentBidder = _highestBidder[id];

            require(SignatureVerifier.verifySignature(id, signature, msg.sender), "Invalid signature");
            require(_checkAuctionParams(auction, id), "invalid parameters");
            require(currentBid != 0 && currentBidder != address(0), "Auction has not begun");
            require(auction.seller == msg.sender || currentBidder == msg.sender , "Invalid claimer");
            require(_isExpired(auction), "Auction active");

            delete _auctions[id];
            delete _claimable[id];
            delete _id[auction.seller][auction.collectionAddr][auction.tokenId];
            delete _highestBid[id];
            delete _highestBidder[id];
            delete _expirationTime[id];

            _ordersFilled[id] = true;

            _addOrderFilled();

            if(auction.royaltySupport) {
                Royalty memory r = royaltyVault.getRoyaltyInfo(auction.collectionAddr);
                uint256 royaltyFee = currentBid.mul(r.feeRate).div(MAX_FEE_RATE);

                delete _royaltySupported[id];
                if(r.feeRecipient != address(0)) {
                    if(auction.currency == address(0)){
                        _safeSendETH(r.feeRecipient, royaltyFee);
                    } else {
                        IERC20(auction.currency).transfer(r.feeRecipient, royaltyFee);
                    }
                }
                currentBid = currentBid.sub(royaltyFee);
            }

            _transferAsset(auction.collectionAddr, auction.tokenId, auction.seller, currentBidder, 1, AssetType.erc721);

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


    /**
    * @dev Allows the highest bidder to get a refund if the auction expires 
    * @param collectionAddr The NFT collection address
    * @param tokenId The ID of the NFT being auctioned
    * @param id The ID of the auction 
    * @param signature The signature of the caller, used for authorization
    */
    function auctionRefund(address collectionAddr, uint256 tokenId, bytes32 id, bytes calldata signature) external override nonReentrant isPaused {
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

        if(a.currency == address(0)) {
            _safeSendETH(bidder, amount);
        } else {
            IERC20(a.currency).transfer(bidder, amount);
        }

    }

    /********************** Query Functions **********************/

    /**
    * @dev Returns the marketplace name
    */
    function marketplace() external pure returns(string memory) {
        return bytes32("TAG Web3 Marketplace").bytes32ToString();
    }

    /** 
    * @dev Returns the contract version
    */
    function version() external pure returns(string memory) {
        return bytes32("V1.0").bytes32ToString();
    }

    /**
    * @dev Returns the highest bid for a given auction
    * @param id The ID of the auction
    */ 
    function getHighestBid(bytes32 id) external override view returns (uint256) {
        return _highestBid[id];
    }

    /**
    * @dev Returns the address of the highest bidder for a given auction
    * @param id The ID of the auction
    */
    function getHighestBidder(bytes32 id) external override view returns(address) {
        return _highestBidder[id];
    }

    /**
    * @dev Returns the auction details for a given NFT
    * @param seller The seller address 
    * @param collectionAddr The NFT collection address
    * @param tokenId The ID of the NFT
    */
    function getAuctionByToken(address seller, address collectionAddr, uint256 tokenId) external override view returns(BasicAuction memory){
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return _decodeAuction(_auctions[id], id);
    }

    /**
    * @dev Returns the auction details for a given auction ID
    * @param id The ID of the auction
    */
    function getAuctionById(bytes32 id) external override view returns(BasicAuction memory) {
        return _decodeAuction(_auctions[id], id);
    }

    /**
    * @dev Returns the order details for a given NFT
    * @param seller The seller address
    * @param collectionAddr The NFT collection address 
    * @param tokenId The ID of the NFT
    */
    function getOrderByTokenId(address seller, address collectionAddr, uint256 tokenId) external override view returns(BasicOrder memory) {
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return _decodeOrder(_order[id], id);
    }

    /**
    * @dev Returns the order details for a given order ID
    * @param id The ID of the order
    */
    function getOrderById(bytes32 id) external override view returns(BasicOrder memory) {
        return _decodeOrder(_order[id], id);
    }

    /**
    * @dev Returns the active order ID for a given NFT
    * @param seller The seller address
    * @param collectionAddr The NFT collection address
    * @param tokenId The ID of the NFT 
    */ 
    function activeOrder(address seller, address collectionAddr, uint256 tokenId) external view override returns(bytes32) {
        bytes32 id = _id[seller][collectionAddr][tokenId];
        return id;
    }

    /**
    * @dev Returns the expiration time for an order 
    * @param seller The seller address
    * @param collectionAddr The NFT collection address
    * @param tokenId The ID of the NFT
    */
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

    /**
    * @dev Checks if refund conditions are met for an auction
    * @param collectionAddr Address of NFT collection 
    * @param tokenId ID of the NFT
    * @param id ID of the auction
    * @return bool True if refund conditions are met, false otherwise
    */
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

    function _decodeAuction(bytes memory encodedAuction, bytes32 id) private view returns (BasicAuction memory) {
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

    function _encodeAuction(BasicAuction memory auction, bytes32 id) private returns (bytes memory) {
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

    function _decodeOrder(bytes memory encodedOrder, bytes32 id) private view returns (BasicOrder memory) {
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

    function _encodeOrder(BasicOrder memory order, bytes32 id) private returns (bytes memory) {
        bytes memory b = new bytes(288);

        address collectionAddr = order.collectionAddr;
        uint256 tokenId = order.tokenId;
        address seller = order.seller;
        address buyer = order.buyer;
        uint256 price = order.price;
        uint256 supply = order.supply;
        uint256 expirationTime = order.expirationTime;
        address currency = order.currency;
        AssetType asset = order.asset;

        _royaltySupported[id] = order.royaltySupport;

        assembly {
            mstore(add(b, 32), collectionAddr)
            mstore(add(b, 64), tokenId)
            mstore(add(b, 96), seller)
            mstore(add(b, 128), buyer)
            mstore(add(b, 160), price)
            mstore(add(b, 192), supply)
            mstore(add(b, 224), expirationTime)
            mstore(add(b, 256), currency)
            mstore(add(b, 288), asset)
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

    /**
     * @dev Checks auction parameters and status for validity
     * @param auction Auction object with parameters to check  
     * @param id Auction ID
     * @return valid True if auction parameters and status are valid
     */
    function _checkAuctionParams(BasicAuction calldata auction, bytes32 id) internal view returns(bool valid) {

        // Check collection address, initial price and seller are valid
        bool validParams = (auction.collectionAddr != address(0) && 
                            auction.initialPrice != 0 &&
                            auction.seller != address(0)) &&
                            auction.seller == IERC721(auction.collectionAddr).ownerOf(auction.tokenId);
        
        // Check auction is not filled, not ended or ending in future 
        bool validAuctionStatus = (!_ordersFilled[id]) &&
                               (_expirationTime[id] == auction.endedAt);

        // Check caller is seller or highest bidder
        bool validOperator = (auction.seller == msg.sender || auction.highestBidder == msg.sender);

        // Return true only if all parameters and auction status are valid
        return validParams && validAuctionStatus && validOperator;
    }


    function _isExpired(BasicAuction calldata auction) internal view returns(bool) {
        return (auction.endedAt < block.timestamp);
    }

    function _isActive(BasicAuction calldata auction) internal view returns(bool) {
        return (auction.endedAt > block.timestamp || auction.endedAt == 0);
    }

        /**
    * @dev Checks order parameters and status for validity
    * @param order Order object with parameters to check
    * @param id Order ID  
    * @return valid True if order parameters and status are valid
    */
    function _checkOrderParams(BasicOrder calldata order, bytes32 id) internal view returns (bool) {
        // Check collection address is not zero address
        require(order.collectionAddr != address(0), "Collection address cannot be zero");
        
        // Check price is greater than zero
        require(order.price > 0, "Price must be greater than zero"); 
        
        // Check seller is not zero address
        require(order.seller != address(0), "Seller cannot be zero address");

        // Check expiration time is greater than zero and in the future
        require(order.expirationTime > 0 && order.expirationTime > block.timestamp, "Expiration time must be greater than zero and in the future");

        // Check order is not already filled
        require(!_ordersFilled[id], "Order is already filled");

        // Check caller is seller or buyer
        require(order.seller == msg.sender || order.buyer == msg.sender, "Caller must be seller or buyer");

        return true;
    }



    /**
     * @dev Sends ETH to a recipient address
     * Checks that the contract has sufficient balance before sending
     * Calls the recipient address with a default empty calldata
     * Requires the send to succeed, otherwise reverts
     * 
     * @param recipient Address to send ETH to 
     * @param amount Amount of ETH to send
     */
    function _safeSendETH(address recipient, uint256 amount) private {
        require(
            address(this).balance >= amount,
            "Insufficient contract balance"
        );

        (bool success, ) = payable(recipient).call{value: amount}("");
        require(success, "Failed to send ETH");
    }



    /** TEST FUNCTION FOR QUICKLY AUCTIONS **/
    /*  function _calculateFiveMinutes() private view returns (uint256) {
        uint256 timestampActual = block.timestamp;

        // Sumamos 10 minutos al timestamp actual
        uint256 timestampFuturo = timestampActual + 300;

        return timestampFuturo;
    }*/

}
