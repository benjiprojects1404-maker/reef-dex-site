// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICurve {
    function buy(uint256, uint256) external payable returns (uint256);
    function sell(uint256, uint256, uint256) external returns (uint256);
    function token() external view returns (address);
}
interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Tries to re-enter sell() while receiving BDAG from a sell.
contract CookedReenter {
    ICurve public curve;
    bool private entered;
    constructor(address c) { curve = ICurve(c); }
    function attackBuy() external payable {
        curve.buy{value: msg.value}(0, block.timestamp + 1);
        IERC20Min(curve.token()).approve(address(curve), type(uint256).max);
    }
    function attackSell() external {
        uint256 b = IERC20Min(curve.token()).balanceOf(address(this));
        curve.sell(b / 2, 0, block.timestamp + 1);
    }
    receive() external payable {
        if (!entered && msg.sender == address(curve)) {
            entered = true;
            uint256 b = IERC20Min(curve.token()).balanceOf(address(this));
            curve.sell(b, 0, block.timestamp + 1);
        }
    }
}

/// A fee wallet that refuses BDAG.
contract CookedRejecter {
    receive() external payable { revert("no"); }
}
