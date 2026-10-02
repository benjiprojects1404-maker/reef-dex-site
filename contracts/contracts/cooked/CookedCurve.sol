// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CookedToken} from "./CookedToken.sol";

interface IReefFactoryLike {
    function createPair(address a, address b) external returns (address);
}

interface IReefPairLike {
    function mint(address to) external returns (uint256);
}

interface IWBDAGLike {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title CookedCurve
/// @notice Fair launch on a bonding curve, then a permanent Reef pool.
///
/// - Deploys the token and holds the whole supply. No presale, no team share.
/// - Sells CURVE_SUPPLY (80%) along a constant-product curve with virtual
///   reserves. Price rises as people buy and falls as they sell.
/// - When the curve sells out, anyone can call graduate(): the BDAG raised and
///   the remaining 20% go into a Reef pool at the curve's final price, and the
///   LP tokens are sent to 0xdead, so the liquidity can never be withdrawn.
/// - No owner and no admin functions. Every number is fixed at deployment.
contract CookedCurve is ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant POOL_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;
    uint256 public constant MAX_FEE_BPS = 100; // 1% hard cap
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    CookedToken public immutable token;
    address public immutable pair;
    address public immutable wbdag;
    address public immutable feeRecipient;
    uint256 public immutable feeBps;
    uint256 public immutable targetRaise;   // BDAG that sells the whole curve
    uint256 public immutable virtualBdag;   // V0
    uint256 public immutable virtualTokens; // T0
    uint256 public immutable startTime;

    uint256 public tokensSold;   // out of CURVE_SUPPLY
    uint256 public bdagRaised;   // real BDAG held for the pool, fees excluded
    bool public complete;        // curve sold out, trading paused until graduation
    bool public graduated;       // pool created, LP burned
    uint256 public feesOwed;     // trading fees waiting to be claimed to feeRecipient

    event Buy(address indexed buyer, uint256 bdagIn, uint256 fee, uint256 tokensOut, uint256 refund);
    event Sell(address indexed seller, uint256 tokensIn, uint256 bdagOut, uint256 fee);
    event Complete(uint256 bdagRaised);
    event Graduated(address indexed pair, uint256 bdag, uint256 tokens, uint256 liquidity);

    error NotStarted();
    error Closed();
    error NotComplete();
    error AlreadyGraduated();
    error Slippage();
    error Expired();
    error ZeroAmount();
    error BadConfig();
    error TransferFailed();

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_,
        address wbdag_,
        address feeRecipient_,
        uint256 feeBps_,
        uint256 targetRaise_,
        uint256 startTime_
    ) {
        if (feeBps_ > MAX_FEE_BPS || targetRaise_ == 0 || feeRecipient_ == address(0)) revert BadConfig();
        wbdag = wbdag_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        targetRaise = targetRaise_;
        startTime = startTime_;

        // Virtual reserves chosen so that selling exactly CURVE_SUPPLY raises
        // targetRaise, and the final curve price equals targetRaise / POOL_SUPPLY,
        // i.e. the pool opens at the same price the curve ended on.
        uint256 v0 = (POOL_SUPPLY * targetRaise_) / (CURVE_SUPPLY - POOL_SUPPLY);
        virtualBdag = v0;
        virtualTokens = CURVE_SUPPLY + (POOL_SUPPLY * (v0 + targetRaise_)) / targetRaise_;

        CookedToken t = new CookedToken(name_, symbol_, TOTAL_SUPPLY);
        token = t;
        address p = IReefFactoryLike(factory_).createPair(address(t), wbdag_);
        pair = p;
        t.setPool(p);
    }

    // ---- views -------------------------------------------------------------

    function reserves() public view returns (uint256 v, uint256 t) {
        v = virtualBdag + bdagRaised;
        t = virtualTokens - tokensSold;
    }

    /// Price of one whole token in BDAG wei, scaled by 1e18.
    function spotPrice() external view returns (uint256) {
        (uint256 v, uint256 t) = reserves();
        return (v * 1e18) / t;
    }

    /// Tokens out for a buy of `bdagIn` (fee included), plus any refund.
    function quoteBuy(uint256 bdagIn) public view returns (uint256 tokensOut, uint256 fee, uint256 refund) {
        uint256 net;
        (net, fee) = _splitFee(bdagIn);
        (uint256 v, uint256 t) = reserves();
        tokensOut = (t * net) / (v + net);
        uint256 left = CURVE_SUPPLY - tokensSold;
        if (tokensOut >= left) {
            tokensOut = left;
            uint256 netNeeded = _ceilDiv(v * left, t - left);
            uint256 gross = _ceilDiv(netNeeded * 10_000, 10_000 - feeBps);
            if (gross > bdagIn) gross = bdagIn; // rounding guard
            fee = gross - netNeeded;
            refund = bdagIn - gross;
        }
    }

    /// BDAG paid out (after fee) for selling `tokensIn`.
    function quoteSell(uint256 tokensIn) public view returns (uint256 bdagOut, uint256 fee) {
        (uint256 v, uint256 t) = reserves();
        uint256 gross = (v * tokensIn) / (t + tokensIn);
        if (gross > bdagRaised) gross = bdagRaised;
        fee = (gross * feeBps) / 10_000;
        bdagOut = gross - fee;
    }

    // ---- trading -----------------------------------------------------------

    function buy(uint256 minTokensOut, uint256 deadline) external payable nonReentrant returns (uint256 tokensOut) {
        _open(deadline);
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee;
        uint256 refund;
        (tokensOut, fee, refund) = quoteBuy(msg.value);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert Slippage();

        uint256 net = msg.value - fee - refund;
        tokensSold += tokensOut;
        bdagRaised += net;

        if (tokensSold == CURVE_SUPPLY) {
            complete = true;
            emit Complete(bdagRaised);
        }

        feesOwed += fee;
        token.transfer(msg.sender, tokensOut);
        _send(msg.sender, refund);
        emit Buy(msg.sender, msg.value, fee, tokensOut, refund);
    }

    function sell(uint256 tokensIn, uint256 minBdagOut, uint256 deadline) external nonReentrant returns (uint256 bdagOut) {
        _open(deadline);
        if (tokensIn == 0) revert ZeroAmount();
        uint256 fee;
        (bdagOut, fee) = quoteSell(tokensIn);
        if (bdagOut == 0 || bdagOut < minBdagOut) revert Slippage();

        token.transferFrom(msg.sender, address(this), tokensIn);
        tokensSold -= tokensIn;
        bdagRaised -= (bdagOut + fee);

        feesOwed += fee;
        _send(msg.sender, bdagOut);
        emit Sell(msg.sender, tokensIn, bdagOut, fee);
    }

    /// Anyone can call once the curve has sold out.
    function graduate() external nonReentrant {
        if (!complete) revert NotComplete();
        if (graduated) revert AlreadyGraduated();
        graduated = true;

        uint256 bdag = bdagRaised;
        uint256 tokens = token.balanceOf(address(this)); // POOL_SUPPLY, plus any tokens sent here by mistake

        token.openPool();
        IWBDAGLike(wbdag).deposit{value: bdag}();
        if (!IWBDAGLike(wbdag).transfer(pair, bdag)) revert TransferFailed();
        token.transfer(pair, tokens);
        // Minting straight on the pair (not via the router) means a stray
        // WBDAG donation to the pair can't block this; it just joins the pool.
        uint256 liquidity = IReefPairLike(pair).mint(DEAD);

        emit Graduated(pair, bdag, tokens, liquidity);
    }

    /// Sends accrued fees to the fixed fee recipient. Anyone can call it.
    /// Fees are pulled, not pushed, so a fee wallet that can't receive BDAG
    /// can never block trading.
    function claimFees() external nonReentrant {
        uint256 amount = feesOwed;
        feesOwed = 0;
        _send(feeRecipient, amount);
    }

    // ---- internals ---------------------------------------------------------

    function _open(uint256 deadline) private view {
        if (block.timestamp < startTime) revert NotStarted();
        if (block.timestamp > deadline) revert Expired();
        if (complete) revert Closed();
    }

    function _splitFee(uint256 amount) private view returns (uint256 net, uint256 fee) {
        fee = (amount * feeBps) / 10_000;
        net = amount - fee;
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
