# Security Audit Report

### Summary

The LoyalProtocol contract implements a marketplace for trading NFTs and other digital assets. It allows users to create and fill buy/sell orders, make offers, and run auctions. The contract manages the escrow and transfer of assets between parties.

### Key functions:

**createBasicOrder** - Create a new buy/sell order
**fillBasicOrder** - Fill an existing buy/sell order
**cancelBasicOrder** - Cancel an unfilled order
**makeOffer** - Make an offer for an asset
**acceptOffer** - Accept an existing offer
**cancelOffer** - Cancel an offer
**createAuction** - Create a new auction
**bid - Place** a bid in an auction
**cancelAuction** - Cancel an active auction
**claimAuction** - Winning bidder claims NFT after auction ends

The contract uses OpenZeppelin's ReentrancyGuard to prevent reentrancy attacks.

## Vulnerability Analysis

##### Integer Overflow
**Severity:** High
**SWC ID:** SWC-101

The _safeAdd and _safeSub functions from SafeMath library are used in several places to prevent integer overflow/underflow. This mitigates the risk.

##### Access Control & Authorization
**Severity:** Medium
**SWC ID:** SWC-999

The onlyAdmin modifier restricts access to sensitive functions like updating protocol parameters and admin address. This is a good practice.

However, there are no access controls around order creation and cancellation. Any user can create and cancel orders on behalf of other users. This can lead to potential griefing attacks.

**Recommendation:** Add modifiers to ensure only order creator can cancel it.

##### Reentrancy
**Severity:** Medium
**SWC ID:** SWC-107

The use of ReentrancyGuard prevents reentrancy attacks when filling orders or transferring assets.

However, the external calls to royaltyVault and transferHelper contracts should be avoided in intermediate states where state variables have been updated but assets have not been transferred yet. This can potentially lead to a reentrancy vulnerability.

**Recommendation:** Move all external calls to the end after internal state has been updated.

Consider using checks-effects-interactions pattern.

##### Logic Errors
**Severity:** Medium

There is no validation that the signer of the order is actually the owner of the asset. This could allow anyone to create fake orders on behalf of a user.

**Recommendation:** Validate order signer owns the asset before creating the order.

##### External Calls
**Severity:** Low

The contract makes external calls to royaltyVault and transferHelper. Make sure proper validations are in place to avoid attacks like reentrancy. Check for contract ownership, implement rollbacks etc.

## Summary

Overall the contract implements a basic NFT marketplace with some access control and reentrancy protections. Some areas of concern around proper authorization validations and order of operations. Following best practices around checks-effects-interactions pattern can make the code more robust.