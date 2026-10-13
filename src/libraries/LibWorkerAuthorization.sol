// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LibWorkerAuthorization
/// @notice EIP-712 hashing of the WorkerAuthorization the IMD network verifies when a device pairs
/// to an IdentityMD NFT.
/// @dev Matches the network's typed data: the "IdentityMD Worker" domain, version "2", on the current
/// chain, with the NFT contract as the verifying contract.
library LibWorkerAuthorization {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant WORKER_AUTHORIZATION_TYPEHASH = keccak256(
        "WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)"
    );
    bytes32 private constant DOMAIN_NAME_HASH = keccak256("IdentityMD Worker");
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256("2");

    /// @notice Returns the EIP-712 digest of a WorkerAuthorization, as viem's `hashTypedData` computes it.
    /// @param nftContract The IdentityMD NFT contract, the domain's verifying contract.
    /// @param deviceKey The device key being authorized.
    /// @param wallet The wallet authorizing the device, the NFT's holder.
    /// @param tokenId The NFT the device works under.
    /// @param nonce The pairing code's nonce.
    /// @param expiresAt When the authorization stops being valid, in unix seconds.
    /// @param relayOrigin The control plane the authorization is bound to.
    /// @return The digest the network passes to the wallet's ERC-1271 `isValidSignature`.
    function hashTypedData(
        address nftContract,
        bytes32 deviceKey,
        address wallet,
        uint256 tokenId,
        bytes32 nonce,
        uint64 expiresAt,
        string memory relayOrigin
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, nftContract)
        );
        bytes32 structHash = keccak256(
            abi.encode(
                WORKER_AUTHORIZATION_TYPEHASH,
                deviceKey,
                wallet,
                tokenId,
                nonce,
                expiresAt,
                keccak256(bytes(relayOrigin))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
