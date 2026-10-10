// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SvoStaking} from "../src/SvoStaking.sol";

/// @notice Deploys SvoStaking on Robinhood Chain and, as a separate step, funds the burn-match pool.
///
///   The chain, the SVO token, the IMD token and the funder Safe are pinned below, not read from the environment, so a
///   wrong env var cannot point a deployment at a look-alike token, another chain or another funder.
///
///   Step 1, deploy (nothing is funded; any wallet can broadcast it, the funder is a constructor argument):
///     STAKING_FUNDER=0x589A639529220f66a2661A41753e3fd432f48DA0 forge script script/DeployStaking.s.sol --sig "run()" \
///       --rpc-url $RPC --private-key $KEY --broadcast
///   Step 2, fund. The funder here is a Safe, so do this as a Safe batch, not with this script:
///     SVO.approve(staking, amount) then staking.fund(amount), with amount = 100000000000000000000000000
///     (100,000,000 SVO written in WEI: 1e26, i.e. fund(100000000000000000000000000). fund() works only once and the
///     contract accepts any amount from 1,000,000 SVO to a tenth of supply, so simulate the batch first and check that
///     the amount is exactly 1e26 BEFORE signing; afterwards matchTotal() must read 1e26.)
///   fund() below is for an EOA funder only and checks everything it can before sending anything:
///     STAKING_CONTRACT=0x... FUND_AMOUNT=100000000000000000000000000 forge script script/DeployStaking.s.sol \
///       --sig "fund()" --rpc-url $RPC --private-key $KEY --broadcast
///
///   Omit --broadcast for a dry run. Before funding, compare STAKING_CONTRACT with the address in your own deploy
///   transaction: the script checks the contract's token, reward token and funder, but a contract written to lie about
///   them would pass those checks.
///
/// Env: STAKING_FUNDER (run(); must be FOUNDER_SAFE unless ALLOW_OTHER_FUNDER is set to that exact address, for
///      rehearsals), STAKING_CONTRACT and FUND_AMOUNT (fund(); must be 100,000,000 SVO unless ALLOW_OTHER_AMOUNT=true).
contract DeployStaking is Script {
    uint256 internal constant CHAIN_ID = 4663; // Robinhood Chain
    address internal constant SVO = 0x7f7e9b8e9f754c3076e514852552019CB571461b;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant FOUNDER_SAFE = 0x589A639529220f66a2661A41753e3fd432f48DA0; // 2-of-3, holds the founder SVO
    uint256 internal constant DEFAULT_FUND = 100_000_000 ether; // 10% of the 1B supply

    function run() external returns (SvoStaking staking) {
        require(block.chainid == CHAIN_ID, "wrong chain");
        require(SVO.code.length != 0, "SVO has no code on this chain");
        require(IMD.code.length != 0, "IMD has no code on this chain");
        require(SovrnToken(SVO).totalSupply() == 1_000_000_000 ether, "SVO is not SVO");
        require(keccak256(bytes(SovrnToken(SVO).symbol())) == keccak256("SVO"), "SVO symbol");

        address funder = vm.envAddress("STAKING_FUNDER"); // no default: the funder is permanent and holds reclaim()
        require(funder != address(0), "funder is zero");
        // The override names the one address it permits, so a leftover value from a rehearsal cannot apply to another funder.
        if (funder != FOUNDER_SAFE) {
            require(vm.envOr("ALLOW_OTHER_FUNDER", address(0)) == funder, "funder is not the founder Safe");
            console2.log("WARNING: funder is NOT the founder Safe (override in use)", funder);
        }

        vm.startBroadcast(); // the broadcaster need not be the funder (it may be a Safe)
        staking = new SvoStaking(SovrnToken(SVO), IMD, funder);
        vm.stopBroadcast();

        console2.log("SvoStaking", address(staking));
        console2.log("  staked/matched token (SVO)", SVO);
        console2.log("  reward token (IMD)", IMD);
        console2.log("  funder (permanent)", funder);
        console2.log("Set STAKING_CONTRACT on the app, then fund() from the funder.");
    }

    function fund() external {
        require(block.chainid == CHAIN_ID, "wrong chain");
        SvoStaking staking = SvoStaking(vm.envAddress("STAKING_CONTRACT"));
        uint256 amount = vm.envOr("FUND_AMOUNT", DEFAULT_FUND);
        require(address(staking).code.length != 0, "STAKING_CONTRACT has no code");
        require(staking.matchStart() == 0, "already funded");
        require(address(staking.token()) == SVO, "STAKING_CONTRACT stakes a different token");
        require(staking.rewardToken() == IMD, "STAKING_CONTRACT rewards a different token");
        require(amount >= staking.MIN_FUND(), "FUND_AMOUNT is below 1,000,000 SVO: is it written in wei?");
        // fund() works once, so a wrong amount inside the contract's bounds is permanent. Pin it like the funder.
        require(amount == DEFAULT_FUND || vm.envOr("ALLOW_OTHER_AMOUNT", false), "FUND_AMOUNT is not 100,000,000 SVO (ALLOW_OTHER_AMOUNT=true to override)");
        SovrnToken svo = SovrnToken(SVO);

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();
        require(caller == staking.funder(), "broadcaster is not the funder");
        require(svo.balanceOf(caller) >= amount, "funder holds less than FUND_AMOUNT");
        svo.approve(address(staking), amount);
        staking.fund(amount);
        vm.stopBroadcast();

        console2.log("Funded burn-match pool, whole SVO", amount / 1 ether);
        console2.log("Reclaimable by the funder after", staking.MATCH_DURATION(), "seconds");
    }
}
