// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMDLend} from "./IMDLend.sol";

import {LibError} from "./libraries/LibError.sol";

import {IIMDLend} from "./interfaces/IIMDLend.sol";
import {IIMDLendMarket} from "./interfaces/IIMDLendMarket.sol";

/// @title IMDLendMarket
/// @notice Where owners list IdentityMD NFTs for lending and operators take them. Taking a listing
/// moves the NFT into the vault for its owner, operator and split, deploying that vault if needed, and
/// pays the owner upfront.
/// @dev A vault's address depends only on its owner, operator and split and this market's address.
/// With the market at the same address on every chain, a vault has the same address wherever IMD
/// launch rewards are paid to it. Listings and takes run only on the identity chain, where the NFTs
/// live; elsewhere the market only deploys vaults.
///
/// Flow:
/// 1. The owner approves this market for the NFT and calls `createListing`
/// 2. An operator calls `takeListing` for a duration from the listing's `minDuration` to `maxDuration`
/// 3. The market deploys or reuses the vault, moves the NFT in and starts the lending
/// 4. The operator pays `pricePerDay` pro rata upfront: the protocol fee, the rest to the owner
/// 5. On the other launch chains, anyone calls `deployVault` to occupy the same vault address
/// @dev Every vault is a minimal clone of one implementation, deployed in this market's constructor and
/// so at the same address on every chain. The owner, the operator and the split are each clone's
/// immutable args.
/// @dev Equal addresses need the CREATE2 deployer at 0x4e59...956C, so only chains that have it can
/// host the market and its vaults.
contract IMDLendMarket is IIMDLendMarket, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CONSTANTS/IMMUTABLES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint16 public constant BPS_PRECISION = 100_00; // 100% in basis points
    uint16 public constant PROTOCOL_FEE = 2_00; // 2% in basis points
    uint32 public constant MAX_DURATION = 365 days; // Longest lending a listing may offer
    uint64 public constant MAX_LISTING_TTL = 90 days; // Longest a listing stays open before it expires

    bytes32 private constant VAULT_SALT = bytes32(0); // The clone args already make each address unique

    /// @notice The chain where the IdentityMD NFTs live, and the only one where listings and takes run:
    /// 1 (Ethereum) for the production markets, or a testnet's id; the same value on every chain keeps
    /// addresses equal.
    uint256 public immutable IDENTITY_CHAIN_ID;

    /// @notice The IdentityMD NFT contract on the identity chain; the same value on every chain keeps
    /// addresses equal.
    IERC721 public immutable NFT_CONTRACT;

    /// @notice The IMD token upfront payments are made in; the same value on every chain keeps
    /// addresses equal.
    IERC20 public immutable IMD_TOKEN;

    /// @notice The vault implementation every vault is a clone of.
    address public immutable VAULT_IMPLEMENTATION;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           STATE                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Receives the protocol fee of every upfront payment and every vault on this chain.
    address public feeRecipient;

    /// @notice The address proposed to take over the protocol fee; zero when none is pending.
    address public pendingFeeRecipient;

    /// @notice How many listings have been created, which makes every listing id unique.
    uint256 public listingCount;

    /// @dev Open listings; a taken, cancelled or never-created id holds an empty listing.
    mapping(bytes32 listingId => Listing listing) private _listings;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        CONSTRUCTOR                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the market and the vault implementation every vault is cloned from.
    /// @param _identityChainId The chain where the IdentityMD NFTs live.
    /// @param _nftContract The IdentityMD NFT contract on that chain.
    /// @param _imdToken The IMD token, in which upfront payments are made.
    /// @param _feeRecipient The first protocol fee recipient; the same value on every chain keeps
    /// addresses equal, so it must be an address its holder controls on every chain.
    constructor(uint256 _identityChainId, IERC721 _nftContract, IERC20 _imdToken, address _feeRecipient) {
        if (address(_nftContract) == address(0) || address(_imdToken) == address(0) || _feeRecipient == address(0)) {
            revert LibError.ZeroAddress();
        }
        // ERC-20 and ERC-721 `transferFrom` share a selector, so the IMD token must not be the NFT contract
        if (address(_imdToken) == address(_nftContract)) revert LibError.InvalidSetup();

        IDENTITY_CHAIN_ID = _identityChainId;
        NFT_CONTRACT = _nftContract;
        IMD_TOKEN = _imdToken;
        feeRecipient = _feeRecipient;
        VAULT_IMPLEMENTATION = address(new IMDLend(_nftContract));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: LISTINGS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Offers one of the caller's NFTs for lending.
    /// @dev The NFT must be in the caller's wallet, which approves this market to move it, or, after an
    /// earlier lending, in the caller's vault for this listing's operator and split. Where it is gets
    /// checked again when the listing is taken.
    /// @param tokenId The NFT to lend.
    /// @param ownerBps The owner's share of rewards in basis points.
    /// @param pricePerDay The upfront payment in IMD for each day of the lending, charged per second.
    /// @param minDuration The shortest lending an operator may take, in seconds; at least 1.
    /// @param maxDuration The longest lending an operator may take, in seconds; at most MAX_DURATION.
    /// @param availableUntil When the listing expires: after now and at most MAX_LISTING_TTL ahead.
    /// @param operator The only operator who may take the listing, zero for anyone.
    /// @return listingId The id operators name to take the listing.
    function createListing(
        uint256 tokenId,
        uint16 ownerBps,
        uint256 pricePerDay,
        uint32 minDuration,
        uint32 maxDuration,
        uint64 availableUntil,
        address operator
    ) external returns (bytes32 listingId) {
        _validateIdentityChain();

        // Validate the expiry and the terms
        // forge-lint: disable-next-line(block-timestamp)
        if (availableUntil <= block.timestamp || availableUntil > block.timestamp + MAX_LISTING_TTL) {
            revert LibError.InvalidExpiry();
        }
        if (minDuration == 0 || minDuration > maxDuration || maxDuration > MAX_DURATION) {
            revert LibError.InvalidDuration();
        }
        if (ownerBps > BPS_PRECISION || operator == msg.sender) {
            revert LibError.InvalidListing();
        }

        // The NFT must be in the caller's wallet, or in the caller's vault for this operator and split
        address holder = NFT_CONTRACT.ownerOf(tokenId);
        if (holder != msg.sender && holder != getVaultAddress(msg.sender, operator, ownerBps)) {
            revert LibError.NftNotOwned(tokenId, holder);
        }

        Listing memory listing = Listing({
            owner: msg.sender,
            ownerBps: ownerBps,
            minDuration: minDuration,
            maxDuration: maxDuration,
            operator: operator,
            availableUntil: availableUntil,
            tokenId: tokenId,
            pricePerDay: pricePerDay
        });

        // The counter keeps ids unique when the same terms are listed again
        listingId = keccak256(abi.encode(listing, ++listingCount));
        _listings[listingId] = listing;

        emit ListingCreated(listingId, msg.sender, tokenId, listing);
    }

    /// @notice Withdraws a listing that has not been taken.
    /// @param listingId The listing to cancel.
    function cancelListing(bytes32 listingId) external {
        if (_listings[listingId].owner != msg.sender) {
            revert LibError.NotListingOwner();
        }

        delete _listings[listingId];
        emit ListingCancelled(listingId);
    }

    /// @notice Takes a listing: the caller becomes the NFT's operator for `duration` seconds and pays
    /// the upfront amount in IMD.
    /// @dev The NFT moves from the owner into the vault for (owner, caller, split), deployed here if
    /// needed. An NFT already in that vault, after an earlier lending to the same operator, stays in
    /// place, so its paired device keeps working.
    /// @dev A take closes only its own listing: the owner's other listings for the NFT stay open until
    /// cancelled or expired, and a take in place needs no approval.
    /// @dev The NFT's ERC-8004 registration is not checked, and the vault cannot register it, so front
    /// ends check it before a take.
    /// @param listingId The listing to take.
    /// @param duration How long the lending lasts in seconds, from the listing's minDuration to its
    /// maxDuration.
    /// @return vault The vault now holding the lent NFT.
    function takeListing(bytes32 listingId, uint32 duration) external nonReentrant returns (IIMDLend vault) {
        _validateIdentityChain();
        Listing memory listing = _listings[listingId];

        // The listing must be open, name the caller or nobody, and allow the duration
        // forge-lint: disable-next-line(block-timestamp)
        if (listing.owner == address(0) || block.timestamp >= listing.availableUntil) {
            revert LibError.ListingNotOpen(listingId);
        }

        if (listing.operator != address(0) && listing.operator != msg.sender) {
            revert LibError.NotListedOperator(msg.sender);
        }

        if (duration < listing.minDuration || duration > listing.maxDuration) {
            revert LibError.InvalidDuration();
        }

        // Delete before any external call, so the listing is taken only once
        delete _listings[listingId];

        vault = _deployVault(listing.owner, msg.sender, listing.ownerBps);

        // Move the NFT into the vault. NFT already there from an earlier lending stays in place
        address holder = NFT_CONTRACT.ownerOf(listing.tokenId);
        if (holder == listing.owner) {
            NFT_CONTRACT.transferFrom(listing.owner, address(vault), listing.tokenId);
        } else if (holder != address(vault)) {
            revert LibError.NftNotAvailable(listing.tokenId, holder);
        }
        vault.startLending(listing.tokenId, duration);

        // Multiplying first keeps the per-second price exact; a partial day's wei rounds down
        uint256 upfrontAmount = listing.pricePerDay * duration / 1 days;
        emit ListingTaken(listingId, msg.sender, address(vault), duration, upfrontAmount);

        _collectUpfrontAmount(listing.owner, upfrontAmount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 EXTERNAL FUNCTIONS: VAULTS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the vault for this owner, operator and split, or returns it when it already
    /// exists.
    /// @dev Anyone may call, on any chain: the address can only ever hold that vault. The owner and the
    /// operator must be different accounts, and the split at most BPS_PRECISION.
    /// @param owner The account that lends its NFTs.
    /// @param operator The account that runs the machines working under the NFTs.
    /// @param ownerBps The owner's share of rewards after the protocol fee, in basis points.
    /// @return vault The vault for these terms.
    function deployVault(address owner, address operator, uint16 ownerBps) external returns (IIMDLend vault) {
        return _deployVault(owner, operator, ownerBps);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             EXTERNAL FUNCTIONS: FEE RECIPIENT                             //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Proposes another address to take over the protocol fee on this chain.
    /// @dev Only the current fee recipient may call. The handover completes when the proposed address
    /// accepts, so a mistyped address never works. Proposing zero cancels a pending handover.
    /// @param newFeeRecipient The address proposed to receive the protocol fee.
    function proposeFeeRecipient(address newFeeRecipient) external {
        _validateFeeRecipient();

        pendingFeeRecipient = newFeeRecipient;
        emit FeeRecipientProposed(newFeeRecipient);
    }

    /// @notice Takes over the protocol fee on this chain, as the proposed fee recipient.
    /// @dev Every later upfront payment and reward release pays the new recipient, including fees that
    /// vaults received before.
    function acceptFeeRecipient() external {
        if (msg.sender != pendingFeeRecipient) revert LibError.NotPendingFeeRecipient();

        emit FeeRecipientUpdated(feeRecipient, msg.sender);
        feeRecipient = msg.sender;
        delete pendingFeeRecipient;
    }

    /// @notice Sends the fee recipient this market's whole balance of `token`, sent here by mistake.
    /// @dev The market never holds tokens: upfront payments go straight from the operator to the fee
    /// recipient and the owner.
    /// @param token The ERC-20 to rescue.
    function rescueTokens(IERC20 token) external {
        _validateFeeRecipient();

        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(msg.sender, amount);
        emit TokensRescued(address(token), amount);
    }

    /// @notice Sends the fee recipient an ERC-721 sent here by mistake with a plain `transferFrom`.
    /// @dev The market never holds NFTs: a take moves the NFT straight from its owner into the vault.
    /// @param collection The NFT's collection.
    /// @param tokenId The NFT to rescue.
    function rescueNft(IERC721 collection, uint256 tokenId) external {
        _validateFeeRecipient();

        collection.transferFrom(address(this), msg.sender, tokenId);
        emit NftRescued(address(collection), tokenId);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       VIEW FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns an open listing's terms.
    /// @param listingId The listing.
    /// @return The listing; an empty one (zero owner) once taken or cancelled, or for an unknown id.
    function getListing(bytes32 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @notice Returns the address of the vault for this owner, operator and split, deployed or not.
    /// @param owner The account that lends its NFTs.
    /// @param operator The account that runs the machines working under the NFTs.
    /// @param ownerBps The owner's share of rewards after the protocol fee, in basis points.
    /// @return The vault's CREATE2 address.
    function getVaultAddress(address owner, address operator, uint16 ownerBps) public view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            VAULT_IMPLEMENTATION, abi.encode(owner, operator, ownerBps), VAULT_SALT
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     INTERNAL FUNCTIONS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Reverts off the identity chain, where no IdentityMD NFT lives.
    function _validateIdentityChain() internal view {
        if (block.chainid != IDENTITY_CHAIN_ID) revert LibError.NotIdentityChain(block.chainid);
    }

    /// @dev Reverts unless the caller is the fee recipient.
    function _validateFeeRecipient() internal view {
        if (msg.sender != feeRecipient) revert LibError.NotFeeRecipient();
    }

    /// @dev Deploys the vault for these terms, or returns it when it already exists, so a deployment
    /// sent ahead of a take never blocks it.
    /// @param owner The account that lends its NFTs.
    /// @param operator The account that runs the machines working under the NFTs.
    /// @param ownerBps The owner's share of rewards after the protocol fee, in basis points.
    /// @return vault The vault for these terms.
    function _deployVault(address owner, address operator, uint16 ownerBps) internal returns (IIMDLend vault) {
        if (owner == address(0) || operator == address(0) || owner == operator || ownerBps > BPS_PRECISION) {
            revert LibError.InvalidTerms();
        }

        // Reuse the vault when it already exists
        address predicted = getVaultAddress(owner, operator, ownerBps);
        if (predicted.code.length > 0) return IIMDLend(predicted);

        vault = IIMDLend(
            Clones.cloneDeterministicWithImmutableArgs(
                VAULT_IMPLEMENTATION, abi.encode(owner, operator, ownerBps), VAULT_SALT
            )
        );

        emit VaultDeployed(address(vault), owner, operator, ownerBps);
    }

    /// @dev Pulls the upfront amount from the operator: the protocol fee to the fee recipient, the rest
    /// to the owner. It goes straight to them, so it never enters a vault's reward split.
    /// @param owner The listing's owner.
    /// @param upfrontAmount The amount the operator pays.
    function _collectUpfrontAmount(address owner, uint256 upfrontAmount) internal {
        uint256 feeAmount = (upfrontAmount * PROTOCOL_FEE) / BPS_PRECISION;
        // A zero amount is skipped, since some tokens refuse zero-amount transfers.
        if (feeAmount > 0) {
            IMD_TOKEN.safeTransferFrom(msg.sender, feeRecipient, feeAmount);
        }
        if (upfrontAmount > feeAmount) {
            IMD_TOKEN.safeTransferFrom(msg.sender, owner, upfrontAmount - feeAmount);
        }
    }
}
