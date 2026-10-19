// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title $NOCAP Token
/// @notice Fixed-supply ERC-20. No mint function exists anywhere in this
///         contract — total supply is set once in the constructor and can
///         never increase. This is intentional: it is the on-chain proof
///         behind the "no cap" brand promise.
///
///         Ownable is used only to perform the initial distribution
///         (liquidity, vesting contract, marketing wallet) at deploy time.
///         Call renounceOwnership() once distribution is complete — after
///         that, there is no privileged account left that can do anything
///         to this contract.
contract NoCapToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18; // 1,000,000,000 $NOCAP

    /// @param liquidityWallet   Receives the public-liquidity allocation (92%)
    /// @param vestingContract   Receives the dev allocation (5%) — must be the
    ///                          address of the deployed NoCapVesting contract
    /// @param marketingWallet   Receives the marketing/community allocation (3%)
    constructor(
        address liquidityWallet,
        address vestingContract,
        address marketingWallet
    ) ERC20("NoCap", "NOCAP") Ownable(msg.sender) {
        require(liquidityWallet != address(0), "liquidity wallet is zero address");
        require(vestingContract != address(0), "vesting contract is zero address");
        require(marketingWallet != address(0), "marketing wallet is zero address");

        uint256 liquidityAmount = (TOTAL_SUPPLY * 92) / 100;
        uint256 devAmount       = (TOTAL_SUPPLY * 5) / 100;
        uint256 marketingAmount = TOTAL_SUPPLY - liquidityAmount - devAmount; // remainder = 3%

        _mint(liquidityWallet, liquidityAmount);
        _mint(vestingContract, devAmount);
        _mint(marketingWallet, marketingAmount);

        // No further _mint calls exist anywhere in this contract.
        // Total supply is fixed forever at this point.
    }
}
