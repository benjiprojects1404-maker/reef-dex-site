// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReefLocker} from "../../contracts/reef/ReefLocker.sol";

contract LockerTestToken is ERC20 {
    constructor() ERC20("Reef LP", "REEF-LP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Drives the locker with random users, amounts, dates and time jumps, and keeps its own ledger of
/// what each open lock is owed and when it unlocks, so the invariants can compare against it.
contract LockerHandler is Test {
    ReefLocker public locker;
    LockerTestToken public token;
    address[] public users;
    uint256 public constant FEE = 1 ether;

    uint256 public ghostOpen;          // sum of amounts of locks not yet withdrawn
    uint256 public ghostWithdrawn;     // total paid out by withdraw()
    uint256 public ghostDeposited;     // total locked in
    uint256 public earlyWithdrawals;   // withdrawals that happened before the unlock date (must stay 0)
    uint256 public foreignWithdrawals; // withdrawals by someone other than the lock owner (must stay 0)

    constructor(ReefLocker locker_, LockerTestToken token_) {
        locker = locker_;
        token = token_;
        for (uint256 i; i < 4; ++i) {
            address u = address(uint160(0xA11CE + i));
            users.push(u);
            token.mint(u, 1e30);
            vm.deal(u, 1e24);
            vm.prank(u);
            token.approve(address(locker_), type(uint256).max);
        }
    }

    function lock(uint256 who, uint256 forWho, uint256 amount, uint256 secs) external {
        address u = users[who % users.length];
        address owner = users[forWho % users.length];
        amount = bound(amount, 1, 1e24);
        secs = bound(secs, 30 days, 3650 days);
        vm.prank(u);
        locker.lock{value: FEE}(address(token), amount, uint64(block.timestamp + secs), owner);
        ghostOpen += amount;
        ghostDeposited += amount;
    }

    function withdraw(uint256 who, uint256 idSeed) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        address caller = users[who % users.length];
        ReefLocker.Lock memory l = locker.getLock(id);
        vm.prank(caller);
        try locker.withdraw(id) {
            if (block.timestamp < l.unlockTime) ++earlyWithdrawals;
            if (caller != l.owner) ++foreignWithdrawals;
            ghostOpen -= l.amount;
            ghostWithdrawn += l.amount;
        } catch {}
    }

    function extend(uint256 who, uint256 idSeed, uint256 extra) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        ReefLocker.Lock memory l = locker.getLock(id);
        extra = bound(extra, 1, 365 days);
        vm.prank(users[who % users.length]);
        try locker.extend(id, l.unlockTime + uint64(extra)) {} catch {}
    }

    function handOver(uint256 who, uint256 idSeed, uint256 toSeed) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        vm.prank(users[who % users.length]);
        try locker.transferLockOwnership(idSeed % n, users[toSeed % users.length]) {} catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 400 days));
    }
}

contract ReefLockerInvariantTest is Test {
    ReefLocker locker;
    LockerTestToken token;
    LockerHandler handler;
    address treasury = address(0x7EA5);

    function setUp() public {
        locker = new ReefLocker(address(this), treasury, 1 ether);
        token = new LockerTestToken();
        handler = new LockerHandler(locker, token);
        targetContract(address(handler));
    }

    /// The locker holds exactly what its open locks are owed: no more, no less.
    function invariant_balanceEqualsOpenLocks() public view {
        assertEq(token.balanceOf(address(locker)), handler.ghostOpen());
        assertEq(locker.totalLocked(address(token)), handler.ghostOpen());
    }

    /// Nothing leaves except through a valid withdraw.
    function invariant_conservation() public view {
        assertEq(handler.ghostDeposited(), handler.ghostOpen() + handler.ghostWithdrawn());
    }

    /// No withdrawal ever happened before its unlock date, or by anyone but the lock's owner.
    function invariant_noEarlyOrForeignWithdrawals() public view {
        assertEq(handler.earlyWithdrawals(), 0);
        assertEq(handler.foreignWithdrawals(), 0);
    }

    /// lockedSummary agrees with the ledger.
    function invariant_summaryMatches() public view {
        (uint256 amount, , ) = locker.lockedSummary(address(token));
        assertEq(amount, handler.ghostOpen());
    }

    /// Fees only ever go to the fee recipient; the locker never keeps BDAG.
    function invariant_lockerHoldsNoBDAG() public view {
        assertEq(address(locker).balance, 0);
    }
}
