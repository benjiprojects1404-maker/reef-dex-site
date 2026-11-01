// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title REEF tranche vesting
/// @notice Pays a fixed amount of a token to one beneficiary in equal tranches on fixed dates.
///         Used for community thank-yous paid over time (e.g. 10,000 REEF as five 2,000 REEF
///         tranches, 9 Nov 2026 to 9 Nov 2027).
///
///         - No owner, no admin, no withdraw: nothing can be changed after deployment and the
///           tokens can only ever go to `beneficiary`.
///         - Funded by a plain token transfer to this contract after deployment. Fund exactly
///           `totalAmount()`: anything above that can never be released.
///         - Anyone may call `release()`; the tokens always go to `beneficiary`.
///         - If the contract is under-funded, `release()` pays what it holds and the rest
///           can be released after it is topped up.
contract ReefTrancheVesting {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public immutable trancheAmount;

    /// @dev Unlock times (unix seconds), strictly increasing. Set once in the constructor.
    uint64[] private _unlockTimes;

    /// @notice Total tokens paid out so far.
    uint256 public released;

    event Released(uint256 amount, uint256 totalReleased);

    constructor(IERC20 token_, address beneficiary_, uint256 trancheAmount_, uint64[] memory unlockTimes_) {
        require(address(token_) != address(0), "token is zero address");
        require(address(token_).code.length > 0, "token is not a contract");
        require(beneficiary_ != address(0), "beneficiary is zero address");
        require(trancheAmount_ > 0, "tranche amount is zero");
        require(unlockTimes_.length > 0 && unlockTimes_.length <= 24, "1 to 24 tranches");
        for (uint256 i = 1; i < unlockTimes_.length; i++) {
            require(unlockTimes_[i] > unlockTimes_[i - 1], "unlock times must increase");
        }
        token = token_;
        beneficiary = beneficiary_;
        trancheAmount = trancheAmount_;
        _unlockTimes = unlockTimes_;
    }

    /// @notice All unlock times (unix seconds).
    function unlockTimes() external view returns (uint64[] memory) {
        return _unlockTimes;
    }

    /// @notice Number of tranches.
    function tranches() external view returns (uint256) {
        return _unlockTimes.length;
    }

    /// @notice The full amount this contract should be funded with.
    function totalAmount() public view returns (uint256) {
        return trancheAmount * _unlockTimes.length;
    }

    /// @notice Tokens unlocked so far (released or not).
    function vested() public view returns (uint256) {
        uint256 n;
        uint256 len = _unlockTimes.length;
        while (n < len && _unlockTimes[n] <= block.timestamp) n++;
        return trancheAmount * n;
    }

    /// @notice Tokens that `release()` would pay out right now.
    function releasable() public view returns (uint256) {
        uint256 due = vested() - released;
        uint256 bal = token.balanceOf(address(this));
        return due < bal ? due : bal;
    }

    /// @notice Pays every unlocked, unpaid tranche to the beneficiary. Anyone may call it.
    function release() external {
        uint256 amount = releasable();
        require(amount > 0, "nothing to release");
        released += amount;
        token.safeTransfer(beneficiary, amount);
        emit Released(amount, released);
    }
}
