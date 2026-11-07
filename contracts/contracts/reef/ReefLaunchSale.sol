// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

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
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
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
///           1. The project sends tokensRequired() of its token, and its bond (bondAmount of
///              REEF), to this contract. buy() refuses BDAG until both are in, so the pool and
///              every claim are covered before anyone pays.
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
///         The project bond is burned only if buyers reached the soft cap but the pool never
///         opened (they had to take refunds). Otherwise it goes back to projectWallet: when
///         the LP lock ends after a launch, or when refunds open if the soft cap was missed.
///         See bondOutcome() and settleBond().
///
///         REEF routing pool (optional, reefSliceBps of the pooled BDAG, 20% for Reef launches):
///         at finalize that share of the BDAG buys REEF from the REEF/BDAG pool and is paired
///         with the token in a TOKEN/REEF pool at the same listing price; both LPs are locked.
///         It only runs when it is safe, and is SKIPPED (never blocks the launch) when:
///         there was no REEF/BDAG pool when this sale was deployed, the REEF/BDAG pool holds
///         less than minReefDepth BDAG, less than a day has passed since deployment, the REEF
///         price is more than 5% away from its average since deployment (someone pushed it),
///         or the TOKEN/REEF pool already has liquidity. Skipped means the whole pooled BDAG
///         goes to TOKEN/BDAG, as without the slice.
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
    uint256 public constant MAX_REEF_SLICE_BPS = 5_000; // at most half the pooled BDAG
    uint256 public constant MAX_SLICE_SLIPPAGE_BPS = 500; // REEF bought within 5% of its average price
    uint256 public constant MIN_AVERAGE_WINDOW = 1 days;
    uint256 public constant MIN_POOL_LIQUIDITY = 1_000; // Reef pools lock the first 1,000 LP units for good

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
        address bondToken; // REEF; the project's bond is held in this token
        uint256 bondAmount; // e.g. 1,000 REEF; 0 = no bond
        address reefToken; // REEF, for the TOKEN/REEF routing pool
        uint256 reefSliceBps; // share of the pooled BDAG for TOKEN/REEF (2000 = 20%); 0 = off
        uint256 minReefDepth; // BDAG wei the REEF/BDAG pool must hold for the slice to run
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
    IERC20 public bondToken;
    uint256 public bondAmount;
    IERC20 public reefToken;
    uint256 public reefSliceBps;
    uint256 public minReefDepth;
    address public reefPair; // REEF/WBDAG pool, recorded at deployment (zero = no slice)
    bool public reefIs0;
    uint256 public reefCumStart; // REEF price accumulator at deployment
    uint256 public reefObsTime;

    // ---- state ----
    uint256 public totalRaised;
    mapping(address => uint256) public contributed;
    mapping(address => bool) public settled; // claimed or refunded
    bool public finalized;
    bool public refunding;
    bool public tokensReturned;
    bool public bondSettled;
    address public lpToken;
    address public reefLpToken; // TOKEN/REEF pool, if the slice ran
    uint256 public lpUnlockTime;

    event Purchased(address indexed buyer, uint256 amountBDAG, uint256 totalRaised);
    event Finalized(uint256 raised, uint256 fee, uint256 bdagPaired, uint256 tokensPaired, uint256 tokensBurned, uint256 lpTokens, address lpToken);
    event Claimed(address indexed buyer, uint256 tokenAmount);
    event Refunded(address indexed buyer, uint256 amountBDAG);
    event TokensReturned(address indexed to, uint256 amount);
    event LPWithdrawn(uint256 amount, address to);
    event BondReturned(address indexed to, uint256 amount);
    event BondBurned(uint256 amount);
    event ReefSlice(uint256 bdagIn, uint256 reefBought, uint256 tokensPaired, uint256 lpTokens, address pool);
    /// reason: 1 off or no REEF pool at deployment, 2 slice too small or too small to open a pool, 3 under a day since deployment,
    ///         4 REEF pool under minReefDepth, 5 REEF price more than 5% from its average, 6 TOKEN/REEF pool already seeded
    event ReefSliceSkipped(uint8 reason);

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
        require(c.softCap > 0, "soft cap is zero");
        require(c.maxPerWallet > 0, "per-wallet cap is zero");
        require(c.startTime >= block.timestamp, "start time is in the past");
        require(c.endTime > c.startTime, "end must be after start");
        require(c.lpLockSeconds >= MIN_LP_LOCK, "LP lock must be at least 180 days");
        if (c.bondAmount > 0) {
            require(c.bondToken != address(0), "bond token is zero address");
            require(c.bondToken != c.token, "bond token is the sale token");
        }

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
        bondToken = IERC20(c.bondToken);
        bondAmount = c.bondAmount;

        if (c.reefSliceBps > 0) {
            require(c.reefSliceBps <= MAX_REEF_SLICE_BPS, "REEF slice above 50%");
            require(c.reefToken != address(0) && c.reefToken != c.token, "bad REEF token");
            reefToken = IERC20(c.reefToken);
            reefSliceBps = c.reefSliceBps;
            minReefDepth = c.minReefDepth;
            address pool = ILaunchFactoryLike(ILaunchRouterLike(c.router).factory()).getPair(c.reefToken, ILaunchRouterLike(c.router).WBDAG());
            if (pool != address(0)) {
                reefPair = pool;
                reefIs0 = ILaunchPairLike(pool).token0() == c.reefToken;
                reefCumStart = _reefCumulative();
                reefObsTime = block.timestamp;
            }
        }

        require(tokensFor(c.hardCap) > 0 && tokensForPool(c.hardCap) > 0, "price too high for the cap");
        // A raise at the soft cap must be able to open the TOKEN/BDAG pool, even with the REEF
        // slice taken out, so a sale that reaches its soft cap can always launch.
        uint256 pooledAtSoft = c.softCap - feeOn(c.softCap);
        uint256 mainAtSoft = pooledAtSoft - (pooledAtSoft * c.reefSliceBps) / BPS;
        require(Math.sqrt(((mainAtSoft * unit) / c.listingPrice) * mainAtSoft) > MIN_POOL_LIQUIDITY, "soft cap too small to open a pool");
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
        require(isBonded(), "project bond not posted");

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

        address wbdag = router.WBDAG();
        IWBDAGLike(wbdag).deposit{value: raised}();
        if (fee > 0) IERC20(wbdag).safeTransfer(feeRecipient, fee);

        // Optional TOKEN/REEF pool first; it returns the BDAG it used (0 if skipped).
        uint256 bdagMain = bdagForPool - _reefSlice(wbdag, bdagForPool);
        uint256 tokensMain = (bdagMain * unit) / listingPrice;

        // Same pool-seeding as the REEF presale: mint directly so dust in the pair can't
        // block the launch, and refuse a pair someone has already given liquidity or loaded
        // with more than 1% of the launch tokens.
        ILaunchFactoryLike factory = ILaunchFactoryLike(router.factory());
        address pair = factory.getPair(address(token), wbdag);
        if (pair == address(0)) pair = factory.createPair(address(token), wbdag);
        require(ILaunchPairLike(pair).totalSupply() == 0, "pool already has liquidity");
        uint256 before = token.balanceOf(pair);
        require(before <= tokensMain / 100, "pool pre-loaded with tokens");

        IERC20(wbdag).safeTransfer(pair, bdagMain);
        token.safeTransfer(pair, tokensMain);
        require(token.balanceOf(pair) - before == tokensMain, "token takes a fee on transfer");
        uint256 liquidity = ILaunchPairLike(pair).mint(address(this));

        // Everything left except what buyers are owed goes to the dead address.
        uint256 owed = tokensFor(raised);
        uint256 burn = token.balanceOf(address(this)) - owed;
        if (burn > 0) token.safeTransfer(DEAD, burn);

        lpToken = pair;
        lpUnlockTime = block.timestamp + lpLockSeconds;
        emit Finalized(raised, fee, bdagMain, tokensMain, burn, liquidity, pair);
    }

    /// @dev Buys REEF with reefSliceBps of the pooled BDAG and seeds TOKEN/REEF at the listing
    ///      price. Any unsafe condition skips it (returns 0) rather than reverting, so the slice
    ///      can never block a launch or be used to force refunds.
    function _reefSlice(address wbdag, uint256 bdagForPool) internal returns (uint256) {
        if (reefPair == address(0)) return _skip(1);
        uint256 slice = (bdagForPool * reefSliceBps) / BPS;
        uint256 tokensSlice = (slice * unit) / listingPrice;
        if (slice == 0 || tokensSlice == 0) return _skip(2);
        uint256 out = _reefQuote(slice);
        if (out == type(uint256).max) return 0; // _reefQuote already emitted the reason
        if (Math.sqrt(tokensSlice * out) <= MIN_POOL_LIQUIDITY) return _skip(2); // too small to open a pool

        ILaunchFactoryLike factory = ILaunchFactoryLike(router.factory());
        address tp = factory.getPair(address(token), address(reefToken));
        if (tp == address(0)) tp = factory.createPair(address(token), address(reefToken));
        uint256 beforeT = token.balanceOf(tp);
        if (ILaunchPairLike(tp).totalSupply() != 0 || beforeT > tokensSlice / 100) return _skip(6);

        // Buy REEF straight from the pool (exact-in, the pool's own 0.30% maths).
        IERC20(wbdag).safeTransfer(reefPair, slice);
        uint256 reefBefore = reefToken.balanceOf(address(this)); // the bond may also be REEF
        ILaunchPairLike(reefPair).swap(reefIs0 ? out : 0, reefIs0 ? 0 : out, address(this), "");
        uint256 got = reefToken.balanceOf(address(this)) - reefBefore;

        reefToken.safeTransfer(tp, got);
        token.safeTransfer(tp, tokensSlice);
        require(token.balanceOf(tp) - beforeT == tokensSlice, "token takes a fee on transfer");
        uint256 lp = ILaunchPairLike(tp).mint(address(this));
        reefLpToken = tp;
        emit ReefSlice(slice, got, tokensSlice, lp, tp);
        return slice;
    }

    /// @dev REEF out for `slice` BDAG, or type(uint256).max (after emitting why) if the REEF
    ///      pool is too thin, the average window too short, or the price too far from average.
    function _reefQuote(uint256 slice) internal returns (uint256) {
        uint256 elapsed = block.timestamp - reefObsTime;
        if (elapsed < MIN_AVERAGE_WINDOW) { _skip(3); return type(uint256).max; }
        (uint112 r0, uint112 r1, ) = ILaunchPairLike(reefPair).getReserves();
        (uint256 rB, uint256 rR) = reefIs0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        if (rB < minReefDepth || rR == 0) { _skip(4); return type(uint256).max; }
        uint256 out = (slice * 997 * rR) / (rB * 1000 + slice * 997);
        uint256 avg;
        unchecked { avg = (_reefCumulative() - reefCumStart) / elapsed; } // BDAG per REEF, UQ112x112
        if (avg == 0 || out == 0 || out * BPS < ((slice << 112) / avg) * (BPS - MAX_SLICE_SLIPPAGE_BPS)) {
            _skip(5);
            return type(uint256).max;
        }
        return out;
    }

    function _skip(uint8 reason) internal returns (uint256) {
        emit ReefSliceSkipped(reason);
        return 0;
    }

    /// @dev The REEF/WBDAG pool's cumulative REEF price (BDAG per REEF, UQ112x112) as of now,
    ///      extrapolated for this block the way the pool itself does.
    function _reefCumulative() internal view returns (uint256 cum) {
        ILaunchPairLike p = ILaunchPairLike(reefPair);
        cum = reefIs0 ? p.price0CumulativeLast() : p.price1CumulativeLast();
        (uint112 r0, uint112 r1, uint32 last) = p.getReserves();
        uint32 ts = uint32(block.timestamp % 2 ** 32);
        if (last != ts && r0 != 0 && r1 != 0) {
            unchecked {
                uint32 el = ts - last;
                cum += (reefIs0 ? (uint256(r1) << 112) / r0 : (uint256(r0) << 112) / r1) * el;
            }
        }
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

    // -------------------------------------------------------------------- bond

    /// @notice True once the project's bond is in this contract (always true with no bond).
    function isBonded() public view returns (bool) {
        return bondAmount == 0 || bondToken.balanceOf(address(this)) >= bondAmount;
    }

    /// @notice What will happen to the bond: 0 = still locked, 1 = goes back to the project,
    ///         2 = burned. It is burned only when buyers reached the soft cap but the pool never
    ///         opened, so they had to take refunds (for example the pair was pre-loaded or the
    ///         token takes a transfer fee). After a launch it returns when the LP lock ends; if
    ///         the soft cap was simply missed, it returns as soon as refunds open.
    function bondOutcome() public view returns (uint8) {
        if (finalized) return block.timestamp >= lpUnlockTime ? 1 : 0;
        if (!refundsOpen()) return 0;
        return (totalRaised > 0 && totalRaised >= softCap) ? 2 : 1;
    }

    /// @notice Anyone can call it once bondOutcome() is decided. Moves the whole bond-token
    ///         balance, so REEF sent here by mistake follows the bond.
    function settleBond() external nonReentrant {
        require(address(bondToken) != address(0), "no bond");
        require(!bondSettled, "bond already settled");
        uint8 outcome = bondOutcome();
        require(outcome != 0, "bond still locked");
        bondSettled = true;
        uint256 amount = bondToken.balanceOf(address(this));
        if (outcome == 2) {
            if (amount > 0) bondToken.safeTransfer(DEAD, amount);
            emit BondBurned(amount);
        } else {
            if (amount > 0) bondToken.safeTransfer(projectWallet, amount);
            emit BondReturned(projectWallet, amount);
        }
    }

    // ----------------------------------------------------------------- LP lock

    function withdrawLP() external nonReentrant {
        require(finalized, "not finalized yet");
        require(block.timestamp >= lpUnlockTime, "LP still locked");
        uint256 amount = IERC20(lpToken).balanceOf(address(this));
        uint256 amountReef = reefLpToken == address(0) ? 0 : IERC20(reefLpToken).balanceOf(address(this));
        require(amount + amountReef > 0, "no LP to withdraw");
        if (amount > 0) {
            IERC20(lpToken).safeTransfer(lpBeneficiary, amount);
            emit LPWithdrawn(amount, lpBeneficiary);
        }
        if (amountReef > 0) {
            IERC20(reefLpToken).safeTransfer(lpBeneficiary, amountReef);
            emit LPWithdrawn(amountReef, lpBeneficiary);
        }
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
            salePrice, listingPrice, softCap, hardCap, maxPerWallet, startTime, endTime, lpLockSeconds,
            address(bondToken), bondAmount, address(reefToken), reefSliceBps, minReefDepth);
    }
}
