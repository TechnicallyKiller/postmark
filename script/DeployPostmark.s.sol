// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {PostmarkHook} from "../src/PostmarkHook.sol";
import {FlowVault} from "../src/FlowVault.sol";
import {ScoreRegistry} from "../src/ScoreRegistry.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

/// @notice Deploys the Postmark stack and wires it.
///
/// The hook address has to carry its permission bits in the low 14 bits, so it is mined and
/// deployed through the canonical CREATE2 proxy. That proxy is the `deployer` the salt is mined
/// against — mining against the EOA instead produces a salt that yields a different address when
/// broadcast, and the constructor's own permission check then reverts.
///
///   forge script script/DeployPostmark.s.sol:DeployPostmark \
///     --rpc-url unichain_sepolia --broadcast --verify
///
/// Required env:
///   PRIVATE_KEY     deployer key
///   POOL_MANAGER    v4 PoolManager on the target chain
/// Optional env:
///   GUARDIAN        emergency-brake holder (defaults to the deployer)
///   TOKEN0/TOKEN1   if both are set, a dynamic-fee pool is initialised (must be sorted)
contract DeployPostmark is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev Deterministic CREATE2 proxy, same address on every chain forge broadcasts to.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Blocks a payer must wait after their last swap before withdrawing bond. Must be at
    /// least the hook's settlement window W, or a payer could outrun their own settlement.
    uint32 internal constant WITHDRAW_COOLDOWN_BLOCKS = 30;

    uint160 internal constant FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address guardian = vm.envOr("GUARDIAN", deployer);

        require(WITHDRAW_COOLDOWN_BLOCKS >= 5, "cooldown must cover the settlement window");

        vm.startBroadcast(pk);

        FlowVault vault = new FlowVault(WITHDRAW_COOLDOWN_BLOCKS);
        ScoreRegistry registry = new ScoreRegistry();

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            FLAGS,
            type(PostmarkHook).creationCode,
            abi.encode(poolManager, vault, registry, guardian)
        );

        PostmarkHook hook = new PostmarkHook{salt: salt}(poolManager, vault, registry, guardian);
        require(address(hook) == predicted, "mined address mismatch");

        vault.setHook(address(hook));
        registry.setAuthorizedHook(address(hook), true);

        PoolId poolId;
        bool pooled;
        address token0 = vm.envOr("TOKEN0", address(0));
        address token1 = vm.envOr("TOKEN1", address(0));
        if (token1 != address(0)) {
            require(token0 < token1, "TOKEN0 must sort below TOKEN1");
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            // 1:1 starting price. sqrt(1) << 96.
            poolManager.initialize(key, 79228162514264337593543950336);
            poolId = key.toId();
            pooled = true;
        }

        vm.stopBroadcast();

        console.log("--- Postmark deployed ---------------------------------");
        console.log("chain id      :", block.chainid);
        console.log("deployer      :", deployer);
        console.log("PoolManager   :", address(poolManager));
        console.log("FlowVault     :", address(vault));
        console.log("ScoreRegistry :", address(registry));
        console.log("PostmarkHook  :", address(hook));
        console.log("guardian      :", guardian);
        console.log("bond cooldown :", WITHDRAW_COOLDOWN_BLOCKS, "blocks");
        if (pooled) {
            console.log("pool token0   :", token0);
            console.log("pool token1   :", token1);
            console.logBytes32(PoolId.unwrap(poolId));
        } else {
            console.log("pool          : not initialised (set TOKEN0 and TOKEN1 to create one)");
        }
        console.log("-------------------------------------------------------");
    }
}
