// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LibError
/// @notice Custom errors of IMDLend and IMDLendMarket.
library LibError {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           COMMON                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error InvalidExpiry();
    error ZeroAddress();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           VAULT                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error ForbiddenToken(address token);
    error NftLocked(uint256 tokenId, uint64 lendingEndsAt);
    error NftNotDelivered(address collection, uint256 tokenId);
    error NftNotHeld(uint256 tokenId);
    error NftNotLent(uint256 tokenId);
    error NoRewardsAvailable(address token);
    error NotAVault();
    error NotMarket();
    error NotOperator();
    error NotOwner();
    error UnexpectedNft(address collection, address from, uint256 tokenId);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           MARKET                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////
    error InvalidDuration();
    error InvalidListing();
    error InvalidSetup();
    error InvalidTerms();
    error ListingNotOpen(bytes32 listingId);
    error NftNotAvailable(uint256 tokenId, address holder);
    error NftNotOwned(uint256 tokenId, address holder);
    error NotFeeRecipient();
    error NotIdentityChain(uint256 chainId);
    error NotListedOperator(address operator);
    error NotListingOwner();
    error NotPendingFeeRecipient();
}
