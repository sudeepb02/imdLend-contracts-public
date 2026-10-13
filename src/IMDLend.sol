// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LibError} from "./libraries/LibError.sol";
import {LibWorkerAuthorization} from "./libraries/LibWorkerAuthorization.sol";

import {IIMDLend} from "./interfaces/IIMDLend.sol";
import {IIMDLendMarket} from "./interfaces/IIMDLendMarket.sol";

/// @title IMDLend
/// @notice A vault through which one owner lends IdentityMD NFTs, the network's seats, to one operator
/// at a fixed split. Holds the lent NFTs, answers ERC-1271 for the operator's device pairings, and
/// splits every ERC-20 it receives between the fee recipient, the owner and the operator.
/// @dev The IMD network pays each NFT's rewards to the address holding it, so this vault is that
/// address. The owner, the operator and the split never change, so rewards that arrive after a lending
/// has ended split exactly as they would have during it.
///
/// Flow:
/// 1. An operator takes a listing: the market moves the NFT in and starts its lending
/// 2. The operator approves device pairings, which the network verifies through ERC-1271
/// 3. The network pays the NFT's rewards to the vault, and anyone splits them between the payees
/// 4. The owner withdraws the NFT once its lending is over
/// @dev Each vault is a clone of one implementation the market deploys. The owner, the operator and the
/// split are the clone's immutable args, so the vault's address commits to them. Their getters are upper
/// case, like the other immutables.
/// @dev `block.timestamp` gates windows of minutes (pairings) to days (lendings). A validator can nudge
/// it by seconds, which is not a lever here.
/// @dev Every chain pays the owner, the operator and the fee recipient at the same addresses, so a
/// contract-wallet payee must exist at its address on each launch chain.
contract IMDLend is IIMDLend, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                    CONSTANTS/IMMUTABLES                                   //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint16 public constant BPS_PRECISION = 100_00; // 100% in basis points
    uint16 public constant PROTOCOL_FEE = 2_00; // 2% in basis points
    uint64 public constant MAX_PAIRING_WINDOW = 1 hours; // Longest a pairing approval stays valid

    bytes4 private constant INVALID_SIGNATURE = 0xffffffff; // ERC-1271 failure value

    /// @notice The IdentityMD collection on the identity chain.
    IERC721 public immutable NFT_CONTRACT;

    /// @notice The market that deploys every vault: the only caller that starts lendings, and the
    /// source of the current fee recipient.
    address public immutable MARKET;

    /// @dev The implementation's own address, where no vault lives.
    address private immutable IMPLEMENTATION;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           STATE                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev A pairing the operator approved, and the lending of its NFT it was approved in.
    struct PairingApproval {
        uint256 tokenId; // The NFT the device pairs to
        uint64 expiresAt; // When the approval stops being valid
        uint64 lendingStartedAt; // Start of the lending the approval belongs to
    }

    /// @dev Each NFT's latest lending.
    mapping(uint256 tokenId => Lending lending) private _lendings;

    /// @dev Pairing approvals by WorkerAuthorization digest.
    mapping(bytes32 digest => PairingApproval approval) private _pairingApprovals;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        CONSTRUCTOR                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the vault implementation with the values every clone shares.
    /// @dev The deployer becomes the market of every clone, and validates these values and each
    /// vault's terms.
    /// @param _nftContract The IdentityMD NFT contract.
    constructor(IERC721 _nftContract) {
        NFT_CONTRACT = _nftContract;
        MARKET = msg.sender;
        IMPLEMENTATION = address(this);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                             EXTERNAL FUNCTIONS: NFT ACTIONS                               //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Sends an IdentityMD NFT back to the owner.
    /// @dev An NFT stays locked while its lending runs; any other NFT the vault holds can be withdrawn
    /// at any time.
    /// @dev The seat's next holder can re-pair a device left running on it, so the operator unlinks its
    /// devices before the lending ends.
    /// @param tokenId The NFT to return.
    function withdrawNft(uint256 tokenId) external {
        _validateOwner();
        if (isNftLent(tokenId)) revert LibError.NftLocked(tokenId, _lendings[tokenId].endsAt);

        NFT_CONTRACT.transferFrom(address(this), OWNER(), tokenId);
        emit NftWithdrawn(tokenId);
    }

    /// @notice Sends the owner an ERC-721 of another collection, such as an airdrop. An NFT cannot be
    /// split, so it goes to the owner whole. Meant for plain ERC-721s, not hybrid tokens such as ERC-404
    /// that also hold an ERC-20 balance.
    /// @dev Only the ERC-721 `safeTransferFrom` is called, and the owner must hold the NFT afterwards.
    /// ERC-721 `transferFrom` shares its selector with ERC-20 `transferFrom`, so without this check a
    /// reward token could leave the vault through here.
    /// @param collection The NFT's collection; never the IdentityMD one.
    /// @param tokenId The NFT to send.
    function rescueNft(IERC721 collection, uint256 tokenId) external nonReentrant {
        _validateOwner();
        if (address(collection) == address(NFT_CONTRACT)) revert LibError.ForbiddenToken(address(collection));

        address owner = OWNER();
        collection.safeTransferFrom(address(this), owner, tokenId);

        // Confirm the NFT reached the owner
        if (collection.ownerOf(tokenId) != owner) revert LibError.NftNotDelivered(address(collection), tokenId);

        emit NftRescued(address(collection), tokenId, 1);
    }

    /// @notice Sends the owner ERC-1155 tokens, such as an airdrop. They go to the owner whole. Meant for
    /// plain ERC-1155s, not hybrid tokens that also hold an ERC-20 balance.
    /// @dev Only the ERC-1155 `safeTransferFrom` is called, and the owner's balance must grow by
    /// `amount`.
    /// @param collection The ERC-1155 contract.
    /// @param id The token id to send.
    /// @param amount How many to send.
    function rescueErc1155(IERC1155 collection, uint256 id, uint256 amount) external nonReentrant {
        _validateOwner();
        if (address(collection) == address(NFT_CONTRACT)) revert LibError.ForbiddenToken(address(collection));

        address owner = OWNER();
        uint256 balanceBefore = collection.balanceOf(owner, id);
        collection.safeTransferFrom(address(this), owner, id, amount, "");

        // Confirm the owner's balance grew by `amount`
        if (collection.balanceOf(owner, id) < balanceBefore + amount) {
            revert LibError.NftNotDelivered(address(collection), id);
        }

        emit NftRescued(address(collection), id, amount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: LENDING                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Starts an NFT's lending to the operator, as the operator takes its listing.
    /// @dev The owner cannot withdraw the NFT until the lending is over.
    /// @param tokenId The NFT, which the vault must hold and not have lent.
    /// @param duration How long the lending lasts, in seconds.
    function startLending(uint256 tokenId, uint64 duration) external {
        _validateMarket();
        if (NFT_CONTRACT.ownerOf(tokenId) != address(this)) revert LibError.NftNotHeld(tokenId);
        if (isNftLent(tokenId)) revert LibError.NftLocked(tokenId, _lendings[tokenId].endsAt);

        uint64 startedAt = uint64(block.timestamp);
        uint64 endsAt = startedAt + duration;
        _lendings[tokenId] = Lending({startedAt: startedAt, endsAt: endsAt});
        emit LendingStarted(tokenId, startedAt, endsAt);
    }

    /// @notice Ends an NFT's lending before its duration is over.
    /// @dev The upfront payment is not refunded.
    /// @param tokenId The lent NFT.
    function endLending(uint256 tokenId) external {
        _validateOperator();
        if (!isNftLent(tokenId)) revert LibError.NftNotLent(tokenId);

        uint64 endedAt = uint64(block.timestamp);
        _lendings[tokenId].endsAt = endedAt;
        emit LendingEnded(tokenId, endedAt);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: PAIRING                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Approves one pairing of an operator device to a lent NFT by its WorkerAuthorization
    /// digest, so the device key stays off chain until the pairing completes.
    /// @dev The approval holds only within the NFT's current lending and until `expiresAt`, and it
    /// validates only with the fields the digest commits to.
    /// @dev Any device key can be approved, so owners unlink their own devices before listing: the
    /// seat's next holder can re-pair one left running.
    /// @param digest The WorkerAuthorization digest, as `getPairingDigest` computes it.
    /// @param tokenId The lent NFT the device works under; the digest's token id.
    /// @param expiresAt When the approval ends: after now and at most MAX_PAIRING_WINDOW ahead; the
    /// digest's expiry.
    function authorizePairing(bytes32 digest, uint256 tokenId, uint64 expiresAt) external {
        _validateOperator();
        if (!isNftLent(tokenId)) revert LibError.NftNotLent(tokenId);
        // forge-lint: disable-next-line(block-timestamp)
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_PAIRING_WINDOW) {
            revert LibError.InvalidExpiry();
        }

        // Record the lending's start, so a lending that starts in a later second never revives the approval
        _pairingApprovals[digest] =
            PairingApproval({tokenId: tokenId, expiresAt: expiresAt, lendingStartedAt: _lendings[tokenId].startedAt});
        emit PairingAuthorized(digest, tokenId, expiresAt);
    }

    /// @notice ERC-1271 signature validation. Valid only for an unexpired pairing the operator approved
    /// in its NFT's running lending.
    /// @dev The signature bytes reveal the rest of the WorkerAuthorization the approved digest commits
    /// to, so the digest is rebuilt and only a WorkerAuthorization naming this vault validates.
    /// Malformed bytes revert, which ERC-1271 callers read as invalid. A lending's pairings validate
    /// from the block after it starts, so a lending that exists only in a simulated call, such as an
    /// ERC-6492 prepare step, never validates one.
    /// @param hash The digest being verified.
    /// @param signature `abi.encode(deviceKey, nonce, relayOrigin)` of the WorkerAuthorization.
    /// @return The ERC-1271 magic value when valid, 0xffffffff otherwise.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        // An unknown digest reads as token 0 with a zero expiry, so it never validates
        PairingApproval memory approval = _pairingApprovals[hash];
        (bytes32 deviceKey, bytes32 nonce, string memory relayOrigin) =
            abi.decode(signature, (bytes32, bytes32, string));

        // The digest must be this vault's WorkerAuthorization for the approved NFT and expiry
        if (getPairingDigest(deviceKey, approval.tokenId, nonce, approval.expiresAt, relayOrigin) != hash) {
            return INVALID_SIGNATURE;
        }
        // A lending started in this block may exist only in the call being simulated
        // forge-lint: disable-next-line(block-timestamp)
        if (_lendings[approval.tokenId].startedAt == block.timestamp) return INVALID_SIGNATURE;
        // forge-lint: disable-next-line(block-timestamp)
        if (isNftLent(approval.tokenId) && getPairingExpiry(hash) > block.timestamp) {
            return IERC1271.isValidSignature.selector;
        }
        return INVALID_SIGNATURE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                EXTERNAL FUNCTIONS: REWARDS                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Splits `amount` of the vault's balance of `token` and pays the fee recipient, the owner and
    /// the operator their parts.
    /// @dev A partial amount lets a token that caps or taxes transfers leave in smaller releases.
    /// @dev A token that refuses any one payee blocks its own release here; anyone may release at any
    /// time.
    /// @dev Only ERC-20s are split; a pre-standard ERC-721 whose `transfer(address,uint256)` moves a
    /// token id is out of scope.
    /// @param token The ERC-20 to split; never the NFT contract.
    /// @param amount How much to split; `type(uint256).max` splits the whole balance.
    function releaseRewards(IERC20 token, uint256 amount) external nonReentrant {
        if (address(token) == address(NFT_CONTRACT)) revert LibError.ForbiddenToken(address(token));
        if (amount == type(uint256).max) amount = token.balanceOf(address(this));
        if (amount == 0) revert LibError.NoRewardsAvailable(address(token));

        (address owner, address operator, uint16 ownerBps) = _getTerms();
        (uint256 feeAmount, uint256 ownerAmount, uint256 operatorAmount) = _calculateSplit(amount, ownerBps);

        // A zero part is skipped, since some tokens refuse zero-amount transfers
        if (feeAmount > 0) token.safeTransfer(IIMDLendMarket(MARKET).feeRecipient(), feeAmount);
        if (ownerAmount > 0) token.safeTransfer(owner, ownerAmount);
        if (operatorAmount > 0) token.safeTransfer(operator, operatorAmount);

        emit RewardsReleased(address(token), feeAmount, ownerAmount, operatorAmount);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                          EXTERNAL FUNCTIONS: NFT OVERRIDES                                //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Accepts an ERC-721 sent with safeTransferFrom, such as an airdrop, from any collection
    /// but the IdentityMD one, whose NFTs arrive only through the market.
    /// @param from The NFT's previous holder.
    /// @param tokenId The NFT received.
    /// @return The ERC-721 receiver magic value.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        _validateVault();
        if (msg.sender == address(NFT_CONTRACT)) revert LibError.UnexpectedNft(msg.sender, from, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Accepts an ERC-1155 transfer, such as an airdrop.
    /// @return The ERC-1155 single-transfer magic value.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        _validateVault();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Accepts an ERC-1155 batch transfer, such as an airdrop.
    /// @return The ERC-1155 batch-transfer magic value.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _validateVault();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       VIEW FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Returns the owner, who lends the NFTs and receives the owner share.
    /// @return The owner.
    function OWNER() public view returns (address) {
        (address owner,,) = _getTerms();
        return owner;
    }

    /// @notice Returns the operator, who runs the machines working under the NFTs and receives the
    /// operator share.
    /// @return The operator.
    function OPERATOR() public view returns (address) {
        (, address operator,) = _getTerms();
        return operator;
    }

    /// @notice Returns the owner's share of rewards after the protocol fee, in basis points.
    /// @return The owner's share in basis points.
    function OWNER_BPS() external view returns (uint16) {
        (,, uint16 ownerBps) = _getTerms();
        return ownerBps;
    }

    /// @notice Returns whether an NFT's lending is running: started and neither over nor ended by the
    /// operator.
    /// @param tokenId The NFT to check.
    /// @return True while the NFT is lent.
    function isNftLent(uint256 tokenId) public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < _lendings[tokenId].endsAt;
    }

    /// @notice Returns an NFT's latest lending.
    /// @param tokenId The NFT.
    /// @return When it started and when it ends (or ended); zero for an NFT never lent.
    function getLending(uint256 tokenId) external view returns (Lending memory) {
        return _lendings[tokenId];
    }

    /// @notice Returns when a pairing the operator approved stops being valid.
    /// @dev Reads only the approval and its lending; `isValidSignature` also needs the lending running
    /// and started in an earlier block.
    /// @param digest The WorkerAuthorization digest.
    /// @return The expiry in unix seconds; zero for a digest never approved, or approved in an earlier
    /// lending of its NFT.
    function getPairingExpiry(bytes32 digest) public view returns (uint64) {
        PairingApproval memory approval = _pairingApprovals[digest];
        if (approval.lendingStartedAt != _lendings[approval.tokenId].startedAt) return 0;
        return approval.expiresAt;
    }

    /// @notice Returns the EIP-712 digest of a WorkerAuthorization naming this vault as the wallet,
    /// under the network's "IdentityMD Worker" v2 domain.
    /// @param deviceKey The device key being paired.
    /// @param tokenId The NFT the device works under.
    /// @param nonce The pairing code's nonce.
    /// @param expiresAt When the authorization stops being valid, in unix seconds.
    /// @param relayOrigin The control plane the pairing is bound to.
    /// @return The digest the network verifies through `isValidSignature`.
    function getPairingDigest(
        bytes32 deviceKey,
        uint256 tokenId,
        bytes32 nonce,
        uint64 expiresAt,
        string memory relayOrigin
    ) public view returns (bytes32) {
        return LibWorkerAuthorization.hashTypedData(
            address(NFT_CONTRACT), deviceKey, address(this), tokenId, nonce, expiresAt, relayOrigin
        );
    }

    /// @notice Returns how `releaseRewards` would split the vault's current balance of `token`.
    /// @param token The ERC-20 to check; never the NFT contract.
    /// @return feeAmount The protocol fee, for the fee recipient.
    /// @return ownerAmount The owner's part.
    /// @return operatorAmount The operator's part.
    function getAvailableRewards(IERC20 token)
        external
        view
        returns (uint256 feeAmount, uint256 ownerAmount, uint256 operatorAmount)
    {
        if (address(token) == address(NFT_CONTRACT)) revert LibError.ForbiddenToken(address(token));
        (,, uint16 ownerBps) = _getTerms();
        return _calculateSplit(token.balanceOf(address(this)), ownerBps);
    }

    /// @notice ERC-165 interface detection.
    /// @dev Advertises ERC-165 and the ERC-721 and ERC-1155 receivers.
    /// @param interfaceId The interface identifier to check.
    /// @return True if the interface is supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     INTERNAL FUNCTIONS                                    //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Reverts unless the caller is the market.
    function _validateMarket() internal view {
        if (msg.sender != MARKET) revert LibError.NotMarket();
    }

    /// @dev Reverts unless the caller is the owner.
    function _validateOwner() internal view {
        if (msg.sender != OWNER()) revert LibError.NotOwner();
    }

    /// @dev Reverts unless the caller is the operator.
    function _validateOperator() internal view {
        if (msg.sender != OPERATOR()) revert LibError.NotOperator();
    }

    /// @dev Reverts on the implementation, which is not a vault.
    function _validateVault() internal view {
        if (address(this) == IMPLEMENTATION) revert LibError.NotAVault();
    }

    /// @dev Reads the vault's owner, operator and split from the clone's immutable args.
    /// @return owner The account that lends its NFTs.
    /// @return operator The account that runs the machines working under the NFTs.
    /// @return ownerBps The owner's share of rewards after the protocol fee, in basis points.
    function _getTerms() internal view returns (address owner, address operator, uint16 ownerBps) {
        _validateVault();
        return abi.decode(Clones.fetchCloneArgs(address(this)), (address, address, uint16));
    }

    /// @dev Splits `amount`: the protocol fee comes off first, the owner takes `ownerBps` of the rest,
    /// and the operator takes what remains, rounding dust included. The three always add up to `amount`.
    /// @dev The products overflow only above about 1.18e73 units, far beyond any launch supply, and then
    /// only that token's release reverts.
    /// @param amount The amount to split.
    /// @param ownerBps The owner's share of what remains after the fee, in basis points.
    /// @return feeAmount The protocol fee, for the fee recipient.
    /// @return ownerAmount The owner's share.
    /// @return operatorAmount The operator's share.
    function _calculateSplit(uint256 amount, uint16 ownerBps)
        internal
        pure
        returns (uint256 feeAmount, uint256 ownerAmount, uint256 operatorAmount)
    {
        feeAmount = amount * PROTOCOL_FEE / BPS_PRECISION;
        ownerAmount = (amount - feeAmount) * ownerBps / BPS_PRECISION;
        operatorAmount = amount - feeAmount - ownerAmount;
    }
}
