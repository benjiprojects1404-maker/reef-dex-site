// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

// TESTING ONLY - not part of the deployed Reef contract set.

interface ILockerLike {
    function withdraw(uint256 id) external;
    function lock(address token, uint256 amount, uint64 unlockTime, address owner_) external payable returns (uint256);
}

/// @dev Burns 1% of every transfer (a "tax" token), to check the locker credits what actually arrives.
contract MockFeeToken {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { totalSupply += amount; balanceOf[to] += amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }
    function _move(address f, address to, uint256 a) internal {
        uint256 cut = a / 100;
        balanceOf[f] -= a;
        balanceOf[to] += a - cut;
        totalSupply -= cut;
    }
}

/// @dev A token whose transfer() calls back into the locker, to check withdraw() can't be re-entered.
contract MockReentrantToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public locker;
    uint256 public targetId;
    bool public armed;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function arm(address locker_, uint256 id) external { locker = locker_; targetId = id; armed = true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (armed) { armed = false; ILockerLike(locker).withdraw(targetId); }
        return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Refuses BDAG, to check a failing fee recipient makes lock() revert instead of keeping the fee.
contract MockRejectBDAG {
    receive() external payable { revert("no"); }
}
