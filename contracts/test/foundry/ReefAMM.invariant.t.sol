// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReefFactory} from "../../contracts/reef/ReefFactory.sol";
import {ReefPair} from "../../contracts/reef/ReefPair.sol";
import {ReefRouter} from "../../contracts/reef/ReefRouter.sol";
import {WBDAG} from "../../contracts/reef/WBDAG.sol";
import {IReefPair} from "../../contracts/reef/interfaces/IReefPair.sol";

contract TestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Drives random liquidity adds and removes, swaps, donations with sync, and time across four pools:
/// three token/token pools (T0/T1, T1/T2, T0/T2) and one native BDAG pool (T0/WBDAG), the last one
/// only through the router's native BDAG functions, the way the Reef app uses it.
contract ReefHandler is Test {
    uint256 public constant N_POOLS = 4; // index 3 is the T0/WBDAG pool
    uint256 internal constant N_ACTORS = 5;

    ReefFactory public factory;
    ReefRouter public router;
    WBDAG public wbdag;
    TestToken[3] public tokens;
    address[] public actors;

    // Ghost state.
    uint256 public kViolations; // a swap lowered a pool's k
    uint256 public bdagAccountingErrors; // native BDAG spent or received didn't match what the router reported
    uint256 public swaps;
    uint256 public bdagSwaps;
    uint256 public liquidityEvents;
    uint256 public bdagLiquidityEvents;
    uint256 public nativeTotal; // native BDAG in the system, fixed after setup

    constructor(ReefFactory _f, ReefRouter _r, WBDAG _w, TestToken[3] memory _t) {
        factory = _f;
        router = _r;
        wbdag = _w;
        tokens = _t;
        for (uint160 i = 1; i <= N_ACTORS; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 1e30);
            for (uint256 j = 0; j < 3; j++) {
                tokens[j].mint(a, 1e30);
                vm.prank(a);
                tokens[j].approve(address(router), type(uint256).max);
            }
        }
        nativeTotal = nativeInSystem();
    }

    // ------------------------------------------------------------------ views

    function pairOf(uint256 p) public view returns (IReefPair) {
        if (p % N_POOLS == 3) return IReefPair(factory.getPair(address(tokens[0]), address(wbdag)));
        (uint256 a, uint256 b) = _pair(p);
        return IReefPair(factory.getPair(address(tokens[a]), address(tokens[b])));
    }

    function actorCount() external pure returns (uint256) {
        return N_ACTORS;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    /// Native BDAG held by everyone who can hold it here: actors, WBDAG, router, handler.
    function nativeInSystem() public view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) sum += actors[i].balance;
        sum += address(wbdag).balance + address(router).balance + address(this).balance;
    }

    // ------------------------------------------------------------------ token/token pools

    function addLiquidity(uint256 s, uint256 p, uint256 amtA, uint256 amtB) external {
        (uint256 ia, uint256 ib) = _pair(p);
        amtA = bound(amtA, 1e6, 1e24);
        amtB = bound(amtB, 1e6, 1e24);
        address a = _actor(s);
        vm.prank(a);
        try router.addLiquidity(address(tokens[ia]), address(tokens[ib]), amtA, amtB, 0, 0, a, block.timestamp) {
            liquidityEvents++;
        } catch {}
    }

    function removeLiquidity(uint256 s, uint256 p, uint256 pct) external {
        (uint256 ia, uint256 ib) = _pair(p);
        address a = _actor(s);
        IReefPair pr = pairOf(p % 3);
        uint256 liq = _share(pr.balanceOf(a), pct);
        if (liq == 0) return;
        vm.startPrank(a);
        pr.approve(address(router), liq);
        try router.removeLiquidity(address(tokens[ia]), address(tokens[ib]), liq, 0, 0, a, block.timestamp) {
            liquidityEvents++;
        } catch {}
        vm.stopPrank();
    }

    function swap(uint256 s, uint256 p, uint256 dir, uint256 amountIn) external {
        (uint256 ia, uint256 ib) = _pair(p);
        if (dir % 2 == 1) (ia, ib) = (ib, ia);
        amountIn = bound(amountIn, 1, 1e22);
        address a = _actor(s);
        IReefPair pr = pairOf(p % 3);
        uint256 kBefore = _k(pr);
        vm.prank(a);
        try router.swapExactTokensForTokens(amountIn, 0, _path(address(tokens[ia]), address(tokens[ib])), a, block.timestamp) {
            swaps++;
            if (_k(pr) < kBefore) kViolations++;
        } catch {}
    }

    /// Donate tokens straight to a pool, then sync: reserves must catch up to balances.
    function donateAndSync(uint256 p, uint256 amount) external {
        p = p % N_POOLS;
        amount = bound(amount, 1, 1e20);
        IReefPair pr = pairOf(p);
        (uint256 ia, ) = p == 3 ? (0, 0) : _pair(p);
        vm.prank(actors[0]);
        tokens[ia].transfer(address(pr), amount);
        pr.sync();
    }

    // ------------------------------------------------------------------ native BDAG pool (T0/WBDAG)

    function addLiquidityBDAG(uint256 s, uint256 amtToken, uint256 amtBDAG) external {
        amtToken = bound(amtToken, 1e6, 1e24);
        amtBDAG = bound(amtBDAG, 1e6, 1e24);
        address a = _actor(s);
        uint256 nativeBefore = a.balance;
        vm.prank(a);
        try router.addLiquidityBDAG{value: amtBDAG}(address(tokens[0]), amtToken, 0, 0, a, block.timestamp) returns (
            uint256, uint256 usedBDAG, uint256
        ) {
            bdagLiquidityEvents++;
            // Anything not used must be refunded, to the wei.
            if (nativeBefore - a.balance != usedBDAG) bdagAccountingErrors++;
        } catch {}
    }

    function removeLiquidityBDAG(uint256 s, uint256 pct) external {
        address a = _actor(s);
        IReefPair pr = pairOf(3);
        uint256 liq = _share(pr.balanceOf(a), pct);
        if (liq == 0) return;
        uint256 nativeBefore = a.balance;
        vm.startPrank(a);
        pr.approve(address(router), liq);
        try router.removeLiquidityBDAG(address(tokens[0]), liq, 0, 0, a, block.timestamp) returns (uint256, uint256 outBDAG) {
            bdagLiquidityEvents++;
            if (a.balance - nativeBefore != outBDAG) bdagAccountingErrors++;
        } catch {}
        vm.stopPrank();
    }

    function swapExactBDAGForTokens(uint256 s, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);
        address a = _actor(s);
        IReefPair pr = pairOf(3);
        uint256 kBefore = _k(pr);
        uint256 nativeBefore = a.balance;
        vm.prank(a);
        try router.swapExactBDAGForTokens{value: amountIn}(0, _path(address(wbdag), address(tokens[0])), a, block.timestamp) {
            bdagSwaps++;
            if (_k(pr) < kBefore) kViolations++;
            if (nativeBefore - a.balance != amountIn) bdagAccountingErrors++;
        } catch {}
    }

    function swapExactTokensForBDAG(uint256 s, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);
        address a = _actor(s);
        IReefPair pr = pairOf(3);
        uint256 kBefore = _k(pr);
        uint256 nativeBefore = a.balance;
        vm.prank(a);
        try router.swapExactTokensForBDAG(amountIn, 0, _path(address(tokens[0]), address(wbdag)), a, block.timestamp) returns (
            uint256[] memory amounts
        ) {
            bdagSwaps++;
            if (_k(pr) < kBefore) kViolations++;
            if (a.balance - nativeBefore != amounts[1]) bdagAccountingErrors++;
        } catch {}
    }

    /// Exact-output buy with BDAG, deliberately overpaying so the refund path runs.
    function swapBDAGForExactTokens(uint256 s, uint256 amountOut, uint256 overpay) external {
        amountOut = bound(amountOut, 1, 1e21);
        overpay = bound(overpay, 0, 1e22);
        address a = _actor(s);
        IReefPair pr = pairOf(3);
        (uint112 r0, uint112 r1, ) = pr.getReserves();
        if (r0 == 0 || r1 == 0) return;
        uint256 kBefore = _k(pr);
        uint256 nativeBefore = a.balance;
        address[] memory path = _path(address(wbdag), address(tokens[0]));
        uint256 needed;
        try router.getAmountsIn(amountOut, path) returns (uint256[] memory amts) {
            needed = amts[0];
        } catch {
            return;
        }
        if (needed > 1e26) return;
        vm.prank(a);
        try router.swapBDAGForExactTokens{value: needed + overpay}(amountOut, path, a, block.timestamp) returns (
            uint256[] memory amounts
        ) {
            bdagSwaps++;
            if (_k(pr) < kBefore) kViolations++;
            // Only what the swap used may leave the wallet; the overpayment must come back.
            if (nativeBefore - a.balance != amounts[0]) bdagAccountingErrors++;
        } catch {}
    }

    function swapTokensForExactBDAG(uint256 s, uint256 amountOut) external {
        amountOut = bound(amountOut, 1, 1e21);
        address a = _actor(s);
        IReefPair pr = pairOf(3);
        uint256 kBefore = _k(pr);
        uint256 nativeBefore = a.balance;
        vm.prank(a);
        try router.swapTokensForExactBDAG(amountOut, type(uint256).max, _path(address(tokens[0]), address(wbdag)), a, block.timestamp) {
            bdagSwaps++;
            if (_k(pr) < kBefore) kViolations++;
            if (a.balance - nativeBefore != amountOut) bdagAccountingErrors++;
        } catch {}
    }

    // ------------------------------------------------------------------ time

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    // ------------------------------------------------------------------ helpers

    function _pair(uint256 p) internal pure returns (uint256 a, uint256 b) {
        p = p % 3;
        if (p == 0) return (0, 1);
        if (p == 1) return (1, 2);
        return (0, 2);
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _share(uint256 bal, uint256 pct) internal pure returns (uint256) {
        if (bal == 0) return 0;
        return (bound(pct, 1, 100) * bal) / 100;
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    function _k(IReefPair pr) internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = pr.getReserves();
        return uint256(r0) * uint256(r1);
    }
}

contract ReefAMMInvariantTest is Test {
    ReefFactory internal factory;
    ReefRouter internal router;
    WBDAG internal wbdag;
    TestToken[3] internal tokens;
    ReefHandler internal handler;
    address internal feeSink = address(0xFEE);

    function setUp() public {
        factory = new ReefFactory(address(this));
        wbdag = new WBDAG();
        router = new ReefRouter(address(factory), address(wbdag));
        tokens[0] = new TestToken("T0", "T0");
        tokens[1] = new TestToken("T1", "T1");
        tokens[2] = new TestToken("T2", "T2");
        factory.createPair(address(tokens[0]), address(tokens[1]));
        factory.createPair(address(tokens[1]), address(tokens[2]));
        factory.createPair(address(tokens[0]), address(tokens[2]));
        factory.createPair(address(tokens[0]), address(wbdag));
        // Turn the protocol fee on, so _mintFee's branch is exercised too.
        factory.setFeeTo(feeSink);

        handler = new ReefHandler(factory, router, wbdag, tokens);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = ReefHandler.addLiquidity.selector;
        sels[1] = ReefHandler.removeLiquidity.selector;
        sels[2] = ReefHandler.swap.selector;
        sels[3] = ReefHandler.donateAndSync.selector;
        sels[4] = ReefHandler.warp.selector;
        sels[5] = ReefHandler.addLiquidityBDAG.selector;
        sels[6] = ReefHandler.removeLiquidityBDAG.selector;
        sels[7] = ReefHandler.swapExactBDAGForTokens.selector;
        sels[8] = ReefHandler.swapExactTokensForBDAG.selector;
        sels[9] = ReefHandler.swapBDAGForExactTokens.selector;
        sels[10] = ReefHandler.swapTokensForExactBDAG.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// R1: after each operation every pool's reserves equal its token balances.
    function invariant_reservesMatchBalances() public view {
        for (uint256 p = 0; p < 4; p++) {
            IReefPair pr = handler.pairOf(p);
            (uint112 r0, uint112 r1, ) = pr.getReserves();
            assertEq(r0, _bal(pr, 0), "reserve0 != balance0");
            assertEq(r1, _bal(pr, 1), "reserve1 != balance1");
        }
    }

    /// R2: a swap never lowers a pool's constant product k (token and native BDAG swaps alike).
    function invariant_swapsNeverLowerK() public view {
        assertEq(handler.kViolations(), 0, "a swap lowered k");
    }

    /// R3: LP supply is fully accounted for in every pool.
    function invariant_lpSupplyAccounted() public view {
        for (uint256 p = 0; p < 4; p++) {
            IReefPair pr = handler.pairOf(p);
            uint256 sum = pr.balanceOf(address(pr)) + pr.balanceOf(address(0xdead)) + pr.balanceOf(feeSink)
                + pr.balanceOf(address(router));
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                sum += pr.balanceOf(handler.actorAt(i));
            }
            assertEq(sum, pr.totalSupply(), "LP supply not accounted for");
        }
    }

    /// R4: no tokens are created or destroyed anywhere in the system.
    function invariant_tokenConservation() public view {
        for (uint256 t = 0; t < 3; t++) {
            uint256 sum = tokens[t].balanceOf(address(handler)) + tokens[t].balanceOf(feeSink)
                + tokens[t].balanceOf(address(router));
            for (uint256 p = 0; p < 4; p++) {
                sum += tokens[t].balanceOf(address(handler.pairOf(p)));
            }
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                sum += tokens[t].balanceOf(handler.actorAt(i));
            }
            assertEq(sum, tokens[t].totalSupply(), "tokens not conserved");
        }
    }

    /// R5: the minimum liquidity is locked forever once a pool has been seeded.
    function invariant_minimumLiquidityLocked() public view {
        for (uint256 p = 0; p < 4; p++) {
            IReefPair pr = handler.pairOf(p);
            if (pr.totalSupply() == 0) continue;
            assertGe(pr.balanceOf(address(0xdead)), 1000, "minimum liquidity not locked");
        }
    }

    /// R6: the router never keeps anything between transactions: no tokens, no WBDAG, no BDAG, no LP.
    function invariant_routerHoldsNothing() public view {
        for (uint256 t = 0; t < 3; t++) {
            assertEq(tokens[t].balanceOf(address(router)), 0, "router kept tokens");
        }
        assertEq(wbdag.balanceOf(address(router)), 0, "router kept WBDAG");
        assertEq(address(router).balance, 0, "router kept native BDAG");
        for (uint256 p = 0; p < 4; p++) {
            assertEq(handler.pairOf(p).balanceOf(address(router)), 0, "router kept LP tokens");
        }
    }

    /// R7: every WBDAG is backed 1:1 by native BDAG held in the WBDAG contract.
    function invariant_wbdagFullyBacked() public view {
        uint256 sum = wbdag.balanceOf(address(router)) + wbdag.balanceOf(address(handler));
        for (uint256 p = 0; p < 4; p++) {
            sum += wbdag.balanceOf(address(handler.pairOf(p)));
        }
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += wbdag.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, address(wbdag).balance, "WBDAG not fully backed");
    }

    /// R8: native BDAG is conserved, and every native payment, refund and payout matched what the router reported.
    function invariant_nativeBdagConserved() public view {
        assertEq(handler.nativeInSystem(), handler.nativeTotal(), "native BDAG created or lost");
        assertEq(handler.bdagAccountingErrors(), 0, "native BDAG paid or refunded wrongly");
    }

    /// Deterministic check that the handler really trades on every path, so the invariants above are not vacuous.
    function test_handlerDoesRealWork() public {
        handler.addLiquidity(1, 0, 1e20, 1e20);
        handler.addLiquidity(2, 1, 1e20, 1e20);
        handler.swap(1, 0, 0, 1e18);
        handler.swap(1, 1, 1, 1e18);
        assertGe(handler.liquidityEvents(), 2, "liquidity was never added");
        assertEq(handler.swaps(), 2, "token swaps never succeeded");

        handler.addLiquidityBDAG(3, 1e20, 1e20);
        handler.swapExactBDAGForTokens(1, 1e18);
        handler.swapExactTokensForBDAG(2, 1e18);
        handler.swapBDAGForExactTokens(1, 1e17, 5e18); // overpays, so the refund runs
        handler.swapTokensForExactBDAG(2, 1e17);
        handler.removeLiquidityBDAG(3, 50);
        assertEq(handler.bdagLiquidityEvents(), 2, "BDAG liquidity paths never succeeded");
        assertEq(handler.bdagSwaps(), 4, "BDAG swaps never succeeded");
        assertEq(handler.bdagAccountingErrors(), 0, "native BDAG accounting off");
        assertEq(handler.kViolations(), 0);
    }

    function _bal(IReefPair pr, uint256 which) internal view returns (uint256) {
        return ERC20Like(which == 0 ? pr.token0() : pr.token1()).balanceOf(address(pr));
    }
}

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
}
