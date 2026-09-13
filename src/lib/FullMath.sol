// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title FullMath
/// @notice 512-bit multiply-then-divide, ported from Uniswap v3 core (MIT).
/// @dev Used everywhere we multiply token amounts by prices without risking overflow.
library FullMath {
    /// @notice Calculates floor(a×b÷d) with full precision.
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            require(d > 0, "FullMath: DIV_BY_ZERO");
            assembly {
                result := div(prod0, d)
            }
        } else {
            require(d > prod1, "FullMath: OVERFLOW");
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            unchecked {
                uint256 twos = (0 - d) & d;
                d = d / twos;
                prod0 = prod0 / twos;
                assembly {
                    twos := div(sub(0, twos), twos)
                }
                uint256 inv = (3 * d) ^ 2;
                inv *= 2 - d * inv;
                inv *= 2 - d * inv;
                inv *= 2 - d * inv;
                inv *= 2 - d * inv;
                inv *= 2 - d * inv;
                inv *= 2 - d * inv;
                result = prod1 * inv + (prod0 * inv);
            }
        }
    }
}
