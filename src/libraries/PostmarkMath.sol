// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

/// @notice Price and notional conversions. Everything Postmark bills is denominated in currency1,
/// the quote asset, so token0 amounts have to be marked to the pool's own price.
library PostmarkMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Value `amount0` of token0 in token1, at price (sqrtPriceX96 / 2^96)^2.
    /// @dev Split into two mulDivs so the intermediate never has to hold amount0 * sqrtP^2.
    function amount0To1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(intermediate, sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Value `amount1` of token1 in token0.
    function amount1To0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(intermediate, FixedPoint96.Q96, sqrtPriceX96);
    }

    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, bps, BPS);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
