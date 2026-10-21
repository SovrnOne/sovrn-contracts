# OverflowKeeper (Safe module for Solomon's overflow)

`src/OverflowKeeper.sol` is a post-launch contract, like `SvoStaking` (`STAKING.md`). It is not part of the launch build in
`launch-attestation.json`. **No audit is claimed**: three independent AI adversarial reviews plus one IMD swarm audit round
(2026-10-20, see "Review notes") and 49 Foundry tests, no human audit.

## What it is
The `LifeForceVault` is immutable and only `REFUEL_SAFE` (`0xEb57c52272B90F989C41B739e2ccc5f00bF7697C`, 2-of-3) can withdraw
from it. Moving Solomon's overflow to stakers therefore needed a Safe batch (withdraw, transfer, notify) signed by two owners
every time, and twice it got stuck in the queue. The keeper is a **Safe module**: once the owners enable it (one
`enableModule(keeper)` transaction), `sweep()` is permissionless and makes the Safe do the three steps with no signatures.

| Item | Value |
| --- | --- |
| Authority over the Safe | exactly three CALLs, `value = 0`, never delegatecall: `vault.withdrawInference(x)`, `IMD.transfer(caller, fee)`, `IMD.transfer(staking, x - fee)` |
| `x` | `vault.inferenceReserve() - full`, computed on chain at execution time; `withdrawInference` itself refuses more than the reserve |
| `full` | 25 IMD at deploy (the app's `LIFE_FORCE_FULL_WEI`); `setFull`, Safe only |
| `minSweep` | 1 IMD at deploy; `setMinSweep`, Safe only, floor `MIN_SWEEP_FLOOR` = 607,840 wei |
| Caller fee | `FEE_BPS` = 50 (0.5%) of each sweep, to `msg.sender`, out of the withdrawn IMD; the Safe itself may call `sweep()` and then pays no fee |
| Safe float | enforced unchanged: the sweep reverts `SafeBalanceMismatch` unless exactly `x` arrived from the vault and the Safe ends with the IMD it started with (so a fee-on-transfer IMD, or a Safe reporting success for a failed call, cannot spend the Safe's own IMD) |
| notify() | called only when SvoStaking will accept it (same checks mirrored, including emission that ran with nobody staked); otherwise the IMD waits in the staking contract and the next big enough sweep streams it. A sweep never reverts on the staking rules, with one bound: a sweep that would push the next stream over `MAX_STREAM` (1e40 wei, unreachable with real IMD) reverts `InvalidAmount` rather than park IMD that could never be streamed |
| Blocklist | `sweep()` reverts `Blocked` and `preview().ready` is false when IMD's `blocked()` is set for the vault, the Safe or the staking contract (any non-zero answer counts; a missing function counts as not blocked) |
| `preview().ready` | false whenever `sweep()` would revert: module not enabled on the Safe (`isModuleEnabled`), below `minSweep`, a blocked party, or the `MAX_STREAM` bound |
| Owner / upgrade / tokens held | none / none / none |
| Off switch | the Safe: `disableModule(prev, keeper)` (2-of-3), or `setFull(huge)` to pause without disabling |

What it cannot do: touch the Safe's ETH or any other token, change owners, threshold, guards or other modules, delegatecall,
withdraw buyback, take the inference reserve below `full`, or hold anything. Enabling it does mean: **any overflow present is
sweepable the moment `enableModule` executes**, and a later `setFull`/`disableModule` is a visible Safe transaction that a sweep
can land before. Set `full` to the real voice budget before enabling; if the Safe needs more than `full` for a voice bill, raise
`full` (or withdraw) in the same batch as `enableModule`, not after.

Economics: 0.5% of a 1 IMD sweep is 0.005 IMD, so no bot will race for it; the team, a cron, or the admin page button is the
realistic caller. Each sweep that meets SvoStaking's one-tenth rule re-spreads what is left plus the new IMD over a fresh week,
so with the keeper on the stream is in effect perpetual with a lag of up to 7 days; stakers lose nothing in total.

## Deployment
Deployed on Robinhood Chain (4663) on 2026-10-21 from commit `b0022c1` (the swarm-audit fixes on top of the audited
`90746ea`): **`0xb2c0A96C6AD46883F8aB3BCd399AEe71C60582D4`** (tx
`0xc1de93686dbfc7658abf295cf2c1f34ddf11e0032691e00eb431d6ed81ec1928`, block 93,853,600, 1,218,477 gas), deployed by
`0x566d…4A92` (the IMD payer wallet; it has no power over the contract). Constructor: vault
`0x2001318118e1B3DF1e653E0999926bdAa48A5A52`, staking `0xe8ebB026Ff49f139aBc50C3Af64bdFebbF28f533`, full
`25000000000000000000` (25 IMD), minSweep `1000000000000000000` (1 IMD). Read back after deploy: `SAFE()`, `IMD()`,
`vault()`, `staking()`, `full()`, `minSweep()`, `FEE_BPS()` = 50, `MIN_SWEEP_FLOOR()` = 607,840 all as expected;
`Safe.isModuleEnabled(keeper)` = false. Bytecode: the on-chain runtime (5,016 bytes) equals the local build of `b0022c1`
except the 10 compiler-marked immutable slots (200 bytes), which decode to the vault and staking addresses above; nothing
else differs. Source verified on Sourcify (full match) and on Etherscan (`https://robin.etherscan.io/address/0xb2c0A96C6AD46883F8aB3BCd399AEe71C60582D4#code`), both on 2026-10-21.

**Not enabled.** The module does nothing until the refuel Safe runs `enableModule(0xb2c0A96C6AD46883F8aB3BCd399AEe71C60582D4)`
(Runbook C). Record the enable transaction and date here when that happens.

Constructor args (vault, staking, full, minSweep), ABI-encoded for Etherscan (`cast abi-encode "constructor(address,address,uint256,uint256)" 0x2001318118e1B3DF1e653E0999926bdAa48A5A52 0xe8ebB026Ff49f139aBc50C3Af64bdFebbF28f533 25000000000000000000 1000000000000000000`):
`0000000000000000000000002001318118e1b3df1e653e0999926bdaa48a5a52000000000000000000000000e8ebb026ff49f139abc50c3af64bdfebbf28f5330000000000000000000000000000000000000000000000015af1d78b58c400000000000000000000000000000000000000000000000000000de0b6b3a7640000`

## Runbook A: deploy and record
1. In `~/sovrn-contracts` at a committed HEAD: `forge build`, `forge test --match-path 'test/*Keeper*'` (49 tests).
2. Dry run: `forge script script/DeployKeeper.s.sol --sig "run()" --rpc-url https://rpc.mainnet.chain.robinhood.com` (no
   `--broadcast`). The log must show `full (wei) 25000000000000000000`, `minSweep (wei) 1000000000000000000` and NO
   "WARNING: non-default settings" line; `env | grep -E 'KEEPER_|ALLOW_OTHER'` must be empty (a non-default value needs
   both `KEEPER_FULL` and `ALLOW_OTHER_FULL` set to the same wei; one alone is refused).
3. Broadcast from any funded EOA (the deployer gets no power): add `--private-key $KEY --broadcast`. The script reads the
   deployed settings back and reverts if they differ. Record the address, tx, block, commit from
   `broadcast/DeployKeeper.s.sol/4663/run-latest.json`.
4. Read back with `cast call <keeper> ... --rpc-url $RPC`: `SAFE()` = `0xEb57…97C`, `IMD()` = `0x5F7B…7127`, `vault()` =
   `0x2001…5A52`, `staking()` = `0xe8eb…8533`, `full()` = 25e18, `minSweep()` = 1e18, `FEE_BPS()` = 50, `preview()` sane;
   `cast call <SAFE> "isModuleEnabled(address)(bool)" <keeper>` = false.
5. Bytecode check (the STAKING.md method): `cast code <keeper>` against `out/OverflowKeeper.sol/OverflowKeeper.json`
   `.deployedBytecode.object`; the only differing words are the two immutables (`vault`, `staking`), see
   `.deployedBytecode.immutableReferences`. Nothing else may differ.
6. Also record `IMD.blocked(x)` for the vault, the Safe and the staking contract at that time.

## Runbook B: verify source
Settings: solc 0.8.26, cancun, optimizer 200 runs, via-IR, bytecodeHash none.
1. Sourcify: `forge verify-contract --verifier sourcify --chain-id 4663 <keeper> src/OverflowKeeper.sol:OverflowKeeper --constructor-args 0x<args above>`.
2. Etherscan (forge 1.5 cannot target chain 4663 directly): `forge verify-contract --show-standard-json-input <keeper> src/OverflowKeeper.sol:OverflowKeeper > std.json`, then POST `https://api.etherscan.io/v2/api?chainid=4663` with
   `module=contract&action=verifysourcecode&codeformat=solidity-standard-json-input&contractname=src/OverflowKeeper.sol:OverflowKeeper&compilerversion=v0.8.26+commit.8a97fa7a`, `sourceCode=<std.json>`, `constructorArguements=<args without 0x>`; poll `checkverifystatus`.
3. On `https://robin.etherscan.io/address/<keeper>#code` confirm the source is `OverflowKeeper` and Read shows `full` = 25e18.

## Runbook C: enable (one Safe tx, 2-of-3)
What is signed: `to` = the Safe itself, `value` 0, operation Call, `data` = `cast calldata "enableModule(address)" <keeper>`
(selector `0x610b5925`). Nothing else in the batch, unless `setFull` is deliberately batched with it (see above).
1. **Each signer independently**: open the verified source on the explorer, read `vault()`, `staking()`, `full()`,
   `minSweep()`, `SAFE()` and compare the full 40-hex keeper address character by character with the deploy record.
   A wrong address enabled as a module has full Safe authority (any call, any value, delegatecall) and can drain the Safe
   and, through it, the vault. The constructor's own checks can be mimicked by a look-alike; only the read-back protects you.
2. Queue it from the Safe{Wallet} UI on the refuel Safe `…97C` (not the Operations Safe `0x589A…8DA0`): Transaction
   Builder, address = the Safe's own address, method `enableModule(address)`, module = keeper. Or from the admin page's
   Keeper card inside the Safe app (Enable).
3. Before the second signature, decode the data in the Safe UI: `to` equals the Safe, method `enableModule`, argument the
   keeper, operation Call, value 0.
4. After execution: `isModuleEnabled(keeper)` = true; `getModulesPaginated(0x…01, 50)` lists only the keeper.
5. First sweep under supervision: `preview()`, then `sweep()` from any wallet (gas only; from the Safe itself it works
   too and pays no fee). Check the `Swept` log, vault
   `inferenceReserve()` == 25e18, staking `unnotified()`/`streamRemaining()` moved, the Safe's IMD unchanged, the caller got
   0.5%. Then set `OVERFLOW_KEEPER=<address>` on the VPS `.env.local` and restart (`./sovrn.sh restart`).

## Runbook D: disable
`disableModule(prevModule, keeper)`: `prevModule` is the entry before the keeper in the Safe's module list
(`getModulesPaginated(0x0000000000000000000000000000000000000001, 50)`; the first entry's predecessor is the sentinel
`0x…01`). With the keeper as the only module: `disableModule(0x0000000000000000000000000000000000000001, <keeper>)`,
selector `0xe009cfde`, `to` = the Safe, value 0, Call. The Safe{Wallet} UI (Settings, Modules, Remove) computes
`prevModule` itself; so does the admin page's Keeper card. Afterwards `sweep()` reverts `GS104` and `preview().ready` is
false. There is no single-key kill
switch; disabling is 2-of-3 like any Safe transaction. A cheaper pause is `setFull(<huge>)`, which makes `overflow()` 0.

## Runbook E: incident (module enabled, something is wrong)
1. First queue and sign `disableModule` (Runbook D), before diagnosis. If it is only a wrong `full`, `setFull` is enough.
2. Unset `OVERFLOW_KEEPER` on the VPS and restart, so `/admin` falls back to the manual batch; do not touch `LIFE_FORCE_FULL_WEI`.
3. Measure: `Swept` logs since enable, vault `inferenceReserve()`, staking `unnotified()`, `streamRemaining()`,
   `totalNotified()`, the Safe's IMD balance. IMD the keeper moved is in SvoStaking and can only go to stakers via `claim()`;
   there is no recovery path; the only "undo" is refuelling the vault from the Safe's own IMD (plain transfer, re-split 70/30).
4. Check the Safe's module list, owners, threshold and guards. The keeper cannot change these; if they changed, the problem is
   a key, not the module.
5. Fix forward: deploy a new keeper (new address, new `enableModule`); never "upgrade"; list the old one here as retired.

## Review notes
2026-10-20, three independent AI adversarial reviews of the first draft (authority and economics; integration with the vault,
the staking contract and Safe 1.5.0 module semantics; deployment and operations). No critical or high finding. Fixed before any
deployment: (1) the Safe's own IMD was assumed, not enforced, to stay untouched: now `SafeBalanceMismatch` reverts a sweep in
which less than `amount` arrived or the Safe would end with less than it started (covers a fee-on-transfer IMD and a Safe or
guard that reports success for a failed inner call); (2) the constructor accepted a staking contract for another token: now it
must stake the vault's token; (3) a non-bool `blocked()` answer panicked `preview()` and `sweep()`: any non-zero word now reads as
blocked; (4) `MIN_SWEEP_FLOOR` was quoted before the fee, so a floor-sized sweep parked: now grossed up (607,840 wei);
(5) the notify() mirror read `undistributed` before notify()'s own fold of emission that ran with nobody staked: now folded
identically, so the prediction is exact; (6) `preview().ready` ignored a blocked vault or Safe: now covers all three parties.
Deploy script: settings pinned with exact-value overrides only, wei-unit floors, read-back after broadcast. Found sound: the
view/withdraw reserve math under shortfall and untracked IMD (fuzzed), fee linearity (no farming or timing edge), parked IMD is
never stranded, atomicity against a hostile IMD, re-entrancy, Safe 1.5.0 return-data and GS104 semantics, module-guard veto,
no delegatecall path, gas (about 310k with notify, 110k parked, as measured by `test_sound_sweepGas`).

2026-10-20, IMD swarm audit (template `audit`: four specialists and a judge; job `5fff9f74-06f9-4039-a489-d9c24b45c9df`,
commit `90746ea`; report at `https://raw.githubusercontent.com/Identity-md/research/main/jobs/5fff9f74-06f9-4039-a489-d9c24b45c9df/files/AUDIT.md`).
Result: 3 low, 3 info, no critical, high or medium. All six fixed before deployment: (1) the Safe calling `sweep()`
itself always reverted (the fee was a Safe-to-Safe transfer, so the balance invariant failed): the Safe now pays no fee;
(2) `preview().ready` was true while the module was not enabled, so a poller would send reverting sweeps: it now reads
`isModuleEnabled`; (3) the deploy script's `ALLOW_OTHER_*` were plain overrides, not the exact-value confirmation the
comment claimed: a non-default value now needs `KEEPER_*` and `ALLOW_OTHER_*` to agree; (4) IMD parked above `MAX_STREAM`
could never be streamed again: a sweep that would cross the bound now reverts instead of forwarding, and `ready` says so;
(5) stale test count and gas figures here; (6) the deploy script said a not-yet-enabled keeper reverts `SafeCallFailed`;
it is the Safe's `GS104`. Acceptance by the swarm means the report met the job's checks, not that the code has no other
defects.
