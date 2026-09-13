// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice View layer shared between FuguiBank and BankNote tokenURI rendering.
interface IFuguiBankView {
    /// @param mode 0 = 落袋为安 LUCKY (meme -> stock on pump) | 1 = 富贵险中求 BOLD (stock -> meme on dip)
    struct Position {
        address owner;
        address meme;
        address stock;
        uint8 mode;
        uint256 srcRemaining; // source side not yet harvested (meme in mode 0 / stock in mode 1)
        uint256 dstAccrued; // accumulated output awaiting claim (stock in mode 0 / meme in mode 1)
        uint256 harvestedOut; // gross output harvested (stats)
        uint256 watermark; // price of 1e18 stock, quoted in meme, 1e18 scale
        uint32 stepBps; // move (bp) required to trigger a harvest
        uint32 sellBps; // fraction (bp) of srcRemaining swapped per trigger
        uint64 lastHarvestAt;
        uint32 harvestCount;
        bool closed;
    }

    function getPosition(uint256 positionId) external view returns (Position memory);
}
