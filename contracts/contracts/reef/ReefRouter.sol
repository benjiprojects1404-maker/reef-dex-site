// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import "./interfaces/IReefFactory.sol";
import "./interfaces/IReefPair.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWBDAG.sol";
import "./libraries/ReefLibrary.sol";
import "./libraries/TransferHelper.sol";

/// @title ReefRouter
/// @notice Public-facing entry point for Reef. Anyone can call addLiquidity for
/// any two tokens - if a pool doesn't exist yet, this router creates it via the
/// factory in the same transaction. No permission step, no allowlist.
contract ReefRouter {
    address public immutable factory;
    address public immutable WBDAG;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "ReefRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _WBDAG) {
        factory = _factory;
        WBDAG = _WBDAG;
    }

    receive() external payable {
        require(msg.sender == WBDAG, "ReefRouter: DIRECT_BDAG_NOT_ACCEPTED"); // only accept native BDAG via WBDAG unwrapping
    }

    // ---------- LIQUIDITY ----------

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB) {
        // create the pair permissionlessly if it doesn't exist yet
        if (IReefFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IReefFactory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = ReefLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = ReefLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "ReefRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = ReefLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "ReefRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = ReefLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IReefPair(pair).mint(to);
    }

    function addLiquidityBDAG(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountBDAGMin,
        address to,
        uint deadline
    ) external payable ensure(deadline) returns (uint amountToken, uint amountBDAG, uint liquidity) {
        (amountToken, amountBDAG) = _addLiquidity(
            token,
            WBDAG,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountBDAGMin
        );
        address pair = ReefLibrary.pairFor(factory, token, WBDAG);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWBDAG(WBDAG).deposit{value: amountBDAG}();
        require(IWBDAG(WBDAG).transfer(pair, amountBDAG));
        liquidity = IReefPair(pair).mint(to);
        // refund leftover native BDAG, if any
        if (msg.value > amountBDAG) TransferHelper.safeTransferBDAG(msg.sender, msg.value - amountBDAG);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = ReefLibrary.pairFor(factory, tokenA, tokenB);
        require(IReefPair(pair).transferFrom(msg.sender, pair, liquidity));
        (uint amount0, uint amount1) = IReefPair(pair).burn(to);
        (address token0, ) = ReefLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "ReefRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "ReefRouter: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityBDAG(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountBDAGMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountToken, uint amountBDAG) {
        (amountToken, amountBDAG) = removeLiquidity(
            token,
            WBDAG,
            liquidity,
            amountTokenMin,
            amountBDAGMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWBDAG(WBDAG).withdraw(amountBDAG);
        TransferHelper.safeTransferBDAG(to, amountBDAG);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB) {
        address pair = ReefLibrary.pairFor(factory, tokenA, tokenB);
        IReefPair(pair).permit(msg.sender, address(this), approveMax ? type(uint).max : liquidity, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    // ---------- SWAPS ----------

    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = ReefLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? ReefLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IReefPair(ReefLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        amounts = ReefLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ReefRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        amounts = ReefLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "ReefRouter: EXCESSIVE_INPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactBDAGForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WBDAG, "ReefRouter: INVALID_PATH");
        amounts = ReefLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ReefRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWBDAG(WBDAG).deposit{value: amounts[0]}();
        require(IWBDAG(WBDAG).transfer(ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }

    function swapTokensForExactBDAG(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WBDAG, "ReefRouter: INVALID_PATH");
        amounts = ReefLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "ReefRouter: EXCESSIVE_INPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWBDAG(WBDAG).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferBDAG(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForBDAG(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WBDAG, "ReefRouter: INVALID_PATH");
        amounts = ReefLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "ReefRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWBDAG(WBDAG).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferBDAG(to, amounts[amounts.length - 1]);
    }

    function swapBDAGForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WBDAG, "ReefRouter: INVALID_PATH");
        amounts = ReefLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "ReefRouter: EXCESSIVE_INPUT_AMOUNT");
        IWBDAG(WBDAG).deposit{value: amounts[0]}();
        require(IWBDAG(WBDAG).transfer(ReefLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund leftover native BDAG, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferBDAG(msg.sender, msg.value - amounts[0]);
    }

    // ---------- VIEW HELPERS (passthroughs to ReefLibrary) ----------

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB) {
        return ReefLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut) {
        return ReefLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn) {
        return ReefLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        return ReefLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts) {
        return ReefLibrary.getAmountsIn(factory, amountOut, path);
    }
}
