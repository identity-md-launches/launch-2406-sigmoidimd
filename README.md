# SigmoidIMD — fair-launch hook and launchpad for Uniswap v4 on Robinhood Chain

A Uniswap v4 hook (`SigmoidIMD`) that protects the opening of token/IMD pools, a fixed-supply launch token
(`SigmoidToken`, name "SigmoidIMD", symbol "SIGMOID"), and a launchpad (`SigmoidLaunchpad`) that deploys new
tokens, opens their IMD pool on the hook and seeds the whole supply as single-sided liquidity.

Target chain: Robinhood Chain (chain id 4663), canonical PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`,
pair currency IMD `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`. Neither address is hardcoded in a contract: both
are constructor arguments and live as constants only in `script/Deploy.s.sol`.

## Layout

| Path | What |
| --- | --- |
| `src/SigmoidIMD.sol` | The hook. No owner, no switches, three immutables. |
| `src/SigmoidToken.sol` | Launch token, no constructor arguments, 1e27 minor units minted to the deployer. |
| `src/FixedSupplyERC20.sol` | Base of the launch token; the launchpad deploys instances with a chosen name/symbol. |
| `src/SigmoidLaunchpad.sol` | Launchpad: deploy token, initialize pool, seed single-sided liquidity, collect LP fees. |
| `src/HookMiner.sol` | Internal-only library that mines the CREATE2 salt for the hook address. |
| `script/Deploy.s.sol` | Reviewable deployment with Robinhood Chain constants; `deploy(Config)` is unit-tested. |
| `test/` | 60 tests (success and failure paths, two fuzz tests). |
| `lib/` | Vendored dependencies as plain files: v4-core, forge-std, OpenZeppelin 5.4.0, solmate `Owned.sol`. No git submodules; the upstream `.gitmodules` text files left under `lib/*/` are inert (git only reads the top-level one). |

Build and test:

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (v4-core needs transient storage), `bytecode_hash =
"none"`, `ffi = false`, no `fs_permissions`.

## What the hook does

One hook instance serves any number of pools. `beforeInitialize` accepts a pool only if one currency is IMD and the
other is an ERC-20 (it reads `totalSupply()`), at any LP fee, static or dynamic. It records the launch token, the
creation block, the wallet buy cap (0.5% of the total supply read at that moment) and the opening price.

The opening window is the first `OPENING_WINDOW_BLOCKS` = 100 blocks after pool creation (blocks `creation` to
`creation + 99`). Inside it:

1. **Dynamic fee.** Total fee = 0.30% + 150 × price impact, capped at 90%. On a dynamic-fee pool the LP fee is pinned
   to 0.30% (`BASE_LP_FEE`, returned as an override from `beforeSwap`); the surcharge (150 × impact, capped at
   89.7% so that the total is 90%) is charged by the hook in `afterSwap` with `afterSwapReturnDelta` and sent to the
   immutable `treasury`. Price impact is `|p_after − p_before| / p_before`, with `p_before` the last settled price.
2. **Circuit breaker.** A swap whose price impact against the last settled price exceeds `MAX_PRICE_MOVE_PIPS` = 25%
   reverts with `CircuitBreaker`. The settled price is the price at the end of the previous swap (the opening price
   for the first swap).
3. **Wallet protection.** A wallet may receive at most `MAX_BUY_BPS` = 0.5% of the token supply in total
   (`WalletBuyCapExceeded`), and may swap at most once every `SWAP_COOLDOWN_BLOCKS` = 3 blocks (`WalletCooldown`).
   Buys are counted net of the hook's fee; sells do not count.

Outside the window only the dynamic fee remains; the breaker, the cap and the cooldown switch off and their
bookkeeping stops.

### Where the surcharge is taken, and how it is paid

The surcharge comes out of the swap's *unspecified* currency, which is the only currency `afterSwapReturnDelta` can
touch: the output of an exact-input swap, the input of an exact-output swap. So an exact-input buy pays it in the
launch token, an exact-output buy and an exact-input sell pay it in IMD, an exact-output sell pays it in the token.
It is paid to the treasury at once with `poolManager.take` whenever the PoolManager holds enough of that currency.
When it does not (the first exact-output buy on a fresh manager seeded with tokens only, for instance) the hook mints
itself an ERC-6909 claim instead, records it in `pendingFees`, and anyone can later call `sweepFees(currency)` to
redeem it to the treasury. Nothing about this touches ETH, so a treasury that cannot receive ETH is not a problem;
the treasury must be able to hold ERC-20s (any EOA or ordinary contract).

### Hook configuration record (OpenZeppelin Wizard shape)

```json
{
  "hook": "BaseHook",
  "name": "SigmoidIMD",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": false, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

The hook does not inherit v4-periphery's `BaseHook` (not vendored); it implements `IHooks` directly with the same
shape: an `onlyPoolManager` modifier on every callback, `Hooks.validateHookPermissions` in the constructor, and
reverting stubs for the callbacks it does not enable. `beforeInitialize` was added because a launch hook needs an
initialization callback; `afterSwap` + `afterSwapReturnDelta` because the surcharge is charged after the swap when
the price impact is known. The hook address must carry flags `0x20C4` (beforeInitialize, beforeSwap, afterSwap,
afterSwapReturnDelta); `HookMiner.find` / `DeploySigmoid.mineHookSalt` produce the CREATE2 salt. No access control:
there is nothing to administer.

## Named constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `OPENING_WINDOW_BLOCKS` | 100 | Protected blocks after pool creation (brief). |
| `SWAP_COOLDOWN_BLOCKS` | 3 | Blocks between two swaps of one wallet inside the window (brief). |
| `MAX_BUY_BPS` | 50 | 0.5% of the supply per wallet inside the window (brief). |
| `BASE_LP_FEE` | 3000 | 0.30% LP fee pinned on dynamic-fee pools (brief). |
| `IMPACT_MULTIPLIER` | 150 | Surcharge = 150 × price impact (brief). |
| `MAX_TOTAL_FEE` | 900000 | 90% cap on LP fee + surcharge (brief). |
| `MAX_PRICE_MOVE_PIPS` | 250000 | 25% circuit breaker (brief). |
| `SigmoidLaunchpad.TICK_SPACING` | 60 | Tick spacing of launchpad pools (chosen). |
| `FixedSupplyERC20.TOTAL_SUPPLY` | 1e27 | 1,000,000,000 tokens at 18 decimals (brief). |

## Deployment parameters

| Contract | Constructor arguments | Robinhood Chain value |
| --- | --- | --- |
| `SigmoidToken` | none | — |
| `SigmoidIMD` | `poolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` (manifest: `$poolManager`) |
| | `pairCurrency` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (IMD) |
| | `treasury` | the requester's treasury; the brief names none, so the launch owner (manifest: `$owner`) |
| `SigmoidLaunchpad` | `poolManager`, `hook` | the PoolManager above and the deployed hook |

The hook's constructor calls no other contract and does not check the chain id, so it can be built on an empty
chain. `DeploySigmoid.run()` refuses any chain but 4663, reads `TREASURY` from the environment, mines the salt for
forge's CREATE2 deployer and deploys the three contracts. Tests call `deploy(Config)` directly with their own
PoolManager and never read the environment.

For an IMD launch the factory opens the pool at the launch policy's static LP fee (12500, 1.25%); the hook accepts
it. The brief's "0.30% base" then does not apply to the LP side: LPs earn 1.25% and the hook's surcharge
(150 × impact, capped at 89.7%) comes on top. On pools the launchpad opens, the fee is the dynamic flag and the hook
pins the LP fee to 0.30%, exactly as the brief describes.

## Assumptions and deviations

- **Blocks on Robinhood Chain.** Robinhood Chain is Arbitrum Nitro, where `block.number` is the L1 (Ethereum) block
  number, advancing roughly every 12 seconds, not the ~100 ms L2 block. The window of 100 blocks is therefore about
  20 minutes and the cooldown of 3 blocks about 36 seconds. The brief counts in blocks, so the hook does too; if the
  requester meant L2 blocks the constants need to change (and `ArbSys.arbBlockNumber()` would have to replace
  `block.number`).
- **Wallet identity is `tx.origin`.** Hook callbacks only see the router as `sender`, and anything a router passes in
  `hookData` is caller-chosen. `tx.origin` is the only identity the hook can observe that costs the trader a funded
  account to change. It is not sybil-resistant: a sniper with many funded EOAs gets many caps. Smart-contract wallets
  and account-abstraction bundlers share one `tx.origin`, so users behind the same bundler share one cap and one
  cooldown during the window. `tx.origin` is used only to key limits, never to grant anything.
- **Fee currency.** The brief does not say which currency the surcharge is paid in. It is paid in the swap's
  unspecified currency (see above), not converted to ETH or IMD. Converting it in-swap would need an IMD/ETH pool and
  owner-set price bounds, which the brief does not ask for.
- **Total supply for the cap** is read once at pool creation. For the launch token it is fixed, so this is exact.
- **Price impact** is measured over the whole swap against the price at the end of the previous swap. Liquidity
  changes never move the price in v4, so this equals the pre-swap price.
- **The launch token is standard.** Fees, limits and the window live in the hook; the token has no mint, owner,
  pause, blocklist, fee or upgrade. The brief asked for nothing else of it.
- **Single-sided seeding.** The launchpad places the entire 1e27 supply in a range on the token side of the opening
  price (at or above it when the token sorts as currency0, at or below when it sorts as currency1). A few wei of
  rounding dust go to the creator. The range becomes active with the first buy when the token is currency1. The
  position is locked in the launchpad forever; the creator can only collect its LP fees.
- **Which side the token sorts on** depends on the new token's address versus IMD's. Callers predict the address
  from the launchpad's nonce (`vm.computeCreateAddress` in tests) or simulate, then pass a price and range for the
  resulting side; the wrong side reverts with `RangeNotSingleSided`.
- **Chain and pair.** The brief names Robinhood Chain and IMD at `0x5F7B…7127`. Where the assignment's reference
  material described an Ethereum mainnet launch instead, the brief was followed. The IMD address was not verified
  on chain from this machine (no RPC access in the sandbox); it is a deployment parameter, not a compiled constant.
- **The hook's own bytecode** contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, is about 8.5 KB of runtime
  code under the pinned settings, and all library calls are internal, so it deploys unlinked.

## Operational responsibilities

- **Treasury.** Immutable. Pick it before deploying; it must hold ERC-20s. Nothing is paid in ETH.
- **Sweeping claims.** When a surcharge could not be paid out at once it sits as an ERC-6909 claim on the hook.
  Watch `SurchargeCollected(..., direct = false)` and `pendingFees(currency)`, and call `sweepFees(currency)` (anyone
  may) once the PoolManager holds that currency. Claims never expire.
- **Hook address.** The deployed address must carry flags `0x20C4`; the constructor reverts otherwise. Mine the salt
  for the actual deployer (`mineHookSalt(deployer, cfg)`), since CREATE2 addresses depend on it.
- **After launch.** There are no owner-set values. The hook's constants cannot change; a new policy means a new hook
  and new pools.
- **Monitoring.** `LaunchRegistered`, `PriceSettled`, `SurchargeCollected`, `FeesSwept` on the hook; `Launched`,
  `FeesCollected` on the launchpad.
- **Audit.** Tests passing are not an audit. The hook charges fees with a return delta (HIGH risk in the v4 security
  matrix) and the launchpad holds locked liquidity; both need independent adversarial review before holding other
  people's funds. Slither/Mythril were not run here (not available offline in this environment).

## Tests

`test/SigmoidIMD.t.sol` (38): permissions vs. address flags, immutables, zero-address and wrong-address constructor
reverts, non-manager callers refused on every callback, disabled callbacks revert, pool registration, static-fee
initialization from an arbitrary factory, rejection of non-IMD / native / non-ERC-20 pools, base-fee-only tiny swap,
surcharge amount and currency for all four swap shapes, the 90% cap, the fee formula, two fuzz tests (surcharge
never exceeds the cap; price impact never reverts across the whole sqrt-price domain), circuit breaker trip / exact
revert reason / 25% boundary / off outside the window / measured from the settled price, buy cap (block, allow up to
cap, cumulative, net of fee, sells excluded, off outside window), cooldown (block, reason, per wallet, off outside
window), window edge, sweep with nothing pending.

`test/SigmoidLaunchpad.t.sol` (12): full launch flow (token, pool, position, dust), wrong-side and straddling
ranges, unknown launch, non-manager callback, in-window buy on a fresh manager with the claim fallback and sweep,
direct payout on exact input, window rules on a launched pool, sell into empty liquidity, fee collection
(creator only, liquidity stays locked), independent windows per launch.

`test/SigmoidToken.t.sol` (6) and `test/Deploy.t.sol` (4): supply, metadata, transfers, absence of admin
functions; deployment wiring, wrong salt, chain constants, chain guard.

Run with the verifier's seed: `FOUNDRY_FUZZ_SEED=0xcee2929ce61ec564c4f0162b467c3ffeea6cc01c5f6714289427872bb7af9b45 forge test`.
