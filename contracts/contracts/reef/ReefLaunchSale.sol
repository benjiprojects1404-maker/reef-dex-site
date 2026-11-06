// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ILaunchRouterLike {
    function factory() external view returns (address);
    function WBDAG() external view returns (address);
}

interface ILaunchFactoryLike {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface ILaunchPairLike {
    function totalSupply() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
}

interface IWBDAGLike {
    function deposit() external payable;
}

/// @title Reef Launch Sale (launchpad presale, v2)
/// @notice One fixed-price token sale, paid in native BDAG on chain 1404, that seeds a locked
///         TOKEN/BDAG pool on Reef when it ends. It is the REEF presale contract that ran on
///         real funds on 6 Nov 2026, with the terms moved from constants into per-sale
///         settings, a disclosed launchpad fee, a soft cap, and a way to hand the project its
///         tokens back if the sale fails.
///
///         No owner, no admin function, no way to withdraw the raised BDAG. Every setting is
///         fixed in the constructor and readable on-chain.
///
///         How a sale runs:
///           1. The project sends tokensRequired() of its token to this contract. buy()
///              refuses BDAG until it is fully funded, so the pool and every claim are covered
///              before anyone pays.
///           2. Buyers call buy() with BDAG between startTime and endTime. They get nothing yet.
///           3. When the sale ends or reaches the hard cap, ANYONE can call finalize(), as long
///              as the soft cap was reached. It sends feeBps of the raise to feeRecipient (as
///              WBDAG, so a recipient can never block it), pairs ALL the rest with tokens at
///              listingPrice, burns every token not owed to a buyer, and keeps the LP tokens.
///           4. Buyers call claim() for their tokens.
///           5. LP stays here until lpUnlockTime (counted from finalize), then withdrawLP()
///              sends it to lpBeneficiary.
///
///         If the sale fails, buyers get all their BDAG back with refund():
///           - soft cap not reached: refunds open as soon as the sale ends;
///           - soft cap reached but not finalized within REFUND_DELAY: refunds open then.
///         Once refunds open, the first refund (or returnTokens()) disables finalize() for good,
///         and returnTokens() sends the project's tokens back to projectWallet.
///
///         Prices are in BDAG wei per ONE whole token (10**decimals units), so any token
///         decimals and fractional prices work. Fee-on-transfer tokens are refused at finalize.
///
///         Not independently audited. Configuration is plain storage rather than `immutable`
///         so simple explorer verifiers can match the bytecode.
contract ReefLaunchSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BPS = 300; // the launchpad fee can never be set above 3%
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_LP_LOCK = 180 days;
    uint256 public constant REFUND_DELAY = 7 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Config {
        address token; // the token being sold (standard ERC-20, no transfer fee)
        address router; // Reef's router
        address projectWallet; // gets the tokens back if the sale fails
        address lpBeneficiary; // gets the LP after the lock
        address feeRecipient; // Reef's treasury
        uint256 feeBps; // launchpad fee in basis points (200 = 2%), at most MAX_FEE_BPS
        uint256 salePrice; // BDAG wei per whole token in the sale
        uint256 listingPrice; // BDAG wei per whole token when the pool opens (>= salePrice)
        uint256 softCap; // BDAG wei; below this the sale refunds
        uint256 hardCap; // BDAG wei; the most the sale takes
        uint256 maxPerWallet; // BDAG wei per wallet
        uint256 startTime;
        uint256 endTime;
        uint256 lpLockSeconds; // at least MIN_LP_LOCK
    }

    // ---- configuration (set once in the constructor, never changed) ----
    IERC20 public token;
    ILaunchRouterLike public router;
    address public projectWallet;
    address public lpBeneficiary;
    address public feeRecipient;
    uint256 public feeBps;
    uint256 public salePrice;
    uint256 public listingPrice;
    uint256 public softCap;
    uint256 public hardCap;
    uint256 public maxPerWallet;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public lpLockSeconds;
    uint256 public unit; // 10 ** token decimals

    // ---- state ----
    uint256 public totalRaised;
    mapping(address => uint256) public contributed;
    mapping(address => bool) public settled; // claimed or refunded
    bool public finalized;
    bool public refunding;
    bool public tokensReturned;
    address public lpToken;
    uint256 public lpUnlockTime;

    event Purchased(address indexed buyer, uint256 amountBDAG, uint256 totalRaised);
    event Finalized(uint256 raised, uint256 fee, uint256 bdagPaired, uint256 tokensPaired, uint256 tokensBurned, uint256 lpTokens, address lpToken);
    event Claimed(address indexed buyer, uint256 tokenAmount);
    event Refunded(address indexed buyer, uint256 amountBDAG);
    event TokensReturned(address indexed to, uint256 amount);
    event LPWithdrawn(uint256 amount, address to);

    constructor(Config memory c) {
        require(c.token != address(0), "token is zero address");
        require(c.router != address(0), "router is zero address");
        require(c.projectWallet != address(0), "project wallet is zero address");
        require(c.lpBeneficiary != address(0), "LP beneficiary is zero address");
        require(c.feeRecipient != address(0), "fee recipient is zero address");
        require(c.feeBps <= MAX_FEE_BPS, "fee above 3%");
        require(c.salePrice > 0, "sale price is zero");
        require(c.listingPrice >= c.salePrice, "listing price below sale price");
        require(c.hardCap > 0 && c.softCap <= c.hardCap, "bad caps");
        require(c.maxPerWallet > 0, "per-wallet cap is zero");
        require(c.startTime >= block.timestamp, "start time is in the past");
        require(c.endTime > c.startTime, "end must be after start");
        require(c.lpLockSeconds >= MIN_LP_LOCK, "LP lock must be at least 180 days");

        token = IERC20(c.token);
        router = ILaunchRouterLike(c.router);
        projectWallet = c.projectWallet;
        lpBeneficiary = c.lpBeneficiary;
        feeRecipient = c.feeRecipient;
        feeBps = c.feeBps;
        salePrice = c.salePrice;
        listingPrice = c.listingPrice;
        softCap = c.softCap;
        hardCap = c.hardCap;
        maxPerWallet = c.maxPerWallet;
        startTime = c.startTime;
        endTime = c.endTime;
        lpLockSeconds = c.lpLockSeconds;
        unit = 10 ** uint256(IERC20Metadata(c.token).decimals());

        require(tokensFor(c.hardCap) > 0 && tokensForPool(c.hardCap) > 0, "price too high for the cap");
    }

    // ------------------------------------------------------------------ maths

    /// @notice Tokens a contribution of `bdag` buys at the sale price.
    function tokensFor(uint256 bdag) public view returns (uint256) {
        return (bdag * unit) / salePrice;
    }

    /// @notice The launchpad fee on a raise of `raised`.
    function feeOn(uint256 raised) public view returns (uint256) {
        return (raised * feeBps) / BPS;
    }

    /// @notice Tokens paired with the rest of a raise of `raised` at the listing price.
    function tokensForPool(uint256 raised) public view returns (uint256) {
        return ((raised - feeOn(raised)) * unit) / listingPrice;
    }

    /// @notice Tokens the project must send before the sale can take BDAG: every claim plus
    ///         the pool, both at the hard cap. Whatever isn't needed is burned at finalize.
    function tokensRequired() public view returns (uint256) {
        return tokensFor(hardCap) + tokensForPool(hardCap);
    }

    // ------------------------------------------------------------------ buying

    function buy() external payable {
        require(block.timestamp >= startTime, "sale not started");
        require(block.timestamp <= endTime && !finalized, "sale ended");
        require(msg.value > 0, "send some BDAG");
        require(token.balanceOf(address(this)) >= tokensRequired(), "sale not funded");

        uint256 newTotal = totalRaised + msg.value;
        require(newTotal <= hardCap, "exceeds hard cap");
        uint256 newContribution = contributed[msg.sender] + msg.value;
        require(newContribution <= maxPerWallet, "exceeds per-wallet cap");

        totalRaised = newTotal;
        contributed[msg.sender] = newContribution;
        emit Purchased(msg.sender, msg.value, newTotal);
    }

    // --------------------------------------------------------------- finalizing

    function finalize() external nonReentrant {
        require(!finalized, "already finalized");
        require(!refunding, "refunds have started");
        require(block.timestamp > endTime || totalRaised == hardCap, "sale still running");
        require(totalRaised > 0 && totalRaised >= softCap, "soft cap not reached");

        finalized = true;

        uint256 raised = totalRaised;
        uint256 fee = feeOn(raised);
        uint256 bdagForPool = raised - fee;
        uint256 forPool = tokensForPool(raised);
        require(forPool > 0, "raise too small to pair");

        // Same pool-seeding as the REEF presale: mint directly so dust in the pair can't
        // block the launch, and refuse a pair someone has already given liquidity or loaded
        // with more than 1% of the launch tokens.
        address wbdag = router.WBDAG();
        ILaunchFactoryLike factory = ILaunchFactoryLike(router.factory());
        address pair = factory.getPair(address(token), wbdag);
        if (pair == address(0)) pair = factory.createPair(address(token), wbdag);
        require(ILaunchPairLike(pair).totalSupply() == 0, "pool already has liquidity");
        uint256 before = token.balanceOf(pair);
        require(before <= forPool / 100, "pool pre-loaded with tokens");

        IWBDAGLike(wbdag).deposit{value: raised}();
        if (fee > 0) IERC20(wbdag).safeTransfer(feeRecipient, fee);
        IERC20(wbdag).safeTransfer(pair, bdagForPool);
        token.safeTransfer(pair, forPool);
        require(token.balanceOf(pair) - before == forPool, "token takes a fee on transfer");
        uint256 liquidity = ILaunchPairLike(pair).mint(address(this));

        // Everything left except what buyers are owed goes to the dead address.
        uint256 owed = tokensFor(raised);
        uint256 burn = token.balanceOf(address(this)) - owed;
        if (burn > 0) token.safeTransfer(DEAD, burn);

        lpToken = pair;
        lpUnlockTime = block.timestamp + lpLockSeconds;
        emit Finalized(raised, fee, bdagForPool, forPool, burn, liquidity, pair);
    }

    // ---------------------------------------------------------------- claiming

    function claim() external nonReentrant {
        require(finalized, "not finalized yet");
        require(!settled[msg.sender], "already settled");
        uint256 owed = tokensFor(contributed[msg.sender]);
        require(owed > 0, "nothing to claim");
        settled[msg.sender] = true;
        token.safeTransfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
    }

    // ----------------------------------------------------------------- refunds

    /// @notice True once buyers can take their BDAG back: the sale ended under the soft cap,
    ///         or it was not finalized within REFUND_DELAY of the end.
    function refundsOpen() public view returns (bool) {
        if (finalized) return false;
        if (refunding) return true;
        if (totalRaised < softCap || totalRaised == 0) return block.timestamp > endTime;
        return block.timestamp > endTime + REFUND_DELAY;
    }

    function refund() external nonReentrant {
        require(refundsOpen(), "refunds not open");
        require(!settled[msg.sender], "already settled");
        uint256 amount = contributed[msg.sender];
        require(amount > 0, "nothing to refund");

        refunding = true;
        settled[msg.sender] = true;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund transfer failed");
        emit Refunded(msg.sender, amount);
    }

    /// @notice Once refunds are open, send the project's tokens back to projectWallet.
    ///         Anyone can call it. It disables finalize() for good, like the first refund.
    function returnTokens() external nonReentrant {
        require(refundsOpen(), "refunds not open");
        require(!tokensReturned, "already returned");
        refunding = true;
        tokensReturned = true;
        uint256 amount = token.balanceOf(address(this));
        if (amount > 0) token.safeTransfer(projectWallet, amount);
        emit TokensReturned(projectWallet, amount);
    }

    // ----------------------------------------------------------------- LP lock

    function withdrawLP() external nonReentrant {
        require(finalized, "not finalized yet");
        require(block.timestamp >= lpUnlockTime, "LP still locked");
        uint256 amount = IERC20(lpToken).balanceOf(address(this));
        require(amount > 0, "no LP to withdraw");
        IERC20(lpToken).safeTransfer(lpBeneficiary, amount);
        emit LPWithdrawn(amount, lpBeneficiary);
    }

    // ------------------------------------------------------------------- views

    function remainingCapacity() external view returns (uint256) {
        return hardCap - totalRaised;
    }

    function claimable(address buyer) external view returns (uint256) {
        if (settled[buyer] || refunding) return 0;
        return tokensFor(contributed[buyer]);
    }

    function lpTimeRemaining() external view returns (uint256) {
        if (!finalized || block.timestamp >= lpUnlockTime) return 0;
        return lpUnlockTime - block.timestamp;
    }

    /// @notice Every sale term in one call, for the sale page.
    function terms() external view returns (Config memory c) {
        c = Config(address(token), address(router), projectWallet, lpBeneficiary, feeRecipient, feeBps,
            salePrice, listingPrice, softCap, hardCap, maxPerWallet, startTime, endTime, lpLockSeconds);
    }
}
