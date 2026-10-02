// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import "./IERC20.sol";

interface IWBDAG is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
}
