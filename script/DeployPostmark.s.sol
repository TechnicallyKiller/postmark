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
    uint32 internal constant WITHDRAW_COOLDOWN_BLOCKS = 150;

    uint160 internal constant FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    /// @dev Read as a function so the check below cannot drift from the hook's own constant.
    function hook_W() internal pure returns (uint32) {
        return 100;
    }

    struct Deployment {
        address deployer;
        address poolManager;
        address vault;
        address registry;
        address hook;
        address guardian;
        PoolId poolId;
        bool pooled;
    }

    function run() external {
        Deployment memory d;
        uint256 pk = vm.envUint("PRIVATE_KEY");
        d.deployer = vm.addr(pk);
        d.poolManager = vm.envAddress("POOL_MANAGER");
        d.guardian = vm.envOr("GUARDIAN", d.deployer);

        require(WITHDRAW_COOLDOWN_BLOCKS >= hook_W(), "cooldown must cover the settlement window");
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 proxy on this chain");

        vm.startBroadcast(pk);
        (d.vault, d.registry, d.hook) = _deployStack(IPoolManager(d.poolManager), d.guardian);
        (d.poolId, d.pooled) = _maybeInitPool(IPoolManager(d.poolManager), d.hook);
        vm.stopBroadcast();

        _report(d);
    }

    function _deployStack(IPoolManager poolManager, address guardian)
        internal
        returns (address vaultAddr, address registryAddr, address hookAddr)
    {
        FlowVault vault = new FlowVault(WITHDRAW_COOLDOWN_BLOCKS);
        ScoreRegistry registry = new ScoreRegistry();

        bytes memory args = abi.encode(poolManager, vault, registry, guardian);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(PostmarkHook).creationCode, args);

        // Call the CREATE2 proxy directly rather than using `new Hook{salt: ...}`.
        //
        // `new` leaves the deployer up to how forge resolves CREATE2 on the particular chain, and
        // that does not always land on the proxy: it deployed to an unmined address on Unichain
        // Sepolia and reverted inside the hook's own permission check, while behaving correctly
        // against anvil. The salt is mined against CREATE2_DEPLOYER, so the deploy has to go
        // through CREATE2_DEPLOYER or the address will not carry the permission bits.
        (bool ok, bytes memory ret) =
            CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(PostmarkHook).creationCode, args));
        require(ok, "CREATE2 deploy failed");

        hookAddr = address(uint160(bytes20(ret)));
        require(hookAddr == predicted, "mined address mismatch");
        require(hookAddr.code.length != 0, "hook has no code");

        vault.setHook(hookAddr);
        registry.setAuthorizedHook(hookAddr, true);

        return (address(vault), address(registry), hookAddr);
    }

    function _maybeInitPool(IPoolManager poolManager, address hookAddr)
        internal
        returns (PoolId poolId, bool pooled)
    {
        address token0 = vm.envOr("TOKEN0", address(0));
        address token1 = vm.envOr("TOKEN1", address(0));
        if (token1 == address(0)) return (poolId, false);

        require(token0 < token1, "TOKEN0 must sort below TOKEN1");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // 1:1 starting price. sqrt(1) << 96.
        poolManager.initialize(key, 79228162514264337593543950336);
        return (key.toId(), true);
    }

    function _report(Deployment memory d) internal pure {
        console.log("--- Postmark deployed ---------------------------------");
        console.log("deployer      :", d.deployer);
        console.log("PoolManager   :", d.poolManager);
        console.log("FlowVault     :", d.vault);
        console.log("ScoreRegistry :", d.registry);
        console.log("PostmarkHook  :", d.hook);
        console.log("guardian      :", d.guardian);
        if (d.pooled) {
            console.log("pool id       :");
            console.logBytes32(PoolId.unwrap(d.poolId));
        } else {
            console.log("pool          : not initialised (set TOKEN0 and TOKEN1 to create one)");
        }
        console.log("-------------------------------------------------------");
    }
}
