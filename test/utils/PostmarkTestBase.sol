// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {PostmarkHook} from "../../src/PostmarkHook.sol";

/// @notice Shared fixture: fresh PoolManager, two ERC20s, a mined Postmark hook and a
/// dynamic-fee pool with liquidity.
abstract contract PostmarkTestBase is Deployers {
    PostmarkHook internal hook;
    PoolId internal poolId;

    uint160 internal constant POSTMARK_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUpPostmark() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), POSTMARK_FLAGS, type(PostmarkHook).creationCode, abi.encode(manager));
        hook = new PostmarkHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddress, "hook address mismatch");

        (key, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }
}
