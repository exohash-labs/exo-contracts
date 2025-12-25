// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Minimal interface for tokens supporting EIP-3009 transferWithAuthorization (e.g., USDC).
interface IERC20TransferWithAuthorization {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 stakeValue,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

// Bankroll interface used by escrow.
// - Escrow reserves exposure on commit.
// - Escrow finalizes (payout, fees, bonus) on settle.
interface IExoBankRoll {
    function reserve(bytes32 betId, uint256 amount) external;

    function finalizeBet(
        bytes32 betId,
        address to,
        uint256 reserved, // reserved exposure to release
        uint256 payout,   // payout to user (final amount; no fees attached)
        uint256 fees,     // protocol/house fees
        uint256 bonus    // user bonus credit
    ) external;

    function freeLiquidity() external view returns (uint256);
    function maxAllowedPayout() external view returns (uint256);
    function token() external view returns (address);
}

// Game interface used by escrow.
// Games define:
// - quote(): stake & maxPayout for exposure control
// - resolve(): deterministic stake & payout given seed
// - GAME_EDGE_BPS(): game-defined edge (if any)
interface IExoGame {
    function quote(uint256 encodedBet) external view returns (uint256 stake, uint256 maxPayout);

    function resolve(uint256 encodedBet, bytes32 seed) external view returns (uint256 stake, uint256 payout);

    function GAME_EDGE_BPS() external view returns (uint16);
    function GAME_ID() external view returns (uint16);
    function GAME_NAME() external view returns (string memory);
}

contract ExoEscrow is Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Core model
    // ---------------------------------------------------------------------
    // - Bets are committed with:
    //   (a) user's EIP-3009 authorization for stake transfer, and
    //   (b) user signature + relayer signature over an escrow-specific digest.
    //
    // - Escrow enforces risk controls:
    //   * Exposure cap: maxPayout must be <= maxAllowedPayout
    //
    // - Settlement randomness:
    //   * Path 1 (Reveal): user supplies secret within REVEAL_WINDOW blocks
    //   * Path 2 (Fallback): after REVEAL_WINDOW, seed excludes secret
    //   * Path 3 (Expiry): after EXPIRY_WINDOW, stake is refunded per game rules
    //
    // Economics:
    // - House takes only fees (feeBps, e.g. 1.2% of stake).
    // - Game edge is defined inside each game (GAME_EDGE_BPS).
    // - If a game edge exists above the house fee, the difference is credited
    //   to user bonus (bonus = stake * (gameEdgeBps - feeBps) / 10_000).
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ExoEscrow_ZeroAddress();
    error ExoEscrow_BetAlreadyCommitted();
    error ExoEscrow_BetUnknown();
    error ExoEscrow_GameUnknown();
    error ExoEscrow_InvalidGameId();
    error ExoEscrow_GameBlocked();
    error ExoEscrow_ValueTransferNotEqualEncoded();
    error ExoEscrow_InsufficientLiquidity();
    error ExoEscrow_ExposureExceeded();
    error ExoEscrow_InvalidRevealSecret();
    error ExoEscrow_TryToRevealInTheSameBlock();
    error ExoEscrow_InvalidRelayerSig();
    error ExoEscrow_InvalidUserBetSig();

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    // Per-bet record stored by betId.
    struct Bet {
        uint256 encodedBet;          // game-specific packed bet payload
        address user;               // bet owner
        uint32 commitBlockNumber;   // block number at commit time
        uint64 reserved;            // max payout exposure reserved in bankroll
    }

    // Per-game registry record.
    struct Game {
        address addr;   // game contract address
        bool blocked;   // blocks new commits if true
    }

    mapping(bytes32 => Bet) public bets;
    mapping(uint16 => Game) public games;
    uint16 public latestGameId;

    // External components.
    IExoBankRoll public immutable bankroll;
    address public immutable usdcAddr;
    IERC20TransferWithAuthorization public immutable usdc3009;

    // Relayer signer used to approve off-chain bet payloads.
    // NOTE: if unset (address(0)), relayer signature validation becomes unsafe.
    // This contract does not enforce non-zero here (kept as-is per requirement).
    address public relayerSigner;

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------
    uint256 internal constant BPS_DENOMINATOR = 10_000;


    // House fee (in bps of stake). Example: 120 = 1.2%.
    uint256 public feeBps = 120;

    // Reveal and expiry windows (in blocks).
    uint256 private constant REVEAL_WINDOW = 20;
    uint256 private constant EXPIRY_WINDOW = 255;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event BetCommitted(
        bytes32 indexed betId,
        address indexed user,
        uint16 indexed gameId,
        uint256 encodedBet,
        uint256 stake,
        uint256 maxPayout
    );

    // path:
    //   1 = reveal
    //   2 = fallback
    //   3 = expiry
    event BetSettled(
        bytes32 indexed betId,
        address indexed user,
        uint16 indexed gameId,
        uint16 path,
        uint256 totalStake,
        uint256 totalPayout,
        uint256 fees,
        uint256 bonus,
        uint256 commitBlockNumber,
        bytes32 commitBlockHash,
        uint256 encodedBet,
        bytes32 seed
    );

    event GameAdded(uint16 indexed gameId, address indexed gameAddr);
    event GameBlocked(uint16 indexed gameId, bool blocked);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address _bankroll, address _owner) Ownable(_owner) {
        bankroll = IExoBankRoll(_bankroll);
        usdcAddr = bankroll.token();
        usdc3009 = IERC20TransferWithAuthorization(usdcAddr);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setRelayerSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert ExoEscrow_ZeroAddress();
        relayerSigner = _newSigner;
    }

    // Registers a new game contract.
    // Game IDs must be sequential: latestGameId + 1.
    function addGame(address gameAddr) external onlyOwner {
        if (gameAddr == address(0)) revert ExoEscrow_ZeroAddress();

        uint16 gameId = IExoGame(gameAddr).GAME_ID();
        if (gameId != latestGameId + 1) revert ExoEscrow_InvalidGameId();
        if (games[gameId].addr != address(0)) revert ExoEscrow_InvalidGameId();

        games[gameId] = Game({addr: gameAddr, blocked: false});
        latestGameId = gameId;

        emit GameAdded(gameId, gameAddr);
    }

    // Enables/disables a game for new bets.
    function setGameBlocked(uint16 gameId, bool blocked) external onlyOwner {
        Game storage g = games[gameId];
        if (g.addr == address(0)) revert ExoEscrow_GameUnknown();

        if (g.blocked != blocked) {
            g.blocked = blocked;
            emit GameBlocked(gameId, blocked);
        }
    }

    function getGame(uint16 gameId) public view returns (address gameAddr, bool blocked) {
        Game storage g = games[gameId];
        return (g.addr, g.blocked);
    }

    // ---------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------

    // Commits a bet:
    // - validates game & quote
    // - validates user + relayer signatures over a deterministic digest
    // - enforces exposure cap
    // - pulls stake into bankroll via EIP-3009
    // - reserves maxPayout exposure in bankroll
    function commitBet(
        bytes32 betId,
        uint256 encodedBet,
        address user,
        uint256 stakeValue,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 vAuth,
        bytes32 rAuth,
        bytes32 sAuth,
        uint8 vUser,
        bytes32 rUser,
        bytes32 sUser,
        uint8 vRelayer,
        bytes32 rRelayer,
        bytes32 sRelayer
    ) external nonReentrant {
        Bet storage b = bets[betId];
        if (b.user != address(0)) revert ExoEscrow_BetAlreadyCommitted();

        // Validate game registry entry.
        uint16 gameId = _decodeGameId(encodedBet);
        (address gameAddr, bool blockedGame) = getGame(gameId);
        if (gameAddr == address(0)) revert ExoEscrow_GameUnknown();
        if (blockedGame) revert ExoEscrow_GameBlocked();

        // Validate that stakeValue matches the stake required by the encoded bet.
        (uint256 stake, uint256 maxPayout) = IExoGame(gameAddr).quote(encodedBet);
        if (stake != stakeValue) revert ExoEscrow_ValueTransferNotEqualEncoded();

        // Create a commit digest binding this escrow, bet parameters, and nonce.
        // This digest is verified by:
        // - user: proves bet intent
        // - relayer: proves relayer authorization
        bytes32 digest = keccak256(
            abi.encodePacked(
                "EXO_ESCROW_BET",
                address(this),
                encodedBet,
                stakeValue,
                nonce
            )
        );

        if (user == address(0) || ecrecover(digest, vUser, rUser, sUser) != user) {
            revert ExoEscrow_InvalidUserBetSig();
        }

        if (relayerSigner == address(0) || ecrecover(digest, vRelayer, rRelayer, sRelayer) != relayerSigner) {
            revert ExoEscrow_InvalidRelayerSig();
        }

        // Enforce exposure cap against current free liquidity with cap(risk control).
        uint256 cap = bankroll.maxAllowedPayout();
        if (maxPayout > cap) revert ExoEscrow_ExposureExceeded();

        // Record bet.
        b.encodedBet = encodedBet;
        b.user = user;
        b.commitBlockNumber = uint32(block.number);
        b.reserved = uint64(maxPayout);

        // Pull stake into bankroll using EIP-3009 authorization.
        usdc3009.transferWithAuthorization(
            user,
            address(bankroll),
            stakeValue,
            validAfter,
            validBefore,
            nonce,
            vAuth,
            rAuth,
            sAuth
        );

        // Reserve max payout exposure in bankroll.
        bankroll.reserve(betId, maxPayout);

        emit BetCommitted(betId, user, gameId, encodedBet, stakeValue, maxPayout);
    }

    // ---------------------------------------------------------------------
    // Settle
    // ---------------------------------------------------------------------

    // Settles a committed bet using one of three paths:
    //  - Path 1 (Reveal): within REVEAL_WINDOW, secret must match betId
    //  - Path 2 (Fallback): after REVEAL_WINDOW, seed excludes secret
    //  - Path 3 (Expiry): after EXPIRY_WINDOW, refund according to game rules
    function settleBet(bytes32 betId, bytes32 secret) external nonReentrant {
        Bet storage b = bets[betId];
        if (b.user == address(0)) revert ExoEscrow_BetUnknown();

        address user = b.user;
        uint256 encodedBet = b.encodedBet;
        uint16 gameId = _decodeGameId(encodedBet);
        uint32 commitBlockNumber = b.commitBlockNumber;
        uint256 reserved = b.reserved;

        // Validate game registry entry at settlement time.
        (address gameAddr, bool blocked) = getGame(gameId);
        if (gameAddr == address(0)) revert ExoEscrow_GameUnknown();
        if (blocked) revert ExoEscrow_GameBlocked();

        uint256 age = block.number - commitBlockNumber;
        if (age == 0) revert ExoEscrow_TryToRevealInTheSameBlock();

        uint16 path;
        bytes32 seed;

        // -------------------------
        // Path 3: Expiry
        // -------------------------
        if (age > EXPIRY_WINDOW) {
            // Expiry uses a zero seed. Game decides refund behavior.
            (uint256 stakeRefund, ) = IExoGame(gameAddr).resolve(encodedBet, bytes32(0));

            bankroll.finalizeBet(
                betId,
                user,
                reserved,
                stakeRefund,
                0,
                0
            );

            delete bets[betId];

            emit BetSettled(
                betId,
                user,
                gameId,
                3,
                stakeRefund,
                stakeRefund,
                0,
                0,
                commitBlockNumber,
                bytes32(0),
                encodedBet,
                bytes32(0)
            );
            return;
        }

        // Common entropy (commit block hash).
        bytes32 commitBlockHash = blockhash(commitBlockNumber);

        // -------------------------
        // Path 1: Reveal
        // -------------------------
        if (age <= REVEAL_WINDOW) {
            if (keccak256(abi.encodePacked(secret)) != betId) {
                revert ExoEscrow_InvalidRevealSecret();
            }

            seed = keccak256(abi.encodePacked(commitBlockHash, secret, betId, user));
            path = 1;
        }
        // -------------------------
        // Path 2: Fallback
        // -------------------------
        else {
            seed = keccak256(abi.encodePacked(commitBlockHash, betId, user));
            path = 2;
        }

        // Resolve bet outcome via game logic.
        (uint256 stake, uint256 payout) = IExoGame(gameAddr).resolve(encodedBet, seed);

        // Fee is always a simple function of stake (house revenue).
        uint256 fees = _calcFees(stake);

        // Bonus is derived from game edge:
        // - If game edge <= house fee: no bonus
        // - Else: bonus = stake * (edge - feeBps) / 10_000
        uint256 bonus = _calcBonus(stake, gameAddr);

        bankroll.finalizeBet(
            betId,
            user,
            reserved,
            payout,
            fees,
            bonus
        );

        delete bets[betId];

        emit BetSettled(
            betId,
            user,
            gameId,
            path,
            stake,
            payout,
            fees,
            bonus,
            commitBlockNumber,
            commitBlockHash,
            encodedBet,
            seed
        );
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    // Encoded bet layout: gameId stored in the top 10 bits.
    function _decodeGameId(uint256 packedBet) internal pure returns (uint16 gameId) {
        uint16 pos = 256 - 10;
        return uint16((packedBet >> pos) & 0x03FF);
    }

    // Fees are taken only from stake (not from payout).
    function _calcFees(uint256 stakeAmount) internal view returns (uint256) {
        return (stakeAmount * feeBps) / BPS_DENOMINATOR;
    }

    // Bonus is credited to the user when the game's edge exceeds the house fee.
    function _calcBonus(uint256 stakeAmount, address gameAddr) internal view returns (uint256) {
        if (stakeAmount == 0) revert ExoEscrow_ValueTransferNotEqualEncoded();
        if (gameAddr == address(0)) revert ExoEscrow_ZeroAddress();

        uint256 edge = IExoGame(gameAddr).GAME_EDGE_BPS();
        if (edge <= feeBps) return 0;

        uint256 bonusBps = edge - feeBps;
        return (stakeAmount * bonusBps) / BPS_DENOMINATOR;
    }
}

