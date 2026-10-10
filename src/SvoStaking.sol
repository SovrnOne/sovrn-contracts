// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SovrnToken} from "./SovrnToken.sol";
import {Guard} from "./Interfaces.sol";

/// @notice Stake SVO for a linear reward stream and for the 30-minute session tier, funded once from the
///         founder allocation, with a burn-match that burns the same SVO again whenever SVO is burned.
/// @dev No owner, no upgrade path, no withdraw of the pools. After `fund()` the only way SVO leaves the
///      reward and match pools is to a staker's claim or to DEAD. The funder can call `fund()` exactly once.
///
///      Pools. `fund(amount)` splits `amount` 60/40: REWARD_BPS to the reward pool (streamed linearly to
///      stakers over DURATION, pro rata by stake, per second) and the rest to the match pool.
///      Emission that falls in a period with nothing staked is not paid to anyone: `burnSkipped()` sends it
///      to DEAD.
///
///      Burn-match. `matchBurn()` is permissionless. It looks at how much SVO has been sent to DEAD since the
///      last call (read from the token's own `totalBurned`, excluding this contract's own burns) and burns the
///      same amount again from the match pool, limited to what has vested (the pool vests linearly over
///      DURATION, so it cannot be drained on day one). Burns it could not match yet carry forward.
///
///      Access tier. `hasAccess(a)` is true when `a` has at least MIN_STAKE staked and the stake is at least
///      MIN_STAKE_AGE old. Adding to a stake restarts the age, which stops stake-wait-unstake rental of the tier.
contract SvoStaking is Guard {
    uint256 public constant DURATION = 365 days;
    uint256 public constant REWARD_BPS = 6000; // 60% rewards, 40% burn-match
    uint256 public constant MIN_STAKE = 1_000_000 ether; // 0.1% of supply, for the 30-minute tier
    uint256 public constant MIN_STAKE_AGE = 1 days;
    uint256 private constant PRECISION = 1e18;

    SovrnToken public immutable token;
    address public immutable funder;

    // Schedule (set once by fund()).
    uint256 public start;
    uint256 public periodFinish;
    uint256 public rewardRate; // SVO wei per second
    uint256 public rewardsTotal; // rewardRate * DURATION
    uint256 public matchTotal; // the rest of the funded amount

    // Staking.
    uint256 public totalStaked;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public skipped; // emission with nobody staked, waiting for burnSkipped()
    uint256 public totalClaimed;
    uint256 public totalSkippedBurned;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public stakedSince;
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public earned;

    // Burn-match.
    uint256 public matchUsed;
    uint256 private burnSnapshot; // token.totalBurned() less burns already matched or made by this contract

    event Funded(uint256 amount, uint256 rewards, uint256 matchPool, uint256 start);
    event Staked(address indexed account, uint256 amount, uint256 total);
    event Unstaked(address indexed account, uint256 amount, uint256 total);
    event Claimed(address indexed account, uint256 amount);
    event MatchBurned(address indexed caller, uint256 observed, uint256 matched, uint256 matchRemaining);
    event SkippedBurned(uint256 amount);
    error Unauthorized();
    error AlreadyFunded();
    error NotFunded();
    error InvalidAmount();
    error TransferFailed();

    constructor(SovrnToken token_, address funder_) {
        if (address(token_).code.length == 0 || funder_ == address(0)) revert Unauthorized();
        token = token_;
        funder = funder_;
    }

    // ---------------------------------------------------------------- funding

    /// @notice One-time funding from the founder allocation. Needs an allowance for `amount`.
    function fund(uint256 amount) external nonReentrant {
        if (msg.sender != funder) revert Unauthorized();
        if (start != 0) revert AlreadyFunded();
        if (amount < DURATION) revert InvalidAmount(); // at least 1 wei per second
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 rewards = (amount / 10_000) * REWARD_BPS + (amount % 10_000) * REWARD_BPS / 10_000;
        rewardRate = rewards / DURATION;
        rewardsTotal = rewardRate * DURATION; // the division remainder goes to the match pool
        matchTotal = amount - rewardsTotal;
        start = block.timestamp;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        burnSnapshot = token.totalBurned(); // burns before funding are not matched
        emit Funded(amount, rewardsTotal, matchTotal, block.timestamp);
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        if (start == 0) revert NotFunded();
        if (amount == 0) revert InvalidAmount();
        _update(msg.sender);
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        staked[msg.sender] += amount;
        totalStaked += amount;
        stakedSince[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount, staked[msg.sender]);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > staked[msg.sender]) revert InvalidAmount();
        _update(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount, staked[msg.sender]);
    }

    function claim() public nonReentrant returns (uint256 reward) {
        _update(msg.sender);
        reward = earned[msg.sender];
        if (reward == 0) return 0;
        earned[msg.sender] = 0;
        totalClaimed += reward;
        if (!token.transfer(msg.sender, reward)) revert TransferFailed();
        emit Claimed(msg.sender, reward);
    }

    // ---------------------------------------------------------------- burn-match

    /// @notice Burn from the match pool the same amount of SVO that was burned elsewhere since the last call.
    function matchBurn() external nonReentrant returns (uint256 matched) {
        if (start == 0) revert NotFunded();
        uint256 burned = token.totalBurned();
        uint256 observed = burned - burnSnapshot;
        matched = observed;
        uint256 available = matchAvailable();
        if (matched > available) matched = available;
        if (matched == 0) revert InvalidAmount();
        matchUsed += matched;
        // Consume `matched` of the observed burns and skip over this contract's own burn of the same size.
        burnSnapshot += 2 * matched;
        if (!token.transfer(token.DEAD(), matched)) revert TransferFailed();
        emit MatchBurned(msg.sender, observed, matched, matchTotal - matchUsed);
    }

    /// @notice Send emission that fell on a period with nothing staked to DEAD (it is never paid out).
    function burnSkipped() external nonReentrant returns (uint256 amount) {
        _updateGlobal();
        amount = skipped;
        if (amount == 0) revert InvalidAmount();
        skipped = 0;
        totalSkippedBurned += amount;
        burnSnapshot += amount; // not an external burn: do not match it
        if (!token.transfer(token.DEAD(), amount)) revert TransferFailed();
        emit SkippedBurned(amount);
    }

    // ---------------------------------------------------------------- views

    function hasAccess(address account) external view returns (bool) {
        return staked[account] >= MIN_STAKE && block.timestamp >= stakedSince[account] + MIN_STAKE_AGE;
    }

    /// @notice Match pool vested so far, minus what has been used.
    function matchAvailable() public view returns (uint256) {
        if (start == 0) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed > DURATION) elapsed = DURATION;
        // matchTotal is at most the supply (1e27) and elapsed at most 3.2e7, so this cannot overflow.
        uint256 vested = matchTotal * elapsed / DURATION;
        return vested - matchUsed;
    }

    /// @notice SVO burned elsewhere that matchBurn() has not matched yet.
    function unmatchedBurns() external view returns (uint256) {
        if (start == 0) return 0;
        return token.totalBurned() - burnSnapshot;
    }

    function matchRemaining() external view returns (uint256) {
        return matchTotal - matchUsed;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (_emitted() * PRECISION / totalStaked);
    }

    function pendingRewards(address account) public view returns (uint256) {
        return earned[account] + staked[account] * (rewardPerToken() - rewardPerTokenPaid[account]) / PRECISION;
    }

    /// @notice Reward pool left to stream or claim: total less what has been paid or burned unpaid.
    function rewardsRemaining() external view returns (uint256) {
        return rewardsTotal - totalClaimed - totalSkippedBurned;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Emission since lastUpdate, clamped to the period end.
    function _emitted() private view returns (uint256) {
        if (start == 0) return 0;
        uint256 until = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (until <= lastUpdate) return 0;
        return (until - lastUpdate) * rewardRate;
    }

    function _updateGlobal() private {
        if (start == 0) return;
        uint256 emitted = _emitted();
        if (totalStaked == 0) skipped += emitted;
        else rewardPerTokenStored += emitted * PRECISION / totalStaked;
        lastUpdate = block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function _update(address account) private {
        _updateGlobal();
        earned[account] = pendingRewards(account);
        rewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
