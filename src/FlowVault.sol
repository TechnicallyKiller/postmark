// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlowVault} from "./interfaces/IFlowVault.sol";

/// @title FlowVault
/// @notice Bond escrow for Postmark. Bonding is opt-in and permissionless, and it only ever lowers
/// a payer's cost: an unbonded swapper still trades, they just land in the top fee tier.
///
/// @dev The hook is set exactly once, at wiring time, and can never be changed. This is the
/// contract that holds money, so it is the contract where immutability matters most (attack A5).
contract FlowVault is IFlowVault {
    using SafeERC20 for IERC20;

    /// @notice The one Postmark hook allowed to lock, debit and credit. Set once, forever.
    address public hook;

    /// @notice Blocks a payer must wait after their last swap before withdrawing. Must be at least
    /// the settlement window W, so a payer cannot swap and run before their receipt is settleable.
    uint32 public immutable withdrawCooldownBlocks;

    address public immutable deployer;

    /// @dev Balance, lock and cooldown timestamp share one storage slot per (payer, currency).
    /// Locking a bond is on the swap hot path, so it must touch exactly one slot: as three separate
    /// mappings this cost two extra cold SSTOREs (~22k) on every swap that wrote a receipt.
    /// `uint112` holds 5.19e33 wei, or 5.19e15 tokens at 18 decimals.
    struct Account {
        uint112 balance; // 112 bits ┐
        uint112 locked; // 112 bits │ one slot
        uint32 lastActivityBlock; //  32 bits ┘
    }

    mapping(address payer => mapping(Currency => Account)) private _accounts;

    error HookAlreadySet();
    error NotDeployer();
    error NotHook();
    error NativeNotSupported();
    error InsufficientFreeBalance();
    error BondStillLocked();
    error CooldownActive();
    error ZeroAmount();
    error AmountTooLarge();

    constructor(uint32 _withdrawCooldownBlocks) {
        deployer = msg.sender;
        withdrawCooldownBlocks = _withdrawCooldownBlocks;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    /// @notice One-shot wiring. The hook address is unknown at vault-deploy time because the hook
    /// address is mined against the vault, so this cannot be a constructor argument.
    function setHook(address _hook) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
    }

    // -------------------------------------------------------------------------
    // Payer surface
    // -------------------------------------------------------------------------

    function deposit(Currency currency, uint256 amount) external {
        depositFor(msg.sender, currency, amount);
    }

    function depositFor(address payer, Currency currency, uint256 amount) public {
        if (amount == 0) revert ZeroAmount();
        if (currency.isAddressZero()) revert NativeNotSupported();

        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);

        Account storage acct = _accounts[payer][currency];
        uint256 next = uint256(acct.balance) + amount;
        if (next > type(uint112).max) revert AmountTooLarge();
        acct.balance = uint112(next);

        emit Deposited(payer, currency, amount);
    }

    /// @notice Withdraw free bond. Requires no open receipts (nothing locked) and the cooldown to
    /// have elapsed since the payer's last swap, so the settlement window cannot be outrun.
    function withdraw(Currency currency, uint256 amount, address to) external {
        if (amount == 0) revert ZeroAmount();

        Account storage acct = _accounts[msg.sender][currency];
        if (acct.locked != 0) revert BondStillLocked();
        if (block.number < uint256(acct.lastActivityBlock) + withdrawCooldownBlocks) revert CooldownActive();

        uint256 bal = acct.balance;
        if (amount > bal) revert InsufficientFreeBalance();
        unchecked {
            acct.balance = uint112(bal - amount);
        }

        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        emit Withdrawn(msg.sender, currency, amount, to);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function balanceOf(address payer, Currency currency) external view returns (uint256) {
        return _accounts[payer][currency].balance;
    }

    function lockedOf(address payer, Currency currency) external view returns (uint256) {
        return _accounts[payer][currency].locked;
    }

    function freeBalanceOf(address payer, Currency currency) public view returns (uint256) {
        Account storage acct = _accounts[payer][currency];
        return uint256(acct.balance) - uint256(acct.locked);
    }

    function lastActivityBlock(address payer, Currency currency) external view returns (uint256) {
        return _accounts[payer][currency].lastActivityBlock;
    }

    // -------------------------------------------------------------------------
    // Hook surface
    // -------------------------------------------------------------------------

    /// @dev Returns false rather than reverting when the bond is short. beforeSwap uses that to
    /// fall back to the top tier instead of failing the swap.
    function lock(address payer, Currency currency, uint256 amount) external onlyHook returns (bool) {
        Account storage acct = _accounts[payer][currency];
        // One slot read, one slot write: this runs inside afterSwap on every receipt.
        Account memory a = acct;
        if (amount > uint256(a.balance) - uint256(a.locked)) return false;

        acct.locked = uint112(uint256(a.locked) + amount);
        acct.lastActivityBlock = uint32(block.number);

        emit Locked(payer, currency, amount);
        return true;
    }

    function unlock(address payer, Currency currency, uint256 amount) external onlyHook {
        Account storage acct = _accounts[payer][currency];
        uint256 locked_ = acct.locked;
        uint256 released = amount > locked_ ? locked_ : amount;
        unchecked {
            acct.locked = uint112(locked_ - released);
        }
        emit Unlocked(payer, currency, released);
    }

    /// @notice Move bond from a payer to another vault account (keeper cut, rebate pool).
    /// @dev Debits locked bond first, capped at what is actually locked and held.
    function debit(address payer, Currency currency, uint256 amount, address to)
        external
        onlyHook
        returns (uint256 taken)
    {
        taken = _take(payer, currency, amount);
        Account storage dest = _accounts[to][currency];
        dest.balance = uint112(uint256(dest.balance) + taken);
        emit Debited(payer, currency, taken, to);
    }

    /// @notice Move bond out of the vault entirely, so the hook can `donate()` it to LPs.
    function debitOut(address payer, Currency currency, uint256 amount, address to)
        external
        onlyHook
        returns (uint256 taken)
    {
        taken = _take(payer, currency, amount);
        if (taken != 0) IERC20(Currency.unwrap(currency)).safeTransfer(to, taken);
        emit Debited(payer, currency, taken, to);
    }

    /// @notice Move balance from the hook's own vault account (the rebate pool) to a payer.
    function credit(address payer, Currency currency, uint256 amount) external onlyHook {
        uint256 pool = freeBalanceOf(msg.sender, currency);
        uint256 paid = amount > pool ? pool : amount;
        if (paid == 0) return;

        Account storage from = _accounts[msg.sender][currency];
        Account storage to = _accounts[payer][currency];
        unchecked {
            from.balance = uint112(uint256(from.balance) - paid);
        }
        to.balance = uint112(uint256(to.balance) + paid);
        emit Credited(payer, currency, paid);
    }

    function _take(address payer, Currency currency, uint256 amount) private returns (uint256 taken) {
        Account storage acct = _accounts[payer][currency];
        uint256 locked_ = acct.locked;
        taken = amount > locked_ ? locked_ : amount;
        if (taken == 0) return 0;
        unchecked {
            acct.locked = uint112(locked_ - taken);
            acct.balance = uint112(uint256(acct.balance) - taken);
        }
    }
}
