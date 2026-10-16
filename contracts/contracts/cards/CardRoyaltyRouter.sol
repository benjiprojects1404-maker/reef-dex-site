// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReefZap} from "./ReefZap.sol";

interface IWBDAGLike {
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @title CardRoyaltyRouter
/// @notice Receives the 5% resale royalty on the cards (in BDAG or WBDAG) and, when anyone calls
///         `flush`, adds it half to the COOKED pool and half to the NOCAP pool, burning the LP.
///         It has no owner and no other way to move funds.
contract CardRoyaltyRouter is ReentrancyGuard, ReefZap {
    address public immutable cookedToken;
    address public immutable nocapToken;
    uint256 public immutable minFlush;

    event Flushed(uint256 bdag, uint256 cookedLiquidity, uint256 nocapLiquidity);

    constructor(address router_, address factory_, address wbdag_, address cooked_, address nocap_, uint256 minFlush_)
        ReefZap(router_, factory_, wbdag_)
    {
        cookedToken = cooked_;
        nocapToken = nocap_;
        minFlush = minFlush_;
        _approveRouter(cooked_);
        _approveRouter(nocap_);
    }

    receive() external payable {}

    function flush(uint256 minCookedOut, uint256 minNocapOut, uint256 deadline) external nonReentrant {
        uint256 w = IWBDAGLike(wbdag).balanceOf(address(this));
        if (w > 0) IWBDAGLike(wbdag).withdraw(w);
        uint256 bal = address(this).balance;
        require(bal >= minFlush, "below minimum");
        uint256 half = bal / 2;
        uint256 lc = _zap(cookedToken, half, minCookedOut, deadline);
        uint256 ln = _zap(nocapToken, bal - half, minNocapOut, deadline);
        emit Flushed(bal, lc, ln);
    }
}
