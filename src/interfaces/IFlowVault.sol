// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

/// @notice Bond escrow. A payer's free balance backs the receipts they leave open; the hook locks
/// against it at swap time and settlement debits from it.
interface IFlowVault {
    event Deposited(address indexed payer, Currency indexed currency, uint256 amount);
    event Withdrawn(address indexed payer, Currency indexed currency, uint256 amount, address to);
    event Locked(address indexed payer, Currency indexed currency, uint256 amount);
    event Unlocked(address indexed payer, Currency indexed currency, uint256 amount);
    event Debited(address indexed payer, Currency indexed currency, uint256 amount, address indexed to);
    event Credited(address indexed payer, Currency indexed currency, uint256 amount);

    function deposit(Currency currency, uint256 amount) external;
    function depositFor(address payer, Currency currency, uint256 amount) external;
    function withdraw(Currency currency, uint256 amount, address to) external;

    function balanceOf(address payer, Currency currency) external view returns (uint256);
    function lockedOf(address payer, Currency currency) external view returns (uint256);
    function freeBalanceOf(address payer, Currency currency) external view returns (uint256);

    /// @dev Hook-only. Returns false instead of reverting when the bond is short, because a swap
    /// must never revert.
    function lock(address payer, Currency currency, uint256 amount) external returns (bool);
    function unlock(address payer, Currency currency, uint256 amount) external;
    /// @dev Hook-only. Moves locked bond out to `to`. Returns the amount actually moved.
    function debit(address payer, Currency currency, uint256 amount, address to) external returns (uint256);
    /// @dev Hook-only. Credits an already-held balance to a payer (rebates).
    function credit(address payer, Currency currency, uint256 amount) external;
}
