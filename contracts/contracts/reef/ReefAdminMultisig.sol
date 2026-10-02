// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

/// @title ReefAdminMultisig
/// @notice A small, self-contained N-of-M multisig, purpose-built to hold Reef's `feeToSetter`
///         role (the one privileged permission in the whole protocol — it can set `feeTo` and
///         reassign `feeToSetter` itself). Deliberately minimal: no modules, no upgradability,
///         no external dependencies — every line here is auditable in one sitting.
///
/// @dev Pattern: owners submit a proposed call (to, value, data), other owners confirm it, and
///      once `required` confirmations are reached, anyone can execute it. The multisig can only
///      change its own owners/threshold by having itself as the `to` of a confirmed transaction
///      (`onlyWallet`) — there is no back-door admin function that bypasses the confirmation flow.
contract ReefAdminMultisig {
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);
    event Deposit(address indexed sender, uint256 value);
    event Submission(uint256 indexed txId, address indexed submitter);
    event Confirmation(uint256 indexed txId, address indexed owner);
    event Revocation(uint256 indexed txId, address indexed owner);
    event Executed(uint256 indexed txId);
    event ExecutionFailed(uint256 indexed txId);

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;

    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmed;
    mapping(uint256 => uint256) public confirmationCount;
    uint256 public transactionCount;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not an owner");
        _;
    }
    modifier onlyWallet() {
        require(msg.sender == address(this), "only via multisig confirmation");
        _;
    }
    modifier txExists(uint256 txId) {
        require(transactions[txId].to != address(0) || transactions[txId].data.length > 0 || transactions[txId].value > 0 || txId < transactionCount, "no such tx");
        _;
    }
    modifier notExecuted(uint256 txId) {
        require(!transactions[txId].executed, "already executed");
        _;
    }

    constructor(address[] memory _owners, uint256 _required) {
        require(_owners.length > 0, "need at least one owner");
        require(_required > 0 && _required <= _owners.length, "invalid required count");
        for (uint256 i = 0; i < _owners.length; i++) {
            address o = _owners[i];
            require(o != address(0), "zero address owner");
            require(!isOwner[o], "duplicate owner");
            isOwner[o] = true;
            owners.push(o);
            emit OwnerAdded(o);
        }
        required = _required;
        emit RequirementChanged(_required);
    }

    receive() external payable {
        if (msg.value > 0) emit Deposit(msg.sender, msg.value);
    }

    // ---------- Core flow: submit -> confirm -> execute ----------

    function submitTransaction(address to, uint256 value, bytes calldata data) external onlyOwner returns (uint256 txId) {
        txId = transactionCount++;
        transactions[txId] = Transaction({ to: to, value: value, data: data, executed: false });
        emit Submission(txId, msg.sender);
        _confirm(txId, msg.sender);
    }

    function confirmTransaction(uint256 txId) external onlyOwner notExecuted(txId) {
        require(txId < transactionCount, "no such tx");
        require(!confirmed[txId][msg.sender], "already confirmed");
        _confirm(txId, msg.sender);
    }

    function _confirm(uint256 txId, address owner) private {
        confirmed[txId][owner] = true;
        confirmationCount[txId] += 1;
        emit Confirmation(txId, owner);
    }

    function revokeConfirmation(uint256 txId) external onlyOwner notExecuted(txId) {
        require(confirmed[txId][msg.sender], "not confirmed by you");
        confirmed[txId][msg.sender] = false;
        confirmationCount[txId] -= 1;
        emit Revocation(txId, msg.sender);
    }

    /// @notice Executes a transaction once it has enough confirmations. Anyone can call this
    ///         (not just owners) — the security is in the confirmation threshold, not in who
    ///         triggers execution. Marks executed BEFORE the external call (checks-effects-
    ///         interactions) so a reentrant call can't run it twice.
    function executeTransaction(uint256 txId) external notExecuted(txId) {
        require(txId < transactionCount, "no such tx");
        require(confirmationCount[txId] >= required, "not enough confirmations");
        Transaction storage t = transactions[txId];
        t.executed = true;
        (bool ok, ) = t.to.call{ value: t.value }(t.data);
        if (ok) {
            emit Executed(txId);
        } else {
            // Revert the executed flag so it can be retried (e.g. after funding the wallet)
            t.executed = false;
            emit ExecutionFailed(txId);
        }
    }

    // ---------- Self-administration (only via a confirmed transaction targeting this contract) ----------

    function addOwner(address owner) external onlyWallet {
        require(owner != address(0), "zero address");
        require(!isOwner[owner], "already an owner");
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }

    function removeOwner(address owner) external onlyWallet {
        require(isOwner[owner], "not an owner");
        require(owners.length - 1 >= required, "would drop below required threshold");
        isOwner[owner] = false;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(owner);
    }

    function changeRequirement(uint256 _required) external onlyWallet {
        require(_required > 0 && _required <= owners.length, "invalid required count");
        required = _required;
        emit RequirementChanged(_required);
    }

    // ---------- Views ----------

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function isConfirmedBy(uint256 txId, address owner) external view returns (bool) {
        return confirmed[txId][owner];
    }
}
