// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {SvoStaking} from "../src/SvoStaking.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {OverflowKeeper} from "../src/OverflowKeeper.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

/// @dev Same slice of a Safe as in OverflowKeeper.t.sol (storage slot 0 = enabled modules, so it can be etched over).
contract MockSafe {
    mapping(address => bool) public enabled;

    function enableModule(address m) external {
        enabled[m] = true;
    }

    function isModuleEnabled(address m) external view returns (bool) {
        return enabled[m];
    }

    function disableModule(address m) external {
        enabled[m] = false;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        virtual
        returns (bool success, bytes memory returnData)
    {
        require(enabled[msg.sender], "GS104");
        require(operation == 0, "call only");
        (success, returnData) = to.call{value: value}(data);
    }

    function callAs(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "callAs");
        return ret;
    }
}

/// @dev A Safe (or a module guard / singleton upgrade) whose module path reports success for a failed inner call.
///      Same storage layout as MockSafe so it can be etched over it.
contract LyingSafe is MockSafe {
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        override
        returns (bool success, bytes memory returnData)
    {
        require(enabled[msg.sender], "GS104");
        require(operation == 0, "call only");
        (, returnData) = to.call{value: value}(data);
        success = true; // lies
    }
}

/// @dev IMD whose `blocked(address)` answers with something that is not a bool (same layout as MockIMD).
contract GarbageBlockedIMD is MockIMD {
    constructor() MockIMD(0) {}

    function blocked(address) external pure returns (uint256) {
        return 2;
    }
}

contract AdversarialKeeperATest is SystemBase {
    event Swept(address indexed caller, uint256 amount, uint256 toStakers, uint256 fee, bool notified);

    SvoStaking internal staking;
    OverflowKeeper internal keeper;
    MockSafe internal safe;
    address internal constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    uint256 internal constant FULL = 25 ether;
    uint256 internal constant MIN_SWEEP = 1 ether;
    uint256 internal constant WEEK = 7 days;
    address internal attacker = address(0xBAD);

    function setUp() public {
        _system(false);
        deployCodeTo("AdversarialKeeperA.t.sol:MockSafe", "", SAFE);
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

    function _asSafe(bytes memory data) internal {
        safe.callAs(address(keeper), data);
    }

    // ============================================================ FINDINGS

    /// A1 (fixed): a fee-on-transfer IMD means less than `amount` arrives in the Safe. The sweep now reverts instead of
    /// paying the difference out of the Safe's own IMD. The Safe's float and the vault are untouched.
    function test_A1_feeOnTransferIMDMakesTheSweepRevertNotTheSafePay() public {
        assertTrue(imd.transfer(SAFE, 10 ether));
        _fund(100 ether); // inference 70, overflow 45
        imd.setFeeBps(100); // IMD starts charging 1% per transfer
        assertEq(keeper.overflow(), 45 ether);
        vm.expectRevert(abi.encodeWithSelector(OverflowKeeper.SafeBalanceMismatch.selector, 45 ether, 44.55 ether));
        vm.prank(attacker);
        keeper.sweep();
        assertEq(imd.balanceOf(SAFE), 10 ether, "the Safe's own IMD is untouched");
        assertEq(vault.inferenceReserve(), 70 ether, "nothing left the vault");
        assertEq(imd.balanceOf(attacker), 0);
    }

    /// A1 (fixed): a Safe that reports success for a failed withdrawal (a hypothetical singleton bug or a guard that
    /// swallows reverts) can no longer make the Safe pay sweeps from its own IMD: nothing arrived, so the sweep reverts.
    function test_A1_safeReportingSuccessForAFailedWithdrawCannotDrainTheSafe() public {
        assertTrue(imd.transfer(SAFE, 200 ether)); // the Safe's own IMD
        _fund(100 ether); // overflow 45 sits in the vault
        vm.etch(SAFE, address(new LyingSafe()).code); // storage kept: the keeper stays enabled
        imd.setRefuses(SAFE, true); // the vault's transfer to the Safe reverts -> withdrawInference reverts
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(abi.encodeWithSelector(OverflowKeeper.SafeBalanceMismatch.selector, 45 ether, 0));
            vm.prank(attacker);
            keeper.sweep();
        }
        assertEq(imd.balanceOf(SAFE), 200 ether, "the Safe's own IMD never moved");
        assertEq(imd.balanceOf(attacker), 0);
        assertEq(imd.balanceOf(address(staking)), 0);
    }

    /// FINDING A2 (low, economics/procedure): nothing above `full` can be kept once the module is enabled. Overflow
    /// already in the vault is sweepable in the same block as `enableModule`, and any later policy change by the Safe
    /// (setFull, disableModule), which is visible on the Safe transaction service before it executes, can be beaten
    /// by a sweep. The Safe's voice budget is then capped at `full` per refill: a manual withdrawal above it fails.
    function test_A2_sweepBeatsAPendingSafePolicyChangeAndCapsManualWithdrawals() public {
        _fund(100 ether); // live-like: inference 70 > full 25
        // The signers decide to keep 60 for a big OpenAI bill and queue setFull(60) + withdrawInference(40).
        vm.prank(attacker);
        keeper.sweep(); // lands first
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (60 ether)));
        assertEq(keeper.overflow(), 0);
        // The Safe's own withdrawal of 40 now fails: only `full` (25) is left for voice.
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vm.prank(SAFE);
        vault.withdrawInference(40 ether);
        assertEq(imd.balanceOf(address(staking)), 44.775 ether, "45 went to stakers, minus the bot's cut");
    }

    /// A3 (fixed): a staking contract for another token (where only the attacker is staked) is refused at construction,
    /// so it cannot be offered to the signers for enableModule.
    function test_A3_constructorRefusesAStakingContractForAnotherToken() public {
        vm.startPrank(attacker);
        SovrnToken other = new SovrnToken();
        SvoStaking rogue = new SvoStaking(other, IMD_ADDR, attacker);
        vm.expectRevert(OverflowKeeper.Unauthorized.selector);
        new OverflowKeeper(vault, rogue, FULL, MIN_SWEEP);
        vm.stopPrank();
    }

    /// A4 (fixed): a `blocked(address)` answer that is not a canonical bool no longer bricks the keeper. A non-zero word
    /// reads as blocked: preview() answers (not ready) and sweep() refuses with Blocked, both without a panic.
    function test_A4_nonBoolBlockedAnswerReadsAsBlockedWithoutPanic() public {
        _fund(100 ether);
        bytes memory saved = IMD_ADDR.code;
        vm.etch(IMD_ADDR, address(new GarbageBlockedIMD()).code);
        (,,,, bool ready) = keeper.preview();
        assertFalse(ready);
        vm.expectRevert(OverflowKeeper.Blocked.selector);
        keeper.sweep();
        vm.etch(IMD_ADDR, saved);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
    }

    /// A5 (fixed): the keeper folds emission that ran with nobody staked into its notify() prediction, exactly as
    /// notify() does, so it no longer parks IMD that the staking contract would have streamed.
    function test_A5_mirrorFoldsStaleUndistributedAndNotifies() public {
        vm.prank(ALICE);
        staking.unstake(1_000_000 ether); // nobody staked
        assertTrue(imd.transfer(address(staking), 100 * WEEK));
        staking.notify();
        skip(WEEK + 1);
        assertEq(staking.undistributed(), 0, "stale in storage: the fold happens inside notify()");
        _asSafe(abi.encodeCall(OverflowKeeper.setMinSweep, (keeper.MIN_SWEEP_FLOOR())));
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (vault.inferenceReserve() + 1)));
        _fund(1 ether);
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (vault.inferenceReserve() - 607840)));
        assertEq(keeper.overflow(), 607840);
        (,,, bool willNotify,) = keeper.preview();
        assertTrue(willNotify, "the keeper sees the rolled-over emission");
        vm.expectEmit(true, false, false, true, address(keeper));
        emit Swept(address(this), 607840, 607840 - 3039, 3039, true);
        keeper.sweep();
        assertEq(staking.unnotified(), 0, "streamed, not parked");
        assertGt(staking.streamRemaining(), 99 * WEEK, "the rolled-over stream is running again");
    }

    /// FINDING A6 (info, SvoStaking design surfaced by the keeper): the keeper restarts the stream at the first moment
    /// the tenth rule allows, which re-spreads what is left over a fresh 7 days. Stakers lose nothing in total, but the
    /// payout horizon keeps moving. Numbers: 44.775 streaming, day 3, +2.786 arrives -> rate falls 6.40 -> 4.05 IMD/day.
    function test_A6_earliestRestartStretchesThePayoutHorizon() public {
        _fund(100 ether);
        keeper.sweep(); // 44.775 over 7 days
        uint256 rate1 = staking.rewardRate();
        uint256 finish1 = staking.periodFinish();
        skip(3 days);
        uint256 leftover = staking.streamRemaining();
        assertApproxEqAbs(leftover, uint256(44.775 ether) * 4 / 7, 1e6);
        _fund(4 ether); // overflow 2.8 -> 2.786 to stakers >= leftover / 10
        (,,, bool willNotify,) = keeper.preview();
        assertTrue(willNotify);
        keeper.sweep();
        uint256 rate2 = staking.rewardRate();
        assertEq(staking.periodFinish(), finish1 + 3 days, "stream extended by 3 days");
        assertLt(rate2 * 100, rate1 * 64, "per-second rate fell by more than a third");
        // Stakers get everything eventually: 44.775 + 2.786.
        skip(WEEK);
        vm.prank(ALICE);
        assertApproxEqAbs(staking.claim(), 44.775 ether + 2.786 ether, 1e12);
    }

    // ============================================================ CHECKED AND SOUND

    /// Fee farming: sweeping at the smallest overflow repeatedly earns exactly what one big sweep would (fee is linear),
    /// and manufacturing overflow by donating to the vault loses 99.65% of the donation.
    function test_sound_feeFarmingBySplittingEarnsNothingExtra() public {
        _fund(uint256(FULL) * 10 / 7); // reserve exactly at full, overflow 0
        // 45 sweeps of ~1 IMD overflow each (1 IMD overflow needs 1/0.7 IMD funded).
        uint256 feeSplit;
        for (uint256 i; i < 45; i++) {
            _fund(uint256(10 ether) / 7 + 1); // overflow >= 1 IMD each time
            vm.prank(attacker);
            (, uint256 fee) = keeper.sweep();
            feeSplit += fee;
        }
        uint256 moved = imd.balanceOf(attacker) + imd.balanceOf(address(staking));
        assertEq(feeSplit, moved * 50 / 10_000, "0.5% of everything moved, however it is split");
        // Donation: 10 IMD in creates 7 IMD of overflow and a 0.035 IMD fee.
        assertTrue(imd.transfer(attacker, 10 ether));
        uint256 before = imd.balanceOf(attacker);
        vm.startPrank(attacker);
        imd.transfer(address(vault), 10 ether);
        (, uint256 fee2) = keeper.sweep();
        vm.stopPrank();
        assertEq(fee2, 0.035 ether);
        assertEq(imd.balanceOf(attacker), before - 10 ether + 0.035 ether);
    }

    /// IMD parked by a sweep that could not notify is never stranded: once the stream ends anyone streams it with a
    /// direct notify(); it never needs another sweep.
    function test_sound_parkedIMDStreamsAfterTheStreamEndsWithoutTheKeeper() public {
        _fund(100 ether);
        keeper.sweep(); // 44.775 streaming
        _fund(3 ether); // 2.1 overflow, below a tenth
        keeper.sweep();
        uint256 parked = staking.unnotified();
        assertGt(parked, 0);
        vm.expectRevert(SvoStaking.InvalidAmount.selector); // still under the tenth rule
        staking.notify();
        skip(WEEK);
        vm.prank(attacker); // anyone
        assertEq(staking.notify(), parked);
        assertEq(staking.unnotified(), 0);
    }

    /// Shortfall clamp: during a seizure the sweep only ever takes what the vault itself reports as inference, leaves
    /// exactly `full`, and the 70/30 split is restored when the IMD comes back. Buyback is never touched.
    function test_sound_sweepDuringAShortfallKeepsTheVaultsOwnAccounting() public {
        _fund(100 ether); // inference 70, buyback 30
        vm.prank(address(vault));
        imd.transfer(attacker, 50 ether); // a seizure: balance 50 < tracked 100
        assertEq(vault.inferenceReserve(), 50 ether);
        assertEq(vault.buybackReserve(), 0);
        assertEq(keeper.overflow(), 25 ether);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
        assertEq(imd.balanceOf(address(vault)), 25 ether);
        // The IMD comes back: inference checkpoint 45, buyback 30.
        vm.prank(attacker);
        imd.transfer(address(vault), 50 ether);
        assertEq(vault.inferenceReserve(), 45 ether);
        assertEq(vault.buybackReserve(), 30 ether);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
        assertEq(vault.buybackReserve(), 30 ether, "buyback untouched throughout");
        assertEq(imd.balanceOf(address(staking)), 24.875 ether + 19.9 ether, "exactly 70 - 25 reached stakers, minus fees");
    }

    /// The Safe's authority over the module is complete and the module's over the Safe is bounded: with the real IMD,
    /// the Safe's own IMD never moves, ETH never moves, and only the vault and IMD are ever called as the Safe.
    function test_sound_safeOwnIMDAndETHUntouchedWithExactIMD() public {
        assertTrue(imd.transfer(SAFE, 10 ether));
        vm.deal(SAFE, 1 ether);
        _fund(100 ether);
        vm.prank(attacker);
        keeper.sweep();
        assertEq(imd.balanceOf(SAFE), 10 ether);
        assertEq(SAFE.balance, 1 ether);
        // disableModule stops everything, and nothing is left in flight.
        _fund(100 ether);
        safe.disableModule(address(keeper));
        vm.expectRevert("GS104");
        keeper.sweep();
        assertEq(imd.balanceOf(address(keeper)), 0);
    }

    /// A blocked caller only blocks itself: the sweep reverts atomically and nothing is withdrawn.
    function test_sound_blockedCallerRevertsAtomically() public {
        _fund(100 ether);
        imd.setRefuses(attacker, true);
        vm.prank(attacker);
        vm.expectRevert();
        keeper.sweep();
        assertEq(vault.inferenceReserve(), 70 ether);
        imd.setRefuses(SAFE, true); // the Safe cannot receive: same
        vm.expectRevert();
        keeper.sweep();
        assertEq(vault.inferenceReserve(), 70 ether);
    }

    /// Reentrancy through the fee callback cannot change what the keeper then notifies: a hooked attacker that
    /// donates to staking and notifies mid-sweep only moves its own IMD; the sweep finishes without reverting.
    function test_sound_midSweepNotifyByTheFeeRecipientDoesNotBreakTheSweep() public {
        _fund(100 ether);
        MidSweepNotifier n = new MidSweepNotifier(keeper, staking, imd);
        imd.transfer(address(n), 50 ether);
        imd.setCallback(address(n));
        n.go();
        assertEq(vault.inferenceReserve(), FULL);
        // The attacker's 50 started a stream mid-sweep; the keeper's 44.775 is >= a tenth of it, so it streams too.
        assertEq(staking.unnotified(), 0);
        assertApproxEqAbs(staking.streamRemaining(), 94.775 ether, 1e7);
        assertEq(imd.balanceOf(address(n)), 0.225 ether, "paid the fee once");
    }

    /// The sweep's gas cost, for the fee economics.
    function test_sound_sweepGas() public {
        _fund(100 ether);
        uint256 g = gasleft();
        keeper.sweep();
        emit log_named_uint("sweep gas (notify path)", g - gasleft());
        _fund(3 ether);
        g = gasleft();
        keeper.sweep();
        emit log_named_uint("sweep gas (park path)", g - gasleft());
    }
}

/// @dev Fee recipient that, inside the IMD callback of its fee transfer, donates to staking and calls notify().
contract MidSweepNotifier {
    OverflowKeeper private immutable keeper;
    SvoStaking private immutable staking;
    MockIMD private immutable imd;

    constructor(OverflowKeeper k, SvoStaking s, MockIMD i) {
        keeper = k;
        staking = s;
        imd = i;
    }

    function go() external {
        keeper.sweep();
    }

    function tokensReceived(uint256) external {
        imd.transfer(address(staking), 50 ether);
        staking.notify();
    }
}
