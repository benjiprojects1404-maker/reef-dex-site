// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

// TESTING ONLY - not part of the deployed Reef contract set.
/// @dev ERC-20 with chosen decimals and an optional transfer fee (in basis points, burned).
contract MockLaunchToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint public totalSupply;
    uint public feeBps;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint initialSupply) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = initialSupply;
        balanceOf[msg.sender] = initialSupply;
        emit Transfer(address(0), msg.sender, initialSupply);
    }

    function setFeeBps(uint bps) external { feeBps = bps; }

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint amount) internal {
        balanceOf[from] -= amount;
        uint fee = (amount * feeBps) / 10000;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @dev Calls refund() and rejects any BDAG sent to it, to show one buyer can't block others.
contract RejectingBuyer {
    function buy(address sale) external payable {
        (bool ok, ) = sale.call{value: msg.value}(abi.encodeWithSignature("buy()"));
        require(ok, "buy failed");
    }
    function refund(address sale) external {
        (bool ok, ) = sale.call(abi.encodeWithSignature("refund()"));
        require(ok, "refund failed");
    }
}
