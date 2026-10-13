// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IIMDLend} from "./IIMDLend.sol";

interface IIMDLendMarket {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          STRUCTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // An owner's offer to lend one NFT. The operator takes it for minDuration to maxDuration seconds,
    // paying pricePerDay pro rata to the second.
    struct Listing {
        // Slot 0: 160 + 16 + 32 + 32 = 240 bits
        address owner; // Lends the NFT and receives the upfront payment
        uint16 ownerBps; // Owner's share of rewards after the protocol fee, in basis points
        uint32 minDuration; // Shortest lending an operator may take, in seconds
        uint32 maxDuration; // Longest lending an operator may take, in seconds

        // Slot 1: 160 + 64 = 224 bits
        address operator; // The only operator who may take the listing; zero for anyone
        uint64 availableUntil; // Takes are refused from this timestamp on

        // Slot 2: 256 bits
        uint256 tokenId;

        // Slot 3: 256 bits
        uint256 pricePerDay; // Upfront payment in IMD per day of lending; zero for none
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           EVENTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event ListingCreated(bytes32 indexed listingId, address indexed owner, uint256 indexed tokenId, Listing listing);
    event ListingCancelled(bytes32 indexed listingId);
    event ListingTaken(
        bytes32 indexed listingId,
        address indexed operator,
        address indexed vault,
        uint32 duration,
        uint256 upfrontAmount
    );
    event VaultDeployed(address indexed vault, address indexed owner, address indexed operator, uint16 ownerBps);
    event FeeRecipientProposed(address indexed proposedRecipient);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event TokensRescued(address indexed token, uint256 amount);
    event NftRescued(address indexed collection, uint256 indexed tokenId);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CONSTANTS/IMMUTABLES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function IDENTITY_CHAIN_ID() external view returns (uint256);
    function BPS_PRECISION() external view returns (uint16);
    function PROTOCOL_FEE() external view returns (uint16);
    function MAX_DURATION() external view returns (uint32);
    function MAX_LISTING_TTL() external view returns (uint64);

    function NFT_CONTRACT() external view returns (IERC721);
    function IMD_TOKEN() external view returns (IERC20);
    function VAULT_IMPLEMENTATION() external view returns (address);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      STATE VARIABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function feeRecipient() external view returns (address);
    function pendingFeeRecipient() external view returns (address);
    function listingCount() external view returns (uint256);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: LISTINGS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function createListing(
        uint256 tokenId,
        uint16 ownerBps,
        uint256 pricePerDay,
        uint32 minDuration,
        uint32 maxDuration,
        uint64 availableUntil,
        address operator
    ) external returns (bytes32 listingId);

    function cancelListing(bytes32 listingId) external;

    function takeListing(bytes32 listingId, uint32 duration) external returns (IIMDLend vault);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 EXTERNAL FUNCTIONS: VAULTS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function deployVault(address owner, address operator, uint16 ownerBps) external returns (IIMDLend vault);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             EXTERNAL FUNCTIONS: FEE RECIPIENT                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function proposeFeeRecipient(address newFeeRecipient) external;

    function acceptFeeRecipient() external;

    function rescueTokens(IERC20 token) external;

    function rescueNft(IERC721 collection, uint256 tokenId) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       VIEW FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getListing(bytes32 listingId) external view returns (Listing memory);
    function getVaultAddress(address owner, address operator, uint16 ownerBps) external view returns (address);
}
