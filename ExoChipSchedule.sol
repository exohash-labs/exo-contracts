// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// 1-2-5 chip ladder in token base units.
// - Works for any ERC-20 decimals >= 1.
// - Intended for stablecoins where 1 token ~= $1 (e.g., USDC).
//
// Ladder (16 chips):
// 0.1, 0.2, 0.5,
// 1, 2, 5,
// 10, 20, 50,
// 100, 200, 500,
// 1_000, 2_000, 5_000, 10_000
//
// Notes on gas:
// - This is a pure library; values are computed in-memory.
// - Calling build() allocates a 16-word array, so prefer valueAt() when only one chip is needed.
library ExoChipSchedule {
    // Returns the full chip ladder for a token with `decimals`.
    function build(uint8 decimals) internal pure returns (uint256[16] memory chips) {
        require(decimals >= 1, "Chip:decimals");

        uint256 s = 10 ** decimals; // 1 token in base units

        // 0.1 .. 0.5
        chips[0]  = s / 10;        // 0.1
        chips[1]  = (2 * s) / 10;  // 0.2
        chips[2]  = (5 * s) / 10;  // 0.5

        // 1 .. 5
        chips[3]  = 1 * s;         // 1
        chips[4]  = 2 * s;         // 2
        chips[5]  = 5 * s;         // 5

        // 10 .. 50
        chips[6]  = 10 * s;        // 10
        chips[7]  = 20 * s;        // 20
        chips[8]  = 50 * s;        // 50

        // 100 .. 500
        chips[9]  = 100 * s;       // 100
        chips[10] = 200 * s;       // 200
        chips[11] = 500 * s;       // 500

        // 1_000 .. 10_000
        chips[12] = 1000 * s;      // 1,000
        chips[13] = 2000 * s;      // 2,000
        chips[14] = 5000 * s;      // 5,000
        chips[15] = 10000 * s;     // 10,000
    }

    // Returns a single chip value at `idx` without allocating the full ladder.
    // This is cheaper than build() when the caller only needs one denomination.
    function valueAt(uint8 decimals, uint8 idx) internal pure returns (uint256) {
        require(decimals >= 1, "Chip:decimals");
        require(idx < 16, "Chip:idx");

        uint256 s = 10 ** decimals;

        // Mapping of idx -> multiplier (numerator, denominator = 10 for first three, else 1).
        // idx:  0    1    2     3  4  5   6   7   8    9    10   11    12    13    14     15
        // val: 0.1, 0.2, 0.5,  1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000
        if (idx == 0) return s / 10;
        if (idx == 1) return (2 * s) / 10;
        if (idx == 2) return (5 * s) / 10;

        if (idx == 3) return 1 * s;
        if (idx == 4) return 2 * s;
        if (idx == 5) return 5 * s;

        if (idx == 6) return 10 * s;
        if (idx == 7) return 20 * s;
        if (idx == 8) return 50 * s;

        if (idx == 9)  return 100 * s;
        if (idx == 10) return 200 * s;
        if (idx == 11) return 500 * s;

        if (idx == 12) return 1000 * s;
        if (idx == 13) return 2000 * s;
        if (idx == 14) return 5000 * s;

        // idx == 15
        return 10000 * s;
    }
}
