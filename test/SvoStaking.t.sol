// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SvoStaking} from "../src/SvoStaking.sol";

contract SvoStakingTest is Test {
    SovrnToken t;
    SvoStaking s;
    address dead;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant POOL = 100_000_000 ether; // 10% of supply
    uint256 constant YEAR = 365 days;

    function setUp() public {
        t = new SovrnToken();
        s = new SvoStaking(t, address(this));
        dead = t.DEAD();
        t.transfer(alice, 10_000_000 ether);
        t.transfer(bob, 10_000_000 ether);
        vm.prank(alice);
        t.approve(address(s), type(uint256).max);
        vm.prank(bob);
        t.approve(address(s), type(uint256).max);
    }

    function _fund() internal {
        t.approve(address(s), POOL);
        s.fund(POOL);
    }

    // ------------------------------------------------------------ funding

    function test_fundSplitsAndLocksSchedule() public {
        _fund();
        assertEq(s.rewardsTotal() + s.matchTotal(), POOL);
        assertEq(s.rewardsTotal(), s.rewardRate() * YEAR);
        assertApproxEqAbs(s.rewardsTotal(), 60_000_000 ether, 1 ether); // rate is an integer per second
        assertEq(t.balanceOf(address(s)), POOL);
        assertEq(s.periodFinish(), s.start() + YEAR);
    }

    function test_fundOnlyFunderAndOnlyOnce() public {
        vm.prank(alice);
        vm.expectRevert(SvoStaking.Unauthorized.selector);
        s.fund(POOL);
        _fund();
        t.approve(address(s), 1 ether);
        vm.expectRevert(SvoStaking.AlreadyFunded.selector);
        s.fund(1 ether);
    }

    function test_nothingBeforeFunding() public {
        vm.prank(alice);
        vm.expectRevert(SvoStaking.NotFunded.selector);
        s.stake(1 ether);
        vm.expectRevert(SvoStaking.NotFunded.selector);
        s.matchBurn();
    }

    // ------------------------------------------------------------ rewards

    function test_soleStakerEarnsWholeStreamOverYear() public {
        _fund();
        vm.prank(alice);
        s.stake(1_000_000 ether);
        vm.warp(block.timestamp + YEAR + 10 days);
        vm.prank(alice);
        uint256 got = s.claim();
        assertApproxEqAbs(got, s.rewardsTotal(), 1 ether);
        assertEq(s.rewardsRemaining(), s.rewardsTotal() - got);
        assertEq(s.skipped(), 0);
    }

    function test_rewardsSplitProRata() public {
        _fund();
        vm.prank(alice);
        s.stake(3_000_000 ether);
        vm.prank(bob);
        s.stake(1_000_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 a = s.pendingRewards(alice);
        uint256 b = s.pendingRewards(bob);
        assertApproxEqRel(a, 3 * b, 1e12);
        assertApproxEqAbs(a + b, s.rewardRate() * 30 days, 1e6);
    }

    function test_unstakeStopsAccrualAndReturnsPrincipal() public {
        _fund();
        vm.startPrank(alice);
        s.stake(2_000_000 ether);
        vm.warp(block.timestamp + 10 days);
        s.unstake(2_000_000 ether);
        uint256 frozen = s.pendingRewards(alice);
        vm.warp(block.timestamp + 10 days);
        assertEq(s.pendingRewards(alice), frozen);
        assertEq(t.balanceOf(alice), 10_000_000 ether);
        s.claim();
        assertEq(t.balanceOf(alice), 10_000_000 ether + frozen);
        vm.stopPrank();
    }

    function test_emissionWithNobodyStakedIsBurnedNotPaid() public {
        _fund();
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        s.stake(1_000_000 ether);
        assertEq(s.skipped(), s.rewardRate() * 10 days);
        uint256 amt = s.skipped();
        s.burnSkipped();
        assertEq(t.balanceOf(dead), amt);
        assertEq(s.skipped(), 0);
        // skipped burn is not external, so it must not be matched
        assertEq(s.unmatchedBurns(), 0);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_cannotUnstakeMoreThanStaked() public {
        _fund();
        vm.startPrank(alice);
        s.stake(1 ether);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.unstake(1 ether + 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ access tier

    function test_accessNeedsMinStakeAndAge() public {
        _fund();
        vm.startPrank(alice);
        s.stake(999_999 ether);
        vm.warp(block.timestamp + 2 days);
        assertFalse(s.hasAccess(alice)); // under threshold
        s.stake(1 ether);
        assertFalse(s.hasAccess(alice)); // top-up restarts the age
        vm.warp(block.timestamp + 1 days - 1);
        assertFalse(s.hasAccess(alice));
        vm.warp(block.timestamp + 1);
        assertTrue(s.hasAccess(alice));
        s.unstake(1 ether);
        assertFalse(s.hasAccess(alice));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ burn-match

    function test_matchBurnMatchesExternalBurnsUpToVested() public {
        _fund();
        uint256 mp = s.matchTotal();
        vm.warp(block.timestamp + 100 days);
        uint256 vested = s.matchAvailable();
        assertEq(vested, mp * 100 days / YEAR);

        vm.prank(alice);
        t.transfer(dead, 1_000 ether); // someone burns
        assertEq(s.unmatchedBurns(), 1_000 ether);
        uint256 before = t.balanceOf(dead);
        uint256 m = s.matchBurn();
        assertEq(m, 1_000 ether);
        assertEq(t.balanceOf(dead), before + 1_000 ether);
        assertEq(s.unmatchedBurns(), 0); // own burn not re-matched
        assertEq(s.matchUsed(), 1_000 ether);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_matchBurnIsCappedByVestingAndCarriesRemainder() public {
        _fund();
        vm.warp(block.timestamp + 1 days);
        uint256 avail = s.matchAvailable();
        vm.prank(alice);
        t.transfer(dead, avail + 5_000 ether);
        uint256 m = s.matchBurn();
        assertEq(m, avail);
        assertEq(s.unmatchedBurns(), 5_000 ether); // carried
        vm.warp(block.timestamp + 10 days);
        m = s.matchBurn();
        assertEq(m, 5_000 ether);
        assertEq(s.unmatchedBurns(), 0);
    }

    function test_burnsBeforeFundingAreNotMatched() public {
        t.transfer(dead, 7 ether);
        _fund();
        vm.warp(block.timestamp + 30 days);
        assertEq(s.unmatchedBurns(), 0);
        vm.expectRevert(SvoStaking.InvalidAmount.selector);
        s.matchBurn();
    }

    function test_matchPoolNeverExceedsTotal() public {
        _fund();
        vm.warp(block.timestamp + 2 * YEAR);
        t.transfer(dead, 90_000_000 ether);
        uint256 m = s.matchBurn();
        assertEq(m, s.matchTotal());
        assertEq(s.matchRemaining(), 0);
        assertEq(s.matchAvailable(), 0);
    }

    // ------------------------------------------------------------ conservation

    /// Whatever stakers and burners do, the contract can always cover principal + owed rewards + match pool.
    function testFuzz_contractStaysSolvent(uint256 aAmt, uint256 bAmt, uint256 dt1, uint256 dt2, uint256 burnAmt) public {
        aAmt = bound(aAmt, 1 ether, 10_000_000 ether);
        bAmt = bound(bAmt, 1 ether, 10_000_000 ether);
        dt1 = bound(dt1, 0, 400 days);
        dt2 = bound(dt2, 0, 400 days);
        burnAmt = bound(burnAmt, 0, 50_000_000 ether);
        _fund();
        vm.prank(alice);
        s.stake(aAmt);
        vm.warp(block.timestamp + dt1);
        vm.prank(bob);
        s.stake(bAmt);
        t.transfer(dead, burnAmt);
        if (s.unmatchedBurns() > 0 && s.matchAvailable() > 0) s.matchBurn();
        vm.warp(block.timestamp + dt2);
        if (s.skipped() > 0 || block.timestamp > s.start()) {
            try s.burnSkipped() {} catch {}
        }
        uint256 owed = s.pendingRewards(alice) + s.pendingRewards(bob);
        uint256 need = s.totalStaked() + owed + (s.matchTotal() - s.matchUsed());
        assertGe(t.balanceOf(address(s)), need);
        vm.prank(alice);
        s.claim();
        vm.prank(bob);
        s.claim();
        vm.prank(alice);
        s.unstake(aAmt);
        vm.prank(bob);
        s.unstake(bAmt);
        assertEq(s.totalStaked(), 0);
        assertGe(t.balanceOf(address(s)), s.matchTotal() - s.matchUsed());
    }
}
