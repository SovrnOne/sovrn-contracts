// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SvoStaking} from "../src/SvoStaking.sol";

/// @notice Deploys SvoStaking on Robinhood Chain and, as a separate step, funds the burn-match pool.
///
///   Step 1, deploy (nothing is funded):
///     SVO_TOKEN=0x... STAKING_FUNDER=0x... forge script script/DeployStaking.s.sol --sig "run()" \
///       --rpc-url $RPC --private-key $KEY --broadcast
///   Step 2, fund (the funder wallet must be the broadcaster; this is the founder allocation and is not
///   reversible except for the one-time reclaim() a year later):
///     STAKING_CONTRACT=0x... FUND_AMOUNT=100000000000000000000000000 forge script script/DeployStaking.s.sol \
///       --sig "fund()" --rpc-url $RPC --private-key $KEY --broadcast
///
///   Omit --broadcast for a dry run. If the funder is a Safe, do step 2 as a Safe batch instead:
///   SVO.approve(staking, amount) then staking.fund(amount).
///
/// Env: SVO_TOKEN (required, both steps), STAKING_FUNDER (required for run(); permanent, choose carefully),
///      EXPECT_CHAIN_ID (default 4663), FUND_AMOUNT (default 100,000,000 SVO), STAKING_CONTRACT (for fund()).
/// Before fund(), compare STAKING_CONTRACT with the address in your own deploy transaction: the script checks the
/// contract's token, reward token and funder, but a contract written to lie about them would pass those checks.
/// IMD is the pool's paired token on chain 4663; it is the reward token.
contract DeployStaking is Script {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 internal constant DEFAULT_FUND = 100_000_000 ether; // 10% of the 1B supply

    function run() external returns (SvoStaking staking) {
        require(block.chainid == vm.envOr("EXPECT_CHAIN_ID", uint256(4663)), "wrong chain");
        address svo = vm.envAddress("SVO_TOKEN");
        require(svo.code.length != 0, "SVO_TOKEN has no code");
        require(IMD.code.length != 0, "IMD has no code on this chain");
        require(SovrnToken(svo).totalSupply() == 1_000_000_000 ether, "SVO_TOKEN is not SVO");
        require(keccak256(bytes(SovrnToken(svo).symbol())) == keccak256("SVO"), "SVO_TOKEN symbol");

        address funder = vm.envAddress("STAKING_FUNDER"); // no default: the funder is permanent and holds reclaim()
        require(funder != address(0), "funder is zero");

        vm.startBroadcast(); // the broadcaster need not be the funder (it may be a Safe)
        staking = new SvoStaking(SovrnToken(svo), IMD, funder);
        vm.stopBroadcast();

        console2.log("SvoStaking", address(staking));
        console2.log("  staked/matched token (SVO)", svo);
        console2.log("  reward token (IMD)", IMD);
        console2.log("  funder (permanent)", funder);
        console2.log("Set STAKING_CONTRACT on the app, then fund() from the funder.");
    }

    function fund() external {
        require(block.chainid == vm.envOr("EXPECT_CHAIN_ID", uint256(4663)), "wrong chain");
        SvoStaking staking = SvoStaking(vm.envAddress("STAKING_CONTRACT"));
        uint256 amount = vm.envOr("FUND_AMOUNT", DEFAULT_FUND);
        require(address(staking).code.length != 0, "STAKING_CONTRACT has no code");
        require(staking.matchStart() == 0, "already funded");
        SovrnToken svo = staking.token();
        require(address(svo) == vm.envAddress("SVO_TOKEN"), "STAKING_CONTRACT stakes a different token");
        require(staking.rewardToken() == IMD, "STAKING_CONTRACT rewards a different token");

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();
        require(caller == staking.funder(), "broadcaster is not the funder");
        require(svo.balanceOf(caller) >= amount, "funder holds less than FUND_AMOUNT");
        svo.approve(address(staking), amount);
        staking.fund(amount);
        vm.stopBroadcast();

        console2.log("Funded burn-match pool (SVO wei)", amount);
        console2.log("Reclaimable by the funder after", staking.MATCH_DURATION(), "seconds");
    }
}
