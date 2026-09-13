// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title StringsLib
/// @notice Minimal uint formatting (toString / decimal formatting with fixed places).
library StringsLib {
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /// @notice Formats a 18-decimal amount with `places` decimals, e.g. 1.5e18 -> "1.50".
    function formatFixed(uint256 value, uint8 places) internal pure returns (string memory) {
        uint256 whole = value / 1e18;
        uint256 frac = value % 1e18;
        string memory wholeStr = toString(whole);
        if (places == 0) return wholeStr;
        uint256 scale = 10 ** uint256(places);
        uint256 fracScaled = (frac * scale) / 1e18;
        string memory fracStr = toString(fracScaled);
        uint256 len = bytes(fracStr).length;
        while (len < places) {
            fracStr = string.concat("0", fracStr);
            len++;
        }
        return string.concat(wholeStr, ".", fracStr);
    }
}
