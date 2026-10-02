// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * NodalReefAdapter
 * =============================================================================
 * Lets NodalRouter route trades through Reef.
 *
 * NodalRouter talks to DEXes through the standard Uniswap V2 router interface,
 * which names the native-coin swaps `swapExactETHForTokens` and
 * `swapExactTokensForETH`. Reef's router is a V2-style router but names those
 * functions `swapExactBDAGForTokens` and `swapExactTokensForBDAG`. NodalRouter
 * is already deployed and can't be changed, so this adapter sits in between:
 * NodalRouter registers the adapter's address as a source, and the adapter
 * forwards every call to Reef under Reef's own function names.
 *
 * Design:
 *  - Stateless pass-through. No owner, no admin functions, no storage, nothing
 *    that can be changed after deployment. The Reef router address is fixed at
 *    construction.
 *  - Holds no funds between transactions. Input tokens go straight from the
 *    caller to Reef, and Reef pays the output straight to `to` (NodalRouter).
 *  - Slippage is enforced by NodalRouter (minNetAmountOut, measured by balance
 *    delta). The `amountOutMin` argument is still passed through to Reef too.
 *  - Anyone can call it, but it only ever moves the caller's own tokens, so
 *    there is nothing to gain by calling it directly.
 *  - No imports, so it verifies as a single file on the explorer.
 *
 * Compiler: Solidity 0.8.24, EVM version Berlin (same as NodalRouter and Reef).
 */

interface IReefRouter {
    function WBDAG() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactBDAGForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForBDAG(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract NodalReefAdapter {
    /// @notice The Reef router every call is forwarded to. Fixed forever.
    IReefRouter public immutable reef;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address reefRouter) {
        require(reefRouter != address(0), "router=0");
        reef = IReefRouter(reefRouter);
    }

    /// @notice Reef's wrapped-BDAG token. NodalRouter's BDAG swaps need this as the
    /// first (BDAG in) or last (BDAG out) entry of `path`.
    function WBDAG() external view returns (address) {
        return reef.WBDAG();
    }

    // ------------------------------------------------------------------
    // Quoting: same name on both sides, forwarded as-is
    // ------------------------------------------------------------------

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts)
    {
        return reef.getAmountsOut(amountIn, path);
    }

    // ------------------------------------------------------------------
    // Swaps: V2 names in, Reef names out
    // ------------------------------------------------------------------

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        _pullAndApprove(path[0], amountIn);
        return reef.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        return reef.swapExactBDAGForTokens{value: msg.value}(amountOutMin, path, to, deadline);
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        _pullAndApprove(path[0], amountIn);
        return reef.swapExactTokensForBDAG(amountIn, amountOutMin, path, to, deadline);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Pull `amount` of `token` from the caller, then approve Reef for exactly
    /// that amount. Handles tokens that return no bool (USDT-style) and tokens that
    /// refuse to change a non-zero allowance (by resetting to zero first).
    function _pullAndApprove(address token, uint256 amount) private {
        _call(token, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount)); // transferFrom
        _call(token, abi.encodeWithSelector(0x095ea7b3, address(reef), 0));                 // approve(reef, 0)
        _call(token, abi.encodeWithSelector(0x095ea7b3, address(reef), amount));            // approve(reef, amount)
    }

    function _call(address token, bytes memory data) private {
        require(token.code.length > 0, "not a token");
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "token call failed");
    }

    /// @dev Reject stray BDAG. Reef pays native BDAG straight to `to`, never to this
    /// contract, so there is no legitimate reason for BDAG to arrive here.
    receive() external payable {
        revert("no direct BDAG");
    }
}
