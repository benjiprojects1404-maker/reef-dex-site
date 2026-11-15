// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title KitchenToken
/// @notice A plain, fixed-supply ERC-20 made by The Kitchen. The whole supply is minted once, to the creator,
///         when the token is made. There is no owner and no admin: nobody can mint more, charge a tax, pause
///         transfers or block wallets. What you see at creation is what it will always be.
contract KitchenToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address creator) ERC20(name_, symbol_) {
        _mint(creator, supply);
    }
}

/// @title KitchenFactory ("The Kitchen")
/// @notice No-code token maker for BlockDAG. Anyone can make a KitchenToken for a flat BDAG fee; every token
///         made here is recorded on-chain so sites (and Reef's safety report) can tell it's a plain Kitchen token.
/// @dev    The admin can only change the fee (capped forever at MAX_FEE) and where it goes, and hand the admin
///         role over in two steps. The factory never holds tokens or BDAG: the fee is forwarded in the same
///         transaction. Tickers of well-known tokens are reserved so the Kitchen can't be used to copy them.
contract KitchenFactory {
    uint256 public constant MAX_FEE = 50_000 ether;          // ceiling on the creation fee, in BDAG (fixed forever)
    uint256 public constant MAX_WHOLE_SUPPLY = 1e15;         // 1 quadrillion whole tokens
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 11;

    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    uint256 public fee; // BDAG (wei) per token made

    address[] private _tokens;
    mapping(address => address[]) private _byCreator;
    mapping(address => bool) public isKitchenToken;
    mapping(bytes32 => bool) public reservedSymbol; // keccak256 of the upper-cased ticker

    event TokenCooked(address indexed token, address indexed creator, string name, string symbol, uint256 supply);
    event FeeChanged(uint256 fee);
    event FeeRecipientChanged(address feeRecipient);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminChanged(address indexed admin);

    error ZeroAddress();
    error WrongFee();
    error FeeTooHigh();
    error BadName();
    error BadSymbol();
    error ReservedSymbol();
    error BadSupply();
    error NotAdmin();
    error FeeTransferFailed();

    constructor(address admin_, address feeRecipient_, uint256 fee_, string[] memory reserved) {
        if (admin_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        admin = admin_;
        feeRecipient = feeRecipient_;
        fee = fee_;
        for (uint256 i; i < reserved.length; ++i) reservedSymbol[keccak256(_upper(bytes(reserved[i])))] = true;
        emit AdminChanged(admin_);
        emit FeeRecipientChanged(feeRecipient_);
        emit FeeChanged(fee_);
    }

    // ------------------------------------------------------------------ making tokens

    /// @notice Make a token. `wholeSupply` is in whole tokens (18 decimals are added); all of it goes to you.
    ///         Send exactly `fee` BDAG.
    function cook(string calldata name_, string calldata symbol_, uint256 wholeSupply) external payable returns (address token) {
        if (msg.value != fee) revert WrongFee();
        _checkName(bytes(name_));
        _checkSymbol(bytes(symbol_));
        if (wholeSupply == 0 || wholeSupply > MAX_WHOLE_SUPPLY) revert BadSupply();

        token = address(new KitchenToken(name_, symbol_, wholeSupply * 1e18, msg.sender));
        _tokens.push(token);
        _byCreator[msg.sender].push(token);
        isKitchenToken[token] = true;
        emit TokenCooked(token, msg.sender, name_, symbol_, wholeSupply * 1e18);

        if (msg.value > 0) {
            (bool ok, ) = feeRecipient.call{value: msg.value}("");
            if (!ok) revert FeeTransferFailed();
        }
    }

    // ------------------------------------------------------------------ views

    function tokenCount() external view returns (uint256) { return _tokens.length; }

    function tokenAt(uint256 i) external view returns (address) { return _tokens[i]; }

    /// @notice Up to `count` tokens, newest first, skipping the `skip` newest.
    function latest(uint256 skip, uint256 count) external view returns (address[] memory out) {
        uint256 n = _tokens.length;
        if (skip >= n) return new address[](0);
        uint256 k = n - skip < count ? n - skip : count;
        out = new address[](k);
        for (uint256 i; i < k; ++i) out[i] = _tokens[n - 1 - skip - i];
    }

    function tokensByCreator(address creator) external view returns (address[] memory) { return _byCreator[creator]; }

    function isReserved(string calldata symbol_) external view returns (bool) {
        return reservedSymbol[keccak256(_upper(bytes(symbol_)))];
    }

    // ------------------------------------------------------------------ admin (fee only)

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        fee = newFee;
        emit FeeChanged(newFee);
    }

    function setFeeRecipient(address newRecipient) external onlyAdmin {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientChanged(newRecipient);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminChanged(admin);
    }

    // ------------------------------------------------------------------ checks

    /// @dev 1-32 bytes of UTF-8 with no control characters, and not blank at either end.
    function _checkName(bytes memory b) private pure {
        if (b.length == 0 || b.length > MAX_NAME_BYTES) revert BadName();
        if (b[0] == 0x20 || b[b.length - 1] == 0x20) revert BadName();
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 || c == 0x7f) revert BadName();
        }
    }

    /// @dev 1-11 characters, letters and digits only (A-Z, a-z, 0-9), so tickers can't hide look-alike characters.
    function _checkSymbol(bytes memory b) private view {
        if (b.length == 0 || b.length > MAX_SYMBOL_BYTES) revert BadSymbol();
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            bool ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
            if (!ok) revert BadSymbol();
        }
        if (reservedSymbol[keccak256(_upper(b))]) revert ReservedSymbol();
    }

    function _upper(bytes memory b) private pure returns (bytes memory out) {
        out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            out[i] = (c >= 0x61 && c <= 0x7a) ? bytes1(c - 32) : b[i];
        }
    }
}
