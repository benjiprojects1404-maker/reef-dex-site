// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title $REEF Token
/// @notice Fixed-supply ERC-20 for Reef DEX. The entire supply is minted once,
///         in the constructor, straight into the six allocation holders below.
///         There is no owner, no admin role, no mint function and no burn
///         function anywhere in this contract, so there is nothing to renounce
///         and nothing anyone can change after deployment.
///
///         Allocation (21,000,000 REEF):
///           Liquidity  45%   9,450,000
///           Treasury   25%   5,250,000
///           Presale     5%   1,050,000   (holder wallet funds the presale contract)
///           Dev        10%   2,100,000   (must be the deployed ReefVesting contract)
///           Airdrop    10%   2,100,000   (holder wallet funds the Merkle claim contract)
///           Marketing   5%   1,050,000
contract ReefToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 21_000_000 * 10 ** 18;

    uint256 private constant LIQUIDITY_AMOUNT = 9_450_000 * 10 ** 18;
    uint256 private constant TREASURY_AMOUNT  = 5_250_000 * 10 ** 18;
    uint256 private constant PRESALE_AMOUNT   = 1_050_000 * 10 ** 18;
    uint256 private constant DEV_AMOUNT       = 2_100_000 * 10 ** 18;
    uint256 private constant AIRDROP_AMOUNT   = 2_100_000 * 10 ** 18;
    uint256 private constant MARKETING_AMOUNT = 1_050_000 * 10 ** 18;

    /// @notice One event per bucket so the public allocation is readable from logs.
    event Allocated(string bucket, address indexed to, uint256 amount);

    /// @param liquidityWallet  Holds the pool-seeding allocation (later locked as LP).
    /// @param treasuryWallet   Holds the treasury allocation.
    /// @param presaleWallet    Temporary holder; sends the presale allocation to the presale contract.
    /// @param vestingContract  The deployed ReefVesting contract (checked to be a contract).
    /// @param airdropWallet    Temporary holder; sends the airdrop allocation to the claim contract.
    /// @param marketingWallet  Holds the marketing allocation.
    constructor(
        address liquidityWallet,
        address treasuryWallet,
        address presaleWallet,
        address vestingContract,
        address airdropWallet,
        address marketingWallet
    ) ERC20("Reef", "REEF") {
        require(liquidityWallet != address(0), "liquidity wallet is zero address");
        require(treasuryWallet != address(0), "treasury wallet is zero address");
        require(presaleWallet != address(0), "presale wallet is zero address");
        require(vestingContract != address(0), "vesting contract is zero address");
        require(airdropWallet != address(0), "airdrop wallet is zero address");
        require(marketingWallet != address(0), "marketing wallet is zero address");
        // Guards against sending the dev allocation to a plain wallet by mistake.
        require(vestingContract.code.length > 0, "vesting address is not a contract");

        require(
            LIQUIDITY_AMOUNT + TREASURY_AMOUNT + PRESALE_AMOUNT +
            DEV_AMOUNT + AIRDROP_AMOUNT + MARKETING_AMOUNT == TOTAL_SUPPLY,
            "allocations do not sum to total supply"
        );

        _mint(liquidityWallet, LIQUIDITY_AMOUNT);
        emit Allocated("liquidity", liquidityWallet, LIQUIDITY_AMOUNT);

        _mint(treasuryWallet, TREASURY_AMOUNT);
        emit Allocated("treasury", treasuryWallet, TREASURY_AMOUNT);

        _mint(presaleWallet, PRESALE_AMOUNT);
        emit Allocated("presale", presaleWallet, PRESALE_AMOUNT);

        _mint(vestingContract, DEV_AMOUNT);
        emit Allocated("dev", vestingContract, DEV_AMOUNT);

        _mint(airdropWallet, AIRDROP_AMOUNT);
        emit Allocated("airdrop", airdropWallet, AIRDROP_AMOUNT);

        _mint(marketingWallet, MARKETING_AMOUNT);
        emit Allocated("marketing", marketingWallet, MARKETING_AMOUNT);
    }
}
