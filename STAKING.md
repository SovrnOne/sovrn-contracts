# SvoStaking (separate from the launch contracts)

`src/SvoStaking.sol` is a post-launch contract. It is not part of the launch build in `launch-attestation.json` and is not
covered by `README.md`, whose statement that the *launch contracts* pay SVO holders nothing stays true of the token, hook and
vault. This contract lets SVO stakers share Solomon's overflow, and holds the founder allocation as a burn-match pool.
**No audit is claimed.**

| Item | Value |
| --- | --- |
| Staked and matched token | SVO (`SovrnToken`), immutable constructor argument |
| Reward token | IMD (constructor argument `rewardToken`) |
| Rewards source | Solomon's overflow: IMD the refuel Safe withdraws from the vault's inference reserve above the "full health" level and sends here |
| Stream | `notify()` (anyone) streams all IMD not yet accounted over `REWARD_PERIOD` (7 days), pro rata by stake, per second. While a stream is running it only accepts new IMD worth at least a tenth of what is left, so nobody can stretch the payout for free; smaller deposits wait and are streamed once the threshold is met or the stream ends |
| Burn-match pool | `fund(amount)`, once, only by the `funder` set at deploy (the founder's SVO, up to 10% of supply); vests linearly over `MATCH_DURATION` (365 days) |
| Access tier | `hasAccess(a)`: at least `MIN_STAKE` (1,000,000 SVO) staked and the stake at least `MIN_STAKE_AGE` (1 day) old |
| Admin | none: no owner, no pause, no upgrade. The one funder power is `reclaim()` (below) |

## Overflow: what is and is not enforced on chain
The `LifeForceVault` is immutable and only `REFUEL_SAFE` can withdraw from it, so **the contract cannot pull the surplus**.
The Safe sends it (an IMD transfer to this contract), then anyone calls `notify()`. What is enforced: once IMD is here it can only
go to stakers (via `claim`); there is no other exit. What is a Safe commitment, not a contract guarantee: that the Safe sends
the surplus. The app's `/tokenomics` shows the surplus still waiting in the vault (`inferenceReserve() - LIFE_FORCE_FULL_WEI`)
so a gap is visible to everyone. "Full health" is a number the app publishes (`LIFE_FORCE_FULL_WEI`); it is not in any contract.

## How tokens can leave the contract
SVO: `unstake` returns a staker's principal; `matchBurn` sends match-pool SVO to DEAD; `reclaim` (below) returns the unmatched
remainder of the pool to the funder, once, a year after `fund()`. Nothing else.
IMD: `claim` pays a staker's earned rewards. Nothing else.
`unstake` moves only SVO, so a misbehaving IMD (blocklist, pause) can block `claim` but never a staker's principal.

## Burn-match
`matchBurn()` is permissionless. It reads `token.totalBurned()` and matches the increase since the last call (burns before
funding are ignored; this contract's own burns are never matched), capped by the part of the pool that has vested. An
unmatched remainder carries forward. After `MATCH_DURATION` the whole pool is available.

## Reclaim
`reclaim()` is callable only by the funder, only once, and only when `MATCH_DURATION` (365 days) has passed since `fund()`. It first
matches any burns still waiting (so it can never cut one off), then sends the unmatched remainder of the pool to the funder and
closes the pool (`matchTotal` becomes `matchUsed`; later burns are not matched). It cannot touch staked SVO or IMD rewards. The
reclaimed SVO is ordinary SVO in the funder's wallet; whether it is held, burned or sold is up to the funder.

## Audit notes (2026-10-10, independent review plus own pass)
No critical or high findings; staked SVO cannot be taken or locked. Fixed: free `notify()` could stretch the stream (now needs real new IMD of at least a tenth of the remainder); `claim` now reverts if the reward token has no code; `reclaim` has its own `AlreadyReclaimed` error; `unmatchedBurns()` is 0 after reclaim. Accepted and documented:
- A burn made just before `reclaim()` is matched first, so anyone can make the pool burn up to the whole remainder at a cost to them equal to the amount burned (it is destroyed together with the pool's equal burn).
- While nothing else is staked, a staker of any size, even 1 wei, earns the whole stream; later stakers share it pro rata from when they join.
- Reward accounting assumes an 18-decimal reward token (per-update rounding is at most `totalStaked / 1e18` wei).
- Tier rental is limited, not removed: the same SVO can rotate across accounts at about one new account per day.

## Known properties
- Rewards depend on how much surplus exists. They can be zero, and the share per staked SVO falls as more is staked.
- If nothing is staked while a stream runs, that emission rolls into the next `notify()` instead of being lost.
- Adding to a stake restarts its age (stops stake-wait-unstake rental of the tier). Unstaking is instant.
- Rounding dust (below a millionth of a token) stays in the contract.
- Tokens sent by plain transfer other than IMD for `notify()`, or SVO other than via `fund`/`stake`, are stranded.
- The tier is read by the app from `hasAccess`; the 30-minute cap itself is enforced in the visitor's browser, like the 10-minute one.
- Tests: `test/SvoStaking.t.sol` (unit, a misbehaving-IMD case, fuzz solvency).
