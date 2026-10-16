// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IZapRouter {
    function swapExactBDAGForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external payable returns (uint[] memory amounts);
    function addLiquidityBDAG(address token, uint amountTokenDesired, uint amountTokenMin, uint amountBDAGMin, address to, uint deadline)
        external payable returns (uint amountToken, uint amountBDAG, uint liquidity);
}

interface IZapFactory {
    function getPair(address a, address b) external view returns (address);
}

interface IZapPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IZapERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Adds native BDAG to a TOKEN/WBDAG Reef pool in one go: swaps the exact share that makes
///         the rest pair with nothing left over, adds liquidity, and sends the LP to the dead address.
abstract contract ReefZap {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IZapRouter public immutable router;
    IZapFactory public immutable factory;
    address public immutable wbdag;

    constructor(address router_, address factory_, address wbdag_) {
        require(router_ != address(0) && factory_ != address(0) && wbdag_ != address(0), "bad reef");
        router = IZapRouter(router_);
        factory = IZapFactory(factory_);
        wbdag = wbdag_;
    }

    function _approveRouter(address token) internal {
        require(IZapERC20(token).approve(address(router), type(uint256).max), "approve failed");
    }

    /// @dev Optimal single-sided amount to swap for a 0.30% fee pool:
    ///      s = (sqrt(r * (r * 3988009 + a * 3988000)) - r * 1997) / 1994
    function swapAmount(uint256 reserveBDAG, uint256 amountIn) public pure returns (uint256) {
        return (Math.sqrt(reserveBDAG * (reserveBDAG * 3988009 + amountIn * 3988000)) - reserveBDAG * 1997) / 1994;
    }

    function bdagReserve(address token) public view returns (uint256) {
        address pair = factory.getPair(token, wbdag);
        require(pair != address(0), "no pool");
        (uint112 r0, uint112 r1, ) = IZapPair(pair).getReserves();
        return IZapPair(pair).token0() == wbdag ? r0 : r1;
    }

    function _zap(address token, uint256 amount, uint256 minTokensOut, uint256 deadline) internal returns (uint256 liquidity) {
        uint256 rB = bdagReserve(token);
        require(rB > 0, "empty pool");
        uint256 s = swapAmount(rB, amount);
        address[] memory path = new address[](2);
        path[0] = wbdag;
        path[1] = token;
        router.swapExactBDAGForTokens{value: s}(minTokensOut, path, address(this), deadline);
        uint256 tok = IZapERC20(token).balanceOf(address(this));
        (, , liquidity) = router.addLiquidityBDAG{value: amount - s}(token, tok, 0, 0, DEAD, deadline);
    }
}
