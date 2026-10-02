// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import "./interfaces/IReefFactory.sol";
import "./ReefPair.sol";

/// @title ReefFactory
/// @notice Permissionless registry/deployer for ReefPair pools. Anyone can call
/// createPair for any two ERC-20 tokens - there is no allowlist, no approval
/// step, and no way for feeToSetter to block a pair from being created.
/// feeToSetter can only ever do two things: point the protocol-fee cut (the
/// disclosed 0.05% of Reef's 0.30% swap fee) at a treasury address, or hand
/// that one power to someone else. It cannot pause pools, freeze funds, or
/// stop anyone from trading.
contract ReefFactory is IReefFactory {
    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, "Reef: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Reef: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Reef: PAIR_EXISTS"); // single check is sufficient

        bytes memory bytecode = type(ReefPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IReefPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "Reef: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "Reef: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
