// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {PostmarkHook} from "../../src/PostmarkHook.sol";
import {FlowVault} from "../../src/FlowVault.sol";
import {ScoreRegistry} from "../../src/ScoreRegistry.sol";

/// @notice Shared fixture: fresh PoolManager, two ERC20s, vault + registry, a mined Postmark hook,
/// and a dynamic-fee pool with liquidity.
abstract contract PostmarkTestBase is Deployers {
    PostmarkHook internal hook;
    FlowVault internal vault;
    ScoreRegistry internal registry;
    PoolId internal poolId;
    Currency internal bondCurrency;
    address internal guardian = makeAddr("guardian");

    /// @dev Settlement window used across the suite, and the vault withdraw cooldown that must
    /// cover it.
    uint32 internal constant WINDOW_BLOCKS = 30;

    uint160 internal constant POSTMARK_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUpPostmark() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new FlowVault(WINDOW_BLOCKS);
        registry = new ScoreRegistry();

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            POSTMARK_FLAGS,
            type(PostmarkHook).creationCode,
            abi.encode(manager, vault, registry, guardian)
        );
        hook = new PostmarkHook{salt: salt}(IPoolManager(address(manager)), vault, registry, guardian);
        require(address(hook) == hookAddress, "hook address mismatch");

        vault.setHook(address(hook));
        registry.setAuthorizedHook(address(hook), true);

        (key, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        bondCurrency = currency1;
    }

    /// @notice Fund `who` with both pool tokens and approve the swap router and the vault.
    function fundTrader(address who, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, amount);
        MockERC20(Currency.unwrap(currency1)).mint(who, amount);

        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Post a bond for `who` in the pool's bond currency.
    function bond(address who, uint256 amount) internal {
        vm.prank(who);
        vault.deposit(bondCurrency, amount);
    }
}
