// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IReefPresaleState {
    function finalized() external view returns (bool);
}

/// @title REEF airdrop claim
/// @notice Pays out the published REEF airdrop list (first 1,000 Reef users, 7 Oct - 6 Nov 2026).
///         The list is fixed by a Merkle root at deployment and anyone can recompute it from the
///         published snapshot script and Reef's on-chain events.
///
///         - No owner, no admin, nothing can be changed after deployment.
///         - Claims open only once the REEF/BDAG pool is live (the presale has been finalized),
///           and close at `claimDeadline` (Thu 4 Feb 2027, 09:00 UTC+7).
///         - Each listed wallet can claim once. Anyone may submit a claim for a wallet, but the
///           REEF always goes to the listed wallet itself.
///         - REEF that is not on the list can be sent to the dead address at any time
///           (`burnUnallocated`). After the deadline, everything left goes to the dead
///           address (`burnExpired`). Neither path can ever send REEF to the team.
contract ReefAirdrop {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    IReefPresaleState public immutable presale;
    bytes32 public immutable merkleRoot;
    /// @notice Sum of every amount in the list.
    uint256 public immutable totalAllocated;
    uint256 public immutable claimDeadline;

    uint256 public totalClaimed;
    mapping(address => bool) public claimed;

    event Claimed(address indexed account, uint256 amount);
    event Burned(uint256 amount, bool expired);

    constructor(IERC20 _token, IReefPresaleState _presale, bytes32 _merkleRoot, uint256 _totalAllocated, uint256 _claimDeadline) {
        require(address(_token) != address(0) && address(_presale) != address(0), "zero address");
        require(_merkleRoot != bytes32(0), "empty root");
        require(_totalAllocated > 0, "nothing allocated");
        require(_claimDeadline > block.timestamp, "deadline passed");
        token = _token;
        presale = _presale;
        merkleRoot = _merkleRoot;
        totalAllocated = _totalAllocated;
        claimDeadline = _claimDeadline;
    }

    /// @notice True while claims are open: pool live and deadline not reached.
    function claimsOpen() public view returns (bool) {
        return presale.finalized() && block.timestamp < claimDeadline;
    }

    /// @notice Leaf format matches OpenZeppelin's StandardMerkleTree for ["address","uint256"].
    function leaf(address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function isValid(address account, uint256 amount, bytes32[] calldata proof) external view returns (bool) {
        return MerkleProof.verifyCalldata(proof, merkleRoot, leaf(account, amount));
    }

    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        require(presale.finalized(), "pool not live yet");
        require(block.timestamp < claimDeadline, "claims closed");
        require(!claimed[account], "already claimed");
        require(MerkleProof.verifyCalldata(proof, merkleRoot, leaf(account, amount)), "not on the list");
        claimed[account] = true;
        totalClaimed += amount;
        token.safeTransfer(account, amount);
        emit Claimed(account, amount);
    }

    /// @notice REEF held here beyond what the list can still claim. Sent only to the dead address.
    function unallocated() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 owed = totalAllocated - totalClaimed;
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Anyone can burn the REEF that no listed wallet can claim (for example if fewer
    ///         than 1,000 wallets qualified). Listed wallets' amounts are never touched.
    function burnUnallocated() external {
        uint256 amount = unallocated();
        require(amount > 0, "nothing to burn");
        token.safeTransfer(DEAD, amount);
        emit Burned(amount, false);
    }

    /// @notice After the deadline, anyone can send everything left (unclaimed + unallocated) to the dead address.
    function burnExpired() external {
        require(block.timestamp >= claimDeadline, "claims still open");
        uint256 amount = token.balanceOf(address(this));
        require(amount > 0, "nothing to burn");
        token.safeTransfer(DEAD, amount);
        emit Burned(amount, true);
    }
}
