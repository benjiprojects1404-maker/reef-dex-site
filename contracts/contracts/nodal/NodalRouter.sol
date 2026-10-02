// SPDX-License-Identifier: MIT
// Pinned to an exact patch, not a floating ^0.8.20 range: some early 0.8.20.x
// patches have known compiler bugs (see Slither's solc-version detector / the
// Solidity bugs list). Pinning guarantees whoever compiles this gets the same
// bytecode we tested, on a patch without those known issues.
pragma solidity 0.8.24;

/**
 * NodalRouter
 * ============================================================================
 * Aggregator/router contract for Nodal, built for BlockDAG (chain ID 1404).
 *
 * READ BEFORE DEPLOYING
 * ----------------------------------------------------------------------------
 * 1. This assumes every registered DEX exposes a Uniswap V2-style router
 *    interface: getAmountsOut / swapExactTokensForTokens /
 *    swapExactETHForTokens / swapExactTokensForETH. Confirm each DEX's actual
 *    router ABI before registering it. If a source uses a different
 *    interface (V3-style concentrated liquidity, a custom AMM, etc.), quoting and swapping against that source will revert
 *    until this contract is adapted to match it.
 *
 * 2. No router or token addresses are hardcoded anywhere in this file. Once
 *    deployed, register each DEX's real router address yourself with
 *    registerSource() — take those addresses from each DEX's own official
 *    docs/deployment records, not guessed from an explorer.
 *
 * 3. This contract has NOT been audited. Do not point it at real user funds
 *    until it has been reviewed by a third party.
 *
 * 4. Ownership is a single key (OpenZeppelin Ownable). The owner can change
 *    the fee (bounded by MAX_FEE_BPS) and the treasury address. Before real
 *    usage, transfer ownership to a multisig or timelock rather than leaving
 *    it on one EOA.
 *
 * 5. Native BDAG swaps (swapExactBDAGForTokens / swapExactTokensForBDAG)
 *    assume the target DEX router wraps native BDAG the same way Uniswap V2
 *    routers wrap ETH — i.e. path[0] or path[last] must be that DEX's
 *    wrapped-native token address. The frontend is responsible for building
 *    that path correctly; this contract just forwards it.
 * ============================================================================
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDexRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract NodalRouter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on the routing fee. The owner can never set feeBps above this,
    /// no matter what — this bound is not itself owner-adjustable.
    uint16 public constant MAX_FEE_BPS = 100; // 1.00%

    /// @notice Current routing fee in basis points (100 = 1.00%). Starts at 0.15%.
    uint16 public feeBps = 15;

    /// @notice Address that receives the routing fee on every swap.
    address public treasury;

    /// @notice Optional per-token cap on amountIn for a single swap, in that token's own
    /// smallest unit. 0 = no cap set for that token (the default — unrestricted). This is
    /// deliberately NOT a dollar-value cap: the contract has no price oracle by design (same
    /// reasoning as keeping quoting oracle-free elsewhere), so "cap deposits at $500" has to
    /// be approximated per-token by the owner rather than enforced automatically in USD terms.
    /// address(0) is used as the key for native BDAG's cap.
    mapping(address => uint256) public maxAmountIn;

    event MaxAmountInUpdated(address indexed token, uint256 oldCap, uint256 newCap);

    struct Source {
        address router;
        string name;
        bool active;
    }

    mapping(bytes32 => Source) public sources;
    bytes32[] public sourceIds;

    event SourceRegistered(bytes32 indexed id, address router, string name);
    event SourceStatusChanged(bytes32 indexed id, bool active);
    event FeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event SwapExecuted(
        address indexed user,
        bytes32 indexed sourceId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 grossAmountOut,
        uint256 fee,
        uint256 netAmountOut
    );

    constructor(address _treasury) Ownable(msg.sender) {
        require(_treasury != address(0), "treasury=0");
        treasury = _treasury;
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    /// @notice Register (or update) a liquidity source. `id` is any stable identifier
    /// you choose off-chain, e.g. keccak256("blockdag-native-swap").
    function registerSource(bytes32 id, address router, string calldata name) external onlyOwner {
        require(router != address(0), "router=0");
        if (sources[id].router == address(0)) {
            sourceIds.push(id);
        }
        sources[id] = Source(router, name, true);
        emit SourceRegistered(id, router, name);
    }

    function setSourceActive(bytes32 id, bool active) external onlyOwner {
        require(sources[id].router != address(0), "unknown source");
        sources[id].active = active;
        emit SourceStatusChanged(id, active);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "treasury=0");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Emergency stop: blocks all new swaps (quoting still works — quoteAll/quote
    /// stay callable while paused, since they're read-only and useful for monitoring).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set a per-transaction cap on how much of `token` can be swapped in at once.
    /// Pass address(0) to cap native BDAG. 0 = uncapped for that token.
    function setMaxAmountIn(address token, uint256 newCap) external onlyOwner {
        emit MaxAmountInUpdated(token, maxAmountIn[token], newCap);
        maxAmountIn[token] = newCap;
    }

    function allSourceIds() external view returns (bytes32[] memory) {
        return sourceIds;
    }

    // ------------------------------------------------------------------
    // Quoting (view-only, no gas to call off-chain)
    // ------------------------------------------------------------------

    /// @notice Quote a single source.
    function quote(bytes32 sourceId, uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256 grossOut, uint256 fee, uint256 netOut)
    {
        Source memory s = sources[sourceId];
        require(s.router != address(0) && s.active, "source unavailable");
        uint256[] memory amounts = IDexRouter(s.router).getAmountsOut(amountIn, path);
        grossOut = amounts[amounts.length - 1];
        fee = (grossOut * feeBps) / 10000;
        netOut = grossOut - fee;
    }

    /// @notice Quote every registered source in one call, so a frontend can rank them
    /// without firing off one RPC call per source. Sources that revert (no pool for this
    /// path, paused, etc.) come back as zero rather than reverting the whole call.
    function quoteAll(uint256 amountIn, address[] calldata path)
        external
        view
        returns (bytes32[] memory ids, uint256[] memory grossOuts, uint256[] memory fees, uint256[] memory netOuts)
    {
        uint256 n = sourceIds.length;
        ids = new bytes32[](n);
        grossOuts = new uint256[](n);
        fees = new uint256[](n);
        netOuts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            bytes32 id = sourceIds[i];
            ids[i] = id;
            Source memory s = sources[id];
            if (!s.active) continue;

            // Reviewed: this is a view function called off-chain for quoting, not a
            // state-changing transaction — an external call per source here costs no
            // gas to the caller and carries none of the reentrancy/DoS risk the
            // calls-loop detector is meant to catch in transactional code.
            // slither-disable-next-line calls-loop
            try IDexRouter(s.router).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
                uint256 gross = amounts[amounts.length - 1];
                uint256 fee = (gross * feeBps) / 10000;
                grossOuts[i] = gross;
                fees[i] = fee;
                netOuts[i] = gross - fee;
            } catch {
                // leave as zero — this source can't quote this path right now
            }
        }
    }

    // ------------------------------------------------------------------
    // Swapping
    // ------------------------------------------------------------------

    /// @dev Reverts if `amountIn` exceeds the configured cap for `token` (address(0) = native
    /// BDAG). A cap of 0 means uncapped, matching setMaxAmountIn's documented semantics.
    function _enforceCap(address token, uint256 amountIn) private view {
        uint256 cap = maxAmountIn[token];
        require(cap == 0 || amountIn <= cap, "exceeds per-tx cap");
    }

    /// @notice ERC20 -> ERC20 swap routed through a specific registered source.
    /// Caller must have approved this contract for `amountIn` of path[0] beforehand.
    function swapExactTokensForTokens(
        bytes32 sourceId,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 netAmountOut) {
        Source memory s = sources[sourceId];
        require(s.router != address(0) && s.active, "source unavailable");
        require(path.length >= 2, "bad path");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        _enforceCap(tokenIn, amountIn);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(s.router, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        // Reviewed: output is measured by balance delta, not the router's returned
        // amounts array — deliberately, since balance diffing is safe even against a
        // router that returns an incorrect amounts array, whereas trusting the
        // return value directly would not be.
        // slither-disable-next-line unused-return
        IDexRouter(s.router).swapExactTokensForTokens(amountIn, 0, path, address(this), deadline);
        uint256 grossAmountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        netAmountOut = _settleTokenOut(sourceId, tokenIn, tokenOut, amountIn, grossAmountOut, minNetAmountOut);
    }

    /// @notice Native BDAG -> ERC20. Send BDAG as msg.value. `path[0]` must be the
    /// target DEX's wrapped-native token address (its own WETH-equivalent).
    function swapExactBDAGForTokens(
        bytes32 sourceId,
        uint256 minNetAmountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 netAmountOut) {
        Source memory s = sources[sourceId];
        require(s.router != address(0) && s.active, "source unavailable");
        require(msg.value > 0, "no value sent");
        require(path.length >= 2, "bad path");
        _enforceCap(address(0), msg.value);

        address tokenOut = path[path.length - 1];

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        // Reviewed: see the matching note in swapExactTokensForTokens — balance-diff
        // by design, not an oversight.
        // slither-disable-next-line unused-return
        IDexRouter(s.router).swapExactETHForTokens{value: msg.value}(0, path, address(this), deadline);
        uint256 grossAmountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        netAmountOut = _settleTokenOut(sourceId, address(0), tokenOut, msg.value, grossAmountOut, minNetAmountOut);
    }

    /// @notice ERC20 -> native BDAG. `path[last]` must be the target DEX's
    /// wrapped-native token address.
    function swapExactTokensForBDAG(
        bytes32 sourceId,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 netAmountOut) {
        Source memory s = sources[sourceId];
        require(s.router != address(0) && s.active, "source unavailable");
        require(path.length >= 2, "bad path");

        address tokenIn = path[0];
        _enforceCap(tokenIn, amountIn);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(s.router, amountIn);

        uint256 balBefore = address(this).balance;
        // Reviewed: see the matching note in swapExactTokensForTokens — balance-diff
        // by design, not an oversight.
        // slither-disable-next-line unused-return
        IDexRouter(s.router).swapExactTokensForETH(amountIn, 0, path, address(this), deadline);
        uint256 grossAmountOut = address(this).balance - balBefore;

        netAmountOut = _settleNativeOut(sourceId, tokenIn, amountIn, grossAmountOut, minNetAmountOut);
    }

    /// @dev Shared settlement for swaps whose output is an ERC20 token: computes the fee,
    /// pays the treasury and the user, and emits the event. Pulled out of the swap
    /// functions themselves to keep their local-variable count low enough for the
    /// default (non-IR) Solidity codegen — inlining this logic back into the callers
    /// reintroduces a "stack too deep" compile error.
    function _settleTokenOut(
        bytes32 sourceId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 grossAmountOut,
        uint256 minNetAmountOut
    ) private returns (uint256 netAmountOut) {
        uint256 fee = (grossAmountOut * feeBps) / 10000;
        netAmountOut = grossAmountOut - fee;
        require(netAmountOut >= minNetAmountOut, "slippage");

        if (fee > 0) IERC20(tokenOut).safeTransfer(treasury, fee);
        IERC20(tokenOut).safeTransfer(msg.sender, netAmountOut);

        emit SwapExecuted(msg.sender, sourceId, tokenIn, tokenOut, amountIn, grossAmountOut, fee, netAmountOut);
    }

    /// @dev Shared settlement for swaps whose output is native BDAG. See _settleTokenOut.
    function _settleNativeOut(
        bytes32 sourceId,
        address tokenIn,
        uint256 amountIn,
        uint256 grossAmountOut,
        uint256 minNetAmountOut
    ) private returns (uint256 netAmountOut) {
        uint256 fee = (grossAmountOut * feeBps) / 10000;
        netAmountOut = grossAmountOut - fee;
        require(netAmountOut >= minNetAmountOut, "slippage");

        if (fee > 0) {
            // Reviewed: `treasury` is an owner-set contract address, not caller-controlled.
            // slither-disable-next-line arbitrary-send-eth
            (bool sentFee, ) = payable(treasury).call{value: fee}("");
            require(sentFee, "fee transfer failed");
        }
        // Reviewed: paying msg.sender their own trade proceeds, not an arbitrary address.
        // slither-disable-next-line arbitrary-send-eth
        (bool sentUser, ) = payable(msg.sender).call{value: netAmountOut}("");
        require(sentUser, "payout failed");

        emit SwapExecuted(msg.sender, sourceId, tokenIn, address(0), amountIn, grossAmountOut, fee, netAmountOut);
    }

    // ------------------------------------------------------------------
    // Safety / rescue
    // ------------------------------------------------------------------

    /// @dev Accepts plain BDAG transfers (e.g. leftover dust from a swap).
    receive() external payable {}

    /// @notice Owner-only rescue for tokens mistakenly sent directly to this contract
    /// (not funds mid-swap — those never rest here longer than one transaction).
    /// Emits an event so any use of this is publicly auditable on-chain.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueBDAG(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        emit Rescued(address(0), to, amount);
        // Reviewed: `to` is an owner-supplied argument (onlyOwner-gated), not
        // attacker-controlled input, so this is not an arbitrary-recipient send.
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool sent, ) = payable(to).call{value: amount}("");
        require(sent, "rescue failed");
    }
}
