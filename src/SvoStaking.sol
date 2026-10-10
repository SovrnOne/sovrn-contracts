// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SovrnToken} from "./SovrnToken.sol";
import {Guard} from "./Interfaces.sol";

/// @notice Stake SVO to share Solomon's overflow, and to unlock the 30-minute session tier. The founder allocation
///         of SVO sits here as a burn-match pool that burns the same SVO again whenever SVO is burned.
/// @dev No owner, no upgrade path, no withdraw of the pools.
///
///      Rewards (IMD). When Solomon's health is full, the refuel Safe sends the surplus IMD from the LifeForceVault
///      to this contract. Anyone then calls `notify()`, which streams everything not yet accounted over
///      REWARD_PERIOD, pro rata by stake, per second. The contract cannot pull that surplus itself: the vault
///      is immutable and only the Safe can withdraw from it, so the Safe is the (public, on-chain) link. Stream
///      emission that falls while nothing is staked is not lost: it rolls into the next stream.
///      Stakers' SVO principal never depends on IMD: `unstake` moves only SVO, so an IMD that misbehaves can
///      block `claim` but never stakers' principal.
///
///      Burn-match (SVO). `fund()` deposits the founder allocation once. `matchBurn()` is permissionless: it
///      reads how much SVO has been sent to DEAD since the last call (the token's own `totalBurned`, excluding
///      this contract's own burns) and burns the same amount again from the pool, limited to what has vested
///      (linear over MATCH_DURATION). Burns it could not match yet carry forward. Once the pool has fully vested
///      (MATCH_DURATION after `fund()`), the funder may `reclaim()` whatever is left, one time, after any waiting
///      burns have been matched. That is the only way SVO ever leaves the pool other than to DEAD.
///
///      Access tier. `hasAccess(a)` is true when `a` has at least MIN_STAKE staked and the stake is at least
///      MIN_STAKE_AGE old. Adding to a stake restarts the age, which stops stake-wait-unstake rental of the tier.
contract SvoStaking is Guard {
    uint256 public constant REWARD_PERIOD = 7 days;
    uint256 public constant MATCH_DURATION = 365 days;
    uint256 public constant MIN_STAKE = 1_000_000 ether; // 0.1% of supply, for the 30-minute tier
    uint256 public constant MIN_STAKE_AGE = 1 days;
    uint256 private constant PRECISION = 1e18;

    SovrnToken public immutable token; // staked and matched
    address public immutable rewardToken; // IMD: what the vault holds and what stakers earn
    address public immutable funder;

    // Staking.
    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public stakedSince;

    // Rewards (IMD).
    uint256 public periodFinish;
    uint256 public rewardRate; // reward-token wei per second
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsReserved; // IMD this contract owes: unstreamed + streamed-but-unclaimed (+ rolled dust)
    uint256 public undistributed; // emission with nobody staked, rolled into the next stream
    uint256 public totalNotified; // lifetime IMD put into streams
    uint256 public totalClaimed;
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public earned;

    // Burn-match (SVO).
    uint256 public matchStart;
    uint256 public matchTotal;
    uint256 public matchUsed;
    bool public reclaimed;
    uint256 private burnSnapshot; // token.totalBurned() less burns already matched or made by this contract

    event Staked(address indexed account, uint256 amount, uint256 total);
    event Unstaked(address indexed account, uint256 amount, uint256 total);
    event Claimed(address indexed account, uint256 amount);
    event RewardAdded(uint256 added, uint256 streamed, uint256 rate, uint256 periodFinish);
    event Funded(uint256 amount, uint256 start);
    event Reclaimed(address indexed funder, uint256 amount);
    event MatchBurned(address indexed caller, uint256 observed, uint256 matched, uint256 matchRemaining);
    error Unauthorized();
    error AlreadyFunded();
    error NotFunded();
    error TooEarly();
    error InvalidAmount();
    error TransferFailed();

    constructor(SovrnToken token_, address rewardToken_, address funder_) {
        if (address(token_).code.length == 0 || rewardToken_.code.length == 0 || funder_ == address(0)) revert Unauthorized();
        token = token_;
        rewardToken = rewardToken_;
        funder = funder_;
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _update(msg.sender);
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        staked[msg.sender] += amount;
        totalStaked += amount;
        stakedSince[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount, staked[msg.sender]);
    }

    /// @dev Moves only SVO. Accrued rewards stay claimable.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > staked[msg.sender]) revert InvalidAmount();
        _update(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount, staked[msg.sender]);
    }

    function claim() external nonReentrant returns (uint256 reward) {
        _update(msg.sender);
        reward = earned[msg.sender];
        if (reward == 0) return 0;
        earned[msg.sender] = 0;
        rewardsReserved -= reward;
        totalClaimed += reward;
        (bool ok, bytes memory data) = rewardToken.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, reward));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        emit Claimed(msg.sender, reward);
    }

    // ---------------------------------------------------------------- rewards

    /// @notice Start (or extend) the stream with IMD that has arrived since the last call. Anyone may call.
    ///         Also restarts emission that rolled over while nothing was staked.
    function notify() external nonReentrant returns (uint256 added) {
        _updateGlobal();
        uint256 balance = _rewardBalance();
        if (balance > rewardsReserved) {
            added = balance - rewardsReserved;
            rewardsReserved = balance;
            totalNotified += added;
        }
        uint256 leftover = block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRate : 0;
        uint256 total = added + leftover + undistributed;
        if (total < REWARD_PERIOD) revert InvalidAmount(); // would stream at less than 1 wei per second
        rewardRate = total / REWARD_PERIOD;
        undistributed = total - rewardRate * REWARD_PERIOD; // rounding dust rolls forward
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + REWARD_PERIOD;
        emit RewardAdded(added, total, rewardRate, periodFinish);
    }

    // ---------------------------------------------------------------- burn-match

    /// @notice One-time deposit of the founder allocation as the burn-match pool.
    function fund(uint256 amount) external nonReentrant {
        if (msg.sender != funder) revert Unauthorized();
        if (matchStart != 0) revert AlreadyFunded();
        if (amount < MATCH_DURATION) revert InvalidAmount();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        matchTotal = amount;
        matchStart = block.timestamp;
        burnSnapshot = token.totalBurned(); // burns before funding are not matched
        emit Funded(amount, block.timestamp);
    }

    /// @notice Burn from the pool the same amount of SVO that was burned elsewhere since the last call.
    function matchBurn() external nonReentrant returns (uint256 matched) {
        if (matchStart == 0) revert NotFunded();
        matched = _match();
        if (matched == 0) revert InvalidAmount();
    }

    /// @notice After MATCH_DURATION the funder may take back whatever the pool has not matched. Burns that
    ///         are still waiting to be matched are matched first, so this can never cut one off. One time;
    ///         it closes the pool for good.
    function reclaim() external nonReentrant returns (uint256 returned) {
        if (msg.sender != funder) revert Unauthorized();
        if (matchStart == 0) revert NotFunded();
        if (reclaimed) revert AlreadyFunded();
        if (block.timestamp < matchStart + MATCH_DURATION) revert TooEarly();
        _match();
        reclaimed = true;
        returned = matchTotal - matchUsed;
        matchTotal = matchUsed; // nothing left to vest or match
        if (returned != 0 && !token.transfer(funder, returned)) revert TransferFailed();
        emit Reclaimed(funder, returned);
    }

    /// @dev Matches what has been burned elsewhere, within the vested amount. Returns 0 when there is nothing to do.
    function _match() private returns (uint256 matched) {
        uint256 observed = token.totalBurned() - burnSnapshot;
        matched = observed;
        uint256 available = matchAvailable();
        if (matched > available) matched = available;
        if (matched == 0) return 0;
        matchUsed += matched;
        // Consume `matched` of the observed burns and skip over this contract's own burn of the same size.
        burnSnapshot += 2 * matched;
        if (!token.transfer(token.DEAD(), matched)) revert TransferFailed();
        emit MatchBurned(msg.sender, observed, matched, matchTotal - matchUsed);
    }

    // ---------------------------------------------------------------- views

    function hasAccess(address account) external view returns (bool) {
        return staked[account] >= MIN_STAKE && block.timestamp >= stakedSince[account] + MIN_STAKE_AGE;
    }

    /// @notice Match pool vested so far, minus what has been used.
    function matchAvailable() public view returns (uint256) {
        if (matchStart == 0) return 0;
        uint256 elapsed = block.timestamp - matchStart;
        if (elapsed > MATCH_DURATION) elapsed = MATCH_DURATION;
        return matchTotal * elapsed / MATCH_DURATION - matchUsed; // matchTotal <= 1e27, elapsed <= 3.2e7: no overflow
    }

    /// @notice SVO burned elsewhere that matchBurn() has not matched yet.
    function unmatchedBurns() external view returns (uint256) {
        if (matchStart == 0) return 0;
        return token.totalBurned() - burnSnapshot;
    }

    function matchRemaining() external view returns (uint256) {
        return matchTotal - matchUsed;
    }

    /// @notice IMD sitting here that notify() has not streamed yet.
    function unnotified() external view returns (uint256) {
        uint256 balance = _rewardBalance();
        return balance > rewardsReserved ? balance - rewardsReserved : 0;
    }

    /// @notice IMD still to stream to stakers in the current period.
    function streamRemaining() external view returns (uint256) {
        return block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRate : 0;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (_emitted() * PRECISION / totalStaked);
    }

    function pendingRewards(address account) public view returns (uint256) {
        return earned[account] + staked[account] * (rewardPerToken() - rewardPerTokenPaid[account]) / PRECISION;
    }

    // ---------------------------------------------------------------- internals

    function _emitted() private view returns (uint256) {
        uint256 until = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (until <= lastUpdate) return 0;
        return (until - lastUpdate) * rewardRate;
    }

    function _updateGlobal() private {
        uint256 emitted = _emitted();
        if (totalStaked == 0) undistributed += emitted;
        else rewardPerTokenStored += emitted * PRECISION / totalStaked;
        lastUpdate = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (lastUpdate == 0) lastUpdate = block.timestamp; // before the first stream
    }

    function _update(address account) private {
        _updateGlobal();
        earned[account] = pendingRewards(account);
        rewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    function _rewardBalance() private view returns (uint256) {
        (bool ok, bytes memory data) = rewardToken.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }
}
