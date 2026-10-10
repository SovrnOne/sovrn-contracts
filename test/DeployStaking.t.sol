// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SvoStaking} from "../src/SvoStaking.sol";
import {DeployStaking} from "../script/DeployStaking.s.sol";

/// Runs the deploy and fund script offline against a stand-in IMD, and (when FORK_4663_RPC is set) the staking
/// flow against the REAL IMD on a fork of Robinhood Chain:
///   FORK_4663_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract StakingFork -vv
contract DeployStakingTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    SovrnToken svo;
    DeployStaking script;

    function setUp() public {
        vm.chainId(4663);
        svo = new SovrnToken();
        svo.transfer(DEFAULT_SENDER, 200_000_000 ether); // scripts broadcast from Foundry's default sender
        vm.etch(IMD, address(new SovrnToken()).code);
        vm.setEnv("SVO_TOKEN", vm.toString(address(svo)));
        vm.setEnv("STAKING_FUNDER", vm.toString(DEFAULT_SENDER));
        script = new DeployStaking();
    }

    /// One test on purpose: the script reads process env vars, which parallel tests would overwrite.
    function test_deployFundAndGuards() public {
        // wrong chain is refused by both steps
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain"));
        script.run();
        vm.expectRevert(bytes("wrong chain"));
        script.fund();
        vm.chainId(4663);

        // the funder has no default
        vm.setEnv("STAKING_FUNDER", "");
        vm.expectRevert();
        script.run();
        vm.setEnv("STAKING_FUNDER", vm.toString(DEFAULT_SENDER));

        SvoStaking s = script.run();
        assertEq(address(s.token()), address(svo));
        assertEq(s.rewardToken(), IMD);
        assertEq(s.funder(), DEFAULT_SENDER);
        assertEq(s.matchStart(), 0);

        // a staking contract for a different token or reward token is refused before anything moves
        SvoStaking wrongToken = new SvoStaking(new SovrnToken(), IMD, DEFAULT_SENDER);
        vm.setEnv("STAKING_CONTRACT", vm.toString(address(wrongToken)));
        vm.expectRevert(bytes("STAKING_CONTRACT stakes a different token"));
        script.fund();
        SvoStaking wrongReward = new SvoStaking(svo, address(new SovrnToken()), DEFAULT_SENDER);
        vm.setEnv("STAKING_CONTRACT", vm.toString(address(wrongReward)));
        vm.expectRevert(bytes("STAKING_CONTRACT rewards a different token"));
        script.fund();
        vm.setEnv("STAKING_CONTRACT", vm.toString(address(s)));

        // a funder that holds too little is refused before anything moves
        vm.setEnv("STAKING_CONTRACT", vm.toString(address(s)));
        vm.setEnv("FUND_AMOUNT", "1000000000000000000000000000"); // 1B: more than the funder holds
        vm.expectRevert(bytes("funder holds less than FUND_AMOUNT"));
        script.fund();
        vm.stopBroadcast(); // a revert inside a script leaves the broadcast open in a test (a real run just aborts)

        vm.setEnv("FUND_AMOUNT", "100000000000000000000000000");
        script.fund();
        assertEq(s.matchTotal(), 100_000_000 ether);
        assertEq(svo.balanceOf(address(s)), 100_000_000 ether);
        vm.expectRevert(bytes("already funded"));
        script.fund();
    }
}

contract StakingForkTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    SovrnToken svo;
    SvoStaking s;
    address alice = address(0xA11CE);

    function setUp() public {
        string memory rpc = vm.envOr("FORK_4663_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "not chain 4663");
        svo = new SovrnToken();
        s = new SvoStaking(svo, IMD, address(this));
        svo.transfer(alice, 5_000_000 ether);
        vm.prank(alice);
        svo.approve(address(s), type(uint256).max);
    }

    /// The Safe sends IMD, anyone notifies, a staker claims, all with the real IMD token.
    function test_overflowStreamsWithRealIMD() public {
        deal(IMD, SAFE, 100 ether);
        uint256 alicePre = _imd(alice);
        vm.prank(alice);
        s.stake(2_000_000 ether);
        vm.prank(SAFE);
        (bool ok,) = IMD.call(abi.encodeWithSignature("transfer(address,uint256)", address(s), 70 ether));
        assertTrue(ok, "real IMD refused the transfer to the staking contract");
        s.notify();
        assertEq(s.unnotified(), 0);
        skip(7 days);
        vm.prank(alice);
        uint256 got = s.claim();
        assertApproxEqAbs(got, 70 ether, 1e12);
        assertEq(_imd(alice), alicePre + got);
        vm.prank(alice);
        s.unstake(2_000_000 ether);
        assertEq(svo.balanceOf(alice), 5_000_000 ether);
    }

    function _imd(address a) internal view returns (uint256 b) {
        (, bytes memory d) = IMD.staticcall(abi.encodeWithSignature("balanceOf(address)", a));
        b = abi.decode(d, (uint256));
    }
}
