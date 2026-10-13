# imdLend contracts

The smart contracts of imdLend, an open market for lending IMD seats (IdentityMD NFTs) to other
parties' machines, with each seat's earnings split on chain. They work against the IMD protocol as
it runs today; nothing in the protocol changes. This repository holds the contract sources only.

How it works:

- **Owners list seats** on `IMDLendMarket`, one seat per listing: a price per day in IMD, the
  shortest and longest lending they accept (in seconds), the owner's share of rewards, an expiry, and
  optionally the one operator allowed to take it.
- **An operator takes a listing** for a duration it picks, paying `pricePerDay * duration / 1 day`
  upfront in IMD: 2% to the fee recipient, the rest to the owner.
- **The seat moves into a vault**, an `IMDLend` clone for that owner, operator and split. The market
  creates the vault on the first take and reuses it afterwards. The network pays rewards to the
  vault, because the vault holds the seat.
- **The operator pairs devices** through the vault's ERC-1271 answer, and can end a lending early.
  The owner cannot take a lent seat back until its lending is over.
- **Anyone can release rewards:** one call splits a token's balance 2% to the fee recipient, then the
  owner's share of the rest to the owner and the remainder to the operator.

Listings and takes run only on Ethereum, where the seats live. The market, and so every vault, has
the same address on every launch chain, so rewards paid on Robinhood Chain or Base reach a vault
anyone can deploy there.

## Security model

| Party         | Can                                                                                                                                          | Cannot                                                                                                                                                                                                      |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Operator      | take an open listing or one naming it (paying its upfront amount), pair devices to its lent seats, end its lendings early, receive its share | move seats, change any term, get a refund, take a listing naming someone else, make a vault validate anything except a pairing naming that vault and a seat in its current lending, expiring within an hour |
| Owner         | list and cancel, withdraw seats that are not lent, rescue other NFTs from its vaults, receive its share                                      | withdraw a lent seat before its lending ends, change a vault's operator or split, pair devices, touch the other shares, list a seat held elsewhere                                                          |
| Fee recipient | receive 2% of rewards and upfront payments, hand over its role in two steps, rescue tokens and ERC-721s sent to the market                   | touch seats in vaults, listings, terms or the other shares                                                                                                                                                  |
| Market        | deploy vaults, start lendings in its own vaults                                                                                              | end lendings, move seats out of vaults, take rewards                                                                                                                                                        |
| Anyone        | deploy a vault for given terms on any chain, claim reward leaves to it, release its rewards                                                  | be paid by a vault, list a seat it does not hold                                                                                                                                                            |

- **No admin, pause or upgrade.** Listings are never edited, and a listing's id commits to its
  terms, so a take executes exactly the terms its caller saw. A listing is deleted before any seat
  or token moves, under a reentrancy guard, so it is taken once.
- **Ending a lending can never be blocked.** It ends by time alone, or early by the operator, and
  `withdrawNft` is a plain `transferFrom`.
- **Pairing.** Only a pairing's EIP-712 digest goes on chain. ERC-1271 answers only when the
  signature's fields rebuild that digest as a WorkerAuthorization naming the vault, for the approved
  seat and expiry, in the seat's current lending and from the block after it started. No other
  digest, such as a token permit, can ever validate, and no ECDSA signature is checked.
- **Rewards are never re-split.** A vault's owner, operator and split are its clone's immutable
  args, so its address commits to them for life. The seat collection is refused as a reward token.
- **Same address on every chain.** The market comes from the CREATE2 deployer and each vault is a
  CREATE2 clone of the market's implementation, so no other code can occupy a vault's address.

## Deployment

The market is deployed through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`
with one salt and the same constructor arguments on Ethereum, Robinhood Chain and Base:

| Argument           | Value                                                                              |
| ------------------ | ---------------------------------------------------------------------------------- |
| `_identityChainId` | `1` (Ethereum)                                                                     |
| `_nftContract`     | IDMD, the IdentityMD seat collection: `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` |
| `_imdToken`        | IMD: `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`                                  |
| `_feeRecipient`    | The first fee recipient, an address it controls on every chain                     |

The market's constructor deploys the vault implementation, so the market's address, and every
vault address it produces, follows from the salt, the arguments and the creation code. The creation
code depends on the build settings in `foundry.toml`, kept as they are: solc 0.8.26, EVM version
cancun, the optimizer at 200 runs, no IR pipeline, and `bytecode_hash = "none"`, which leaves the
metadata hash out so the code does not depend on file paths or comments.

## Operating the market

These are single calls, here with `cast`.

```
# Hand the protocol fee to a new recipient on one chain: propose from the current one, accept from the new one
cast send <market> "proposeFeeRecipient(address)" <newRecipient> --rpc-url <rpc> --account <current>
cast send <market> "acceptFeeRecipient()" --rpc-url <rpc> --account <new>

# As the fee recipient: recover ERC-20s or ERC-721s sent to the market by mistake
cast send <market> "rescueTokens(address)" <token> --rpc-url <rpc> --account <feeRecipient>
cast send <market> "rescueNft(address,uint256)" <collection> <tokenId> --rpc-url <rpc> --account <feeRecipient>

# As a vault's owner: recover another collection's NFTs sent to the vault
cast send <vault> "rescueNft(address,uint256)" <collection> <tokenId> --rpc-url <rpc> --account <owner>
cast send <vault> "rescueErc1155(address,uint256,uint256)" <collection> <id> <amount> --rpc-url <rpc> --account <owner>
```

## Layout

| Path                    | What it holds                                                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------------------- |
| `src/IMDLendMarket.sol` | Listings, takes, vault deployment, the fee recipient and its rescues                                      |
| `src/IMDLend.sol`       | The vault: custody, per-seat lendings, pairing, reward split                                              |
| `src/interfaces/`       | Each contract's structs, events and external API, with `pragma ^0.8.26` so other projects can import them |
| `src/libraries/`        | The custom errors of both contracts, and the EIP-712 hashing of a device pairing                          |

The only dependency is OpenZeppelin Contracts v5.7.0, a git submodule in `lib/` pinned in
`foundry.lock`.

## Building

Requires [Foundry](https://getfoundry.sh).

```
forge install   # OpenZeppelin Contracts v5.7.0, at the commit in foundry.lock
forge build
forge fmt --check
```

Not audited. The vaults take custody of NFTs, so they need an independent audit before mainnet use.

## License

MIT, see `LICENSE`.
