// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {SvoStaking} from "../src/SvoStaking.sol";
import {OverflowKeeper} from "../src/OverflowKeeper.sol";

/// @notice Deploys OverflowKeeper on Robinhood Chain. The vault, the staking contract, the Safe and IMD are pinned
///         below, not read from the environment, so a wrong env var cannot point it at a look-alike.
///
///   Deploy (any wallet can broadcast; the keeper has no owner):
///     forge script script/DeployKeeper.s.sol --sig "run()" --rpc-url $RPC --private-key $KEY --broadcast
///   Then, from the refuel Safe (2-of-3), ONE transaction: Safe.enableModule(<keeper>). Until then sweep() reverts
///   SafeCallFailed (the Safe answers GS104) and nothing can move. The Safe can disableModule() at any time.
///
///   Settings are PINNED: full = 25 IMD (the app's LIFE_FORCE_FULL_WEI) and minSweep = 1 IMD, written in WEI
///   (25 IMD is 25000000000000000000). A different value is taken only when ALLOW_OTHER_FULL / ALLOW_OTHER_MIN_SWEEP
///   names that exact wei value, so a leftover rehearsal variable cannot apply by accident. Later changes are Safe
///   transactions (setFull / setMinSweep). Omit --broadcast for a dry run. A keeper deployed with wrong settings is
///   harmless until enabled: deploy again and enable the right one.
contract DeployKeeper is Script {
    uint256 internal constant CHAIN_ID = 4663; // Robinhood Chain
    address internal constant VAULT = 0x2001318118e1B3DF1e653E0999926bdAa48A5A52;
    address internal constant STAKING = 0xe8ebB026Ff49f139aBc50C3Af64bdFebbF28f533;
    address internal constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 internal constant DEFAULT_FULL = 25 ether;
    uint256 internal constant DEFAULT_MIN_SWEEP = 1 ether;

    function run() external returns (OverflowKeeper keeper) {
        require(block.chainid == CHAIN_ID, "wrong chain");
        require(VAULT.code.length != 0, "vault has no code on this chain");
        require(STAKING.code.length != 0, "staking has no code on this chain");
        require(LifeForceVault(VAULT).REFUEL_SAFE() == SAFE, "vault's Safe is not the refuel Safe");
        require(LifeForceVault(VAULT).IMD() == IMD, "vault's IMD is not IMD");
        require(SvoStaking(STAKING).rewardToken() == IMD, "staking rewards a different token");
        // The override must name the exact value it permits (the DeployStaking pattern), never a bare flag.
        uint256 full = vm.envOr("ALLOW_OTHER_FULL", DEFAULT_FULL);
        uint256 minSweep = vm.envOr("ALLOW_OTHER_MIN_SWEEP", DEFAULT_MIN_SWEEP);
        require(full >= 1 ether, "full is below 1 IMD: is it written in wei?");
        require(minSweep >= 1 ether / 10, "minSweep is below 0.1 IMD: is it written in wei?");
        require(full > minSweep, "full must be above minSweep (arguments swapped?)");
        if (full != DEFAULT_FULL || minSweep != DEFAULT_MIN_SWEEP) console2.log("WARNING: non-default settings in use (ALLOW_OTHER_* set)");

        vm.startBroadcast();
        keeper = new OverflowKeeper(LifeForceVault(VAULT), SvoStaking(STAKING), full, minSweep);
        vm.stopBroadcast();

        // Read back what was deployed before anyone is asked to enable it.
        require(keeper.SAFE() == SAFE && keeper.IMD() == IMD, "keeper constants");
        require(address(keeper.vault()) == VAULT && address(keeper.staking()) == STAKING, "keeper wiring");
        require(keeper.full() == full && keeper.minSweep() == minSweep, "keeper settings");

        console2.log("OverflowKeeper", address(keeper));
        console2.log("  vault", VAULT);
        console2.log("  staking", STAKING);
        console2.log("  full (wei)", full);
        console2.log("  minSweep (wei)", minSweep);
        console2.log("  Safe", keeper.SAFE());
        console2.log("  IMD", keeper.IMD());
        console2.log("Next: verify the source, then from the refuel Safe ONE tx: enableModule(keeper). Then set OVERFLOW_KEEPER on the app.");
    }
}
