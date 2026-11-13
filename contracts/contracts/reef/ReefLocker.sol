// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ReefLocker ("Reef Lock")
/// @notice A public time-lock for ERC-20 tokens on BlockDAG, mainly Reef LP tokens and team allocations.
///         Anyone can lock any amount of any token until a date of their choosing (30 days to 10 years).
///         Only the lock's owner can take the tokens out, and only after the unlock date. Nobody else
///         can, including the admin: the admin can only set the creation fee (capped) and where it goes.
/// @dev    No upgrades, no pause, no admin withdrawal, no way to shorten a lock. Tokens that charge a fee
///         on transfer are credited with the amount that actually arrived. Rebasing tokens (balances that
///         change on their own) are not supported; see ReefLocker.REVIEW.md.
contract ReefLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        address owner;      // who can withdraw after unlockTime, and extend or hand over the lock
        uint256 amount;     // tokens actually received
        uint64 lockedAt;
        uint64 unlockTime;
        bool withdrawn;
    }

    uint256 public constant MIN_LOCK = 30 days;
    uint256 public constant MAX_LOCK = 3650 days;
    uint256 public constant MAX_FEE = 100_000 ether; // ceiling on the creation fee, in BDAG (fixed forever)

    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    uint256 public fee; // BDAG (wei) paid with each new lock

    Lock[] private _locks;
    mapping(address => uint256[]) private _tokenLocks;
    mapping(address => uint256[]) private _ownerLocks;
    /// @notice Tokens of each kind currently held for open locks.
    mapping(address => uint256) public totalLocked;

    event Locked(uint256 indexed id, address indexed token, address indexed owner, uint256 amount, uint64 unlockTime);
    event Extended(uint256 indexed id, uint64 oldUnlockTime, uint64 newUnlockTime);
    event LockOwnerChanged(uint256 indexed id, address indexed from, address indexed to);
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount);
    event FeeChanged(uint256 fee);
    event FeeRecipientChanged(address feeRecipient);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminChanged(address indexed admin);

    error ZeroAddress();
    error ZeroAmount();
    error WrongFee();
    error BadUnlockTime();
    error NotLockOwner();
    error StillLocked();
    error AlreadyWithdrawn();
    error NothingReceived();
    error FeeTooHigh();
    error NotAdmin();
    error FeeTransferFailed();
    error NoSuchLock();

    constructor(address admin_, address feeRecipient_, uint256 fee_) {
        if (admin_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        admin = admin_;
        feeRecipient = feeRecipient_;
        fee = fee_;
        emit AdminChanged(admin_);
        emit FeeRecipientChanged(feeRecipient_);
        emit FeeChanged(fee_);
    }

    // ------------------------------------------------------------------ locking

    /// @notice Lock `amount` of `token` until `unlockTime`; `owner_` can withdraw after that. Send exactly `fee` BDAG.
    /// @dev Approve this contract for `amount` first. Returns the new lock's id.
    function lock(address token, uint256 amount, uint64 unlockTime, address owner_) external payable nonReentrant returns (uint256 id) {
        if (token == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (msg.value != fee) revert WrongFee();
        if (unlockTime < block.timestamp + MIN_LOCK || unlockTime > block.timestamp + MAX_LOCK) revert BadUnlockTime();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        id = _locks.length;
        _locks.push(Lock(token, owner_, received, uint64(block.timestamp), unlockTime, false));
        _tokenLocks[token].push(id);
        _ownerLocks[owner_].push(id);
        totalLocked[token] += received;
        emit Locked(id, token, owner_, received, unlockTime);

        if (msg.value > 0) {
            (bool ok, ) = feeRecipient.call{value: msg.value}("");
            if (!ok) revert FeeTransferFailed();
        }
    }

    /// @notice Push a lock's unlock date later. It can never be brought forward.
    function extend(uint256 id, uint64 newUnlockTime) external {
        Lock storage l = _get(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (newUnlockTime <= l.unlockTime || newUnlockTime > block.timestamp + MAX_LOCK) revert BadUnlockTime();
        emit Extended(id, l.unlockTime, newUnlockTime);
        l.unlockTime = newUnlockTime;
    }

    /// @notice Hand a lock to a new owner (e.g. a multisig). The tokens stay locked until the same date.
    function transferLockOwnership(uint256 id, address newOwner) external {
        Lock storage l = _get(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (newOwner == address(0)) revert ZeroAddress();
        emit LockOwnerChanged(id, l.owner, newOwner);
        l.owner = newOwner;
        _ownerLocks[newOwner].push(id);
    }

    /// @notice After the unlock date, the lock's owner takes the tokens back.
    function withdraw(uint256 id) external nonReentrant {
        Lock storage l = _get(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked();
        l.withdrawn = true;
        totalLocked[l.token] -= l.amount;
        emit Withdrawn(id, l.owner, l.amount);
        IERC20(l.token).safeTransfer(l.owner, l.amount);
    }

    // ------------------------------------------------------------------ views

    function lockCount() external view returns (uint256) { return _locks.length; }

    function getLock(uint256 id) external view returns (Lock memory) { return _get(id); }

    /// @notice Every lock id ever created for `token` (open and withdrawn).
    function locksForToken(address token) external view returns (uint256[] memory) { return _tokenLocks[token]; }

    /// @notice Every lock id `owner_` has owned (check getLock(id).owner for the current owner).
    function locksForOwner(address owner_) external view returns (uint256[] memory) { return _ownerLocks[owner_]; }

    /// @notice For labels: how much of `token` is locked right now, the earliest open unlock date, and the open lock count.
    /// @dev Walks every lock for the token; meant for off-chain reads.
    function lockedSummary(address token) external view returns (uint256 amount, uint64 earliestUnlock, uint256 openLocks) {
        uint256[] storage ids = _tokenLocks[token];
        for (uint256 i; i < ids.length; ++i) {
            Lock storage l = _locks[ids[i]];
            if (l.withdrawn) continue;
            amount += l.amount;
            ++openLocks;
            if (earliestUnlock == 0 || l.unlockTime < earliestUnlock) earliestUnlock = l.unlockTime;
        }
    }

    // ------------------------------------------------------------------ admin (fee only)

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        fee = newFee;
        emit FeeChanged(newFee);
    }

    function setFeeRecipient(address newRecipient) external onlyAdmin {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientChanged(newRecipient);
    }

    /// @notice Two-step admin handover: the new admin must accept.
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

    function _get(uint256 id) private view returns (Lock storage) {
        if (id >= _locks.length) revert NoSuchLock();
        return _locks[id];
    }
}
