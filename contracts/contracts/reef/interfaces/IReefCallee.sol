// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

// Implemented by any contract that wants to receive tokens mid-swap (flash swaps)
// before repaying the pair. Optional feature, inherited unmodified from the
// standard AMM pattern this codebase is forked from.
interface IReefCallee {
    function reefCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}
