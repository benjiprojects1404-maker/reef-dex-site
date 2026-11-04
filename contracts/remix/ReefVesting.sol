// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Reef Vesting
/// @notice Holds the dev allocation and releases it to `beneficiary` on a fixed
///         schedule: nothing before the cliff, then a straight line from zero
///         at the cliff to 100% at the end. There is no lump sum when the cliff
///         lifts: vesting starts from zero at that moment.
///
///         It does not need to know the token address at deployment, which is
///         what lets it be deployed BEFORE ReefToken and receive the dev
///         allocation directly from the token's constructor (no follow-up
///         transfer step). Every token is tracked separately, so the contract
///         works for any ERC-20 sent to it; only REEF is intended.
///
///         Schedule variables are ordinary storage rather than `immutable` on
///         purpose: simple explorer verifiers cannot match bytecode that has
///         immutables baked in, and this keeps verification straightforward.
///         There is no owner, no admin function and no way to change the
///         beneficiary or the schedule after deployment.
contract ReefVesting {
    using SafeERC20 for IERC20;

    address public beneficiary;
    uint256 public start;
    uint256 public cliffEnd;
    uint256 public end;

    /// @notice Total already released, per token.
    mapping(address => uint256) public released;

    event Released(address indexed token, uint256 amount, address to);

    /// @param beneficiary_     Receives everything that vests.
    /// @param cliffSeconds     Time from deployment until vesting begins.
    /// @param durationSeconds  Time from deployment until 100% is vested. Must exceed the cliff.
    constructor(address beneficiary_, uint256 cliffSeconds, uint256 durationSeconds) {
        require(beneficiary_ != address(0), "beneficiary is zero address");
        require(cliffSeconds > 0, "cliff must be positive");
        require(durationSeconds > cliffSeconds, "duration must exceed cliff");

        beneficiary = beneficiary_;
        start = block.timestamp;
        cliffEnd = block.timestamp + cliffSeconds;
        end = block.timestamp + durationSeconds;
    }

    /// @notice Total amount of `token` that has vested so far (released or not).
    function vestedAmount(address token) public view returns (uint256) {
        uint256 total = IERC20(token).balanceOf(address(this)) + released[token];
        if (block.timestamp < cliffEnd) return 0;
        if (block.timestamp >= end) return total;
        return (total * (block.timestamp - cliffEnd)) / (end - cliffEnd);
    }

    /// @notice Vested but not yet released.
    function releasable(address token) public view returns (uint256) {
        return vestedAmount(token) - released[token];
    }

    /// @notice Anyone can trigger a release; funds only ever go to `beneficiary`.
    function release(address token) external {
        uint256 amount = releasable(token);
        require(amount > 0, "nothing to release");

        released[token] += amount;
        IERC20(token).safeTransfer(beneficiary, amount);
        emit Released(token, amount, beneficiary);
    }
}
