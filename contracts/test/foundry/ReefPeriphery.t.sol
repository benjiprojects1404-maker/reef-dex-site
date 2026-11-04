// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReefTrancheVesting} from "../../contracts/reef/ReefTrancheVesting.sol";
import {ReefAirdrop, IReefPresaleState} from "../../contracts/reef/ReefAirdrop.sol";
import {ReefTWAPOracle} from "../../contracts/reef/ReefTWAPOracle.sol";
import {ReefFactory} from "../../contracts/reef/ReefFactory.sol";
import {ReefRouter} from "../../contracts/reef/ReefRouter.sol";
import {WBDAG} from "../../contracts/reef/WBDAG.sol";
import {MockPresaleState} from "../../contracts/reef/mocks/MockPresaleState.sol";
import {TestToken} from "./ReefAMM.invariant.t.sol";

// =====================================================================================
// Tranche vesting
// =====================================================================================

/// Random schedules, random funding (including under-funding and later top-ups), random
/// release times. The beneficiary must get exactly what has unlocked, never early, never more.
contract ReefVestingFuzzTest is Test {
    TestToken internal token;
    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_790_000_000); // late Sep 2026
        token = new TestToken("REEF", "REEF");
    }

    function _schedule(uint256 n, uint256 seed) internal view returns (uint64[] memory out) {
        out = new uint64[](n);
        uint64 t = uint64(block.timestamp) + uint64(bound(seed, 1, 30 days));
        for (uint256 i = 0; i < n; i++) {
            out[i] = t;
            t += uint64(bound(uint256(keccak256(abi.encode(seed, i))), 1, 120 days));
        }
    }

    ReefTrancheVesting internal v;
    uint64[] internal times;
    uint256 internal tranche;
    uint256 internal total;

    function testFuzz_vestingPaysExactlyWhatUnlocked(
        uint8 nRaw,
        uint256 trancheRaw,
        uint256 seed,
        uint256 fundPct,
        uint256[8] memory steps
    ) public {
        uint256 n = bound(nRaw, 1, 24);
        tranche = bound(trancheRaw, 1, 1e27);
        times = _schedule(n, seed);
        v = new ReefTrancheVesting(IERC20(address(token)), beneficiary, tranche, times);
        total = v.totalAmount();
        assertEq(total, tranche * n);

        // Fund between 0% and 150% of the total.
        token.mint(address(v), (total * bound(fundPct, 0, 150)) / 100);

        // Nothing can be released before the first unlock.
        vm.expectRevert("nothing to release");
        v.release();
        assertEq(token.balanceOf(beneficiary), 0, "paid before first unlock");

        for (uint256 i = 0; i < steps.length; i++) _step(steps[i]);

        // After the last unlock, with full funding, everything is paid and nothing more can be.
        vm.warp(uint256(times[n - 1]) + 1);
        _topUp();
        if (v.releasable() > 0) v.release();
        assertEq(v.released(), total, "not fully paid after the last unlock");
        assertEq(token.balanceOf(beneficiary), total);
        vm.expectRevert("nothing to release");
        v.release();
    }

    function _topUp() internal {
        uint256 have = token.balanceOf(address(v)) + v.released();
        if (have < total) token.mint(address(v), total - have);
    }

    function _step(uint256 r) internal {
        vm.warp(block.timestamp + bound(r, 0, 200 days));
        if (r % 3 == 0) _topUp(); // sometimes top up an under-funded contract
        uint256 due = v.vested() - v.released();
        uint256 bal = token.balanceOf(address(v));
        uint256 expected = due < bal ? due : bal;
        uint256 before = token.balanceOf(beneficiary);
        vm.prank(stranger); // anyone may call release; the tokens still go to the beneficiary
        if (expected == 0) vm.expectRevert("nothing to release");
        v.release();
        assertEq(token.balanceOf(beneficiary) - before, expected, "release paid the wrong amount");
        assertEq(token.balanceOf(beneficiary), v.released(), "released counter out of sync");
        assertLe(v.released(), v.vested(), "paid more than has unlocked");
        assertLe(v.released(), total, "paid more than the total");
        assertEq(token.balanceOf(stranger), 0, "caller was paid");
        uint256 unlocked;
        for (uint256 j = 0; j < times.length; j++) if (times[j] <= block.timestamp) unlocked++;
        assertEq(v.vested(), unlocked * tranche, "vested() disagrees with the schedule");
    }

    function testFuzz_constructorRejectsBadSchedules(uint64 a, uint64 b) public {
        b = uint64(bound(b, 0, a));
        uint64[] memory bad = new uint64[](2);
        bad[0] = a;
        bad[1] = b; // not strictly increasing
        vm.expectRevert("unlock times must increase");
        new ReefTrancheVesting(IERC20(address(token)), beneficiary, 1, bad);

        vm.expectRevert("1 to 24 tranches");
        new ReefTrancheVesting(IERC20(address(token)), beneficiary, 1, new uint64[](25));
        vm.expectRevert("1 to 24 tranches");
        new ReefTrancheVesting(IERC20(address(token)), beneficiary, 1, new uint64[](0));
    }
}

// =====================================================================================
// Airdrop
// =====================================================================================

/// Builds a random Merkle list the same way OpenZeppelin's StandardMerkleTree does
/// (double-hashed leaves, sorted-pair nodes), then tries every way to claim, double-claim,
/// claim the wrong amount, burn listed tokens and claim late.
contract ReefAirdropFuzzTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    TestToken internal token;
    MockPresaleState internal presale;
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new TestToken("REEF", "REEF");
        presale = new MockPresaleState();
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    /// Root plus a proof for every leaf. An odd node at the end of a layer is carried up unchanged.
    function _tree(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = leaves.length;
        proofs = new bytes32[][](n);
        uint256[] memory pos = new uint256[](n);
        uint256[] memory plen = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            proofs[i] = new bytes32[](8);
            pos[i] = i;
        }
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            for (uint256 i = 0; i < n; i++) {
                uint256 sib = pos[i] ^ 1;
                if (sib < layer.length) proofs[i][plen[i]++] = layer[sib];
                pos[i] /= 2;
            }
            bytes32[] memory next = new bytes32[]((layer.length + 1) / 2);
            for (uint256 j = 0; j < next.length; j++) {
                next[j] = 2 * j + 1 < layer.length ? _hashPair(layer[2 * j], layer[2 * j + 1]) : layer[2 * j];
            }
            layer = next;
        }
        root = layer[0];
        for (uint256 i = 0; i < n; i++) {
            bytes32[] memory p = proofs[i];
            uint256 len = plen[i];
            assembly {
                mstore(p, len)
            }
        }
    }

    function testFuzz_airdropPaysOnlyTheList(uint256 seed, uint8 nRaw, uint256 extra, uint256 claimMask) public {
        uint256 n = bound(nRaw, 1, 40);
        address[] memory accts = new address[](n);
        uint256[] memory amts = new uint256[](n);
        bytes32[] memory leaves = new bytes32[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            accts[i] = address(uint160(uint256(keccak256(abi.encode(seed, "acct", i))) | 1 << 159));
            amts[i] = bound(uint256(keccak256(abi.encode(seed, "amt", i))), 1, 1e24);
            leaves[i] = _leaf(accts[i], amts[i]);
            total += amts[i];
        }
        (bytes32 root, bytes32[][] memory proofs) = _tree(leaves);
        uint256 deadline = block.timestamp + 90 days;
        ReefAirdrop drop = new ReefAirdrop(IERC20(address(token)), IReefPresaleState(address(presale)), root, total, deadline);
        assertEq(drop.merkleRoot(), root);
        extra = bound(extra, 0, 1e24);
        token.mint(address(drop), total + extra);

        // Closed until the pool is live.
        vm.expectRevert("pool not live yet");
        drop.claim(accts[0], amts[0], proofs[0]);
        presale.setFinalized(true);

        // Nothing can be burned before the deadline; any over-funding just waits for burnExpired.
        vm.expectRevert("claims still open");
        drop.burnExpired();

        uint256 claimedSum;
        for (uint256 i = 0; i < n; i++) {
            assertTrue(drop.isValid(accts[i], amts[i], proofs[i]), "valid proof rejected");
            // Wrong amount and wrong account must fail.
            vm.expectRevert("not on the list");
            drop.claim(accts[i], amts[i] + 1, proofs[i]);
            vm.expectRevert("not on the list");
            drop.claim(relayer, amts[i], proofs[i]);

            if ((claimMask >> (i % 256)) & 1 == 0) continue;
            vm.prank(relayer); // a third party submits it; the tokens must go to the listed wallet
            drop.claim(accts[i], amts[i], proofs[i]);
            claimedSum += amts[i];
            assertEq(token.balanceOf(accts[i]), amts[i], "wrong payout");
            vm.expectRevert("already claimed");
            drop.claim(accts[i], amts[i], proofs[i]);
            // Whatever is still owed stays in the contract.
            assertGe(token.balanceOf(address(drop)), drop.totalAllocated() - drop.totalClaimed(), "owed REEF missing");
            assertEq(drop.outstanding(), drop.totalAllocated() - drop.totalClaimed());
        }
        assertEq(drop.totalClaimed(), claimedSum);
        assertEq(token.balanceOf(relayer), 0, "relayer was paid");

        // After the deadline, claims close and the remainder can only go to the dead address.
        vm.warp(deadline);
        for (uint256 i = 0; i < n; i++) {
            if (drop.claimed(accts[i])) continue;
            vm.expectRevert("claims closed");
            drop.claim(accts[i], amts[i], proofs[i]);
            break;
        }
        uint256 left = token.balanceOf(address(drop));
        if (left > 0) {
            drop.burnExpired();
            assertEq(token.balanceOf(DEAD), left);
        }
        assertEq(token.balanceOf(address(drop)), 0);
        // Every REEF went either to a listed wallet or to the dead address.
        assertEq(claimedSum + token.balanceOf(DEAD), total + extra, "REEF went somewhere else");
    }
}

// =====================================================================================
// TWAP oracle
// =====================================================================================

contract ReefOracleFuzzTest is Test {
    TestToken internal t0;
    TestToken internal t1;
    ReefFactory internal factory;
    ReefRouter internal router;
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    function setUp() public {
        vm.warp(1_790_000_000);
        factory = new ReefFactory(address(this));
        router = new ReefRouter(address(factory), address(new WBDAG()));
        t0 = new TestToken("A", "A");
        t1 = new TestToken("B", "B");
        factory.createPair(address(t0), address(t1));
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? lp : trader;
            t0.mint(who, 1e36);
            t1.mint(who, 1e36);
            vm.startPrank(who);
            t0.approve(address(router), type(uint256).max);
            t1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seed(uint256 a, uint256 b) internal returns (ReefTWAPOracle o) {
        vm.prank(lp);
        router.addLiquidity(address(t0), address(t1), a, b, 0, 0, lp, block.timestamp);
        o = new ReefTWAPOracle(address(factory), address(t0), address(t1));
    }

    /// With a steady pool, the 24-hour average equals the pool price.
    function testFuzz_steadyPriceAverageMatchesPool(uint256 a, uint256 b, uint256 extraTime, uint256 amountIn) public {
        a = bound(a, 1e9, 1e30);
        b = bound(b, 1e9, 1e30);
        // consult() multiplies a UQ112x112 price by amountIn in 256 bits, so amountIn x price must
        // stay under about 2^144. Keep inside that; testFuzz_consultRevertsRatherThanWrapping covers the rest.
        uint256 ratio = (a > b ? a / b : b / a) + 1;
        amountIn = bound(amountIn, 1, (uint256(1) << 140) / ratio);
        ReefTWAPOracle o = _seed(a, b);

        vm.expectRevert("ReefTWAPOracle: PERIOD_NOT_ELAPSED");
        o.update();
        assertGt(o.secondsUntilNextUpdate(), 0);

        vm.warp(block.timestamp + 24 hours + bound(extraTime, 0, 30 days));
        assertEq(o.secondsUntilNextUpdate(), 0);
        o.update();

        (address tok0, ) = address(t0) < address(t1) ? (address(t0), address(t1)) : (address(t1), address(t0));
        (uint256 r0, uint256 r1) = tok0 == address(t0) ? (a, b) : (b, a);
        address other = tok0 == address(t0) ? address(t1) : address(t0);
        _close(o.consult(tok0, amountIn), (amountIn * r1) / r0, "token0 average off");
        _close(o.consult(other, amountIn), (amountIn * r0) / r1, "token1 average off");

        vm.expectRevert("ReefTWAPOracle: INVALID_TOKEN");
        o.consult(address(0xBEEF), 1);
        // A second update needs another full period.
        vm.expectRevert("ReefTWAPOracle: PERIOD_NOT_ELAPSED");
        o.update();
    }

    /// Within 1 part in a billion, plus 1 unit of rounding.
    function _close(uint256 actual, uint256 expected, string memory why) internal pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        assertLe(diff, expected / 1e9 + 1, why);
    }

    /// Outside that range, consult() must revert, never return a wrapped (wrong) number.
    function testFuzz_consultRevertsRatherThanWrapping(uint256 amountIn) public {
        ReefTWAPOracle o = _seed(1e30, 1e9); // one token priced 1e21x the other
        vm.warp(block.timestamp + 24 hours);
        o.update();
        (address tok0, address tok1) = address(t0) < address(t1) ? (address(t0), address(t1)) : (address(t1), address(t0));
        address dear = tok0 == address(t0) ? tok1 : tok0; // the token worth 1e21 of the other
        amountIn = bound(amountIn, 1, type(uint256).max);
        try o.consult(dear, amountIn) returns (uint256 out) {
            // When it answers, the answer is right.
            _close(out, amountIn > type(uint256).max / 1e21 ? out : amountIn * 1e21, "wrong value instead of a revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSignature("Panic(uint256)", 0x11), "unexpected revert");
            assertGt(amountIn, (uint256(1) << 143) / 1e21, "reverted inside the safe range");
        }
    }

    /// A price spike held for only the last few seconds of a window barely moves the average.
    function testFuzz_lastMomentSpikeBarelyMovesAverage(uint256 depth, uint256 spikeSecs, uint256 spikePct) public {
        depth = bound(depth, 1e18, 1e27);
        spikeSecs = bound(spikeSecs, 1, 60);
        spikePct = bound(spikePct, 10, 1000); // push 10% to 1000% of the pool in
        ReefTWAPOracle o = _seed(depth, depth); // price 1:1

        vm.warp(block.timestamp + 24 hours - spikeSecs);
        address[] memory path = new address[](2);
        path[0] = address(t0);
        path[1] = address(t1);
        vm.prank(trader);
        router.swapExactTokensForTokens((depth * spikePct) / 100, 0, path, trader, block.timestamp);
        vm.warp(block.timestamp + spikeSecs);
        o.update();

        // Spot price moved by up to ~120x, but the 24-hour average can move at most by the spike's
        // share of the window: (spike price - 1) * spikeSecs / 86400.
        uint256 avg1 = o.consult(address(t1), 1e18); // value of t1 in t0, which the spike raises
        (uint112 r0, uint112 r1, ) = factory.getPair(address(t0), address(t1)) == address(0)
            ? (uint112(0), uint112(0), uint32(0))
            : _reserves();
        uint256 spot = address(t0) < address(t1) ? (1e18 * uint256(r0)) / r1 : (1e18 * uint256(r1)) / r0;
        assertGt(spot, 1e18, "spike did not move spot");
        uint256 maxMove = ((spot - 1e18) * spikeSecs) / 86400 + 1e12;
        assertLe(avg1, 1e18 + maxMove, "average moved more than the spike's time share");
        assertGe(avg1, 1e18 - 1e12, "average fell below the steady price");
    }

    function _reserves() internal view returns (uint112, uint112, uint32) {
        (bool ok, bytes memory data) = factory.getPair(address(t0), address(t1)).staticcall(abi.encodeWithSignature("getReserves()"));
        require(ok);
        return abi.decode(data, (uint112, uint112, uint32));
    }
}
