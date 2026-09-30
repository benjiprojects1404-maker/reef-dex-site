// Sources flattened with hardhat v2.29.1 https://hardhat.org

// SPDX-License-Identifier: MIT

// File contracts/interfaces/IERC20.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity =0.8.24;

interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}


// File contracts/interfaces/IWBDAG.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity =0.8.24;

interface IWBDAG is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
}


// File contracts/WBDAG.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity =0.8.24;

/// @title WBDAG
/// @notice Wrapped BDAG. 1:1 backed, deposit native BDAG in / get WBDAG out,
/// and back again. Same pattern as WETH9 - lets native BDAG be traded through
/// Reef's ERC-20-only pools.
contract WBDAG is IWBDAG {
    string public constant name = "Wrapped BDAG";
    string public constant symbol = "WBDAG";
    uint8 public constant decimals = 18;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    // Approval/Transfer events come from IERC20 (via IWBDAG) - not redeclared here
    event Deposit(address indexed from, uint value);
    event Withdrawal(address indexed to, uint value);

    receive() external payable {
        deposit();
    }

    function deposit() public payable override {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint amount) external override {
        require(balanceOf[msg.sender] >= amount, "WBDAG: INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] -= amount;
        (bool success, ) = msg.sender.call{value: amount}(new bytes(0));
        require(success, "WBDAG: TRANSFER_FAILED");
        emit Withdrawal(msg.sender, amount);
    }

    function totalSupply() external view override returns (uint) {
        return address(this).balance;
    }

    function approve(address spender, uint amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint amount) external override returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint amount) public override returns (bool) {
        require(balanceOf[from] >= amount, "WBDAG: INSUFFICIENT_BALANCE");

        if (from != msg.sender) {
            uint allowed = allowance[from][msg.sender];
            if (allowed != type(uint).max) {
                require(allowed >= amount, "WBDAG: INSUFFICIENT_ALLOWANCE");
                allowance[from][msg.sender] = allowed - amount;
            }
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
