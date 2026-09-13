// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Base64
/// @notice Standard base64 encoding (bytes -> string), enough for on-chain metadata.
library Base64 {
    string internal constant TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        bytes memory table = bytes(TABLE);

        uint256 i;
        uint256 j;
        for (i = 0; i < data.length - 2; i += 3) {
            (result[j], result[j + 1], result[j + 2], result[j + 3]) = (
                table[uint8(data[i]) >> 2],
                table[((uint8(data[i]) & 0x03) << 4) | (uint8(data[i + 1]) >> 4)],
                table[((uint8(data[i + 1]) & 0x0f) << 2) | (uint8(data[i + 2]) >> 6)],
                table[uint8(data[i + 2]) & 0x3f]
            );
            j += 4;
        }

        uint256 remain = data.length - i;
        if (remain == 1) {
            result[j] = table[uint8(data[i]) >> 2];
            result[j + 1] = table[(uint8(data[i]) & 0x03) << 4];
            result[j + 2] = "=";
            result[j + 3] = "=";
        } else if (remain == 2) {
            result[j] = table[uint8(data[i]) >> 2];
            result[j + 1] = table[((uint8(data[i]) & 0x03) << 4) | (uint8(data[i + 1]) >> 4)];
            result[j + 2] = table[(uint8(data[i + 1]) & 0x0f) << 2];
            result[j + 3] = "=";
        }
        return string(result);
    }
}
