// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SvoStaking} from "../src/SvoStaking.sol";

/// IMD that can be told to refuse transfers, to show it cannot touch stakers' SVO.
contract BrokenIMD {
    mapping(address => uint256) public balanceOf;
    bool public broken;
    constructor() { balanceOf[msg.sender] = 1e27; }
    function setBroken(bool b) external { broken = b; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (broken) revert("blocked");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract SvoStakingTest is Test {
    SovrnToken svo;
    SovrnToken imd; // a plain 18-decimal ERC-20 stands in for IMD
    SvoStaking s;
    address dead;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant POOL = 100_000_000 ether; // 10% of supply
    uint256 constant WEEK = 7 days;

    function setUp() public {
        svo = new SovrnToken();
        imd = new SovrnToken();
        s = new SvoStaking(svo, address(imd), address(this));
        dead = svo.DEAD();
        svo.transfer(alice, 10_000_000 ether);
        svo.transfer(bob, 10_000_000 ether);
        vm.prank(alice);
        svo.approve(address(s), type(uint256).max);
        vm.prank(bob);
        svo.approve(address(s), type(uint256).max);
    }

    /// The Safe sends overflow IMD to the contract; anyone notifies.
    function _overflow(uint256 amt) internal {
        imd.transfer(address(s), amt);
        s.notify();
    }

    function _fundMatch() internal {
        svo.approve(address(s), POOL);
        s.fund(POOL);
    }

    // ------------------------------------------------------------ rewards (IMD overflow)

    function test_overflowStreamsToStakersOverAWeek() public {
        vm.prank(alice);
        s.stake(1_000_000 ether);
        _overflow(700 ether);
        assertEq(s.unnotified(), 0);
        skip(WEEK / 2);
        assertApproxEqAbs(s.pendingRewards(alice), 350 ether, 1e12);
        skip(WEEK);
        vm.prank(alice);
        uint256 got = s.claim();
        assertApproxEqAbs(got, 700 ether, 1e12);
        assertEq(imd.balanceOf(alice), got);
        assertEq(s.streamRemaining(), 0);
    }

    function test_proRataAndLateJoinerOnlyEarnsAfterJoining() public {
        vm.prank(alice);
        s.stake(3_000_000 ether);
        _overflow(700 ether);
        skip(WEEK / 2); // alice alone for half the week
        vm.prank(bob);
        s.stake(1_000_000 ether);
        skip(WEEK);
        // alice: 350 + 3/4 * 350, bob: 1/4 * 350
        assertApproxEqAbs(s.pendingRewards(alice), 350 ether + 262.5 ether, 1e12);
        assertApproxEqAbs(s.pendingRewards(bob), 87.5 ether, 1e12);
    }

    function test_secondOverflowExtendsStreamWithoutLosingLeftover() public {
        vm.prank(alice);
        s.stake(1_000_000 ether);
        _overflow(700 ether);
        skip(WEEK / 2);
        _overflow(350 ether); // leftover 350 + new 350 over a fresh week
        skip(WEEK);
        vm.prank(alice);
        assertApproxEqAbs(s.claim(), 1050 ether, 1e12);
    }

    function test_emissionWithNobodyStakedRollsIntoNextStream() public {
        _overflow(700 ether); // nobody staked
        skip(WEEK + 1 days);
        vm.prank(alice);
        s.stake(1_000_000 ether);
        assertEq(s.pendingRewards(alice), 0);
        s.notify(); // restarts the rolled-over IMD
        skip(WEEK);
        vm.prank(alice);
        assertApproxEqAbs(s.claim(), 700 ether, 1e12);
    }

    function test_notifyRevertsWithNothingToStream() public {
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.notify();
    }

    function test_unstakeStopsAccrualReturnsPrincipalKeepsRewards() public {
        vm.startPrank(alice);
        s.stake(2_000_000 ether);
        vm.stopPrank();
        _overflow(700 ether);
        skip(2 days);
        vm.startPrank(alice);
        s.unstake(2_000_000 ether);
        uint256 frozen = s.pendingRewards(alice);
        assertGt(frozen, 0);
        skip(3 days);
        assertEq(s.pendingRewards(alice), frozen);
        assertEq(svo.balanceOf(alice), 10_000_000 ether);
        assertEq(s.claim(), frozen);
        vm.stopPrank();
    }

    function test_cannotUnstakeMoreThanStaked() public {
        vm.startPrank(alice);
        s.stake(1 ether);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.unstake(1 ether + 1);
        vm.stopPrank();
    }

    function test_brokenIMDBlocksClaimButNeverPrincipal() public {
        BrokenIMD bad = new BrokenIMD();
        SvoStaking s2 = new SvoStaking(svo, address(bad), address(this));
        vm.prank(alice);
        svo.approve(address(s2), type(uint256).max);
        vm.prank(alice);
        s2.stake(2_000_000 ether);
        bad.transfer(address(s2), 700 ether);
        s2.notify();
        skip(WEEK);
        bad.setBroken(true);
        vm.prank(alice);
        vm.expectRevert(SvoStaking.TransferFailed.selector);
        s2.claim();
        vm.prank(alice);
        s2.unstake(2_000_000 ether); // principal is unaffected
        assertEq(svo.balanceOf(alice), 10_000_000 ether);
        bad.setBroken(false);
        vm.prank(alice);
        assertApproxEqAbs(s2.claim(), 700 ether, 1e12); // and the rewards are still there
    }

    // ------------------------------------------------------------ access tier

    function test_accessNeedsMinStakeAndAge() public {
        vm.startPrank(alice);
        s.stake(999_999 ether);
        skip(2 days);
        assertFalse(s.hasAccess(alice));
        s.stake(1 ether);
        assertFalse(s.hasAccess(alice)); // top-up restarts the age
        skip(1 days - 1);
        assertFalse(s.hasAccess(alice));
        skip(1);
        assertTrue(s.hasAccess(alice));
        s.unstake(1 ether);
        assertFalse(s.hasAccess(alice));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ funding and burn-match

    function test_fundOnlyFunderAndOnlyOnce() public {
        vm.prank(alice);
        vm.expectRevert(SvoStaking.Unauthorized.selector);
        s.fund(POOL);
        _fundMatch();
        assertEq(s.matchTotal(), POOL);
        svo.approve(address(s), 1 ether);
        vm.expectRevert(SvoStaking.AlreadyFunded.selector);
        s.fund(1 ether);
    }

    function test_matchBurnNeedsFunding() public {
        vm.expectRevert(SvoStaking.NotFunded.selector);
        s.matchBurn();
    }

    function test_matchBurnMatchesExternalBurnsUpToVested() public {
        _fundMatch();
        skip(100 days);
        assertEq(s.matchAvailable(), POOL * 100 days / 365 days);
        vm.prank(alice);
        svo.transfer(dead, 1_000 ether);
        assertEq(s.unmatchedBurns(), 1_000 ether);
        uint256 before = svo.balanceOf(dead);
        assertEq(s.matchBurn(), 1_000 ether);
        assertEq(svo.balanceOf(dead), before + 1_000 ether);
        assertEq(s.unmatchedBurns(), 0); // own burn not re-matched
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_matchBurnCappedByVestingAndCarriesRemainder() public {
        _fundMatch();
        skip(1 days);
        uint256 avail = s.matchAvailable();
        vm.prank(alice);
        svo.transfer(dead, avail + 5_000 ether);
        assertEq(s.matchBurn(), avail);
        assertEq(s.unmatchedBurns(), 5_000 ether);
        skip(10 days);
        assertEq(s.matchBurn(), 5_000 ether);
        assertEq(s.unmatchedBurns(), 0);
    }

    function test_burnsBeforeFundingAreNotMatched() public {
        svo.transfer(dead, 7 ether);
        _fundMatch();
        skip(30 days);
        assertEq(s.unmatchedBurns(), 0);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_matchPoolNeverExceedsTotal() public {
        _fundMatch();
        skip(2 * 365 days);
        svo.transfer(dead, 150_000_000 ether);
        assertEq(s.matchBurn(), POOL);
        assertEq(s.matchRemaining(), 0);
    }

    // ------------------------------------------------------------ conservation

    function testFuzz_contractStaysSolvent(uint256 aAmt, uint256 bAmt, uint256 over1, uint256 over2, uint256 dt1, uint256 dt2) public {
        aAmt = bound(aAmt, 1 ether, 10_000_000 ether);
        bAmt = bound(bAmt, 1 ether, 10_000_000 ether);
        over1 = bound(over1, 1 ether, 1_000_000 ether);
        over2 = bound(over2, 1 ether, 1_000_000 ether);
        dt1 = bound(dt1, 0, 20 days);
        dt2 = bound(dt2, 0, 20 days);
        vm.prank(alice);
        s.stake(aAmt);
        _overflow(over1);
        skip(dt1);
        vm.prank(bob);
        s.stake(bAmt);
        imd.transfer(address(s), over2);
        try s.notify() {} catch {} // may wait: under a tenth of what is left to stream
        skip(dt2);
        uint256 owed = s.pendingRewards(alice) + s.pendingRewards(bob);
        assertLe(owed, s.rewardsReserved());
        assertGe(imd.balanceOf(address(s)), s.rewardsReserved());
        vm.prank(alice);
        s.claim();
        vm.prank(bob);
        s.claim();
        assertGe(imd.balanceOf(address(s)), s.rewardsReserved());
        vm.prank(alice);
        s.unstake(aAmt);
        vm.prank(bob);
        s.unstake(bAmt);
        assertEq(s.totalStaked(), 0);
        assertEq(svo.balanceOf(address(s)), 0);
        assertEq(s.totalClaimed() + s.rewardsReserved() + s.unnotified(), over1 + over2);
    }

    // ------------------------------------------------------------ reclaim

    function test_reclaimOnlyFunderOnlyAfterAYearOnlyOnce() public {
        _fundMatch();
        vm.prank(alice);
        vm.expectRevert(SvoStaking.Unauthorized.selector);
        s.reclaim();
        skip(365 days - 1);
        vm.expectRevert(SvoStaking.TooEarly.selector);
        s.reclaim();
        skip(1);
        uint256 before = svo.balanceOf(address(this));
        assertEq(s.reclaim(), POOL);
        assertEq(svo.balanceOf(address(this)), before + POOL);
        assertEq(svo.balanceOf(address(s)), 0);
        assertEq(s.matchRemaining(), 0);
        vm.expectRevert(SvoStaking.AlreadyReclaimed.selector);
        s.reclaim();
        assertEq(s.unmatchedBurns(), 0);
        // the pool is closed: later burns are not matched
        svo.transfer(dead, 5 ether);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_reclaimMatchesWaitingBurnsFirst() public {
        _fundMatch();
        skip(365 days);
        svo.transfer(dead, 30_000_000 ether); // burned, not yet matched
        uint256 before = svo.balanceOf(address(this));
        uint256 returned = s.reclaim();
        assertEq(returned, POOL - 30_000_000 ether);
        assertEq(s.matchUsed(), 30_000_000 ether);
        assertEq(svo.balanceOf(address(this)), before + returned);
    }

    function test_reclaimNeedsFunding() public {
        vm.expectRevert(SvoStaking.NotFunded.selector);
        s.reclaim();
    }

    // ------------------------------------------------------------ audit fixes

    function test_freeNotifyCannotStretchTheStream() public {
        vm.prank(alice);
        s.stake(1_000_000 ether);
        _overflow(7000 ether);
        skip(6 days);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.notify(); // nothing new: must not push the last day's payout out to a fresh week
        imd.transfer(address(s), 1 wei);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.notify(); // dust does not count either
        assertEq(s.unnotified(), 1 wei);
        skip(1 days);
        vm.prank(alice);
        assertApproxEqAbs(s.claim(), 7000 ether, 1e12); // paid on the original schedule
    }

    function test_smallDepositWaitsThenStreamsOnceTheStreamEnds() public {
        vm.prank(alice);
        s.stake(1_000_000 ether);
        _overflow(700 ether);
        skip(1 days);
        imd.transfer(address(s), 10 ether); // far under a tenth of the ~600 left
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.notify();
        skip(WEEK);
        s.notify(); // stream over: now it starts, nothing was lost
        skip(WEEK);
        vm.prank(alice);
        assertApproxEqAbs(s.claim(), 710 ether, 1e12);
    }

    function test_deposit_ofATenthOrMoreExtendsTheStream() public {
        vm.prank(alice);
        s.stake(1_000_000 ether);
        _overflow(700 ether);
        skip(1 days);
        _overflow(60 ether); // exactly a tenth of the 600 left
        skip(WEEK);
        vm.prank(alice);
        assertApproxEqAbs(s.claim(), 760 ether, 1e12);
    }

    function test_claimRevertsIfRewardTokenHasNoCode() public {
        // an address that had code at deploy and lost it cannot make claim() look successful
        BrokenIMD bad = new BrokenIMD();
        SvoStaking s2 = new SvoStaking(svo, address(bad), address(this));
        vm.prank(alice);
        svo.approve(address(s2), type(uint256).max);
        vm.prank(alice);
        s2.stake(1_000_000 ether);
        bad.transfer(address(s2), 100 ether);
        s2.notify();
        skip(WEEK);
        vm.etch(address(bad), "");
        vm.prank(alice);
        vm.expectRevert(SvoStaking.TransferFailed.selector);
        s2.claim();
    }
}
