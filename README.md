# exo-contracts

Smart contracts for **ExoHash**, a **non-custodial on-chain execution protocol for real-time betting games** deployed on **Sei EVM**.

ExoHash enables Web2-like UX while keeping **custody, settlement, randomness, and accounting fully on-chain**.  
All outcomes are **deterministic, provably fair, and auditable**.

---

## Core Principles

- **Non-custodial** – user funds are never controlled by operators
- **Provably fair** – outcomes are deterministic and verifiable on-chain
- **Explicit risk controls** – exposure is capped before settlement
- **Separation of concerns** – escrow, bankroll, and game logic are isolated
- **Relayer-compatible** – supports gas abstraction and off-chain UX

---

## Deployed Addresses (Sei EVM)

    ESCROW_ADDRESS   = "0xC8F9D2A0227372B2096176F225474B4BD3228522";
    BANKROLL_ADDRESS = "0xA06b68e814e0a3A35EBD5B93e42d24fBb7d2BFCE";

    ROULETTE_GAME_ADDRESS = "0x41efd0516588639b1f89f5171215bA2cd09AFc98";
    
    // Development / testing only
    USDC_ADDRESS     = "0x0E7E8C427ec0ec1114647201cd8A53eafAC7F29a";

---

## Contracts

### ExoEscrow.sol
Bet **commitment and settlement coordinator**.

- commits bets using **EIP-3009 stake authorization**
- requires **user signature + authorized relayer signature**
- enforces **maximum payout / exposure limits** before accepting a bet
- manages **reveal window**, **fallback settlement**, and **expiry path**
- derives deterministic seeds for game resolution
- routes resolution to a registered game contract
- coordinates **reserve, payout, or refund** with the bankroll

This contract **does not custody liquidity**.

---

### ExoBankRoll.sol
Protocol **liquidity vault and accounting engine**.

- holds USDC liquidity backing all games
- reserves exposure when a bet is accepted
- releases or consumes reserves on settlement
- executes payouts and collects losses
- accounts for protocol fees and bonus balances
- enforces that settlements only occur via escrow-approved calls

This contract is the **only component that moves funds**.

---

### ExoRoulette.sol
Deterministic **roulette game logic** (European roulette).

- validates encoded roulette bets
- computes maximum exposure for a bet
- resolves outcomes deterministically from a provided seed
- returns payout amounts without modifying protocol state

Contains **no custody, no randomness sources, and no protocol logic**.

---

### ExoChipSchedule.sol
Shared utility contract defining:

- chip denominations
- wager sizing helpers
- standardized betting units used across games

---

### MockUSDC.sol
ERC20-compatible **mock USDC** used for development and testing.  
**Not intended for production use.**

---

## Protocol Flow (High Level)

At a high level:

- Bets are authorized and committed on-chain via `ExoEscrow`
- Risk is validated before any exposure is reserved
- Game contracts deterministically resolve outcomes
- `ExoBankRoll` applies the resulting accounting changes

All critical steps are **verifiable on-chain**, while UX-specific sequencing
(remoting, batching, relayers) remains an implementation detail.

---

## Tooling

- **Solidity:** `^0.8.26`
- **Chain:** Sei EVM
- Compatible with Foundry / Hardhat

---

## Documentation

See **`docs.md`** for full protocol design, settlement paths, assumptions,
and threat model.

---

## License

MIT

