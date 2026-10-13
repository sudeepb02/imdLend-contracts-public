// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

// IERC721Receiver and IERC1155Receiver let the vault receive NFTs airdropped to it.
// IERC1271 brings isValidSignature, through which the network verifies a device pairing.
interface IIMDLend is IERC721Receiver, IERC1155Receiver, IERC1271 {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                          STRUCTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // An NFT's latest lending; it runs while block.timestamp < endsAt.
    struct Lending {
        uint64 startedAt; // When the market started the lending
        uint64 endsAt; // When the duration runs out, or when the operator ended it early
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           EVENTS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event NftWithdrawn(uint256 indexed tokenId);
    event NftRescued(address indexed collection, uint256 indexed tokenId, uint256 amount);
    event LendingStarted(uint256 indexed tokenId, uint64 startedAt, uint64 endsAt);
    event LendingEnded(uint256 indexed tokenId, uint64 endedAt);
    event PairingAuthorized(bytes32 indexed digest, uint256 indexed tokenId, uint64 expiresAt);
    event RewardsReleased(address indexed token, uint256 feeAmount, uint256 ownerAmount, uint256 operatorAmount);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CONSTANTS/IMMUTABLES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function BPS_PRECISION() external view returns (uint16);
    function PROTOCOL_FEE() external view returns (uint16);
    function MAX_PAIRING_WINDOW() external view returns (uint64);

    function NFT_CONTRACT() external view returns (IERC721);
    function MARKET() external view returns (address);
    function OWNER() external view returns (address);
    function OPERATOR() external view returns (address);
    function OWNER_BPS() external view returns (uint16);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: CUSTODY                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function withdrawNft(uint256 tokenId) external;

    function rescueNft(IERC721 collection, uint256 tokenId) external;

    function rescueErc1155(IERC1155 collection, uint256 id, uint256 amount) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: LENDING                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function startLending(uint256 tokenId, uint64 duration) external;

    function endLending(uint256 tokenId) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: PAIRING                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function authorizePairing(bytes32 digest, uint256 tokenId, uint64 expiresAt) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: REWARDS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function releaseRewards(IERC20 token, uint256 amount) external;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       VIEW FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function isNftLent(uint256 tokenId) external view returns (bool);
    function getLending(uint256 tokenId) external view returns (Lending memory);

    function getPairingExpiry(bytes32 digest) external view returns (uint64);
    function getPairingDigest(
        bytes32 deviceKey,
        uint256 tokenId,
        bytes32 nonce,
        uint64 expiresAt,
        string memory relayOrigin
    ) external view returns (bytes32);

    function getAvailableRewards(IERC20 token)
        external
        view
        returns (uint256 feeAmount, uint256 ownerAmount, uint256 operatorAmount);
}
