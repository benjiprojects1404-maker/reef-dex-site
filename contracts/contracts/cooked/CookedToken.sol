// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CookedToken
/// @notice Fixed-supply ERC-20. The whole supply is minted once, to the launch
/// curve that deploys it. There is no owner, no mint, no tax and no blacklist.
///
/// One temporary rule: until the curve graduates, nobody except the curve can
/// send tokens to the Reef pool address. That stops anyone seeding the pool at
/// a fake price before launch. The curve lifts the rule, once and for good,
/// at the moment it adds the real liquidity.
contract CookedToken is ERC20 {
    address public immutable curve;
    address public pool;
    bool public poolOpen;

    error OnlyCurve();
    error PoolNotOpen();
    error PoolAlreadySet();

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        curve = msg.sender;
        _mint(msg.sender, supply);
    }

    /// Called once by the curve, right after it creates the Reef pair.
    function setPool(address pool_) external {
        if (msg.sender != curve) revert OnlyCurve();
        if (pool != address(0)) revert PoolAlreadySet();
        pool = pool_;
    }

    /// Called once by the curve at graduation. Cannot be undone.
    function openPool() external {
        if (msg.sender != curve) revert OnlyCurve();
        poolOpen = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!poolOpen && to == pool && pool != address(0) && from != curve) revert PoolNotOpen();
        super._update(from, to, value);
    }
}
