// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title $NOCAP LP Lock
/// @notice Locks LP tokens (from the liquidity pool once one exists on
///         BlockDAG) until `unlockTime`. No one — including the deployer —
///         can withdraw before then. Deploy this once the LP token address
///         is known (i.e. once a pool has actually been created), send the
///         LP tokens in, then publish this contract's address and
///         unlockTime publicly as proof liquidity can't be pulled early.
contract NoCapLPLock {
    using SafeERC20 for IERC20;

    IERC20 public immutable lpToken;
    address public immutable beneficiary;
    uint256 public immutable unlockTime;

    event Withdrawn(uint256 amount, address to);

    constructor(address lpToken_, address beneficiary_, uint256 lockDurationSeconds) {
        require(lpToken_ != address(0), "lp token is zero address");
        require(beneficiary_ != address(0), "beneficiary is zero address");
        require(lockDurationSeconds >= 180 days, "lock must be at least 6 months");

        lpToken = IERC20(lpToken_);
        beneficiary = beneficiary_;
        unlockTime = block.timestamp + lockDurationSeconds;
    }

    /// @notice Anyone can check remaining lock time — useful for public verification
    function timeRemaining() external view returns (uint256) {
        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }

    /// @notice Withdraw locked LP tokens. Only callable after unlockTime, only by beneficiary.
    function withdraw() external {
        address to = beneficiary; // cache: avoid repeated state reads
        require(msg.sender == to, "not beneficiary");
        require(block.timestamp >= unlockTime, "still locked");

        uint256 balance = lpToken.balanceOf(address(this));
        require(balance > 0, "nothing to withdraw");

        lpToken.safeTransfer(to, balance);
        emit Withdrawn(balance, to);
    }
}
