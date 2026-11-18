// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Standard Uniswap V2 router (as deployed on Base: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24).
interface IUniV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IUniV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @title KitchenToken
/// @notice A plain, fixed-supply ERC-20 made by The Kitchen. The whole supply is minted once, when the token is made.
///         No owner and no admin: nobody can mint more, charge a tax, pause transfers or block wallets.
contract KitchenToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_) {
        _mint(to, supply);
    }
}

/// @title KitchenServeUniV2 ("The Kitchen" on Base and other Uniswap V2 chains)
/// @notice Same recipe as The Kitchen on BlockDAG (KitchenServe.sol), pointed at a standard Uniswap V2 router:
///         makes a token AND its TOKEN/ETH Uniswap V2 pool in one transaction. Part of the supply plus the
///         creator's ETH go into the pool, the LP tokens are burned (sent to 0x…dEaD, so that liquidity can never
///         be pulled), and the rest of the supply goes to the creator.
/// @dev    msg.value = fee + liquidity. The admin can only change the fee (capped), the minimum liquidity (capped)
///         and where the fee goes, and hand admin over in two steps. The contract keeps no tokens and no ETH.
///         Uniswap V2 itself locks the pool's first 1,000 LP units at address(0); everything else goes to 0x…dEaD.
contract KitchenServeUniV2 is ReentrancyGuard {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_FEE = 1 ether;
    uint256 public constant MAX_MIN_LIQUIDITY = 100 ether;
    uint256 public constant MAX_WHOLE_SUPPLY = 1e15;
    uint256 public constant MIN_POOL_PERCENT = 10;
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 11;

    IUniV2Router public immutable router;
    address public immutable weth;
    address public immutable pairFactory;

    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    uint256 public fee;          // ETH (wei) per token
    uint256 public minLiquidity; // ETH (wei) the pool must start with

    address[] private _tokens;
    mapping(address => address[]) private _byCreator;
    mapping(address => bool) public isKitchenToken;
    mapping(address => address) public pairOf;
    mapping(bytes32 => bool) public reservedSymbol;

    event TokenServed(address indexed token, address indexed creator, address indexed pair, string name, string symbol,
        uint256 supply, uint256 poolTokens, uint256 poolETH);
    event FeeChanged(uint256 fee);
    event MinLiquidityChanged(uint256 minLiquidity);
    event FeeRecipientChanged(address feeRecipient);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminChanged(address indexed admin);

    error ZeroAddress();
    error NotEnoughETH();
    error FeeTooHigh();
    error MinTooHigh();
    error BadName();
    error BadSymbol();
    error ReservedSymbol();
    error BadSupply();
    error BadPoolShare();
    error NotAdmin();
    error TransferFailed();
    error NotRouter();

    constructor(address router_, address admin_, address feeRecipient_, uint256 fee_, uint256 minLiquidity_, string[] memory reserved) {
        if (router_ == address(0) || admin_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        if (minLiquidity_ > MAX_MIN_LIQUIDITY) revert MinTooHigh();
        router = IUniV2Router(router_);
        weth = IUniV2Router(router_).WETH();
        pairFactory = IUniV2Router(router_).factory();
        admin = admin_;
        feeRecipient = feeRecipient_;
        fee = fee_;
        minLiquidity = minLiquidity_;
        for (uint256 i; i < reserved.length; ++i) reservedSymbol[keccak256(_upper(bytes(reserved[i])))] = true;
        emit AdminChanged(admin_);
        emit FeeRecipientChanged(feeRecipient_);
        emit FeeChanged(fee_);
        emit MinLiquidityChanged(minLiquidity_);
    }

    // ------------------------------------------------------------------ cook and serve

    /// @notice Make a token and its Uniswap V2 pool. `wholeSupply` is in whole tokens (18 decimals added).
    ///         `poolPercent` (10-100) of the supply goes into the pool with all the ETH sent above the fee; the
    ///         rest of the supply comes to you. The pool's LP tokens are burned. Send fee + liquidity.
    function cook(string calldata name_, string calldata symbol_, uint256 wholeSupply, uint256 poolPercent)
        external payable nonReentrant returns (address token, address pair)
    {
        uint256 _fee = fee;
        if (msg.value < _fee || msg.value - _fee < minLiquidity || msg.value == _fee) revert NotEnoughETH();
        _checkName(bytes(name_));
        _checkSymbol(bytes(symbol_));
        if (wholeSupply == 0 || wholeSupply > MAX_WHOLE_SUPPLY) revert BadSupply();
        if (poolPercent < MIN_POOL_PERCENT || poolPercent > 100) revert BadPoolShare();

        uint256 liquidityETH = msg.value - _fee;
        uint256 supply = wholeSupply * 1e18;
        uint256 poolTokens = supply * poolPercent / 100;

        token = address(new KitchenToken(name_, symbol_, supply, address(this)));
        IERC20(token).approve(address(router), poolTokens);
        // Exact minimums: if anyone tampered with a pool for this token address beforehand, this reverts
        // instead of adding liquidity at a price the creator didn't choose.
        router.addLiquidityETH{value: liquidityETH}(token, poolTokens, poolTokens, liquidityETH, DEAD, block.timestamp);
        pair = IUniV2Factory(pairFactory).getPair(token, weth);

        _tokens.push(token);
        _byCreator[msg.sender].push(token);
        isKitchenToken[token] = true;
        pairOf[token] = pair;
        emit TokenServed(token, msg.sender, pair, name_, symbol_, supply, poolTokens, liquidityETH);

        uint256 rest = IERC20(token).balanceOf(address(this));
        if (rest > 0 && !IERC20(token).transfer(msg.sender, rest)) revert TransferFailed();
        if (_fee > 0) _send(feeRecipient, _fee);
        uint256 left = address(this).balance;
        if (left > 0) _send(msg.sender, left);
    }

    /// @dev Only the router may send ETH back (a refund of unused liquidity).
    receive() external payable {
        if (msg.sender != address(router)) revert NotRouter();
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

    // ------------------------------------------------------------------ admin (fee and minimum only)

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        fee = newFee;
        emit FeeChanged(newFee);
    }

    function setMinLiquidity(uint256 newMin) external onlyAdmin {
        if (newMin > MAX_MIN_LIQUIDITY) revert MinTooHigh();
        minLiquidity = newMin;
        emit MinLiquidityChanged(newMin);
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

    // ------------------------------------------------------------------ helpers

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev 1-32 bytes of UTF-8 with no control characters, and not blank at either end.
    function _checkName(bytes memory b) private pure {
        if (b.length == 0 || b.length > MAX_NAME_BYTES) revert BadName();
        if (b[0] == 0x20 || b[b.length - 1] == 0x20) revert BadName();
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 || c == 0x7f) revert BadName();
        }
    }

    /// @dev 1-11 characters, letters and digits only, so tickers can't hide look-alike characters.
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
