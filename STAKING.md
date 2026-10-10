# SvoStaking (separate from the launch contracts)

`src/SvoStaking.sol` is a post-launch contract. It is not part of the launch build in `launch-attestation.json` and is not
covered by `README.md`, whose statement that the *launch contracts* pay SVO holders nothing stays true of the token, hook and
vault. This contract is where the founder allocation (10% of supply) is used to reward stakers and to match burns. **No audit
is claimed.**

| Item | Value |
| --- | --- |
| Token | SVO (`SovrnToken`), immutable constructor argument |
| Funding | `fund(amount)`, callable once, only by the `funder` set at deploy; needs an SVO allowance |
| Split | 60% reward stream, 40% burn-match pool (the division remainder of the reward rate goes to the match pool) |
| Schedule | `DURATION` 365 days from `fund()`; reward rate fixed at funding |
| Access tier | `hasAccess(a)`: at least `MIN_STAKE` (1,000,000 SVO) staked and the stake at least `MIN_STAKE_AGE` (1 day) old |
| Admin | none: no owner, no pause, no upgrade, no withdraw of the pools |

## How SVO can leave the contract
1. `unstake` returns a staker's own principal. 2. `claim` pays a staker's earned rewards. 3. `matchBurn` sends SVO from the
match pool to DEAD. 4. `burnSkipped` sends reward emission that accrued while nothing was staked to DEAD.
Nothing else moves SVO out, including for the funder after `fund()`.

## Burn-match
`matchBurn()` is permissionless. It reads `token.totalBurned()` and matches the increase since the last call (burns before
funding are ignored; this contract's own burns are never matched), capped by the part of the match pool that has vested
(linear over `DURATION`). An unmatched remainder carries forward. After `DURATION` the whole pool is available.

## Known properties
- Staking rewards are a fixed pool shared pro rata; the rate falls as more is staked. Nothing is promised.
- Adding to a stake restarts its age (stops stake-wait-unstake rental of the tier). Unstaking is instant.
- Per-share rounding dust stays in the contract.
- SVO sent to the contract by plain transfer (not `fund`/`stake`) is stranded.
- The tier is read by the app from `hasAccess`; the 30-minute cap itself is enforced in the visitor's browser, like the 10-minute one.
- Tests: `test/SvoStaking.t.sol` (unit, fuzz solvency).
