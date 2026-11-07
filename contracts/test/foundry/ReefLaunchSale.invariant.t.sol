// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReefFactory} from "../../contracts/reef/ReefFactory.sol";
import {ReefPair} from "../../contracts/reef/ReefPair.sol";
import {ReefRouter} from "../../contracts/reef/ReefRouter.sol";
import {WBDAG} from "../../contracts/reef/WBDAG.sol";
import {ReefLaunchSale} from "../../contracts/reef/ReefLaunchSale.sol";

contract LaunchTestToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Shared set-up: a real Reef factory, router and WBDAG, a REEF token with a deep REEF/BDAG pool,
/// and helpers to build a Reef Launchpad sale with the standard terms (2% fee, 1,000 REEF bond,
/// 20% TOKEN/REEF slice).
abstract contract LaunchBase is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal project = makeAddr("project");
    address internal treasury = makeAddr("treasury");
    address internal lpBen = makeAddr("lpBeneficiary");

    ReefFactory internal factory;
    ReefRouter internal router;
    WBDAG internal wbdag;
    LaunchTestToken internal reef;

    function _deployAmm() internal {
        wbdag = new WBDAG();
        factory = new ReefFactory(address(this));
        router = new ReefRouter(address(factory), address(wbdag));
        reef = new LaunchTestToken("Reef", "REEF", 18);
        // REEF/BDAG pool at 220 BDAG per REEF, 2.2M BDAG deep.
        reef.mint(address(this), 10_000 ether);
        reef.approve(address(router), type(uint256).max);
        vm.deal(address(this), 2_200_000 ether);
        router.addLiquidityBDAG{value: 2_200_000 ether}(address(reef), 10_000 ether, 0, 0, address(this), block.timestamp + 600);
    }

    function _config(LaunchTestToken token, uint256 salePrice, uint256 listingPrice, uint256 softCap, uint256 hardCap, uint256 perWallet)
        internal
        view
        returns (ReefLaunchSale.Config memory c)
    {
        c = ReefLaunchSale.Config({
            token: address(token),
            router: address(router),
            projectWallet: project,
            lpBeneficiary: lpBen,
            feeRecipient: treasury,
            feeBps: 200,
            salePrice: salePrice,
            listingPrice: listingPrice,
            softCap: softCap,
            hardCap: hardCap,
            maxPerWallet: perWallet,
            startTime: block.timestamp + 1 hours,
            endTime: block.timestamp + 1 hours + 7 days,
            lpLockSeconds: 365 days,
            bondToken: address(reef),
            bondAmount: 1_000 ether,
            reefToken: address(reef),
            reefSliceBps: 2_000,
            minReefDepth: 1_000_000 ether
        });
    }

    function _fund(ReefLaunchSale sale, LaunchTestToken token) internal {
        token.mint(address(sale), sale.tokensRequired());
        reef.mint(address(sale), sale.bondAmount());
    }

    receive() external payable {}
}

/// Drives one sale through random buys, time, REEF price pushes, finalize, claims, refunds,
/// returnTokens, settleBond and withdrawLP, keeping ghost totals of everything that moved.
contract LaunchHandler is Test {
    ReefLaunchSale public sale;
    LaunchTestToken public token;
    LaunchTestToken public reef;
    ReefRouter public router;
    WBDAG public wbdag;
    address public treasury;
    address public project;
    address[] public actors;
    address public attacker = makeAddr("attacker");

    // Ghost totals
    uint256 public bdagIn; // BDAG buyers paid in
    uint256 public bdagRefunded;
    uint256 public tokensClaimed;
    mapping(address => uint256) public paid;
    mapping(address => bool) public done;
    uint256 public claimErrors; // a claim paid a different amount from tokensFor(contributed)
    uint256 public refundErrors; // a refund paid a different amount from what was contributed
    uint256 public finalizeUnexpectedFailures; // finalize reverted when every condition was met
    uint256 public bondBurnedWrongly; // bond burned when the launch wasn't blocked
    uint256 public bondReturnedTo; // REEF the bond sent to the project
    uint256 public bondBurned;
    uint256 public mainPoolPriceErrors; // TOKEN/BDAG pool didn't open at the listing price
    uint256 public reefPoolPriceErrors; // TOKEN/REEF pool didn't open at the price paid for REEF
    uint256 public finalizes;
    uint256 public slices;
    uint256 public refundsDone;
    uint256 public claimsDone;

    constructor(ReefLaunchSale _sale, LaunchTestToken _token, LaunchTestToken _reef, ReefRouter _router, WBDAG _wbdag, address _treasury, address _project) {
        sale = _sale;
        token = _token;
        reef = _reef;
        router = _router;
        wbdag = _wbdag;
        treasury = _treasury;
        project = _project;
        for (uint256 i = 0; i < 5; i++) actors.push(makeAddr(string(abi.encodePacked("buyer", vm.toString(i)))));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ---------------------------------------------------------------- actions

    function buy(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        if (block.timestamp < sale.startTime() || block.timestamp > sale.endTime() || sale.finalized()) return;
        uint256 room = sale.hardCap() - sale.totalRaised();
        uint256 walletRoom = sale.maxPerWallet() - sale.contributed(a);
        uint256 max = room < walletRoom ? room : walletRoom;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.deal(a, amount);
        vm.prank(a);
        sale.buy{value: amount}();
        bdagIn += amount;
        paid[a] += amount;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }

    /// Someone moves the REEF price either way, at any time, including just before finalize.
    function pushReef(uint256 amount, bool up) external {
        address[] memory path = new address[](2);
        if (up) {
            amount = bound(amount, 1 ether, 600_000 ether);
            vm.deal(attacker, amount);
            path[0] = address(wbdag);
            path[1] = address(reef);
            vm.prank(attacker);
            router.swapExactBDAGForTokens{value: amount}(0, path, attacker, block.timestamp + 600);
        } else {
            amount = bound(amount, 0.01 ether, 3_000 ether);
            reef.mint(attacker, amount);
            path[0] = address(reef);
            path[1] = address(wbdag);
            vm.startPrank(attacker);
            reef.approve(address(router), amount);
            router.swapExactTokensForBDAG(amount, 0, path, attacker, block.timestamp + 600);
            vm.stopPrank();
        }
    }

    function finalize() external {
        bool shouldWork = !sale.finalized() && !sale.refunding()
            && (block.timestamp > sale.endTime() || sale.totalRaised() == sale.hardCap())
            && sale.totalRaised() > 0 && sale.totalRaised() >= sale.softCap();
        uint256 treasuryBefore = wbdag.balanceOf(treasury);
        try sale.finalize() {
            finalizes++;
            uint256 raised = sale.totalRaised();
            // fee check is in the invariants; here, the opening prices
            uint256 fee = wbdag.balanceOf(treasury) - treasuryBefore;
            uint256 pooled = raised - fee;
            ReefPair main = ReefPair(sale.lpToken());
            (uint112 r0, uint112 r1,) = main.getReserves();
            bool tokenIs0 = main.token0() == address(token);
            uint256 rTok = tokenIs0 ? r0 : r1;
            uint256 rB = tokenIs0 ? r1 : r0;
            uint256 unit = sale.unit();
            if (rTok != (rB * unit) / sale.listingPrice()) mainPoolPriceErrors++;
            if (sale.reefLpToken() != address(0)) {
                slices++;
                uint256 slice = pooled - rB;
                if (slice != (pooled * sale.reefSliceBps()) / 10_000) mainPoolPriceErrors++;
                ReefPair rp = ReefPair(sale.reefLpToken());
                (uint112 q0, uint112 q1,) = rp.getReserves();
                uint256 qTok = rp.token0() == address(token) ? q0 : q1;
                if (qTok != (slice * unit) / sale.listingPrice()) reefPoolPriceErrors++;
            }
        } catch {
            if (shouldWork) finalizeUnexpectedFailures++;
        }
    }

    function claim(uint256 seed) external {
        address a = _actor(seed);
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        try sale.claim() {
            uint256 got = token.balanceOf(a) - before;
            if (got != sale.tokensFor(paid[a]) || done[a]) claimErrors++;
            done[a] = true;
            tokensClaimed += got;
            claimsDone++;
        } catch {}
    }

    function refund(uint256 seed) external {
        address a = _actor(seed);
        uint256 before = a.balance;
        vm.prank(a);
        try sale.refund() {
            uint256 got = a.balance - before;
            if (got != paid[a] || done[a]) refundErrors++;
            done[a] = true;
            bdagRefunded += got;
            refundsDone++;
        } catch {}
    }

    function returnTokens() external {
        try sale.returnTokens() {} catch {}
    }

    function settleBond() external {
        uint8 outcome = sale.bondOutcome();
        uint256 projBefore = reef.balanceOf(project);
        uint256 deadBefore = reef.balanceOf(address(0xdEaD));
        bool blocked = !sale.finalized() && sale.totalRaised() > 0 && sale.totalRaised() >= sale.softCap();
        try sale.settleBond() {
            uint256 toProject = reef.balanceOf(project) - projBefore;
            uint256 burned = reef.balanceOf(address(0xdEaD)) - deadBefore;
            bondReturnedTo += toProject;
            bondBurned += burned;
            if (burned > 0 && (!blocked || outcome != 2)) bondBurnedWrongly++;
        } catch {}
    }

    function withdrawLP() external {
        try sale.withdrawLP() {} catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract ReefLaunchSaleInvariantTest is LaunchBase {
    ReefLaunchSale internal sale;
    LaunchTestToken internal token;
    LaunchHandler internal handler;

    function setUp() public {
        _deployAmm();
        token = new LaunchTestToken("Launch", "LNCH", 18);
        // 100 BDAG per token, pool opens at 150; soft cap 500k, hard cap 2M, 600k per wallet:
        // five buyers can land under the soft cap, above it, or sell out.
        sale = new ReefLaunchSale(_config(token, 100 ether, 150 ether, 500_000 ether, 2_000_000 ether, 600_000 ether));
        _fund(sale, token);
        handler = new LaunchHandler(sale, token, reef, router, wbdag, treasury, project);
        targetContract(address(handler));
    }

    /// BDAG can only leave the sale as the pool + fee (all of it, at finalize) or as refunds.
    function invariant_bdagOnlyLeavesAsPoolFeeOrRefund() public view {
        if (sale.finalized()) {
            assertEq(address(sale).balance, 0, "BDAG left behind after finalize");
            assertEq(handler.bdagRefunded(), 0, "refund after finalize");
        } else {
            assertEq(address(sale).balance, handler.bdagIn() - handler.bdagRefunded(), "BDAG missing before finalize");
        }
        assertEq(sale.totalRaised(), handler.bdagIn(), "totalRaised drifted");
    }

    /// The treasury only ever gets exactly the disclosed fee, and only after a launch.
    function invariant_feeIsExactlyTheDisclosedShare() public view {
        uint256 expected = sale.finalized() ? (sale.totalRaised() * sale.feeBps()) / 10_000 : 0;
        assertEq(wbdag.balanceOf(treasury), expected, "treasury got something other than the fee");
    }

    /// After a launch, the sale always holds enough tokens for every unclaimed buyer.
    function invariant_tokensCoverEveryUnclaimedBuyer() public view {
        if (!sale.finalized()) return;
        uint256 owed;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            if (!sale.settled(a)) owed += sale.tokensFor(sale.contributed(a));
        }
        assertGe(token.balanceOf(address(sale)), owed, "not enough tokens for unclaimed buyers");
    }

    /// Before refunds or a launch, the deposit covers every claim and the pool at the hard cap.
    function invariant_depositCoversSaleUntilItResolves() public view {
        if (sale.finalized() || sale.tokensReturned()) return;
        assertGe(token.balanceOf(address(sale)), sale.tokensRequired(), "deposit fell short");
    }

    /// A sale ends one way only: launched, or refunding. Never both.
    function invariant_launchedOrRefundingNeverBoth() public view {
        assertFalse(sale.finalized() && sale.refunding(), "finalized and refunding");
        if (sale.tokensReturned()) assertFalse(sale.finalized(), "tokens returned after launch");
    }

    /// Every claim and refund paid exactly what it should, once per buyer.
    function invariant_claimsAndRefundsExact() public view {
        assertEq(handler.claimErrors(), 0, "a claim paid the wrong amount");
        assertEq(handler.refundErrors(), 0, "a refund paid the wrong amount");
    }

    /// The REEF slice (or a pushed REEF price) can never block a launch that should go ahead.
    function invariant_finalizeNeverBlockedWhenConditionsMet() public view {
        assertEq(handler.finalizeUnexpectedFailures(), 0, "finalize reverted when it should have worked");
    }

    /// Both pools open at the advertised price.
    function invariant_poolsOpenAtListingPrice() public view {
        assertEq(handler.mainPoolPriceErrors(), 0, "TOKEN/BDAG pool or slice size wrong");
        assertEq(handler.reefPoolPriceErrors(), 0, "TOKEN/REEF pool wrong");
    }

    /// The bond is only ever burned when the launch was blocked; otherwise it all goes back.
    function invariant_bondOnlyBurnedWhenBlocked() public view {
        assertEq(handler.bondBurnedWrongly(), 0, "bond burned when it shouldn't be");
        if (!sale.bondSettled()) assertGe(reef.balanceOf(address(sale)), sale.bondAmount(), "bond went missing");
        else assertEq(handler.bondReturnedTo() + handler.bondBurned(), 1_000 ether, "bond not fully settled");
    }

    function invariant_callSummary() public view {
        // Shows how far the runs got (forge prints it with -vv); always passes.
        handler.finalizes();
    }
}

/// Whole-sale fuzz tests across token decimals, prices, caps and buyer counts.
contract ReefLaunchSaleFuzzTest is LaunchBase {
    function setUp() public {
        _deployAmm();
    }

    /// Launch path: any sale that deploys and reaches its soft cap can launch, every buyer can claim
    /// exactly their share, and the sale ends with only rounding dust.
    function testFuzz_launchPaysEveryoneExactly(uint8 decSeed, uint256 priceSeed, uint256 premiumBps, uint256 capSeed, uint256 softBps, uint256[6] memory buys) public {
        uint8 dec = uint8(bound(decSeed, 6, 18));
        uint256 salePrice = bound(priceSeed, 0.001 ether, 1_000 ether);
        uint256 listingPrice = salePrice + (salePrice * bound(premiumBps, 0, 20_000)) / 10_000;
        uint256 hardCap = bound(capSeed, 10_000 ether, 5_000_000 ether);
        uint256 softCap = (hardCap * bound(softBps, 1, 10_000)) / 10_000;
        if (softCap == 0) softCap = 1;
        LaunchTestToken token = new LaunchTestToken("Fuzz", "FZZ", dec);
        ReefLaunchSale sale;
        try new ReefLaunchSale(_config(token, salePrice, listingPrice, softCap, hardCap, hardCap)) returns (ReefLaunchSale s) {
            sale = s;
        } catch {
            return; // settings the contract refuses (e.g. a soft cap too small to open a pool)
        }
        _fund(sale, token);
        vm.warp(sale.startTime());

        address[7] memory who;
        uint256 total;
        for (uint256 i = 0; i < 6; i++) {
            who[i] = makeAddr(string(abi.encodePacked("fb", vm.toString(i))));
            uint256 room = hardCap - total;
            if (room == 0) break;
            uint256 amt = bound(buys[i], 1, room);
            vm.deal(who[i], amt);
            vm.prank(who[i]);
            sale.buy{value: amt}();
            total += amt;
        }
        who[6] = makeAddr("topup");
        if (total < softCap) { // make sure the soft cap is reached
            uint256 amt = softCap - total;
            vm.deal(who[6], amt);
            vm.prank(who[6]);
            sale.buy{value: amt}();
            total += amt;
        }
        vm.warp(sale.endTime() + 1);
        sale.finalize(); // must never revert once the soft cap is reached
        assertEq(wbdag.balanceOf(treasury), (total * 200) / 10_000, "fee");
        for (uint256 i = 0; i < 7; i++) {
            uint256 c = sale.contributed(who[i]);
            if (c == 0 || sale.tokensFor(c) == 0) continue;
            vm.prank(who[i]);
            sale.claim();
            assertEq(token.balanceOf(who[i]), sale.tokensFor(c), "claim amount");
        }
        // Only rounding dust (at most one unit per buyer) can remain.
        assertLe(token.balanceOf(address(sale)), 7, "more than rounding dust left");
        assertEq(address(sale).balance, 0, "BDAG left in the sale");
    }

    /// Refund path: under the soft cap, every buyer gets back exactly what they paid, the project
    /// gets every token back and the bond back, and nothing is burned.
    function testFuzz_failedSaleReturnsEverything(uint256 softSeed, uint256[4] memory buys) public {
        LaunchTestToken token = new LaunchTestToken("Fuzz", "FZZ", 18);
        uint256 hardCap = 1_000_000 ether;
        uint256 softCap = bound(softSeed, 100_000 ether, hardCap);
        ReefLaunchSale sale = new ReefLaunchSale(_config(token, 100 ether, 150 ether, softCap, hardCap, hardCap));
        _fund(sale, token);
        uint256 deposit = token.balanceOf(address(sale));
        vm.warp(sale.startTime());
        address[4] memory who;
        uint256 total;
        for (uint256 i = 0; i < 4; i++) {
            who[i] = makeAddr(string(abi.encodePacked("rb", vm.toString(i))));
            uint256 room = softCap - 1 - total; // stay under the soft cap
            if (room == 0) break;
            uint256 amt = bound(buys[i], 1, room);
            vm.deal(who[i], amt);
            vm.prank(who[i]);
            sale.buy{value: amt}();
            total += amt;
        }
        vm.warp(sale.endTime() + 1);
        vm.expectRevert(bytes("soft cap not reached"));
        sale.finalize();
        for (uint256 i = 0; i < 4; i++) {
            uint256 c = sale.contributed(who[i]);
            if (c == 0) continue;
            vm.prank(who[i]);
            sale.refund();
            assertEq(who[i].balance, c, "refund amount");
        }
        sale.returnTokens();
        sale.settleBond();
        assertEq(token.balanceOf(project), deposit, "project tokens");
        assertEq(reef.balanceOf(project), 1_000 ether, "bond returned");
        assertEq(reef.balanceOf(DEAD), 0, "nothing burned");
        assertEq(address(sale).balance, 0, "BDAG left");
    }
}
