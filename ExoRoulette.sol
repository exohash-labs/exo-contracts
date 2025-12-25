// SPDX-License-Identifier: MIT
// ExoRoulette is a single-zero (European) roulette game implementation.
//
// This contract is deterministic given (encodedBet, seed):
// - quote() returns the required stake and the maximum possible payout for exposure control.
// - resolve() returns the actual stake and payout for a specific spin derived from `seed`.
//
// Economics:
// - The house fee is handled by the escrow/bankroll layer (not here).
// - The game edge (if any) is declared via GAME_EDGE_BPS() and is used by escrow to compute user bonuses.
//
// encodedBet packing (MSB-first):
// - [10 bits]  gameId
// - [4 bits ]  legCount   (1..15)
// - For each leg (8 bits + 4 bits):
//   - [8 bits ] betId     (index into SHAPES)
//   - [4 bits ] chipIdx   (index into ExoChipSchedule ladder, 0..15)
//
pragma solidity ^0.8.26;

import {ExoChipSchedule} from "./ExoChipSchedule.sol";

interface IGame {
  function quote(uint256 encodedBet) external view returns (uint256 stake, uint256 maxPayout);
  function resolve(uint256 encodedBet, bytes32 seed) external view returns (uint256 stake, uint256 payout);
  function GAME_EDGE_BPS() external view returns (uint16);
  function GAME_ID() external view returns (uint16);
  function GAME_NAME() external view returns (string memory);
}

// Roulette bit helpers.
// We represent selectable pockets with a 64-bit bitmask (bits 0..36 used).
library _Mask {
  function b(uint8 n) internal pure returns (uint64) { return uint64(1) << n; } // n in [0..36]
}

// ExoRoulette (single-zero) – ExoEscrow-compatible roulette implementation.
// The contract exposes a complete paytable via SHAPES[] where each betId maps to:
// - mask37 : pockets included in this bet
// - grossMul : gross multiplier paid when pocket hits (includes stake), e.g. 36 for straight-up (35:1 + stake)
contract ExoRoulette is IGame{
  // ---------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------
  uint16 public constant override GAME_ID = 1;
  string public constant override GAME_NAME = "Roulette";
  uint16 public constant override GAME_EDGE_BPS = 270; // 2.70% (single-zero roulette edge)

  // Token decimals used to build chip ladder in quote()/resolve().
  // This game is designed around a USDC-style 6-decimal token.
  uint8 public tokenDecimals;

  // ---------------------------------------------------------------------
  // Paytable storage
  // ---------------------------------------------------------------------
  // Each Shape defines one bet option.
  // - mask37: bitmask of covered pockets
  // - grossMul: gross payout multiplier (payout includes stake)
  struct Shape { uint64 mask37; uint16 grossMul; } // grossMul = payout + 1
  Shape[] public SHAPES; // betId -> shape

  // ---------------------------------------------------------------------
  // Multipliers (gross = payout + 1)
  // ---------------------------------------------------------------------
  uint16 constant ZERO_M      = 36; // 35+1
  uint16 constant STRAIGHT_M  = 36; // 35+1
  uint16 constant SPLIT_M     = 18; // 17+1
  uint16 constant STREET_M    = 12; // 11+1
  uint16 constant CORNER_M    = 9;  //  8+1
  uint16 constant SIXLINE_M   = 6;  //  5+1
  uint16 constant TRIO_M      = 12; // 11+1 (0-1-2 and 0-2-3)
  uint16 constant FIRSTFOUR_M = 9;  //  8+1 (0-1-2-3)
  uint16 constant COLUMN_M    = 3;  //  2+1
  uint16 constant DOZEN_M     = 3;  //  2+1
  uint16 constant OUTSIDE_M   = 2;  //  1+1 (even-money)

  // ---------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------
  constructor() {
    tokenDecimals = 6; // USDC-style
    _buildDefaultPaytable();
  }

  // ---------------------------------------------------------------------
  // IGame
  // ---------------------------------------------------------------------

  // Quotes the stake and maximum possible payout for the encoded bet.
  // - stake is the sum of chips across all legs.
  // - maxPayout is the largest possible gross payout over all pockets.
  function quote(uint256 encodedBet)
    external
    view
    override
    returns (uint256 stake, uint256 maxPayout)
  {
    (, uint8 count, ) = _decodeHeader(encodedBet);
    require(count > 0 && count <= 15, "no legs");

    uint256[16] memory chips = ExoChipSchedule.build(tokenDecimals);

    // Track maximum gross payout over all pockets (0..36).
    uint256[37] memory profitByPocket;

    unchecked {
      for (uint8 i = 0; i < count; ++i) {
        (uint8 betId, uint8 chipIdx) = _decodeBetAt(encodedBet, i);
        require(chipIdx < 16, "chip");
        require(betId < SHAPES.length, "betId");

        uint256 c = chips[chipIdx];
        stake += c;

        Shape memory sh = SHAPES[betId];
        uint256 profit = c * sh.grossMul;

        // Distribute this leg's gross payout into every covered pocket.
        uint64 m = sh.mask37;
        for (uint8 p = 0; p <= 36; ++p) {
          if (((m >> p) & 1) == 1) profitByPocket[p] += profit;
        }
      }

      // Compute the maximum across all pockets.
      for (uint8 p = 0; p <= 36; ++p) {
        uint256 v = profitByPocket[p];
        if (v > maxPayout) maxPayout = v;
      }
    }
  }

  // Resolves a bet outcome for a given seed.
  // - The winning pocket is derived from the seed.
  // - payout is the sum of gross payouts for all legs that cover the pocket.
  function resolve(uint256 encodedBet, bytes32 seed) external view override returns (uint256 stake, uint256 payout) {
    (, uint8 count, ) = _decodeHeader(encodedBet);
    require(count > 0 && count <= 15, "no legs");

    uint256[16] memory chips = ExoChipSchedule.build(tokenDecimals);
    uint8 pocket = _spin(seed);

    unchecked {
      for (uint8 i = 0; i < count; ++i) {
        (uint8 betId, uint8 chipIdx) = _decodeBetAt(encodedBet, i);
        require(chipIdx < 16, "chip");
        require(betId < SHAPES.length, "betId");

        uint256 c = chips[chipIdx];
        stake += c;

        Shape memory sh = SHAPES[betId];
        if (((sh.mask37 >> pocket) & 1) == 1) {
          payout += c * sh.grossMul;
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // Encoding helpers
  // ---------------------------------------------------------------------

  // Decodes the top-of-word header:
  // - gameId (10 bits)
  // - legCount (4 bits)
  // - position cursor (bit index) for subsequent leg decoding
  function _decodeHeader(uint256 packed) internal pure returns (uint16 gameId, uint8 count, uint16 pos) {
    pos = 256;

    pos -= 10; gameId = uint16((packed >> pos) & 0x03FF);
    pos -= 4;  count  = uint8((packed >> pos) & 0x0F);
  }

  // Decodes one leg at index `i`.
  // Each leg stores:
  // - betId (8 bits)
  // - chipIdx (4 bits)
  function _decodeBetAt(uint256 packed, uint8 i) internal pure returns (uint8 betId, uint8 chipIdx) {
    (, , uint16 pos0) = _decodeHeader(packed);
    uint16 pos = pos0;

    // Skip i legs.
    unchecked { pos -= uint16(i) * 12; }

    pos -= 8;  betId   = uint8((packed >> pos) & 0xFF);
    pos -= 4;  chipIdx = uint8((packed >> pos) & 0x0F);
  }

  // ---------------------------------------------------------------------
  // Spin / randomness mapping
  // ---------------------------------------------------------------------

  // Maps seed -> [0..36].
  // The escrow determines the seed; this contract only derives a uniform pocket.
  function _spin(bytes32 seed) internal pure returns (uint8) {
    return uint8(uint256(seed) % 37);
  }

  // ---------------------------------------------------------------------
  // Paytable builder (157 shapes)
  // ---------------------------------------------------------------------
  // Shapes are appended in a fixed order. betId indexes directly into SHAPES.
  // The size is asserted to ensure the paytable is built exactly as expected.
  function _buildDefaultPaytable() internal {
    delete SHAPES;

    // --- Zero ---
    SHAPES.push(Shape(_Mask.b(0), ZERO_M));

    // --- Straight-ups 1..36 ---
    for (uint8 n = 1; n <= 36; ) {
      SHAPES.push(Shape(_Mask.b(n), STRAIGHT_M));
      unchecked { ++n; }
    }

    // --- Splits (horizontal + vertical) ---
    // Horizontal splits
    for (uint8 row = 0; row < 12; ) {
      uint8 base = uint8(1 + row * 3);
      SHAPES.push(Shape(_Mask.b(base) | _Mask.b(base + 1), SPLIT_M));
      SHAPES.push(Shape(_Mask.b(base + 1) | _Mask.b(base + 2), SPLIT_M));
      unchecked { ++row; }
    }
    // Vertical splits
    for (uint8 n = 1; n <= 33; ) {
      SHAPES.push(Shape(_Mask.b(n) | _Mask.b(n + 3), SPLIT_M));
      unchecked { ++n; }
    }
    // Zero splits: 0-1, 0-2, 0-3
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(1), SPLIT_M));
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(2), SPLIT_M));
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(3), SPLIT_M));

    // --- Streets ---
    for (uint8 row = 0; row < 12; ) {
      uint8 base = uint8(1 + row * 3);
      SHAPES.push(Shape(_Mask.b(base) | _Mask.b(base + 1) | _Mask.b(base + 2), STREET_M));
      unchecked { ++row; }
    }

    // --- Corners ---
    for (uint8 row = 0; row < 11; ) {
      uint8 base = uint8(1 + row * 3);
      SHAPES.push(Shape(_Mask.b(base) | _Mask.b(base + 1) | _Mask.b(base + 3) | _Mask.b(base + 4), CORNER_M));
      SHAPES.push(Shape(_Mask.b(base + 1) | _Mask.b(base + 2) | _Mask.b(base + 4) | _Mask.b(base + 5), CORNER_M));
      unchecked { ++row; }
    }

    // --- Six lines ---
    for (uint8 row = 0; row < 11; ) {
      uint8 base = uint8(1 + row * 3);
      SHAPES.push(
        Shape(
          _Mask.b(base) | _Mask.b(base + 1) | _Mask.b(base + 2) |
          _Mask.b(base + 3) | _Mask.b(base + 4) | _Mask.b(base + 5),
          SIXLINE_M
        )
      );
      unchecked { ++row; }
    }

    // --- Trio and first four (zero area) ---
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(1) | _Mask.b(2), TRIO_M));
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(2) | _Mask.b(3), TRIO_M));
    SHAPES.push(Shape(_Mask.b(0) | _Mask.b(1) | _Mask.b(2) | _Mask.b(3), FIRSTFOUR_M));

    // --- Columns (1st/2nd/3rd) ---
    uint64 col1 = 0; for (uint8 n = 1; n <= 34; ) { col1 |= _Mask.b(n); unchecked { n += 3; } }
    uint64 col2 = 0; for (uint8 n = 2; n <= 35; ) { col2 |= _Mask.b(n); unchecked { n += 3; } }
    uint64 col3 = 0; for (uint8 n = 3; n <= 36; ) { col3 |= _Mask.b(n); unchecked { n += 3; } }
    SHAPES.push(Shape(col1, COLUMN_M));
    SHAPES.push(Shape(col2, COLUMN_M));
    SHAPES.push(Shape(col3, COLUMN_M));

    // --- Dozens (1-12, 13-24, 25-36) ---
    uint64 dozen1 = 0; for (uint8 n = 1;  n <= 12; ) { dozen1 |= _Mask.b(n); unchecked { ++n; } }
    uint64 dozen2 = 0; for (uint8 n = 13; n <= 24; ) { dozen2 |= _Mask.b(n); unchecked { ++n; } }
    uint64 dozen3 = 0; for (uint8 n = 25; n <= 36; ) { dozen3 |= _Mask.b(n); unchecked { ++n; } }
    SHAPES.push(Shape(dozen1, DOZEN_M));
    SHAPES.push(Shape(dozen2, DOZEN_M));
    SHAPES.push(Shape(dozen3, DOZEN_M));

    // --- Outside bets (even money) ---
    uint64 lowMask   = 0; for (uint8 n = 1;  n <= 18; ) { lowMask   |= _Mask.b(n); unchecked { ++n; } }
    uint64 highMask  = 0; for (uint8 n = 19; n <= 36; ) { highMask  |= _Mask.b(n); unchecked { ++n; } }

    // Standard European color layout.
    // (Masks are built explicitly to avoid relying on off-chain tables.)
    uint64 redMask = 0;
    redMask |= _Mask.b(1)  | _Mask.b(3)  | _Mask.b(5)  | _Mask.b(7)  | _Mask.b(9)  | _Mask.b(12) | _Mask.b(14) | _Mask.b(16) | _Mask.b(18);
    redMask |= _Mask.b(19) | _Mask.b(21) | _Mask.b(23) | _Mask.b(25) | _Mask.b(27) | _Mask.b(30) | _Mask.b(32) | _Mask.b(34) | _Mask.b(36);

    uint64 blackMask = 0;
    blackMask |= _Mask.b(2)  | _Mask.b(4)  | _Mask.b(6)  | _Mask.b(8)  | _Mask.b(10) | _Mask.b(11) | _Mask.b(13) | _Mask.b(15) | _Mask.b(17);
    blackMask |= _Mask.b(20) | _Mask.b(22) | _Mask.b(24) | _Mask.b(26) | _Mask.b(28) | _Mask.b(29) | _Mask.b(31) | _Mask.b(33) | _Mask.b(35);

    uint64 evenMask = 0; for (uint8 n = 1; n <= 36; ) { if ((n % 2) == 0) evenMask |= _Mask.b(n); unchecked { ++n; } }
    uint64 oddMask  = 0; for (uint8 n = 1; n <= 36; ) { if ((n % 2) == 1) oddMask  |= _Mask.b(n); unchecked { ++n; } }

    SHAPES.push(Shape(lowMask,   OUTSIDE_M));
    SHAPES.push(Shape(evenMask,  OUTSIDE_M));
    SHAPES.push(Shape(redMask,   OUTSIDE_M));
    SHAPES.push(Shape(blackMask, OUTSIDE_M));
    SHAPES.push(Shape(oddMask,   OUTSIDE_M));
    SHAPES.push(Shape(highMask,  OUTSIDE_M));

    require(SHAPES.length == 157, "paytable size");
  }
}
