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
| Stream | `notify()` (anyone) streams all IMD not yet accounted over `REWARD_PERIOD` (7 days), pro rata by stake, per second. While a stream is running it only accepts new IMD worth at least a tenth of what is left, so nobody can stretch the payout for free; smaller deposits wait and are streamed once the threshold is met or the stream ends. A restart re-spreads what is left plus the new IMD over a fresh week, so the per-second rate can fall; whoever's IMD is waiting pays the threshold, and anyone may trigger it once it is met. One stream is capped at `MAX_STREAM` (1e40 wei) so a hostile reward token cannot overflow the reward math |
| Burn-match pool | `fund(amount)`, once (the script pins the amount at 100,000,000 SVO; for a Safe batch simulate it and check `1e26` before signing), only by the `funder` set at deploy (the founder's SVO; the contract accepts between `MIN_FUND` = 1,000,000 SVO and a tenth of the supply, so a wrong-unit amount cannot use up the one-time deposit); vests linearly over `MATCH_DURATION` (365 days) |
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

## Trust assumptions you should know about
- **IMD's owner can freeze claims.** IMD is an independent token. Its `owner()` is a single key
  (`0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`, no code, held by the IMD project's main developer) and IMD has
  `setBlocked(address,bool)`. If that key blocks this contract or a staker, `claim()` reverts for them. Staked SVO is
  unaffected: `unstake` moves only SVO. IMD earned by a blocked staker stays in the contract, counted as reserved, until the
  block is lifted: it is not redistributed and nobody can withdraw it. If the contract itself is blocked, later deposits are
  frozen too while `notify()` keeps succeeding, so the refuel Safe should check `blocked(staking)` before sending surplus. The same key could already block the vault or the pool; that predates staking.
- **The refuel Safe decides when the surplus is sent.** The vault is immutable and only the Safe can withdraw, so the
  contract cannot pull Solomon's overflow. `/tokenomics` shows the surplus still waiting in the vault.
- **The funder (a Safe) holds `reclaim()`** and the founder allocation until it is funded.
- **Fund one matcher only.** The burn-match reads `token.totalBurned()`, which counts every transfer to DEAD, including
  another matcher's. Two funded `SvoStaking` contracts on the same SVO would match each other's burns and drain both
  pools for gas only. Never fund a second one while another holds SVO; reclaim or exhaust the first.
- **Vault burns are matched.** `LifeForceVault.burn()` sends SVO to DEAD, so those burns count toward the match. This is
  intended.
- **Pin the address between deploy and fund.** `script/DeployStaking.s.sol fund()` checks that `STAKING_CONTRACT` stakes
  the expected SVO and rewards IMD, but a contract written to lie about that would pass. Compare the address with your own
  deploy transaction before the Safe batch.

## Audit notes
Reviews so far, all single-reviewer AI reviews, none a substitute for an independent human audit:
- 2026-10-10, two internal reviews. Fixed: free `notify()` could stretch a running stream (now needs new IMD of at least a
  tenth of the remainder); `claim` reverts if the reward token has no code; `AlreadyReclaimed` error; `unmatchedBurns()`
  is 0 after reclaim.
- 2026-10-10, external review of `8a3222d` (IMD job `6d08c511-9192-424f-95b3-c301eb934d36`): no critical or high
  findings. Acted on: the constructor now rejects `rewardToken == token`; the deploy script has no default funder, `fund()`
  checks the chain, the staked token and the reward token. Accepted: restarting a running stream costs a donor a tenth of
  the remainder in real IMD and only delays rewards (nothing is lost); truncation dust accumulates across updates (below a
  millionth of a token per update, negligible at 18 decimals).
- Accepted: a burn just before `reclaim()` makes the pool burn that much first, at an equal cost to the burner; with nothing
  else staked a staker of any size earns the whole stream; the same SVO can rotate across accounts to rent the access tier
  at about one new account per day; reward accounting assumes an 18-decimal IMD.

- 2026-10-10, IMD swarm audit of `6a980ca` (job `27aae9c4-e0db-4a83-b551-903d307b3205`: four specialists and a judge): no
  critical, high or medium findings; 3 low and 7 info, all reproduced. Acted on: `notify()` now rejects a stream above
  `MAX_STREAM` (a reward token reporting an absurd balance could otherwise overflow the reward math and lock `unstake`;
  unreachable with the real IMD); `fund()` now accepts only `MIN_FUND` to a tenth of the supply; `DeployStaking` pins the
  chain, the SVO and IMD addresses and the founder Safe (override only with `ALLOW_OTHER_FUNDER=true`) and refuses a
  `FUND_AMOUNT` below `MIN_FUND`; NatSpec now says `reclaim()` withdraws and that `notify()` restarts; `RewardAdded.streamed`
  now reports what is actually streamed; `Staked`/`Unstaked` use `accountTotal`. **These fixes were then checked by the final swarm round below.**

- 2026-10-10, final IMD swarm audit of `cfd73ae` (job `36b2abd5-7aa4-4924-9236-59ea60642f13`): no critical, high or medium
  findings; 1 low and 7 info, all reproduced. Acted on: `DeployStaking.fund()` now pins the amount at 100,000,000 SVO unless
  `ALLOW_OTHER_AMOUNT=true` (an in-bounds typo would fix the pool at the wrong size, permanently); the funder override is now
  `ALLOW_OTHER_FUNDER=<that exact address>`, so a leftover value cannot apply to another funder; the access-tier wording above
  now says what the age reset does and does not stop; the blocked-staker note above; test gaps filled (all stakers leaving
  mid-stream, reclaim with nothing left, partial unstake, burn-match fuzz). Not changed: the error names
  (`TransferFailed` for a failed `balanceOf`, `Unauthorized` for bad constructor arguments) are misleading but harmless; the
  launch README is hashed by the attestation and keeps its unqualified "no payouts" sentence, with the staking disclosure in
  this file and on the app's stake page. This file's wording and the script were fixed after the review; the contract's
  logic was not changed.

## Known properties
- Rewards depend on how much surplus exists. They can be zero, and the share per staked SVO falls as more is staked.
- If nothing is staked while a stream runs, that emission rolls into the next `notify()` instead of being lost.
- Adding to a stake restarts its age, so a pre-staged dust stake cannot be topped up for instant access. This does not stop renting the tier: any account that keeps `MIN_STAKE` staked for a day can use it and unstake at once. Unstaking is instant.
- Rounding dust (below a millionth of a token per update; it accumulates across updates and stays in the contract).
- Tokens sent by plain transfer other than IMD for `notify()`, or SVO other than via `fund`/`stake`, are stranded.
- The tier is read by the app from `hasAccess`; the 30-minute cap itself is enforced in the visitor's browser, like the 10-minute one.
- Tests: `test/SvoStaking.t.sol` (unit, misbehaving-IMD, burn-match and fuzz tests), `test/DeployStaking.t.sol` (the deploy and fund script, and a fork test against the real IMD: `FORK_4663_RPC=... forge test --match-contract StakingForkTest`). Run `forge test` for the current count.
