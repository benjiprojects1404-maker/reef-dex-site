// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Only the two Reef router functions this contract needs. Reef renames every
///      *ETH function to *BDAG, so this is addLiquidityBDAG, not addLiquidityETH.
interface IReefRouterLike {
    function factory() external view returns (address);
    function WBDAG() external view returns (address);
    function addLiquidityBDAG(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountBDAGMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountBDAG, uint256 liquidity);
}

interface IReefFactoryLike {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IReefPairLike {
    function totalSupply() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
}

interface IWBDAGLike {
    function deposit() external payable;
}

/// @title Reef Presale
/// @notice Fixed-price REEF sale, paid in native BDAG on chain 1404. THIS IS THE ONLY
///         $REEF CONTRACT THAT HOLDS OTHER PEOPLE'S FUNDS, so it is deliberately small
///         and has no owner, no admin function and no way to withdraw the raised BDAG.
///
///         Terms (fixed in code):
///           - 1,050,000 REEF for sale at 150 BDAG each
///           - maximum raise 157,500,000 BDAG; per-wallet cap 2,500,000 BDAG
///           - the pool opens at 225 BDAG per REEF (1.5x the presale price)
///
///         How it works:
///           1. Before the sale, the presale holder wallet sends 1,050,000 REEF here.
///              buy() refuses to take money until that is true.
///           2. Buyers call buy() with BDAG during the window. They receive nothing yet.
///           3. When the sale ends (or sells out) ANYONE can call finalize(). The
///              contract itself pairs ALL raised BDAG with REEF at 225 via Reef's router,
///              sends any unsold presale REEF to the dead address, and keeps the LP tokens.
///           4. Buyers then call claim() for their REEF. No REEF circulates from the
///              presale before the pool exists.
///           5. The LP tokens stay in this contract until lpUnlockTime, then withdrawLP()
///              sends them to lpBeneficiary. The unlock time counts from finalize().
///
///         Safety fallback: if finalize() has not happened within REFUND_DELAY after the
///         sale ends (for example the pool cannot be seeded), buyers can refund() their
///         BDAG in full. Once any refund happens, finalize() is permanently disabled. In
///         that case the presale REEF stays locked in this contract and is never released.
///
///         The liquidity wallet must approve this contract for the REEF needed to pair
///         (at most 700,000 REEF) before finalize(); the contract pulls exactly what it
///         needs, so nothing extra is ever taken.
///
///         Not independently audited. Configuration is plain storage rather than
///         `immutable` so simple explorer verifiers can match the bytecode.
contract ReefPresale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- fixed terms (BDAG and REEF both use 18 decimals, so wei math works directly) ----
    uint256 public constant PRESALE_PRICE = 150; // BDAG per 1 REEF
    uint256 public constant LISTING_PRICE = 225; // BDAG per 1 REEF at pool launch
    uint256 public constant TOTAL_FOR_SALE = 1_050_000 * 10 ** 18;
    uint256 public constant MAX_RAISE = TOTAL_FOR_SALE * PRESALE_PRICE; // 157,500,000 BDAG
    uint256 public constant MAX_PER_WALLET = 2_500_000 * 10 ** 18; // in BDAG
    uint256 public constant MIN_LP_LOCK = 180 days;
    uint256 public constant REFUND_DELAY = 7 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- configuration (set once in the constructor, never changed) ----
    IERC20 public token;
    IReefRouterLike public router;
    address public liquidityWallet;
    address public lpBeneficiary;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public lpLockSeconds;

    // ---- state ----
    uint256 public totalRaised; // BDAG, in wei
    mapping(address => uint256) public contributed; // BDAG per wallet, in wei
    mapping(address => bool) public settled; // true once the wallet has claimed or refunded
    bool public finalized;
    bool public refunding;
    address public lpToken;
    uint256 public lpUnlockTime;

    event Purchased(address indexed buyer, uint256 amountBDAG, uint256 totalRaised);
    event Finalized(uint256 bdagPaired, uint256 reefPaired, uint256 reefSentToDead, uint256 lpTokens, address lpToken);
    event Claimed(address indexed buyer, uint256 reefAmount);
    event Refunded(address indexed buyer, uint256 amountBDAG);
    event LPWithdrawn(uint256 amount, address to);

    /// @param token_          The deployed ReefToken.
    /// @param router_         Reef's router (0xbd6fbA41Ab84292163A599510a12d6Bf8B7CCc76).
    /// @param liquidityWallet_ Holds the REEF used to pair with the raised BDAG.
    /// @param lpBeneficiary_  Receives the LP tokens after the lock (use a hardware wallet).
    /// @param startTime_      Unix time the sale opens (must not be in the past).
    /// @param endTime_        Unix time the sale closes.
    /// @param lpLockSeconds_  How long LP stays locked after finalize(), at least 180 days.
    constructor(
        address token_,
        address router_,
        address liquidityWallet_,
        address lpBeneficiary_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 lpLockSeconds_
    ) {
        require(token_ != address(0), "token is zero address");
        require(router_ != address(0), "router is zero address");
        require(liquidityWallet_ != address(0), "liquidity wallet is zero address");
        require(lpBeneficiary_ != address(0), "LP beneficiary is zero address");
        require(startTime_ >= block.timestamp, "start time is in the past");
        require(endTime_ > startTime_, "end must be after start");
        require(lpLockSeconds_ >= MIN_LP_LOCK, "LP lock must be at least 180 days");

        token = IERC20(token_);
        router = IReefRouterLike(router_);
        liquidityWallet = liquidityWallet_;
        lpBeneficiary = lpBeneficiary_;
        startTime = startTime_;
        endTime = endTime_;
        lpLockSeconds = lpLockSeconds_;
    }

    // ------------------------------------------------------------------ buying

    /// @notice Send BDAG to reserve REEF at 150 BDAG each. REEF is claimed after finalize().
    function buy() external payable {
        require(block.timestamp >= startTime, "presale not started");
        require(block.timestamp <= endTime && !finalized, "presale ended");
        require(msg.value > 0, "send some BDAG");
        require(token.balanceOf(address(this)) >= TOTAL_FOR_SALE, "presale not funded");

        uint256 newTotal = totalRaised + msg.value;
        require(newTotal <= MAX_RAISE, "exceeds presale capacity");

        uint256 newContribution = contributed[msg.sender] + msg.value;
        require(newContribution <= MAX_PER_WALLET, "exceeds per-wallet cap");

        totalRaised = newTotal;
        contributed[msg.sender] = newContribution;
        emit Purchased(msg.sender, msg.value, newTotal);
    }

    // --------------------------------------------------------------- finalizing

    /// @notice Seeds the pool with every BDAG raised. Callable by anyone once the sale has
    ///         ended or sold out. Reverts (and can be retried) if the router call fails.
    function finalize() external nonReentrant {
        require(!finalized, "already finalized");
        require(!refunding, "refunds have started");
        require(block.timestamp > endTime || totalRaised == MAX_RAISE, "presale still running");
        require(totalRaised > 0, "nothing raised");

        finalized = true; // set first; if anything below reverts, this reverts too

        uint256 raised = totalRaised;
        uint256 sold = raised / PRESALE_PRICE; // REEF owed to buyers, in total
        uint256 unsold = TOTAL_FOR_SALE - sold;
        uint256 reefForPool = raised / LISTING_PRICE;
        require(reefForPool > 0, "raise too small to pair");

        // Unsold presale REEF goes to the dead address, not to any team wallet.
        if (unsold > 0) {
            token.safeTransfer(DEAD, unsold);
        }

        // Seed the pair directly instead of through the router. Anyone can create the
        // REEF/WBDAG pair and donate dust to it (then sync()), which makes the router's
        // exact-amount addLiquidityBDAG revert forever and forces refunds for the cost of
        // gas. Minting directly works as long as nobody holds LP yet: dust already in the
        // pair simply joins the pool, owned by these LP tokens.
        address wbdag = router.WBDAG();
        IReefFactoryLike factory = IReefFactoryLike(router.factory());
        address pair = factory.getPair(address(token), wbdag);
        if (pair == address(0)) {
            pair = factory.createPair(address(token), wbdag);
        }
        // If someone has already minted real liquidity the launch price is not ours to set:
        // revert, and refunds open after REFUND_DELAY. (Needs REEF, which nobody outside the
        // team holds before finalize.)
        require(IReefPairLike(pair).totalSupply() == 0, "pool already has liquidity");
        // REEF donated beforehand would lower the opening price; allow at most 1% of it.
        require(token.balanceOf(pair) <= reefForPool / 100, "pool pre-loaded with REEF");

        IWBDAGLike(wbdag).deposit{value: raised}();
        IERC20(wbdag).safeTransfer(pair, raised);
        // Pull exactly the REEF needed from the liquidity wallet (needs its approval).
        token.safeTransferFrom(liquidityWallet, pair, reefForPool);
        uint256 liquidity = IReefPairLike(pair).mint(address(this));

        lpToken = pair;
        lpUnlockTime = block.timestamp + lpLockSeconds;

        emit Finalized(raised, reefForPool, unsold, liquidity, pair);
    }

    // ---------------------------------------------------------------- claiming

    /// @notice After finalize(), collect the REEF you bought.
    function claim() external nonReentrant {
        require(finalized, "not finalized yet");
        require(!settled[msg.sender], "already settled");

        uint256 owed = contributed[msg.sender] / PRESALE_PRICE;
        require(owed > 0, "nothing to claim");

        settled[msg.sender] = true;
        token.safeTransfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
    }

    // ----------------------------------------------------------------- refunds

    /// @notice If finalize() has not happened within REFUND_DELAY after the sale ends,
    ///         get your BDAG back in full. The first refund permanently disables finalize().
    function refund() external nonReentrant {
        require(!finalized, "already finalized");
        require(block.timestamp > endTime + REFUND_DELAY, "refunds not open yet");
        require(!settled[msg.sender], "already settled");

        uint256 amount = contributed[msg.sender];
        require(amount > 0, "nothing to refund");

        refunding = true;
        settled[msg.sender] = true;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund transfer failed");
        emit Refunded(msg.sender, amount);
    }

    // ----------------------------------------------------------------- LP lock

    /// @notice After lpUnlockTime, send the locked LP tokens to lpBeneficiary.
    function withdrawLP() external nonReentrant {
        require(finalized, "not finalized yet");
        require(block.timestamp >= lpUnlockTime, "LP still locked");

        uint256 amount = IERC20(lpToken).balanceOf(address(this));
        require(amount > 0, "no LP to withdraw");

        IERC20(lpToken).safeTransfer(lpBeneficiary, amount);
        emit LPWithdrawn(amount, lpBeneficiary);
    }

    // ------------------------------------------------------------------- views

    /// @notice BDAG still available to raise.
    function remainingCapacity() external view returns (uint256) {
        return MAX_RAISE - totalRaised;
    }

    /// @notice REEF this wallet will receive on claim (0 once settled).
    function claimable(address buyer) external view returns (uint256) {
        if (settled[buyer]) return 0;
        return contributed[buyer] / PRESALE_PRICE;
    }

    /// @notice Seconds until the LP can be withdrawn (0 if unlocked or not yet finalized).
    function lpTimeRemaining() external view returns (uint256) {
        if (!finalized || block.timestamp >= lpUnlockTime) return 0;
        return lpUnlockTime - block.timestamp;
    }
}
