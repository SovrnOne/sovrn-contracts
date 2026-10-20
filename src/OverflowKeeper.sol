// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Guard} from "./Interfaces.sol";
import {LifeForceVault} from "./LifeForceVault.sol";
import {SvoStaking} from "./SvoStaking.sol";

/// @dev The slice of a Safe (1.3+, the refuel Safe is 1.5.0) a module uses. The Safe runs the call as itself.
interface ISafeModuleManager {
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success, bytes memory returnData);
}

/// @notice Keeper for Solomon's overflow: moves the vault's inference reserve above "full health" to SvoStaking in one
///         permissionless call, through the refuel Safe, so the Safe's signers never have to queue it by hand.
/// @dev The LifeForceVault is immutable and lets only REFUEL_SAFE withdraw. This contract is a Safe *module*: once the
///      Safe's owners enable it (one `enableModule(keeper)` transaction, 2-of-3), `sweep()` makes the Safe call
///      `withdrawInference(amount)` and forward the IMD, with no signatures. The authority it holds over the Safe is
///      exactly those calls, and `amount` is computed on chain at execution time as the reserve above `full`, so a
///      call can never dip into Solomon's voice reserve nor move anything else the Safe holds. The Safe can disable the
///      module at any time (`disableModule`) and is the only party that can change `full` and `minSweep`.
///
///      Caller fee. Whoever calls `sweep()` receives FEE_BPS (0.5%) of the amount moved, paid by the Safe out of the
///      withdrawn IMD; the rest goes to the staking contract. The fee is the gas and attention incentive; nothing else
///      ever leaves through this contract. The Safe's own IMD balance is unchanged by a sweep, and that is enforced:
///      the sweep checks that exactly `amount` arrived from the vault and that the Safe ends where it started, so a
///      token that skims a fee, or a Safe that reports success for a failed withdrawal, makes the sweep revert
///      instead of spending the Safe's float.
///
///      Never stuck. After the transfer the keeper calls `SvoStaking.notify()` only when it will succeed (something to
///      add; while a stream runs, at least a tenth of what is left; within the contract's bounds). Otherwise the IMD
///      waits in the staking contract, where it can only ever go to stakers, and the next sweep that meets the
///      threshold streams it. A sweep therefore never reverts on the staking contract's rules.
///
///      No owner, no upgrade, holds no tokens. If IMD ever blocks the staking contract the sweep refuses, so IMD is not
///      withdrawn into a Safe that cannot forward it.
///
///      Naming: `Guard` below is this repo's re-entrancy guard (src/Interfaces.sol). This contract is a Safe *module*;
///      it is not a Safe transaction guard or module guard.
contract OverflowKeeper is Guard {
    address public constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C; // LifeForceVault.REFUEL_SAFE
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 public constant FEE_BPS = 50; // 0.5% of each sweep to the caller
    uint256 public constant BPS = 10_000;
    /// @dev `minSweep` may not go below this: SvoStaking streams at least 1 wei per second over REWARD_PERIOD (7 days),
    ///      and what reaches it is the sweep less the fee, so the floor is 7 days of wei grossed up by the fee
    ///      (607,840 wei). A sweep that small is dust anyway.
    uint256 public constant MIN_SWEEP_FLOOR = 7 days * BPS / (BPS - FEE_BPS) + 1;

    LifeForceVault public immutable vault;
    SvoStaking public immutable staking;

    /// @notice Inference reserve (IMD wei) that counts as full health; everything above it is overflow for stakers.
    uint256 public full;
    /// @notice Smallest overflow worth a sweep (IMD wei). Below it `sweep()` reverts NothingToSweep.
    uint256 public minSweep;

    event Swept(address indexed caller, uint256 amount, uint256 toStakers, uint256 fee, bool notified);
    event FullSet(uint256 full);
    event MinSweepSet(uint256 minSweep);
    error Unauthorized();
    error NothingToSweep();
    error InvalidAmount();
    error Blocked();
    error SafeCallFailed(bytes returnData);
    error TransferFailed();
    /// @dev The Safe did not receive exactly what the vault was asked for, or did not end a sweep with the IMD it started
    ///      with. The sweep is undone so the Safe's own IMD is never spent.
    error SafeBalanceMismatch(uint256 expected, uint256 actual);

    constructor(LifeForceVault vault_, SvoStaking staking_, uint256 full_, uint256 minSweep_) {
        if (address(vault_).code.length == 0 || address(staking_).code.length == 0) revert Unauthorized();
        if (vault_.REFUEL_SAFE() != SAFE || vault_.IMD() != IMD) revert Unauthorized();
        if (staking_.rewardToken() != IMD) revert Unauthorized();
        // The staking contract must be the one for this vault's token, not a look-alike staking some other token.
        if (address(staking_.token()) != address(vault_.token())) revert Unauthorized();
        if (minSweep_ < MIN_SWEEP_FLOOR) revert InvalidAmount();
        vault = vault_;
        staking = staking_;
        full = full_;
        minSweep = minSweep_;
        emit FullSet(full_);
        emit MinSweepSet(minSweep_);
    }

    modifier onlySafe() {
        if (msg.sender != SAFE) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------- settings (the Safe only)

    function setFull(uint256 full_) external onlySafe {
        full = full_;
        emit FullSet(full_);
    }

    function setMinSweep(uint256 minSweep_) external onlySafe {
        if (minSweep_ < MIN_SWEEP_FLOOR) revert InvalidAmount();
        minSweep = minSweep_;
        emit MinSweepSet(minSweep_);
    }

    // ---------------------------------------------------------------- views

    /// @notice IMD the vault's inference reserve holds above full health right now.
    function overflow() public view returns (uint256) {
        uint256 reserve = vault.inferenceReserve();
        return reserve > full ? reserve - full : 0;
    }

    /// @notice What `sweep()` would do now. `ready` is false when it would revert (below minSweep, or IMD blocks the
    ///         vault, the Safe or the staking contract); `willNotify` says whether the stream starts or extends in the
    ///         same call. A caller that IMD blocks still fails on its own fee transfer.
    function preview()
        external
        view
        returns (uint256 amount, uint256 fee, uint256 toStakers, bool willNotify, bool ready)
    {
        amount = overflow();
        fee = amount * FEE_BPS / BPS;
        toStakers = amount - fee;
        ready = amount >= minSweep && !_anyBlocked();
        willNotify = ready && _notifyWouldPass(staking.unnotified() + toStakers);
    }

    // ---------------------------------------------------------------- the sweep (anyone)

    /// @notice Move the overflow to stakers: the Safe withdraws it from the vault, pays the caller FEE_BPS of it and
    ///         sends the rest to SvoStaking; then the stream is notified if the staking contract will accept it.
    function sweep() external nonReentrant returns (uint256 toStakers, uint256 fee) {
        uint256 amount = overflow();
        if (amount < minSweep) revert NothingToSweep();
        if (_anyBlocked()) revert Blocked();
        fee = amount * FEE_BPS / BPS;
        toStakers = amount - fee;

        // 1. The Safe withdraws the overflow; the vault sends it to REFUEL_SAFE, i.e. the Safe itself. Exactly `amount`
        //    must arrive, or the Safe would be paying the difference out of its own IMD below.
        uint256 start = _imdBalance(SAFE);
        _safeCall(address(vault), abi.encodeCall(LifeForceVault.withdrawInference, (amount)));
        uint256 got = _imdBalance(SAFE) - start;
        if (got != amount) revert SafeBalanceMismatch(amount, got);
        // 2. The Safe pays the caller and forwards the rest. Both come out of what was just withdrawn.
        if (fee != 0) _safeTransfer(msg.sender, fee);
        _safeTransfer(address(staking), toStakers);
        uint256 end = _imdBalance(SAFE);
        if (end != start) revert SafeBalanceMismatch(start, end);
        // 3. Start or extend the stream only when the staking contract will take it; otherwise the IMD waits there.
        bool notified;
        if (_notifyWouldPass(staking.unnotified())) {
            staking.notify();
            notified = true;
        }
        emit Swept(msg.sender, amount, toStakers, fee, notified);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Mirrors the checks in SvoStaking.notify() exactly, so a sweep never trips them. `added` = IMD at the
    ///      staking contract above what it has reserved, which is what notify() would stream. notify() first folds
    ///      emission that ran while nobody was staked into `undistributed`; the same fold is applied here.
    function _notifyWouldPass(uint256 added) private view returns (bool) {
        uint256 leftover = staking.streamRemaining();
        if (leftover != 0 && (added == 0 || added < leftover / 10)) return false;
        uint256 undistributed = staking.undistributed();
        if (staking.totalStaked() == 0) {
            uint256 periodFinish = staking.periodFinish();
            uint256 until = block.timestamp < periodFinish ? block.timestamp : periodFinish;
            uint256 lastUpdate = staking.lastUpdate();
            if (until > lastUpdate) undistributed += (until - lastUpdate) * staking.rewardRate();
        }
        uint256 total = added + leftover + undistributed;
        if (total < staking.REWARD_PERIOD()) return false;
        if (total > staking.MAX_STREAM()) return false;
        return true;
    }

    /// @dev Any of the three parties a sweep moves IMD between on IMD's blocklist.
    function _anyBlocked() private view returns (bool) {
        return _blocked(address(vault)) || _blocked(SAFE) || _blocked(address(staking));
    }

    /// @dev IMD's `blocked(address)` blocklist, read tolerantly: a token without it, or a failing read, counts as not
    ///      blocked (the transfer itself then decides); any non-zero word counts as blocked, so an answer that is not
    ///      a canonical bool cannot make this revert.
    function _blocked(address who) private view returns (bool) {
        (bool ok, bytes memory data) = IMD.staticcall(abi.encodeWithSignature("blocked(address)", who));
        return ok && data.length >= 32 && abi.decode(data, (uint256)) != 0;
    }

    /// @dev The Safe's IMD balance, read like the vault reads its own.
    function _imdBalance(address who) private view returns (uint256) {
        (bool ok, bytes memory data) = IMD.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    function _safeTransfer(address to, uint256 amount) private {
        bytes memory ret = _safeCall(IMD, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert TransferFailed();
    }

    /// @dev Runs `data` at `to` as the Safe (operation 0 = CALL). Reverts with the inner call's return data when it
    ///      fails. When this contract is not an enabled module the Safe itself reverts ("GS104"), which bubbles up.
    function _safeCall(address to, bytes memory data) private returns (bytes memory) {
        (bool ok, bytes memory ret) = ISafeModuleManager(SAFE).execTransactionFromModuleReturnData(to, 0, data, 0);
        if (!ok) revert SafeCallFailed(ret);
        return ret;
    }
}
