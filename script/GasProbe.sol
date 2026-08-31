// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GasProbe
/// @notice Measures the gas a swap actually costs, inside the transaction that performs it, and
/// emits the number.
///
/// @dev Reading gas out of forge's broadcast log does not work: its `transactions` and `receipts`
/// arrays are not aligned, and a transaction's `function` label does not correspond to its `hash` —
/// the first entry labelled `swap(...)` resolves on chain to a plain ERC20 call. Rather than parse
/// around that, the measurement happens where it cannot be misattributed.
///
/// The probe holds its own tokens and approves the router itself, so `msg.sender` for the swap is
/// the probe. Comparing two pools therefore compares like with like.
contract GasProbe {
    using PoolIdLibrary for PoolKey;

    /// @param hooked whether the pool being swapped carried a hook
    /// @param bonded whether the attested payer had a bond posted, which is what decides between
    /// the quote-only path and the full path that also writes a receipt and locks collateral
    event SwapGas(PoolId indexed poolId, uint256 gasUsed, bool hooked, bool bonded, uint256 round);

    function approveRouter(address router, address token0, address token1) external {
        IERC20(token0).approve(router, type(uint256).max);
        IERC20(token1).approve(router, type(uint256).max);
    }

    /// @notice Swap once and emit what it cost.
    function probe(
        PoolSwapTest router,
        PoolKey calldata key,
        SwapParams calldata params,
        PoolSwapTest.TestSettings calldata settings,
        bytes calldata hookData,
        bool bonded,
        uint256 round
    ) external {
        uint256 before = gasleft();
        router.swap(key, params, settings, hookData);
        uint256 used = before - gasleft();

        emit SwapGas(key.toId(), used, address(key.hooks) != address(0), bonded, round);
    }
}
