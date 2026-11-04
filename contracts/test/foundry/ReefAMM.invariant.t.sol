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

/// Drives random liquidity adds and removes, swaps, donations with sync, and time, across three pairs.
contract ReefHandler is Test {
    ReefFactory public factory;
    ReefRouter public router;
    TestToken[3] public tokens;
    address[] public actors;
    address public constant DEAD = address(0xdead);
    address public feeSink = address(0xFEE);

    // Ghost state: the last k of each pair after a swap must never fall.
    uint256 public kViolations;
    uint256 public swaps;
    uint256 public liquidityEvents;

    constructor(ReefFactory _f, ReefRouter _r, TestToken[3] memory _t) {
        factory = _f;
        router = _r;
        tokens = _t;
        for (uint160 i = 1; i <= 5; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            for (uint256 j = 0; j < 3; j++) {
                tokens[j].mint(a, 1e30);
                vm.prank(a);
                tokens[j].approve(address(router), type(uint256).max);
            }
        }
    }

    function pairOf(uint256 p) public view returns (IReefPair) {
        (uint256 a, uint256 b) = _pair(p);
        return IReefPair(factory.getPair(address(tokens[a]), address(tokens[b])));
    }

    function _pair(uint256 p) internal pure returns (uint256 a, uint256 b) {
        p = p % 3;
        if (p == 0) return (0, 1);
        if (p == 1) return (1, 2);
        return (0, 2);
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

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
        IReefPair pr = pairOf(p);
        uint256 bal = pr.balanceOf(a);
        if (bal == 0) return;
        uint256 liq = bound(pct, 1, 100) * bal / 100;
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
        IReefPair pr = pairOf(p);
        uint256 kBefore = _k(pr);
        vm.prank(a);
        try router.swapExactTokensForTokens(amountIn, 0, _path(ia, ib), a, block.timestamp) {
            swaps++;
            if (_k(pr) < kBefore) kViolations++;
        } catch {}
    }

    /// Donate tokens straight to a pair, then sync: reserves must catch up to balances.
    function donateAndSync(uint256 p, uint256 amount) external {
        (uint256 ia, ) = _pair(p);
        amount = bound(amount, 1, 1e20);
        IReefPair pr = pairOf(p);
        vm.prank(actors[0]);
        tokens[ia].transfer(address(pr), amount);
        pr.sync();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    function _path(uint256 a, uint256 b) internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(tokens[a]);
        path[1] = address(tokens[b]);
    }

    function _k(IReefPair pr) internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = pr.getReserves();
        return uint256(r0) * uint256(r1);
    }
}

contract ReefAMMInvariantTest is Test {
    ReefFactory internal factory;
    ReefRouter internal router;
    TestToken[3] internal tokens;
    ReefHandler internal handler;
    address internal feeSink = address(0xFEE);

    function setUp() public {
        factory = new ReefFactory(address(this));
        WBDAG wbdag = new WBDAG();
        router = new ReefRouter(address(factory), address(wbdag));
        tokens[0] = new TestToken("T0", "T0");
        tokens[1] = new TestToken("T1", "T1");
        tokens[2] = new TestToken("T2", "T2");
        factory.createPair(address(tokens[0]), address(tokens[1]));
        factory.createPair(address(tokens[1]), address(tokens[2]));
        factory.createPair(address(tokens[0]), address(tokens[2]));
        // Turn the protocol fee on, so _mintFee's branch is exercised too.
        factory.setFeeTo(feeSink);

        handler = new ReefHandler(factory, router, tokens);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = ReefHandler.addLiquidity.selector;
        sels[1] = ReefHandler.removeLiquidity.selector;
        sels[2] = ReefHandler.swap.selector;
        sels[3] = ReefHandler.donateAndSync.selector;
        sels[4] = ReefHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// R1: after each operation the reserves equal the pair's token balances (after sync).
    function invariant_reservesMatchBalances() public {
        for (uint256 p = 0; p < 3; p++) {
            IReefPair pr = handler.pairOf(p);
            if (address(pr) == address(0)) continue;
            (uint112 r0, uint112 r1, ) = pr.getReserves();
            assertEq(r0, _bal(pr, 0), "reserve0 != balance0");
            assertEq(r1, _bal(pr, 1), "reserve1 != balance1");
        }
    }

    /// R2: a swap never lowers the pair's constant product k.
    function invariant_swapsNeverLowerK() public view {
        assertEq(handler.kViolations(), 0, "a swap lowered k");
    }

    /// R3: LP supply is fully accounted for: holders + the pair itself + dead address sum to totalSupply.
    function invariant_lpSupplyAccounted() public view {
        for (uint256 p = 0; p < 3; p++) {
            IReefPair pr = handler.pairOf(p);
            if (address(pr) == address(0)) continue;
            uint256 sum = pr.balanceOf(address(pr)) + pr.balanceOf(address(0xdead)) + pr.balanceOf(feeSink);
            for (uint160 i = 1; i <= 5; i++) {
                sum += pr.balanceOf(address(uint160(0xA000 + i)));
            }
            assertEq(sum, pr.totalSupply(), "LP supply not accounted for");
        }
    }

    /// R4: no tokens are created or destroyed: sum of holder balances equals total supply, per token.
    function invariant_tokenConservation() public view {
        for (uint256 t = 0; t < 3; t++) {
            uint256 sum = tokens[t].balanceOf(address(handler)) + tokens[t].balanceOf(feeSink);
            for (uint256 p = 0; p < 3; p++) {
                IReefPair pr = handler.pairOf(p);
                if (address(pr) != address(0)) sum += tokens[t].balanceOf(address(pr));
            }
            for (uint160 i = 1; i <= 5; i++) {
                sum += tokens[t].balanceOf(address(uint160(0xA000 + i)));
            }
            sum += tokens[t].balanceOf(address(router));
            assertEq(sum, tokens[t].totalSupply(), "tokens not conserved");
        }
    }

    /// Deterministic check that the handler really swaps and adds liquidity, so the invariants above are not vacuous.
    function test_handlerDoesRealWork() public {
        handler.addLiquidity(1, 0, 1e20, 1e20);
        handler.addLiquidity(2, 1, 1e20, 1e20);
        handler.swap(1, 0, 0, 1e18);
        handler.swap(1, 1, 1, 1e18);
        assertGe(handler.liquidityEvents(), 2, "liquidity was never added");
        assertEq(handler.swaps(), 2, "swaps never succeeded");
    }

    /// R5: the minimum liquidity is locked forever once a pair has been seeded.
    function invariant_minimumLiquidityLocked() public view {
        for (uint256 p = 0; p < 3; p++) {
            IReefPair pr = handler.pairOf(p);
            if (address(pr) == address(0) || pr.totalSupply() == 0) continue;
            assertGe(pr.balanceOf(address(0xdead)), 1000, "minimum liquidity not locked");
        }
    }

    function _bal(IReefPair pr, uint256 which) internal view returns (uint256) {
        return ERC20Like(which == 0 ? pr.token0() : pr.token1()).balanceOf(address(pr));
    }
}

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
}
