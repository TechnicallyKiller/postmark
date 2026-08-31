// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {PostmarkHook} from "../src/PostmarkHook.sol";
import {FlowVault} from "../src/FlowVault.sol";
import {GasProbe} from "./GasProbe.sol";

/// @notice Stands up a live Postmark pool and drives real flow through it, alongside an identical
/// vanilla pool so the hook's on-chain gas overhead can be read off the two receipts.
///
/// Deploys two test tokens, opens both pools, seeds them with the same liquidity, posts a bond, and
/// swaps through each. The Postmark swap attests the sender as the payer via `hookData`, which is
/// how a router names its end user.
///
///   forge script script/SetupPool.s.sol:SetupPool \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
///
/// Required env: PRIVATE_KEY, POOL_MANAGER, POSTMARK_HOOK, FLOW_VAULT,
///               POOL_SWAP_TEST, POOL_MODIFY_LIQUIDITY_TEST
contract SetupPool is Script {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant VANILLA_FEE = 3000;

    /// @dev Wide enough that the swaps below move the price a little without slamming a limit.
    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int128 internal constant LIQUIDITY = 1e18;

    uint256 internal constant MINT = 1_000_000e18;
    uint256 internal constant BOND = 1e18;
    uint256 internal constant SWAP_IN = 1e15;

    /// @dev Rounds of (vanilla, postmark) swaps. The last round is the one worth reading.
    uint256 internal constant WARMUP_ROUNDS = 5;

    struct Env {
        address me;
        IPoolManager pm;
        PostmarkHook hook;
        FlowVault vault;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest lpRouter;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Env memory e = Env({
            me: vm.addr(pk),
            pm: IPoolManager(vm.envAddress("POOL_MANAGER")),
            hook: PostmarkHook(vm.envAddress("POSTMARK_HOOK")),
            vault: FlowVault(vm.envAddress("FLOW_VAULT")),
            swapRouter: PoolSwapTest(vm.envAddress("POOL_SWAP_TEST")),
            lpRouter: PoolModifyLiquidityTest(vm.envAddress("POOL_MODIFY_LIQUIDITY_TEST"))
        });

        vm.startBroadcast(pk);
        (PoolKey memory pmKey, PoolKey memory vanillaKey) = _openPools(e);
        _seedAndSwap(e, pmKey, vanillaKey);
        vm.stopBroadcast();

        _report(pmKey, vanillaKey);
    }

    function _openPools(Env memory e) internal returns (PoolKey memory pmKey, PoolKey memory vanillaKey) {
        (Currency c0, Currency c1) =
            _deployTokens(e.me, address(e.swapRouter), address(e.lpRouter), address(e.vault));

        pmKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(e.hook))
        });
        vanillaKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: VANILLA_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        e.pm.initialize(pmKey, SQRT_PRICE_1_1);
        e.pm.initialize(vanillaKey, SQRT_PRICE_1_1);
    }

    function _seedAndSwap(Env memory e, PoolKey memory pmKey, PoolKey memory vanillaKey) internal {
        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0});
        e.lpRouter.modifyLiquidity(pmKey, lp, "");
        e.lpRouter.modifyLiquidity(vanillaKey, lp, "");

        // Bond in the quote asset, so the swap below is quoted a tier rather than the baseline.
        e.vault.deposit(pmKey.currency1, BOND);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory sp = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_IN),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // The probe measures each swap from inside the transaction and emits the number, because
        // forge's broadcast log cannot be trusted for this - its transaction labels and hashes do
        // not correspond. Give it its own tokens so it is the swap's msg.sender.
        // Two probes: one with a bond, one without. Bonding is what decides whether afterSwap
        // writes a receipt and locks collateral, so the two are materially different code paths and
        // both are worth a number.
        GasProbe bondedProbe = new GasProbe();
        GasProbe bareProbe = new GasProbe();
        _fundProbe(bondedProbe, pmKey, address(e.swapRouter));
        _fundProbe(bareProbe, pmKey, address(e.swapRouter));

        // The vault pulls from msg.sender, so the deployer funds the probe's bond on its behalf.
        e.vault.depositFor(address(bondedProbe), pmKey.currency1, BOND);

        // Alternating rounds, so every pool warms identically. The first swap into a fresh pool
        // pays for cold token balances and cold pool state, several times the cost of the next one,
        // so only the last round is a fair comparison.
        for (uint256 i = 0; i < WARMUP_ROUNDS; i++) {
            bondedProbe.probe(e.swapRouter, vanillaKey, sp, settings, "", false, i);
            bareProbe.probe(e.swapRouter, pmKey, sp, settings, abi.encode(address(bareProbe)), false, i);
            bondedProbe.probe(e.swapRouter, pmKey, sp, settings, abi.encode(address(bondedProbe)), true, i);
        }

        // One bonded swap from the deployer too, so the live pool has a receipt from a real payer.
        e.swapRouter.swap(pmKey, sp, settings, abi.encode(e.me));
    }

    function _fundProbe(GasProbe probe, PoolKey memory key, address router) internal {
        MockERC20(Currency.unwrap(key.currency0)).mint(address(probe), MINT);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(probe), MINT);
        probe.approveRouter(router, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
    }

    function _report(PoolKey memory pmKey, PoolKey memory vanillaKey) internal pure {
        console.log("--- Postmark pool live --------------------------------");
        console.log("token0        :", Currency.unwrap(pmKey.currency0));
        console.log("token1        :", Currency.unwrap(pmKey.currency1));
        console.log("postmark pool :");
        console.logBytes32(PoolId.unwrap(pmKey.toId()));
        console.log("vanilla pool  :");
        console.logBytes32(PoolId.unwrap(vanillaKey.toId()));
        console.log("");
        console.log("GasProbe emitted a SwapGas event per swap. Read them with:");
        console.log("  POSTMARK_HOOK=<hook> RPC=<rpc> python3 scripts/swap_gas.py");
        console.log("-------------------------------------------------------");
    }

    function _deployTokens(address me, address swapRouter, address lpRouter, address vault)
        internal
        returns (Currency c0, Currency c1)
    {
        MockERC20 a = new MockERC20("Postmark Test USD", "ptUSD", 18);
        MockERC20 b = new MockERC20("Postmark Test ETH", "ptETH", 18);
        a.mint(me, MINT);
        b.mint(me, MINT);

        // v4 requires currency0 < currency1.
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        t0.approve(swapRouter, type(uint256).max);
        t1.approve(swapRouter, type(uint256).max);
        t0.approve(lpRouter, type(uint256).max);
        t1.approve(lpRouter, type(uint256).max);
        t1.approve(vault, type(uint256).max);

        return (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
    }
}
