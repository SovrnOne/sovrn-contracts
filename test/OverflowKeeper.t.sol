// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {SvoStaking} from "../src/SvoStaking.sol";
import {OverflowKeeper} from "../src/OverflowKeeper.sol";
import {Guard} from "../src/Interfaces.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

/// @dev The part of a Safe a module touches, installed at the real refuel Safe address. Executes a module's call as
///      the Safe when the module is enabled, refuses (like GS104) otherwise.
contract MockSafe {
    mapping(address => bool) public enabled;

    function enableModule(address m) external {
        enabled[m] = true;
    }

    function disableModule(address m) external {
        enabled[m] = false;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        require(enabled[msg.sender], "GS104");
        require(operation == 0, "call only");
        (success, returnData) = to.call{value: value}(data);
    }

    /// @dev Lets a test act as the Safe for the keeper's setters.
    function callAs(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "callAs");
        return ret;
    }
}

/// @dev A caller that re-enters sweep() from the fee transfer (MockIMD's callback), to show the guard holds.
contract ReentrantCaller {
    OverflowKeeper private immutable keeper;
    bool public reentryBlocked;

    constructor(OverflowKeeper k) {
        keeper = k;
    }

    function go() external {
        keeper.sweep();
    }

    function tokensReceived(uint256) external {
        (bool ok,) = address(keeper).call(abi.encodeCall(OverflowKeeper.sweep, ()));
        reentryBlocked = !ok;
    }
}

/// @dev The IMD mock plus a `blocked(address)` blocklist, like the real token. Same storage layout as MockIMD with
///      the new mapping appended, so it can be etched over the live mock and keep every balance.
contract BlocklistIMD is MockIMD {
    mapping(address => bool) public blocked;

    constructor() MockIMD(0) {}

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }
}

contract OverflowKeeperTest is SystemBase {
    event Swept(address indexed caller, uint256 amount, uint256 toStakers, uint256 fee, bool notified);
    event FullSet(uint256 full);
    event MinSweepSet(uint256 minSweep);

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
        // One staker, so streamed IMD has somewhere to go.
        vm.startPrank(ALICE);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1_000_000 ether);
        vm.stopPrank();
    }

    /// @dev IMD sent straight to the vault, as pool fees are. 70% lands in the inference reserve.
    function _fund(uint256 amount) internal {
        assertTrue(imd.transfer(address(vault), amount));
        vault.sync();
    }

    function _asSafe(bytes memory data) internal {
        safe.callAs(address(keeper), data);
    }

    // ------------------------------------------------------------ constructor and settings

    function test_constructorPinsTheSystem() public view {
        assertEq(keeper.SAFE(), vault.REFUEL_SAFE());
        assertEq(keeper.IMD(), vault.IMD());
        assertEq(address(keeper.vault()), address(vault));
        assertEq(address(keeper.staking()), address(staking));
        assertEq(keeper.full(), FULL);
        assertEq(keeper.minSweep(), MIN_SWEEP);
        assertEq(keeper.FEE_BPS(), 50);
    }

    function test_constructorRefusesDustFloorAndWrongStaking() public {
        vm.expectRevert(OverflowKeeper.InvalidAmount.selector);
        new OverflowKeeper(vault, staking, FULL, 7 days - 1);
        // A staking contract whose reward token is not IMD.
        SvoStaking wrong = new SvoStaking(token, address(new BlocklistIMD()), address(this));
        vm.expectRevert(OverflowKeeper.Unauthorized.selector);
        new OverflowKeeper(vault, wrong, FULL, MIN_SWEEP);
    }

    function test_onlyTheSafeChangesSettings() public {
        vm.expectRevert(OverflowKeeper.Unauthorized.selector);
        keeper.setFull(1 ether);
        vm.expectRevert(OverflowKeeper.Unauthorized.selector);
        keeper.setMinSweep(2 ether);
        vm.expectEmit(false, false, false, true, address(keeper));
        emit FullSet(30 ether);
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (30 ether)));
        assertEq(keeper.full(), 30 ether);
        vm.expectEmit(false, false, false, true, address(keeper));
        emit MinSweepSet(2 ether);
        _asSafe(abi.encodeCall(OverflowKeeper.setMinSweep, (2 ether)));
        assertEq(keeper.minSweep(), 2 ether);
        vm.expectRevert("callAs");
        _asSafe(abi.encodeCall(OverflowKeeper.setMinSweep, (7 days - 1)));
    }

    // ------------------------------------------------------------ the sweep

    function test_sweepMovesOverflowPaysFeeAndStreams() public {
        _fund(100 ether); // inference 70, buyback 30
        assertEq(keeper.overflow(), 45 ether);
        (uint256 pAmount, uint256 pFee, uint256 pTo, bool pNotify, bool pReady) = keeper.preview();
        assertEq(pAmount, 45 ether);
        assertEq(pFee, 0.225 ether);
        assertEq(pTo, 44.775 ether);
        assertTrue(pNotify);
        assertTrue(pReady);

        uint256 safeBefore = imd.balanceOf(SAFE);
        vm.expectEmit(true, false, false, true, address(keeper));
        emit Swept(caller, 45 ether, 44.775 ether, 0.225 ether, true);
        vm.prank(caller);
        (uint256 toStakers, uint256 fee) = keeper.sweep();

        assertEq(toStakers, 44.775 ether);
        assertEq(fee, 0.225 ether);
        assertEq(imd.balanceOf(caller), 0.225 ether);
        assertEq(imd.balanceOf(address(staking)), 44.775 ether);
        assertEq(imd.balanceOf(SAFE), safeBefore, "the Safe keeps nothing");
        assertEq(vault.inferenceReserve(), FULL, "reserve is back at full health");
        assertEq(vault.buybackReserve(), 30 ether, "buyback untouched");
        assertEq(staking.unnotified(), 0, "everything is streaming");
        assertEq(staking.streamRemaining(), 44.775 ether - (44.775 ether % WEEK));
        assertEq(keeper.overflow(), 0);
        assertEq(imd.balanceOf(address(keeper)), 0, "the keeper holds nothing");

        skip(WEEK);
        vm.prank(ALICE);
        uint256 got = staking.claim();
        assertApproxEqAbs(got, 44.775 ether, 1e12);
    }

    function test_nothingToSweepBelowFullOrBelowMinSweep() public {
        _fund(30 ether); // inference 21 < full
        assertEq(keeper.overflow(), 0);
        vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
        keeper.sweep();
        _fund(5 ether); // inference 24.5 < full
        vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
        keeper.sweep();
        _fund(2 ether); // inference 25.9: overflow 0.9 < minSweep
        assertEq(keeper.overflow(), 0.9 ether);
        (,,,, bool ready) = keeper.preview();
        assertFalse(ready);
        vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
        keeper.sweep();
        _fund(1 ether); // overflow 1.6 >= minSweep
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
    }

    function test_sweepRefusesWhenNotEnabledAndWorksOnceEnabled() public {
        _fund(100 ether);
        safe.disableModule(address(keeper));
        vm.expectRevert("GS104"); // the Safe itself reverts for a module that is not enabled
        keeper.sweep();
        // Nothing moved.
        assertEq(vault.inferenceReserve(), 70 ether);
        safe.enableModule(address(keeper));
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
    }

    /// A small overflow while a big stream runs: the IMD is moved but notify() is skipped (it would revert), so the
    /// sweep never gets stuck; the next sweep big enough streams everything waiting.
    function test_smallSweepWaitsInsteadOfRevertingThenStreamsLater() public {
        _fund(100 ether);
        keeper.sweep(); // streams 44.775 over a week
        uint256 remaining = staking.streamRemaining();
        _fund(3 ether); // inference +2.1 => overflow 2.1, under a tenth of ~44.7
        assertLt(2.1 ether * 995 / 1000, remaining / 10);
        (uint256 amount,,, bool willNotify, bool ready) = keeper.preview();
        assertEq(amount, 2.1 ether);
        assertTrue(ready);
        assertFalse(willNotify);
        vm.expectEmit(true, false, false, true, address(keeper));
        emit Swept(address(this), 2.1 ether, 2.1 ether - 2.1 ether * 50 / 10_000, 2.1 ether * 50 / 10_000, false);
        keeper.sweep();
        uint256 waiting = staking.unnotified();
        assertEq(waiting, 2.1 ether - 2.1 ether * 50 / 10_000, "waits in the staking contract");
        assertEq(staking.streamRemaining(), remaining, "stream untouched");
        assertEq(vault.inferenceReserve(), FULL);
        // Enough new overflow: this sweep notifies the waiting IMD too.
        _fund(20 ether); // overflow 14
        (,,, willNotify,) = keeper.preview();
        assertTrue(willNotify);
        keeper.sweep();
        assertEq(staking.unnotified(), 0, "the waiting IMD streams with the new");
        assertGt(staking.streamRemaining(), remaining);
    }

    function test_sweepStillMovesWhenNobodyIsStakedAndAccountsAsUndistributed() public {
        vm.prank(ALICE);
        staking.unstake(1_000_000 ether);
        _fund(100 ether);
        keeper.sweep();
        assertEq(staking.unnotified(), 0);
        skip(WEEK);
        // Emission with nobody staked rolls into the next stream; nothing is lost to the keeper or the Safe.
        _fund(10 ether); // overflow 7
        keeper.sweep();
        assertGt(staking.undistributed() + staking.streamRemaining(), 44 ether);
    }

    function test_sweepRefusesWhenIMDBlocksTheStakingContract() public {
        _fund(100 ether);
        // Swap the IMD mock for one with a blocklist (same storage, balances kept) that blocks the staking contract.
        bytes memory saved = IMD_ADDR.code;
        vm.etch(IMD_ADDR, address(new BlocklistIMD()).code);
        BlocklistIMD(IMD_ADDR).setBlocked(address(staking), true);
        assertEq(vault.inferenceReserve(), 70 ether, "balances survived the swap");
        (,,,, bool ready) = keeper.preview();
        assertFalse(ready);
        vm.expectRevert(OverflowKeeper.Blocked.selector);
        keeper.sweep();
        vm.etch(IMD_ADDR, saved);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), FULL);
    }

    function test_sweepRevertsAsAWholeWhenTheTransferFails() public {
        _fund(100 ether);
        imd.setRefuses(address(staking), true);
        uint256 reserve = vault.inferenceReserve();
        vm.expectRevert();
        keeper.sweep();
        assertEq(vault.inferenceReserve(), reserve, "nothing withdrawn when the forward fails");
        imd.setRefuses(address(staking), false);
        imd.setReturnFalse(true);
        vm.expectRevert();
        keeper.sweep();
        imd.setReturnFalse(false);
        keeper.sweep();
    }

    function test_reentrancyFromTheFeeTransferIsBlocked() public {
        _fund(100 ether);
        ReentrantCaller rc = new ReentrantCaller(keeper);
        imd.setCallback(address(rc));
        rc.go();
        assertTrue(rc.reentryBlocked(), "the nested sweep reverted");
        assertEq(vault.inferenceReserve(), FULL);
        assertEq(imd.balanceOf(address(rc)), 0.225 ether, "paid once");
    }

    function test_fullCanBeRaisedSoLessIsSwept() public {
        _fund(100 ether);
        _asSafe(abi.encodeCall(OverflowKeeper.setFull, (60 ether)));
        assertEq(keeper.overflow(), 10 ether);
        keeper.sweep();
        assertEq(vault.inferenceReserve(), 60 ether);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_sweepLeavesExactlyFullAndSafeUnchanged(uint96 raw) public {
        uint256 amount = bound(raw, 0, 100_000 ether);
        _fund(amount);
        uint256 reserve = vault.inferenceReserve();
        uint256 buyback = vault.buybackReserve();
        uint256 safeBefore = imd.balanceOf(SAFE);
        uint256 over = reserve > FULL ? reserve - FULL : 0;
        if (over < MIN_SWEEP) {
            vm.expectRevert(OverflowKeeper.NothingToSweep.selector);
            vm.prank(caller);
            keeper.sweep();
            return;
        }
        vm.prank(caller);
        (uint256 toStakers, uint256 fee) = keeper.sweep();
        assertEq(toStakers + fee, over);
        assertEq(fee, over * 50 / 10_000);
        assertEq(vault.inferenceReserve(), FULL);
        assertEq(vault.buybackReserve(), buyback);
        assertEq(imd.balanceOf(SAFE), safeBefore);
        assertEq(imd.balanceOf(caller), fee);
        assertEq(imd.balanceOf(address(staking)), toStakers);
        assertEq(imd.balanceOf(address(keeper)), 0);
    }
}
