// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// TESTING ONLY - not part of the deployed Reef contract set.
contract MockPresaleState {
    bool public finalized;

    function setFinalized(bool v) external {
        finalized = v;
    }
}
