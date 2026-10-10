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
    address constant SVO = 0x7f7e9b8e9f754c3076e514852552019CB571461b; // pinned in the script
    address constant SAFE = 0x589A639529220f66a2661A41753e3fd432f48DA0; // pinned funder
    SovrnToken svo = SovrnToken(SVO);
    DeployStaking script;

    function setUp() public {
        vm.chainId(4663);
        vm.etch(SVO, address(new SovrnToken()).code); // the real SVO address, with stand-in code
        vm.etch(IMD, address(new SovrnToken()).code);
        deal(SVO, DEFAULT_SENDER, 200_000_000 ether); // scripts broadcast from Foundry's default sender
        vm.setEnv("STAKING_FUNDER", vm.toString(SAFE));
        script = new DeployStaking();
    }

    /// One test on purpose: the script reads process env vars, which parallel tests would overwrite.
    function test_deployFundAndGuards() public {
        // wrong chain is refused by both steps (the chain is pinned, not read from the environment)
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain"));
        script.run();
        vm.expectRevert(bytes("wrong chain"));
        script.fund();
        vm.chainId(4663);

        // a token that is not the real SVO address is refused: the script no longer reads the token from env
        vm.etch(SVO, "");
        vm.expectRevert(bytes("SVO has no code on this chain"));
        script.run();
        vm.etch(SVO, address(new SovrnToken()).code);
        deal(SVO, DEFAULT_SENDER, 200_000_000 ether);

        // the funder has no default, and only the founder Safe is accepted unless explicitly overridden
        vm.setEnv("STAKING_FUNDER", "");
        vm.expectRevert();
        script.run();
        vm.setEnv("STAKING_FUNDER", vm.toString(DEFAULT_SENDER));
        vm.expectRevert(bytes("funder is not the founder Safe"));
        script.run();

        // the real deployment shape: funder = the Safe
        vm.setEnv("STAKING_FUNDER", vm.toString(SAFE));
        SvoStaking real = script.run();
        assertEq(address(real.token()), SVO);
        assertEq(real.rewardToken(), IMD);
        assertEq(real.funder(), SAFE);

        // rehearsal with an EOA funder, to exercise fund(): needs the explicit override
        // a leftover boolean from an old rehearsal does nothing: the override must name the exact funder
        vm.setEnv("ALLOW_OTHER_FUNDER", "true");
        vm.setEnv("STAKING_FUNDER", vm.toString(DEFAULT_SENDER));
        vm.expectRevert();
        script.run();
        vm.setEnv("ALLOW_OTHER_FUNDER", vm.toString(address(0xBEEF))); // names a different address
        vm.expectRevert(bytes("funder is not the founder Safe"));
        script.run();
        vm.setEnv("ALLOW_OTHER_FUNDER", vm.toString(DEFAULT_SENDER));
        SvoStaking s = script.run();
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

        // an amount that looks like whole tokens typed as wei is refused before anything is signed
        vm.setEnv("FUND_AMOUNT", "100000000");
        vm.expectRevert(bytes("FUND_AMOUNT is below 1,000,000 SVO: is it written in wei?"));
        script.fund();

        // an in-bounds typo (one zero short of 100,000,000 SVO) is refused unless explicitly overridden
        vm.setEnv("FUND_AMOUNT", "10000000000000000000000000");
        vm.expectRevert(bytes("FUND_AMOUNT is not 100,000,000 SVO (ALLOW_OTHER_AMOUNT=true to override)"));
        script.fund();

        // a funder that holds too little is refused before anything moves
        vm.setEnv("FUND_AMOUNT", "100000000000000000000000000");
        deal(SVO, DEFAULT_SENDER, 1 ether);
        vm.expectRevert(bytes("funder holds less than FUND_AMOUNT"));
        script.fund();
        vm.stopBroadcast(); // a revert inside a script leaves the broadcast open in a test (a real run just aborts)
        deal(SVO, DEFAULT_SENDER, 200_000_000 ether);

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
