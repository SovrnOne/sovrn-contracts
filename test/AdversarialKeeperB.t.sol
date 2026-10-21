// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SystemBase} from "./SystemBase.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {SvoStaking} from "../src/SvoStaking.sol";
import {OverflowKeeper} from "../src/OverflowKeeper.sol";
import {MockIMD} from "./mocks/MockERC20.sol";
import {MockSafe} from "./OverflowKeeper.t.sol";

/// @dev IMD whose `blocked(address)` answers with a value that is not a canonical bool (an enum / tier / timestamp).
///      Same storage layout as MockIMD, so it can be etched over the live mock.
contract OddBlockedIMD is MockIMD {
    constructor() MockIMD(0) {}

    function blocked(address) external pure returns (uint256) {
        return 2;
    }
}

/// @dev IMD whose `blocked(address)` returns fewer than 32 bytes (a bool packed by a non-Solidity token).
contract ShortBlockedIMD is MockIMD {
    constructor() MockIMD(0) {}

    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

/// @dev USDT-style IMD: `transfer` moves funds and returns NO data, no `blocked`. Slots 0..2 pad solmate's
///      name/symbol/totalSupply so `balanceOf` lands on MockIMD's slot 3 and the etched balances survive.
contract NoReturnIMD {
    string private _pad0;
    string private _pad1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev A Safe 1.5.0 module guard that vetoes in checkAfterModuleExecution (the mock Safe below honours it).
interface IModuleGuard {
    function checkModuleTransaction(address to, uint256 value, bytes calldata data, uint8 operation, address module)
        external
        returns (bytes32);
    function checkAfterModuleExecution(bytes32 hash, bool success) external;
}

contract VetoAfterGuard is IModuleGuard {
    function checkModuleTransaction(address, uint256, bytes calldata, uint8, address) external pure returns (bytes32) {
        return bytes32(0);
    }

    function checkAfterModuleExecution(bytes32, bool) external pure {
        revert("guard veto");
    }
}

/// @dev A Safe stand-in with the 1.5.0 module-guard hooks (pre and post), to show what the plain mock hides.
contract GuardedMockSafe {
    mapping(address => bool) public enabled;
    address public moduleGuard;

    function enableModule(address m) external {
        enabled[m] = true;
    }

    function isModuleEnabled(address m) external view returns (bool) {
        return enabled[m];
    }

    function setModuleGuard(address g) external {
        moduleGuard = g;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        require(enabled[msg.sender], "GS104");
        bytes32 h;
        if (moduleGuard != address(0)) h = IModuleGuard(moduleGuard).checkModuleTransaction(to, value, data, operation, msg.sender);
        (success, returnData) = to.call{value: value}(data);
        if (moduleGuard != address(0)) IModuleGuard(moduleGuard).checkAfterModuleExecution(h, success);
    }
}

contract AdversarialKeeperBTest is SystemBase {
    SvoStaking internal staking;
    OverflowKeeper internal keeper;
    MockSafe internal safe;
    address internal constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    uint256 internal constant FULL = 25 ether;
    uint256 internal constant MIN_SWEEP = 1 ether;
    uint256 internal constant WEEK = 7 days;
    address internal caller = address(0xCA11E4);

    function setUp() public {
        _system(false);
        deployCodeTo("OverflowKeeper.t.sol:MockSafe", "", SAFE);
        safe = MockSafe(SAFE);
        staking = new SvoStaking(token, IMD_ADDR, address(this));
        keeper = new OverflowKeeper(vault, staking, FULL, MIN_SWEEP);
        safe.enableModule(address(keeper));
        vm.startPrank(ALICE);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1_000_000 ether);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        assertTrue(imd.transfer(address(vault), amount));
        vault.sync();
    }

    /// @dev IMD leaves the vault outside the vault's accounting (a seizure / outflow not made through the vault).
    function _seize(uint256 amount) internal {
        vm.prank(address(vault));
        assertTrue(imd.transfer(address(0xDEAD), amount));
    }

    function _asSafe(bytes memory data) internal {
        safe.callAs(address(keeper), data);
    }

    function _floorKeeper() internal returns (OverflowKeeper k) {
        k = new OverflowKeeper(vault, staking, FULL, keeper.MIN_SWEEP_FLOOR());
        safe.enableModule(address(k));
    }

    // ================================================================ F1: fee-on-transfer IMD drains the Safe's own IMD

    /// F1 (fixed): with a fee-on-transfer IMD less than `amount` reaches the Safe; the sweep reverts rather than take
    /// the difference from the Safe's float.
    function test_F1_feeOnTransferIMDRevertsTheSweepAndLeavesTheSafeFloat() public {
        _fund(100 ether); // inference 70 -> overflow 45
        assertTrue(imd.transfer(SAFE, 10 ether)); // the Safe's own float
        imd.setFeeBps(100); // 1%
        vm.expectRevert(abi.encodeWithSelector(OverflowKeeper.SafeBalanceMismatch.selector, 45 ether, 44.55 ether));
        vm.prank(caller);
        keeper.sweep();
        assertEq(imd.balanceOf(SAFE), 10 ether, "float untouched");
        assertEq(vault.inferenceReserve(), 70 ether, "withdrawal undone");
        assertEq(imd.balanceOf(address(staking)), 0);
    }

    /// Same, but the Safe holds no float: the forward underflows and the whole sweep reverts (SafeCallFailed). Nothing
    /// is lost, but the keeper is stuck until the Safe keeps IMD of its own around or the fee goes away.
    function test_F1b_feeOnTransferWithNoSafeFloatMakesEverySweepRevert() public {
        _fund(100 ether);
        imd.setFeeBps(1); // 0.01%
        assertEq(imd.balanceOf(SAFE), 0);
        (,,,, bool ready) = keeper.preview();
        assertTrue(ready, "preview cannot see it coming");
        vm.expectRevert();
        keeper.sweep();
        assertEq(vault.inferenceReserve(), 70 ether, "atomic: nothing withdrawn");
    }

    // ================================================================ F2: _notifyWouldPass reads `undistributed` BEFORE _updateGlobal()

    /// F2 (fixed): the keeper's notify() mirror folds the emission that ran with nobody staked, like notify() itself,
    /// so a floor-sized sweep after a rolled-over stream streams instead of parking.
    function test_F2_staleUndistributedIsFoldedSoTheSweepNotifies() public {
        OverflowKeeper k = _floorKeeper();
        vm.prank(ALICE);
        staking.unstake(1_000_000 ether); // nobody staked: emission rolls into undistributed on the next update
        _fund(100000000000000785641);
        k.sweep(); // streams ~44.775 IMD over a week
        skip(WEEK + 1); // the whole stream emitted with nobody staked; NOT yet folded into storage
        assertEq(staking.streamRemaining(), 0);
        assertEq(staking.undistributed(), 0, "stored value is stale: the fold happens inside notify()");
        safe.callAs(address(k), abi.encodeCall(OverflowKeeper.setFull, (vault.inferenceReserve() - 607840)));
        assertEq(k.overflow(), 607840);
        (uint256 amount, uint256 fee, uint256 toStakers, bool willNotify,) = k.preview();
        assertEq(amount, 607840);
        assertEq(fee, 3039);
        assertEq(toStakers, 604801);
        assertTrue(willNotify, "keeper: 604801 + 0 + folded ~44.775 IMD >= REWARD_PERIOD");
        k.sweep();
        assertEq(staking.unnotified(), 0, "streamed");
        assertGt(staking.streamRemaining(), 44 ether, "the rolled-over week is streaming again");
    }

    /// F2b (fixed twice): with the fold mirrored the keeper sees that notify() would exceed MAX_STREAM; since IMD parked
    /// above that bound could never be streamed again (swarm audit finding 4), the sweep refuses instead of forwarding.
    /// (deal() is a test cheat; real IMD supply is nowhere near this.)
    function test_F2b_nearMaxStreamTheSweepRefusesInsteadOfStranding() public {
        vm.prank(ALICE);
        staking.unstake(1_000_000 ether);
        deal(IMD_ADDR, address(staking), 0.95e40);
        staking.notify();
        skip(WEEK + 1); // emitted 0.95e40 (minus dust) is pending the fold
        deal(IMD_ADDR, address(vault), 0.1e40 + 60 ether);
        vault.sync();
        uint256 over = keeper.overflow();
        assertGt(over, 0.06e40);
        (,,, bool willNotify, bool ready) = keeper.preview();
        assertFalse(ready, "would strand above MAX_STREAM");
        assertFalse(willNotify);
        uint256 reserve = vault.inferenceReserve();
        vm.expectRevert(OverflowKeeper.InvalidAmount.selector);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), reserve, "nothing moved");
        assertEq(staking.unnotified(), 0, "nothing parked");
    }

    // ================================================================ F3: MIN_SWEEP_FLOOR is quoted before the fee

    /// F3 (fixed): MIN_SWEEP_FLOOR is grossed up by the fee (607,840 wei), so a floor-sized sweep on a fresh system
    /// delivers at least REWARD_PERIOD wei to the staking contract and streams.
    function test_F3_floorSweepOnFreshSystemStreams() public {
        assertEq(keeper.MIN_SWEEP_FLOOR(), 607840);
        assertGe(uint256(607840) - uint256(607840) * 50 / 10000, uint256(604800));
        assertLt(uint256(607838) - uint256(607838) * 50 / 10000, uint256(604800));
        OverflowKeeper k = _floorKeeper();
        _fund(100 ether);
        safe.callAs(address(k), abi.encodeCall(OverflowKeeper.setFull, (70 ether)));
        _fund(868342); // 70% of it = 607,840 wei of inference
        assertEq(k.overflow(), 607840);
        (,,, bool willNotify, bool ready) = k.preview();
        assertTrue(ready);
        assertTrue(willNotify);
        k.sweep();
        assertEq(staking.unnotified(), 0, "streamed");
        assertEq(staking.streamRemaining(), 604800 - (604800 % WEEK) + 0, "1 wei per second for a week");
    }

    // ================================================================ F4: _blocked() decode is not tolerant of non-canonical bools

    /// F4 (fixed): a `blocked()` that answers 2 reads as blocked; preview() and sweep() answer without a panic.
    function test_F4_blockedReturningTwoReadsAsBlocked() public {
        _fund(100 ether);
        bytes memory saved = IMD_ADDR.code;
        vm.etch(IMD_ADDR, address(new OddBlockedIMD()).code);
        assertEq(vault.inferenceReserve(), 70 ether, "balances survived");
        (,,,, bool ready) = keeper.preview();
        assertFalse(ready);
        vm.expectRevert(OverflowKeeper.Blocked.selector);
        keeper.sweep();
        vm.etch(IMD_ADDR, saved);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
    }

    /// A token answering blocked() with fewer than 32 bytes is "not blocked" (tolerant path), as documented.
    function test_F4b_shortBlockedAnswerCountsAsNotBlocked() public {
        _fund(100 ether);
        bytes memory saved = IMD_ADDR.code;
        vm.etch(IMD_ADDR, address(new ShortBlockedIMD()).code);
        (,,,, bool ready) = keeper.preview();
        assertTrue(ready);
        vm.etch(IMD_ADDR, saved);
    }

    // ================================================================ F5: preview() is blind to a blocked Safe / vault / caller

    /// The keeper checks blocked(staking) only. If IMD blocks the Safe (recipient of the withdrawal) or the vault
    /// (sender), preview() says ready and sweep() reverts SafeCallFailed(TransferFailed). No loss, but
    /// the "ready" promise is weaker than it reads; the deploy notes should record blocked() for all four parties.
    function test_F5_previewReadyButSweepRevertsWhenIMDRefusesTheSafe() public {
        _fund(100 ether);
        imd.setRefuses(SAFE, true);
        (,,,, bool ready) = keeper.preview();
        assertTrue(ready);
        vm.expectRevert(); // SafeCallFailed(abi.encodeWithSelector(LifeForceVault.TransferFailed.selector))
        keeper.sweep();
        imd.setRefuses(SAFE, false);
        // A refused caller only blocks that caller's sweep.
        imd.setRefuses(caller, true);
        vm.prank(caller);
        vm.expectRevert();
        keeper.sweep();
        keeper.sweep(); // another caller is fine
        assertEq(vault.inferenceReserve(), FULL);
    }

    // ================================================================ Sound: shortfall clamp, untracked IMD, exact `full`

    /// After an unreversed loss (seizure), the view clamps inference to the balance; withdrawInference checkpoints
    /// (a no-op in shortfall), sees the same clamp, and the reserve afterwards is exactly `full`; buyback is unchanged.
    /// `seizeBps` covers 0..100% of the balance, `pending` is unsynced IMD on top (the view includes it, the
    /// withdrawal checkpoints it: same split either way).
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_shortfallAndUntrackedIMDStillLeaveExactlyFull(uint96 rawFund, uint16 seizeBps, uint96 rawPending, bool syncFirst)
        public
    {
        uint256 fundAmt = bound(rawFund, 0, 50_000 ether);
        uint256 pending = bound(rawPending, 0, 50_000 ether);
        _fund(fundAmt);
        uint256 seize = imd.balanceOf(address(vault)) * bound(seizeBps, 0, 10_000) / 10_000;
        if (seize != 0) _seize(seize);
        if (pending != 0) assertTrue(imd.transfer(address(vault), pending));
        if (syncFirst) vault.sync();
        uint256 reserve = vault.inferenceReserve();
        uint256 buyback = vault.buybackReserve();
        assertEq(reserve + buyback, imd.balanceOf(address(vault)));
        uint256 over = reserve > FULL ? reserve - FULL : 0;
        uint256 safeBefore = imd.balanceOf(SAFE);
        if (over < MIN_SWEEP) {
            vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
            keeper.sweep();
            return;
        }
        vm.prank(caller);
        (uint256 toStakers, uint256 fee) = keeper.sweep();
        assertEq(toStakers + fee, over);
        assertEq(vault.inferenceReserve(), FULL, "exactly full");
        assertEq(vault.buybackReserve(), buyback, "buyback untouched even through the clamp");
        assertEq(imd.balanceOf(SAFE), safeBefore);
        assertEq(imd.balanceOf(address(keeper)), 0);
    }

    /// minSweep equality proceeds; one wei under reverts; full > reserve gives overflow 0.
    function test_minSweepEdgeAndFullAboveReserve() public {
        _fund(100 ether);
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (70 ether - MIN_SWEEP)));
        assertEq(keeper.overflow(), MIN_SWEEP);
        _asSafe(abi.encodeCall(OverflowKeeper.setMinSweep, (MIN_SWEEP + 1)));
        vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
        keeper.sweep();
        _asSafe(abi.encodeCall(OverflowKeeper.setMinSweep, (MIN_SWEEP)));
        keeper.sweep();
        assertEq(vault.inferenceReserve(), 70 ether - MIN_SWEEP);
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (type(uint256).max)));
        assertEq(keeper.overflow(), 0);
        (uint256 a,,,, bool ready) = keeper.preview();
        assertEq(a, 0);
        assertFalse(ready);
    }

    /// Fee rounding: toStakers + fee == amount for every amount; fee is floor(amount * 0.5%).
    function testFuzz_feeRounding(uint256 amount) public pure {
        amount = bound(amount, 604800, 1e33);
        uint256 fee = amount * 50 / 10_000;
        assertEq(fee + (amount - fee), amount);
        assertLe(fee * 10_000, amount * 50);
        assertGt((fee + 1) * 10_000, amount * 50);
    }

    /// A transfer that returns no data (USDT style) is accepted on both Safe legs; the Safe hands back empty
    /// returnData; a token without blocked() counts as not blocked.
    function test_noReturnDataTransferAndMissingBlockedAreAccepted() public {
        _fund(100 ether);
        bytes memory saved = IMD_ADDR.code;
        vm.etch(IMD_ADDR, address(new NoReturnIMD()).code);
        assertEq(NoReturnIMD(IMD_ADDR).balanceOf(address(vault)), 100 ether, "balances survived the etch");
        assertEq(vault.inferenceReserve(), 70 ether);
        (,,,, bool ready) = keeper.preview();
        assertTrue(ready);
        vm.prank(caller);
        (uint256 toStakers, uint256 fee) = keeper.sweep();
        assertEq(NoReturnIMD(IMD_ADDR).balanceOf(caller), fee);
        assertEq(NoReturnIMD(IMD_ADDR).balanceOf(address(staking)), toStakers);
        assertEq(vault.inferenceReserve(), FULL);
        vm.etch(IMD_ADDR, saved);
    }

    /// periodFinish == block.timestamp: both sides see leftover 0; the tenth rule is off; any added >= 7 days wei streams.
    function test_periodFinishExactlyNowIsTreatedAsEnded() public {
        _fund(100 ether);
        keeper.sweep();
        vm.warp(staking.periodFinish());
        assertEq(staking.streamRemaining(), 0);
        _fund(2 ether); // overflow 1.4 (would fail the tenth rule a second earlier)
        (,,, bool willNotify,) = keeper.preview();
        assertTrue(willNotify);
        keeper.sweep();
        assertEq(staking.unnotified(), 0);
    }

    /// The tenth rule boundary: added == leftover/10 passes on both sides; one wei less parks on both sides.
    function test_tenthRuleBoundaryMirrorsExactly() public {
        _fund(100 ether);
        keeper.sweep();
        skip(1 days);
        uint256 leftover = staking.streamRemaining();
        uint256 need = leftover / 10; // toStakers needed
        // amount such that amount - amount*50/10000 == need (search the few candidates).
        uint256 amount = need * 10_000 / 9_950;
        while (amount - amount * 50 / 10_000 < need) amount++;
        uint256 toStakers = amount - amount * 50 / 10_000;
        assertEq(toStakers, need, "exact preimage exists");
        // Vault funding that raises inference by exactly `amount`: x - floor(0.3x) == amount; try nearby x.
        uint256 x = amount * 10_000 / 7_000;
        while (x - ((x / 10_000) * 3000 + (x % 10_000) * 3000 / 10_000) < amount) x++;
        assertEq(x - ((x / 10_000) * 3000 + (x % 10_000) * 3000 / 10_000), amount, "exact vault preimage");
        _fund(x);
        assertEq(keeper.overflow(), amount);
        (,,, bool willNotify,) = keeper.preview();
        assertTrue(willNotify, "added == leftover/10 passes");
        keeper.sweep();
        assertEq(staking.unnotified(), 0);
    }

    /// The Safe's own float is never touched and the right nominal amount is forwarded regardless of it.
    function test_safeFloatIsIgnoredNotForwarded() public {
        assertTrue(imd.transfer(SAFE, 1000 ether));
        _fund(100 ether);
        keeper.sweep();
        assertEq(imd.balanceOf(SAFE), 1000 ether);
        assertEq(imd.balanceOf(address(staking)), 44.775 ether);
    }

    /// Safe 1.5.0 fidelity: a module guard's checkAfterModuleExecution can veto after the inner call succeeded; the
    /// whole sweep reverts (the plain MockSafe has no guard hooks). The keeper reverts with the guard's reason.
    function test_moduleGuardVetoRevertsTheWholeSweep() public {
        _fund(100 ether);
        vm.etch(SAFE, address(new GuardedMockSafe()).code);
        GuardedMockSafe gs = GuardedMockSafe(SAFE);
        gs.enableModule(address(keeper));
        (,,,, bool ready) = keeper.preview();
        assertTrue(ready);
        keeper.sweep(); // no guard: fine
        assertEq(vault.inferenceReserve(), FULL);
        _fund(100 ether);
        gs.setModuleGuard(address(new VetoAfterGuard()));
        vm.expectRevert("guard veto"); // bubbles straight through the Safe and the keeper; nothing moved
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL + 70 ether);
    }

    /// Selector pinned: Safe 1.5.0 `execTransactionFromModuleReturnData(address,uint256,bytes,uint8)` = 0x5229073f
    /// (Enum.Operation is uint8 in the ABI). Operation 0 = CALL.
    function test_safeSelectorIsPinned() public pure {
        assertEq(bytes4(keccak256("execTransactionFromModuleReturnData(address,uint256,bytes,uint8)")), bytes4(0x5229073f));
    }
}

// ==================================================================== stateful fuzz: the mirror and the ledger

/// @dev Random funding, seizures, time, stake/unstake, direct notify() calls, claims and sweeps. After every sweep:
///      reserve == full, buyback unchanged, Safe float unchanged, keeper holds nothing, and — the mirror — if the
///      keeper did not notify then a direct notify() must revert now (else IMD parked needlessly); if it did
///      notify, unnotified() == 0. With minSweep = 1 IMD the mirror holds exactly (F2 needs the dust floor).
contract KeeperHandler is Test {
    SvoStaking public staking;
    OverflowKeeper public keeper;
    LifeForceVault public vault;
    MockIMD public imd;
    address public constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    address public alice;
    uint256 public full;
    uint256 public sweeps;
    uint256 public parked;
    uint256 public streamed;
    uint256 public mirrorViolations;

    constructor(SvoStaking s, OverflowKeeper k, LifeForceVault v, MockIMD i, address a) {
        staking = s;
        keeper = k;
        vault = v;
        imd = i;
        alice = a;
        full = k.full();
    }

    function fund(uint96 raw, bool sync) external {
        uint256 amt = bound(raw, 0, raw % 7 == 0 ? 400 ether : 8 ether); // mostly small lots, sometimes a big one, so parks happen
        if (imd.balanceOf(address(this)) < amt) return;
        imd.transfer(address(vault), amt);
        if (sync) vault.sync();
    }

    function seize(uint16 bps) external {
        uint256 amt = imd.balanceOf(address(vault)) * bound(bps, 0, 2_000) / 10_000;
        if (amt == 0) return;
        vm.prank(address(vault));
        imd.transfer(address(0xDEAD), amt);
    }

    function warp(uint32 secs) external {
        skip(bound(secs, 0, 3 days));
    }

    function stakeAlice(uint96 raw) external {
        uint256 amt = bound(raw, 1, 1_000_000 ether);
        vm.startPrank(alice);
        try staking.stake(amt) {} catch {}
        vm.stopPrank();
    }

    function unstakeAll() external {
        uint256 s = staking.staked(alice);
        if (s == 0) return;
        vm.prank(alice);
        staking.unstake(s);
    }

    function claimAlice() external {
        vm.prank(alice);
        staking.claim();
    }

    function directNotify() external {
        try staking.notify() {} catch {}
    }

    function sweep() external {
        uint256 over = keeper.overflow();
        if (over < keeper.minSweep()) return;
        uint256 buyback = vault.buybackReserve();
        uint256 safeBefore = imd.balanceOf(SAFE);
        (, uint256 fee, uint256 toStakers, bool willNotify, bool ready) = keeper.preview();
        assertTrue(ready);
        vm.recordLogs();
        (uint256 gotTo, uint256 gotFee) = keeper.sweep();
        sweeps++;
        assertEq(gotTo, toStakers);
        assertEq(gotFee, fee);
        assertEq(vault.inferenceReserve(), full, "reserve == full after sweep");
        assertEq(vault.buybackReserve(), buyback, "buyback unchanged");
        assertEq(imd.balanceOf(SAFE), safeBefore, "safe float unchanged");
        assertEq(imd.balanceOf(address(keeper)), 0);
        // Did it notify? Read the Swept event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool notified;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(keeper) && logs[i].topics[0] == keccak256("Swept(address,uint256,uint256,uint256,bool)")) {
                (,,, notified) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                found = true;
            }
        }
        assertTrue(found);
        assertEq(notified, willNotify, "preview predicted notify");
        if (notified) {
            streamed++;
            assertEq(staking.unnotified(), 0);
        } else {
            parked++;
            // The mirror: notify() must revert right now, else the keeper parked needlessly.
            try staking.notify() {
                mirrorViolations++;
            } catch {}
        }
    }
}

contract AdversarialKeeperBInvariant is StdInvariant, SystemBase {
    SvoStaking internal staking;
    OverflowKeeper internal keeper;
    KeeperHandler internal handler;
    address internal constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;

    function setUp() public {
        _system(false);
        deployCodeTo("OverflowKeeper.t.sol:MockSafe", "", SAFE);
        staking = new SvoStaking(token, IMD_ADDR, address(this));
        keeper = new OverflowKeeper(vault, staking, 25 ether, 1 ether);
        MockSafe(SAFE).enableModule(address(keeper));
        handler = new KeeperHandler(staking, keeper, vault, imd, ALICE);
        imd.transfer(address(handler), 1e30);
        vm.prank(ALICE);
        token.approve(address(staking), type(uint256).max);
        targetContract(address(handler));
    }

    function invariant_mirrorAndLedger() public view {
        assertEq(handler.mirrorViolations(), 0, "keeper parked IMD that notify() would have streamed");
        assertEq(imd.balanceOf(address(keeper)), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), imd.balanceOf(address(vault)));
        assertEq(imd.balanceOf(SAFE), 0, "the Safe never keeps anything");
    }

    function invariant_callSummary() public view {
        // Not an assertion: surfaces coverage in -vv output via the handler's counters.
        handler.sweeps();
    }

    /// Same handler driven by 32 fixed seeds x 96 steps on one state, so the sweep/park/stream counts show in -vv.
    function test_sequenceCoverage() public {
        for (uint256 i = 0; i < 32 * 96; i++) {
            uint256 r = uint256(keccak256(abi.encode("keeperB", i)));
            uint256 op = r % 8;
            if (op == 0) handler.fund(uint96(r >> 8), (r >> 200) & 1 == 1);
            else if (op == 1) handler.seize(uint16(r >> 8));
            else if (op == 2) handler.warp(uint32(r >> 8));
            else if (op == 3) handler.stakeAlice(uint96(r >> 8));
            else if (op == 4) handler.unstakeAll();
            else if (op == 5) handler.claimAlice();
            else if (op == 6) handler.directNotify();
            else handler.sweep();
        }
        assertEq(handler.mirrorViolations(), 0);
        console2.log("sweeps/parked/streamed", handler.sweeps(), handler.parked(), handler.streamed());
    }
}
