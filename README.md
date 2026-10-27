# KEYMIND contracts

KEYMIND ($KMD) is an open peer-to-peer protocol for AI agents to discover each other, communicate privately and settle
payments per task. This repository holds the exact sources of the $KMD launch graph for the
[Programmable](https://programmable.market) Ethereum Custom Launch, and the KEYMIND Vault.

## Launch graph (`protected/`)

Programmable requires every new native-ETH launch to use its sealed launch-protection package v1
(`@programmable/launch` 4.1.7). $KMD uses that package unchanged, plus one KEYMIND contract:

| Target | Contract | Role |
|---|---|---|
| `initializer` | `ProtectedNativeInitializerV1` (Programmable) | USD 15,000 opening floor on the Chainlink ETH/USD feed, 100% of supply as one locked position, the capped opening buy |
| `token` | `ProtectedLaunchTokenV1` (Programmable) | $KMD, 1,000,000,000 fixed supply; 2% receive cap per wallet for 300 seconds |
| `hook` | `ProtectedNative30HookV1` (Programmable) | 0.30% platform fee + fixed 2.5% creator fee on buys and sells; 99% opening buy fee decaying to normal in 30 seconds; 2% per-buyer cap for 300 seconds |
| `vault` | `src/KeymindVault.sol` (KEYMIND) | The hook's immutable creator-fee recipient |

Only one value differs from Programmable's own helper output: the creator-fee recipient is the KEYMIND Vault instead
of the launch wallet.

## KEYMIND Vault (`src/KeymindVault.sol`)

- **Split.** `distribute()`, callable by anyone, pays 80% of new creator fees to the project treasury wallet
  (team, development, operations and marketing) and keeps 20% in the vault as the Agent Grants pool.
- **Agent Grants.** The guardian proposes a grant: a unique id, the recipient, the amount and the hash of its public
  description. The amount is at most 25% of the pool when proposed, and the recipient can never be the treasury
  wallet, the guardian (current or pending) or the vault. After a 24-hour public review, during which the guardian can
  cancel it, anyone can execute the grant; it is paid once.
- **Timelocks.** Changing the treasury wallet or the guardian takes a 48-hour public timelock with no immediate
  exception; a treasury change distributes pending fees to the old treasury first. There is no other way to move ETH
  out of the vault. Reentrancy-guarded; no immutables.

The protocol layers (identity, discovery, messaging, settlement, reputation), registry staking, relay rewards,
arbitration and governance are planned and not part of the launch graph.

## Build and test

Foundry, solc 0.8.26, optimizer 1000, `cancun`, no via-IR, no CBOR metadata. Dependencies are vendored in `lib/`.

```bash
forge test --no-match-contract KeymindExactVersionForkTest
```

`test/KeymindVault.t.sol` covers the split, grant proposal rules and caps, the review period, cancellation, excluded
recipients, pool exhaustion, both timelocks, reentrancy by the treasury and by a grantee, and zero addresses, with
fuzzing of the split and of the per-grant cap.

## Packing the Programmable request

`programmable/build-protected.mjs` reproduces Programmable's `buildProtectedEthereumLaunchV1` with the KEYMIND Vault as
the fourth target, writes `protected/` and `protected/protected-launch.config.json`, and verifies every predicted
address with the CLI library. The project description (`programmable/description.txt`) states who holds each vault
role; the build fills that part from the role addresses' on-chain code (ordinary wallet or smart-contract wallet).

## Exact-version execution evidence

Reviewer summary: [docs/EXACT-VERSION-EVIDENCE.md](docs/EXACT-VERSION-EVIDENCE.md).

`programmable/pack-exact.mjs` packs the request together with execution evidence for that exact request:

1. `build-protected.mjs` writes `protected/` (nonce, permit window and opening tick pinned by `LAUNCH_NONCE`,
   `VALID_AFTER`, `DEADLINE`, `START_TICK`), and the CLI packs `protected/launch.json`.
2. `export-exact-fixture.mjs` turns that `launch.json` into `test/fixtures/exact-launch.json`: the Router's graph
   targets with resolved init code and initializer calldata, in deployment order, plus the route namespace and nonce.
3. `forge test` runs everything. `test/KeymindExactVersion.fork.t.sol` deploys those exact targets through
   Programmable's GraphFactory on a mainnet fork (pinned by `FORK_BLOCK`), called as the 24h Router with the launch
   wallet as `tx.origin`, and asserts each target's CREATE2 address and runtime code hash. Scenarios: the bound
   initial buy; twelve protection scenarios; four swap quadrants at three sizes; a second user over a year; liquidity
   custody; callback authentication; fee backing, refunds and claims into the KEYMIND Vault and its 80/20 split;
   Agent Grants on the deployed vault; and the exact 0.30% platform fee on every route.
4. `collect-exact-evidence.mjs` writes `evidence/exact-version.json` (no target addresses) and
   `evidence/forge-tests.json`, which the next build packs as attestation evidence.

The loop repeats until the regenerated evidence is byte-identical to the packed evidence.
`programmable/evidence-page.mjs` then writes the reviewer page from the packed evidence.

On Windows run the CLI with `node --import programmable/win-dir-fsync-shim.mjs <cli>`.

## License

KEYMIND sources: MIT. Vendored dependencies keep their own licenses.
