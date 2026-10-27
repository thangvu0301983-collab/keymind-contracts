# KEYMIND ($KMD): exact-version evidence for review

This page summarizes the evidence for KEYMIND's protected Ethereum launch. The machine-readable evidence is packed inside
the request as the attestation `exact-version-execution-evidence`
([`protected/keymind/evidence/exact-version.json`](../protected/keymind/evidence/exact-version.json)). It was produced by
[`test/KeymindExactVersion.fork.t.sol`](../test/KeymindExactVersion.fork.t.sol), and
[`programmable/pack-exact.mjs`](../programmable/pack-exact.mjs) reproduces it. This page is generated from that file
by [`programmable/evidence-page.mjs`](../programmable/evidence-page.mjs).

## Why the admission record says "static only"

The API accepts `behaviorExecution` only from Programmable's platform runtime executor, and caller-supplied proofs
cannot clear admission findings. On Ethereum the executor reports `BEHAVIOR_RUNNER_NOT_CONFIGURED`, so the
applicant cannot add runtime evidence to the admission record. It is provided here instead, bound to the exact request.

## How the evidence is bound to the exact version

1. `export-exact-fixture.mjs` reads the packed `launch.json` and produces the Router's graph targets with resolved
   init code and initializer calldata, in deployment order, plus the route namespace and nonce.
2. On an Ethereum mainnet fork (block 26285151), the test sends those exact targets to Programmable's
   GraphFactory (`0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887`), called as the 24h Router (`0xBE4bF6Ac8c6F012E1C8f25747A9fBccB2FDAC4C3`) with the launch
   wallet as `tx.origin`.
3. Every target is asserted at its predicted CREATE2 address with the packed runtime code hash.
4. Only the Router's permit signature check is not exercised.

The evidence file is part of the source bundle, which decides the addresses, so it records no target addresses. The
request is rebuilt and re-tested until the regenerated evidence is byte-identical to the packed file. Results:
20 of 20 exact-version scenarios pass, and 37 of 37 repository tests pass.

## 1. Permit window

The permit is valid from `validAfter` = 2026-10-28 16:55:02 UTC to `deadline` = 2026-10-29 16:55:02 UTC: 86,400 s, the 24h Router's
`MAX_PERMIT_LIFETIME`. The window opens about 24 hours after packing, so it covers the 24-hour review and then the
24-hour launch window.

## 2. Initial buy: bound call, observed input and output

| Item | Value |
|---|---|
| Bound call | `initialize(hook, token, 187440, developer, 6597454028649830624328022)`, value 0.05 ETH, executed by the GraphFactory in the launch transaction |
| Observed input | 50,000,000,000,000,000 wei |
| Observed output | 6,664,094,978,434,172,347,806,083 KMD units (6,664,094.97 KMD) to the developer, at or above the minimum and below the 2% cap (20,000,000 KMD) |
| Fees | platform 150,000,000,000,000 wei; creator 1,250,000,000,000,000 wei; opening tax 0 (developer exempt) |
| Opening price | FDV USD 17,011 at tick 187440 |
| Feed | Chainlink ETH/USD answer 234827950000, 2,868 s old (limit 3,600 s) |
| Floor | Launch passes while the answer is at least 207061823437 (11.82% below); one unit lower reverts with `OpeningValuationTooLow` |
| Oversized buy | A 0.5 ETH opening buy reverts the whole graph (`BuyerLimitExceeded`) |
| Short buy | A 0.045 ETH buy misses the bound minimum and reverts (`InvalidInitialBuy`) |

## 3. Twelve protection scenarios (P01–P12)

| # | Scenario | Result |
|---|---|---|
| P01 | USD 15,000 floor | Reverts one feed unit below the floor; passes at it |
| P02 | Fresh oracle | Feed older than 3,600 s reverts (`InvalidOraclePrice`); exactly 3,600 s is accepted |
| P03 | 2% opening-buy cap | Oversized opening buy reverts atomically; nothing is deployed |
| P04 | Minimum output | Underfunded buy reverts |
| P05 | Single atomic initialization | Initializer callable only by the GraphFactory, once; the pool cannot be re-initialized or cloned; the graph authorization cannot be replayed |
| P06 | 99% opening fee | 0.01 ETH buy at second 0: opening tax 0.00962 ETH, platform 0.00003 ETH, creator 0.00025 ETH (990,000 ppm) |
| P07 | Linear decay | Exact surcharge at seconds 1, 10, 20 and 29; zero from second 30 |
| P08 | Developer | Exempt from the surcharge but still capped: an over-cap buy reverts (`BuyerLimitExceeded`) |
| P09 | Cumulative buyer cap | Second buy over 2% reverts; selling does not refill the budget |
| P10 | Recipient cap | Over-cap transfer reverts (`WalletLimitExceeded`); forwarding does not refill |
| P11 | Canonical router only | For 300 s, buys through a test router or a raw PoolManager integration revert (`UnsupportedRouter`); the Universal Router works; sells use any route at normal fees |
| P12 | Expiry | Still protected at second 299; at second 300 a buy above 2% and a transfer above 2% succeed |

## 4. Swaps, liquidity, callbacks, accounting and the 0.3% fee

- **Four swap quadrants** (S01) and **a second user over time** (S02): exact-in and exact-out buys and sells at three
  sizes, interleaved users across 30 days and a year; every fee matches an independent reimplementation of the fee
  formula (gross native ETH, ceil per trade).
- **Liquidity custody and withdrawal** (L01): the seed position (liquidity 85,112,943,940,938,711,019,369) belongs to
  the initializer, which has no withdrawal entry point. A third-party LP adds and fully withdraws, losing at most
  1 wei of rounding on each side.
- **Callback authentication** (C01): hook callbacks revert unless called by the PoolManager; `afterSwap` is bound to
  the active swap; the module is kernel-only; fee vaults reject non-kernel records and unbound callbacks.
- **Custom accounting** (A01): recorded fees are backed one-to-one by PoolManager ERC-6909 claims; supply is conserved;
  an exact-output buy sent with 10 ETH pays exactly its gross (0.036516860737078985 ETH)
  and gets the rest refunded. Claims are caller-independent and reach only the fixed recipients: creator fees go to the
  KEYMIND Vault, platform fees and the opening tax to the treasury.
- **Exact 0.3% platform fee** (F01): the same trades through the Universal Router, a v4 test router and a raw
  PoolManager integration each pay exactly `ceil(gross × 30 / 10000)`: 3,000 ppm of
  21.72 ETH gross, no bypass and no overcharge.

## 5. KEYMIND Vault and Agent Grants (G01, A01)

The KEYMIND Vault is the fourth graph target and the hook's immutable creator-fee recipient. On the exact deployed
vault:

- `distribute()` (anyone) pays 80% to the project treasury wallet and keeps 20% as the Agent Grants pool
  (A01: 0.05752 ETH paid out, 0.01438 ETH kept).
- Only the guardian can propose a grant (recipient, amount, hash of its public description), at most 25% of the pool
  when proposed, and never to the treasury wallet, the guardian or the vault.
- A grant can be paid only after the 24-hour public review, never once cancelled, exactly once, and then by anyone
  (G01: 0.006312 ETH paid from a 0.02525 ETH pool).
- Changing the treasury wallet or the guardian takes a 48-hour public timelock, with no immediate exception. There is
  no other way to move ETH out of the vault.

The guardian chooses grant recipients; the review period, the per-grant cap and the excluded recipients limit that
trust but do not remove it. The project description in the request states this, and states who holds each role.

## Reproduce

Place the submitted bytes at `protected/launch.json` with its config, then run:

```bash
PL_DIR=<@programmable/launch 4.1.7> node programmable/export-exact-fixture.mjs
mkdir -p evidence/exact
ETH_RPC_URL=<archive RPC> FORK_BLOCK=26285151 forge test --json > forge.json
FORK_BLOCK=26285151 node programmable/collect-exact-evidence.mjs forge.json
```

`evidence/exact-version.json` then matches the packed `keymind/evidence/exact-version.json` byte for byte.
