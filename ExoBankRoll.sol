// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Bankroll contract:
// - Escrow is the only party that can reserve/finalize bets.
// - Users can only withdraw their bonus (direct or gasless via signature).
// - Liquidity Providers (LPs) are whitelisted and deposit/withdraw via non-transferable shares.
// - Fees accrue into feePool by escrow; anyone can call distributeFees() to split fees between team and LPs.
contract ExoBankRoll is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Bankroll_EscrowNotSet();
    error Bankroll_EscrowAlreadySet();
    error Bankroll_OnlyEscrow();

    error Bankroll_ReservationAmountZero();
    error Bankroll_ZeroPayoutRecipient();
    error Bankroll_InsufficientFreeLiquidity();
    error Bankroll_ReservesOutOfSync();

    error Bankroll_InsufficientBonus();
    error Bankroll_SignatureExpired();
    error Bankroll_InvalidUserSig();

    error Bankroll_FeeRecipientNotSet();

    // LP / vault
    error Bankroll_LPNotWhitelisted();
    error Bankroll_LPAmountZero();
    error Bankroll_InsufficientLPShares();
    error Bankroll_NoLPShares();
    error Bankroll_ExposureCapOutOfRange();
    error Bankroll_BankrollNotEmpty();
    error Bankroll_InitialDepositTooSmall();
    // bps must be in [0..10_000]
    error Bankroll_FeeSplitOutOfRange();
    // Deposits are temporarily disabled when too much equity is encumbered by reserved exposure.
    error Bankroll_DepositsLocked();

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    IERC20 public immutable usdc;

    // Minimum bonus withdraw amount (USDC has 6 decimals). Example: 5_000_000 = 5 USDC.
    uint256 public minBonusWithdrawable = 5_000_000;

    // Escrow address allowed to reserve/finalize bets.
    address public escrow;

    // Address that receives the team portion of distributed fees.
    address public feeRecipient;

    // Total reserved max payout exposure for unsettled bets.
    uint256 public totalReserved;

    // Senior liabilities (must be honored before LP equity).
    uint256 public totalBonus; // total withdrawable bonus owed to users
    uint256 public feePool;    // undistributed fees accrued by escrow

    mapping(address => uint256) public bonusBalance;

    // ---------------------------------------------------------------------
    // LP vault (non-transferable shares)
    // ---------------------------------------------------------------------
    mapping(address => bool) public isWhitelistedLP;

    uint256 public totalLpShares;
    mapping(address => uint256) public lpShares;

    // Informational seed value used for UI/display.
    uint256 public seedLiquidity = 1_000_000_000; // 1000 USDC (6 decimals)

    // Exposure cap applied to freeLiquidity() for escrow risk controls.
    // 1%..5% bounded; default 2% (200 bps)
    uint256 public maxExposureCapBps = 200;

    // Minimum LP deposit amount (USDC has 6 decimals). Default: 1000 USDC.
    uint256 public minDepositLiquidity = 1_000_000_000;

    // Team share of feePool distribution in basis points. Default: 7500 bps (75%).
    uint16 public feeRecipientSplitBps = 7_500;

    // Nonces for bonus withdraw signatures (replay protection).
    mapping(address => uint256) public nonces;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event EscrowSet(address indexed escrow);
    event FeeRecipientSet(address indexed feeRecipient);
    event LPWhitelistSet(address indexed lp, bool allowed);

    event Reserved(bytes32 indexed betId, uint256 amount);

    event Finalized(
        bytes32 indexed betId,
        address indexed user,
        uint256 reservedReleased,
        uint256 payout,
        uint256 fees,
        uint256 bonus
    );

    event BonusWithdrawn(address indexed user, uint256 amount);

    event LPDeposited(address indexed lp, uint256 assets, uint256 mintedShares);
    event LPWithdrawn(address indexed lp, uint256 burnedShares, uint256 assets);

    event FeesDistributed(uint256 amount, uint256 feeRecipientAmount, uint256 lpAmount);

    event MaxExposureCapBpsSet(uint256 bps);
    // Team fee share in bps (0..10_000)
    event FeeSplitBpsSet(uint16 feeRecipientBps);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address _usdc, address _owner) Ownable(_owner) {
        usdc = IERC20(_usdc);
    }

    function token() external view returns (address) {
        return address(usdc);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------
    function setEscrow(address _escrow) external onlyOwner {
        if (escrow != address(0)) revert Bankroll_EscrowAlreadySet();
        if (_escrow == address(0)) revert Bankroll_EscrowNotSet();
        escrow = _escrow;
        emit EscrowSet(_escrow);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert Bankroll_FeeRecipientNotSet();
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    function setLPWhitelist(address lp, bool allowed) external onlyOwner {
        if (lp == address(0)) revert Bankroll_LPNotWhitelisted();
        isWhitelistedLP[lp] = allowed;
        emit LPWhitelistSet(lp, allowed);
    }

    // 1%..5% => 100..500 bps
    function setMaxExposureCapBps(uint256 bps) external onlyOwner {
        if (bps < 100 || bps > 500) revert Bankroll_ExposureCapOutOfRange();
        maxExposureCapBps = bps;
        emit MaxExposureCapBpsSet(bps);
    }

    // Sets the minimum LP deposit size (USDC has 6 decimals).
    function setMinDepositLiquidity(uint256 amount) external onlyOwner {
        minDepositLiquidity = amount;
    }

    // Sets the team share of fee distribution in bps (0..10_000).
    function setFeeRecipientSplitBps(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert Bankroll_FeeSplitOutOfRange();
        feeRecipientSplitBps = bps;
        emit FeeSplitBpsSet(bps);
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert Bankroll_OnlyEscrow();
        _;
    }

    modifier onlyWhitelistedLP() {
        if (!isWhitelistedLP[msg.sender]) revert Bankroll_LPNotWhitelisted();
        _;
    }

    // ---------------------------------------------------------------------
    // Exposure math
    // ---------------------------------------------------------------------
    // Seniors are bonus + feePool.
    // freeLiquidity is the portion of balance available after seniors and reserved exposure.
    function freeLiquidity() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 seniors = totalBonus + feePool;
        uint256 enc = seniors + totalReserved;
        if (bal <= enc) return 0;
        return bal - enc;
    }

    // LP equity priced without subtracting temporary reserved exposure.
    // grossEquity = balance - seniors (bonus + feePool)
    function lpGrossEquity() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 seniors = totalBonus + feePool;
        if (bal <= seniors) return 0;
        return bal - seniors;
    }

    // Escrow risk limit: cap is applied to freeLiquidity().
    function maxAllowedPayout() external view returns (uint256) {
        return (freeLiquidity() * maxExposureCapBps) / 10_000;
    }

    // ---------------------------------------------------------------------
    // Reservations
    // ---------------------------------------------------------------------
    function reserve(bytes32 betId, uint256 amount) external onlyEscrow {
        if (amount == 0) revert Bankroll_ReservationAmountZero();
        totalReserved += amount;
        emit Reserved(betId, amount);
    }

    // ---------------------------------------------------------------------
    // Finalize (called by escrow)
    // ---------------------------------------------------------------------
    function finalizeBet(
        bytes32 betId,
        address to,
        uint256 reserved,
        uint256 payout,
        uint256 fees,
        uint256 bonus
    ) external onlyEscrow nonReentrant {
        if (to == address(0)) revert Bankroll_ZeroPayoutRecipient();
        if (reserved > totalReserved) revert Bankroll_ReservesOutOfSync();

        // Release reserved exposure.
        totalReserved -= reserved;

        // Accrue fee liability.
        if (fees != 0) feePool += fees;

        // Accrue bonus liability.
        if (bonus != 0) {
            bonusBalance[to] += bonus;
            totalBonus += bonus;
        }

        // Pay user payout (game payout is already net; no fees attached).
        if (payout != 0) usdc.safeTransfer(to, payout);

        emit Finalized(betId, to, reserved, payout, fees, bonus);
    }

    // ---------------------------------------------------------------------
    // Fees distribution (permissionless, full feePool)
    // ---------------------------------------------------------------------
    function distributeFees() external nonReentrant {
        if (feeRecipient == address(0)) revert Bankroll_FeeRecipientNotSet();

        uint256 amount = feePool;
        if (amount == 0) return;

        // Clear senior fee liability first, then split the amount.
        feePool = 0;

        uint256 toFeeRecipient = (amount * feeRecipientSplitBps) / 10_000;
        uint256 toLP = amount - toFeeRecipient;

        if (toFeeRecipient != 0) usdc.safeTransfer(feeRecipient, toFeeRecipient);
        // LP share stays in the contract balance, increasing gross equity and PPS.

        emit FeesDistributed(amount, toFeeRecipient, toLP);
    }

    // ---------------------------------------------------------------------
    // Users: bonus withdraw only
    // ---------------------------------------------------------------------
    // Withdraw full bonus balance for msg.sender.
    function claimBonus() external nonReentrant {
        _claimBonusAmount(msg.sender, bonusBalance[msg.sender]);
    }

    // Gasless bonus withdraw (amountOrMax = 0 => withdraw full bonus).
    // Digest is escrow-style (no EIP-191 prefix).
    function claimBonusWithSign(
        address user,
        uint256 amountOrMax,
        uint256 deadline,
        uint8 vUser,
        bytes32 rUser,
        bytes32 sUser
    ) external nonReentrant {
        if (block.timestamp > deadline) revert Bankroll_SignatureExpired();

        uint256 nonce = nonces[user];

        bytes32 digest = keccak256(
            abi.encodePacked(
                "EXO_BANKROLL_WITHDRAW_BONUS",
                address(this),
                user,
                amountOrMax,
                deadline,
                nonce
            )
        );

        if (ecrecover(digest, vUser, rUser, sUser) != user) revert Bankroll_InvalidUserSig();

        nonces[user] = nonce + 1;

        uint256 amount = amountOrMax == 0 ? bonusBalance[user] : amountOrMax;
        _claimBonusAmount(user, amount);
    }

    function _claimBonusAmount(address user, uint256 amount) internal {
        if (amount < minBonusWithdrawable) revert Bankroll_InsufficientBonus();
        if (bonusBalance[user] < amount) revert Bankroll_InsufficientBonus();

        // Bonus is a senior liability, so it must be payable from freeLiquidity().
        if (amount > freeLiquidity()) revert Bankroll_DepositsLocked();

        bonusBalance[user] -= amount;
        totalBonus -= amount;

        usdc.safeTransfer(user, amount);
        emit BonusWithdrawn(user, amount);
    }

    // ---------------------------------------------------------------------
    // LP vault (whitelisted LPs only, non-transferable shares)
    // ---------------------------------------------------------------------
    function lpPPS() public view returns (uint256) {
        if (totalLpShares == 0) return 1e18;

        uint256 ge = lpGrossEquity();
        // If gross equity is zero while shares exist, the vault is insolvent and PPS returns zero.
        return (ge * 1e18) / totalLpShares;
    }

    function lpValue(address lp) external view returns (uint256) {
        if (totalLpShares == 0) return 0;
        // User value is proportional claim on gross equity (not reduced by reserved exposure).
        return (lpShares[lp] * lpPPS()) / 1e18;
    }

    // Deposit USDC and receive non-transferable LP shares.
    function depositLP(uint256 assets) external onlyWhitelistedLP nonReentrant {
        if (assets == 0) revert Bankroll_LPAmountZero();
        if (assets < minDepositLiquidity) revert Bankroll_InitialDepositTooSmall();

        // Optional deposit guard: require a minimum fraction of gross equity to be currently free.
        // This prevents depositors from entering while most equity is encumbered by reserved exposure.
        if (totalLpShares != 0) {
            uint256 ge = lpGrossEquity();
            if (ge != 0) {
                uint256 free = freeLiquidity();
                if ((free * 10_000) / ge < 2_000) revert Bankroll_InsufficientFreeLiquidity();
            }
        }

        uint256 shares;

        if (totalLpShares == 0) {
            // Genesis deposit must start from a clean state to prevent capturing any pre-existing value.
            if (usdc.balanceOf(address(this)) != 0) revert Bankroll_BankrollNotEmpty();
            if (totalBonus != 0 || feePool != 0 || totalReserved != 0) revert Bankroll_BankrollNotEmpty();

            // 1:1 shares to asset units at genesis (USDC has 6 decimals).
            shares = assets;
        } else {
            // Price shares off gross equity (excludes reserved exposure).
            uint256 geBefore = lpGrossEquity();
            if (geBefore == 0) revert Bankroll_NoLPShares();

            shares = (assets * totalLpShares) / geBefore;
            if (shares == 0) revert Bankroll_NoLPShares();
        }

        usdc.safeTransferFrom(msg.sender, address(this), assets);

        lpShares[msg.sender] += shares;
        totalLpShares += shares;

        emit LPDeposited(msg.sender, assets, shares);
    }

    // Withdraw by burning shares. Payout is limited by freeLiquidity().
    function withdrawLP(uint256 shares) external onlyWhitelistedLP nonReentrant {
        if (shares == 0) revert Bankroll_LPAmountZero();

        uint256 userShares = lpShares[msg.sender];
        if (userShares < shares) revert Bankroll_InsufficientLPShares();
        if (totalLpShares == 0) revert Bankroll_NoLPShares();

        uint256 ge = lpGrossEquity();

        // Amount is the LP's pro-rata claim on gross equity.
        uint256 amount = (shares * ge) / totalLpShares;

        // Withdrawals can only be paid from free liquidity (after reserved exposure).
        if (amount > freeLiquidity()) revert Bankroll_InsufficientFreeLiquidity();

        lpShares[msg.sender] = userShares - shares;
        totalLpShares -= shares;

        usdc.safeTransfer(msg.sender, amount);
        emit LPWithdrawn(msg.sender, shares, amount);
    }

    // ---------------------------------------------------------------------
    // Views (UI)
    // ---------------------------------------------------------------------
    function getUserAccount(address user)
        external
        view
        returns (
            uint256 userBalance,
            uint256 bankrollFreeLiquidity,
            uint256 userBonus,
            uint256 userNonce,
            uint256 blockNumber,
            uint256 blockTimeStamp
        )
    {
        userBalance = usdc.balanceOf(user);
        bankrollFreeLiquidity = freeLiquidity();
        userBonus = bonusBalance[user];
        userNonce = nonces[user];
        blockNumber = block.number;
        blockTimeStamp = block.timestamp;
    }

    function getAccounting()
        external
        view
        returns (
            uint256 balance,
            uint256 reserved,
            uint256 totalBonusLiability,
            uint256 feePoolLiability,
            uint256 seniors,
            uint256 freeLiq,
            uint256 maxExposureCapBps_,
            uint256 maxAllowedPayout_,
            uint256 lpAssets_,
            uint256 totalLpShares_,
            uint256 lpPps_,
            uint256 seedLiquidity_,
            address feeRecipient_,
            uint256 blockNumber,
            uint256 blockTimeStamp
        )
    {
        balance = usdc.balanceOf(address(this));
        reserved = totalReserved;

        totalBonusLiability = totalBonus;
        feePoolLiability = feePool;

        seniors = totalBonusLiability + feePoolLiability;

        uint256 enc = seniors + reserved;
        freeLiq = balance <= enc ? 0 : balance - enc;

        maxExposureCapBps_ = maxExposureCapBps;
        maxAllowedPayout_ = (freeLiq * maxExposureCapBps_) / 10_000;

        // LP accounting uses gross equity for pricing (reserved exposure is not subtracted).
        lpAssets_ = lpGrossEquity();
        totalLpShares_ = totalLpShares;
        lpPps_ = totalLpShares_ == 0 ? 1e18 : (lpAssets_ * 1e18) / totalLpShares_;

        seedLiquidity_ = seedLiquidity;

        feeRecipient_ = feeRecipient;

        blockNumber = block.number;
        blockTimeStamp = block.timestamp;
    }
    function getLpAccount(address lp)
        external
        view
        returns (
            bool whitelisted,
            uint256 lpShares_,
            uint256 lpValueGross_,       // claim on gross equity (not reduced by reserved exposure)
            uint256 lpPps_,
            uint256 bankrollFreeLiquidity,
            uint256 maxWithdrawAssets_,  // max USDC the LP can withdraw right now
            uint256 maxWithdrawShares_,  // max shares the LP can burn right now
            bool depositsAllowed_,       // mirrors deposit guard condition
            uint256 minDepositLiquidity_,
            uint256 blockNumber,
            uint256 blockTimeStamp
        )
    {
        whitelisted = isWhitelistedLP[lp];

        lpShares_ = lpShares[lp];
        bankrollFreeLiquidity = freeLiquidity();

        // PPS and gross LP value
        lpPps_ = lpPPS();
        lpValueGross_ = totalLpShares == 0 ? 0 : (lpShares_ * lpPps_) / 1e18;

        // Max withdrawable is limited by free liquidity
        // (LP withdrawal amount is pro-rata of gross equity, but must be payable from freeLiquidity)
        uint256 ge = lpGrossEquity();
        uint256 amountByShares = (totalLpShares == 0) ? 0 : (lpShares_ * ge) / totalLpShares;

        maxWithdrawAssets_ = amountByShares;
        if (maxWithdrawAssets_ > bankrollFreeLiquidity) maxWithdrawAssets_ = bankrollFreeLiquidity;

        // Convert max withdrawable assets back into shares (floor rounding)
        maxWithdrawShares_ = 0;
        if (ge != 0 && totalLpShares != 0) {
            maxWithdrawShares_ = (maxWithdrawAssets_ * totalLpShares) / ge;
            if (maxWithdrawShares_ > lpShares_) maxWithdrawShares_ = lpShares_;
        }

        // Deposit guard mirror (same rule as depositLP)
        depositsAllowed_ = true;
        if (totalLpShares != 0) {
            if (ge == 0) {
                depositsAllowed_ = false;
            } else {
                // require free/GE >= 20%
                uint256 freeBps = (bankrollFreeLiquidity * 10_000) / ge;
                if (freeBps < 2_000) depositsAllowed_ = false;
            }
        }

        minDepositLiquidity_ = minDepositLiquidity;

        blockNumber = block.number;
        blockTimeStamp = block.timestamp;
    }

}
