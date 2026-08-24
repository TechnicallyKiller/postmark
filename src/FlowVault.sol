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

    mapping(address payer => mapping(Currency => uint256)) private _balance;
    mapping(address payer => mapping(Currency => uint256)) private _locked;
    mapping(address payer => uint64 blockNumber) public lastActivityBlock;

    error HookAlreadySet();
    error NotDeployer();
    error NotHook();
    error NativeNotSupported();
    error InsufficientFreeBalance();
    error BondStillLocked();
    error CooldownActive();
    error ZeroAmount();

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
        _balance[payer][currency] += amount;

        emit Deposited(payer, currency, amount);
    }

    /// @notice Withdraw free bond. Requires no open receipts (nothing locked) and the cooldown to
    /// have elapsed since the payer's last swap, so the settlement window cannot be outrun.
    function withdraw(Currency currency, uint256 amount, address to) external {
        if (amount == 0) revert ZeroAmount();
        if (_locked[msg.sender][currency] != 0) revert BondStillLocked();
        if (block.number < lastActivityBlock[msg.sender] + withdrawCooldownBlocks) revert CooldownActive();

        uint256 bal = _balance[msg.sender][currency];
        if (amount > bal) revert InsufficientFreeBalance();
        unchecked {
            _balance[msg.sender][currency] = bal - amount;
        }

        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        emit Withdrawn(msg.sender, currency, amount, to);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function balanceOf(address payer, Currency currency) external view returns (uint256) {
        return _balance[payer][currency];
    }

    function lockedOf(address payer, Currency currency) external view returns (uint256) {
        return _locked[payer][currency];
    }

    function freeBalanceOf(address payer, Currency currency) public view returns (uint256) {
        return _balance[payer][currency] - _locked[payer][currency];
    }

    // -------------------------------------------------------------------------
    // Hook surface
    // -------------------------------------------------------------------------

    /// @dev Returns false rather than reverting when the bond is short. beforeSwap uses that to
    /// fall back to the top tier instead of failing the swap.
    function lock(address payer, Currency currency, uint256 amount) external onlyHook returns (bool) {
        if (amount > freeBalanceOf(payer, currency)) return false;
        _locked[payer][currency] += amount;
        lastActivityBlock[payer] = uint64(block.number);
        emit Locked(payer, currency, amount);
        return true;
    }

    function unlock(address payer, Currency currency, uint256 amount) external onlyHook {
        uint256 locked_ = _locked[payer][currency];
        uint256 released = amount > locked_ ? locked_ : amount;
        unchecked {
            _locked[payer][currency] = locked_ - released;
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
        _balance[to][currency] += taken;
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
        unchecked {
            _balance[msg.sender][currency] -= paid;
        }
        _balance[payer][currency] += paid;
        emit Credited(payer, currency, paid);
    }

    function _take(address payer, Currency currency, uint256 amount) private returns (uint256 taken) {
        uint256 locked_ = _locked[payer][currency];
        taken = amount > locked_ ? locked_ : amount;
        if (taken == 0) return 0;
        unchecked {
            _locked[payer][currency] = locked_ - taken;
            _balance[payer][currency] -= taken;
        }
    }
}
