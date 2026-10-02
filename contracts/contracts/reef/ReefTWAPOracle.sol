// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

/// @notice Minimal interface into a Reef pool (matches ReefPair / Uniswap V2's ABI shape).
interface IReefPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IReefFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice UQ112x112 fixed-point helper, same layout ReefPair already uses internally.
library FixedPoint {
    struct uq112x112 {
        uint224 _x;
    }

    // Divides a uq112x112 by a uint112, returning a uq112x112.
    function divUq112x112(uq112x112 memory self, uint112 divisor) internal pure returns (uq112x112 memory) {
        require(divisor > 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112(self._x / uint224(divisor));
    }

    // Decodes a uq112x112 into a uint (truncating the fractional part) scaled by 2**112.
    function decode144(uq112x112 memory self) internal pure returns (uint144) {
        return uint144(self._x >> 112);
    }

    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        return uq112x112(uint224(x) << 112);
    }
}

/// @title ReefTWAPOracle
/// @notice Time-weighted average price oracle for a single Reef pool, sampled over a fixed window.
/// @dev Anyone can call `update()`. It only records a new observation once `PERIOD` has elapsed
///      since the last one, so gas cost is paid by whoever happens to call it after the window
///      opens (a keeper, the frontend, or a user's own transaction) rather than needing infra
///      Reef has to run itself. Mirrors Uniswap V2's ExampleOracleSimple pattern, wired to
///      ReefPair's existing price0CumulativeLast / price1CumulativeLast accumulators.
contract ReefTWAPOracle {
    using FixedPoint for FixedPoint.uq112x112;

    uint256 public constant PERIOD = 24 hours;

    IReefPair public immutable pair;
    address public immutable token0;
    address public immutable token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast, uint32 blockTimestamp);

    constructor(address factory, address tokenA, address tokenB) {
        address pairAddress = IReefFactory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "ReefTWAPOracle: NO_PAIR");
        IReefPair _pair = IReefPair(pairAddress);
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();

        price0CumulativeLast = _pair.price0CumulativeLast();
        price1CumulativeLast = _pair.price1CumulativeLast();

        (, , uint32 reserveTimestamp) = _pair.getReserves();
        blockTimestampLast = reserveTimestamp;
    }

    /// @notice Refreshes the stored average price if at least PERIOD has elapsed since the last
    ///         update. Reverts if called too early, so a keeper can safely call this on a timer
    ///         without wasting gas on a no-op — check `secondsUntilNextUpdate()` first if unsure.
    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices();
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired (mod 2**32)

        require(timeElapsed >= PERIOD, "ReefTWAPOracle: PERIOD_NOT_ELAPSED");

        // price average = (cumulative_now - cumulative_then) / timeElapsed, still in UQ112x112 form
        unchecked {
            price0Average = FixedPoint.uq112x112(
                uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)
            );
            price1Average = FixedPoint.uq112x112(
                uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)
            );
        }

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;

        emit Updated(price0Cumulative, price1Cumulative, blockTimestamp);
    }

    /// @notice Converts `amountIn` of `token` into its TWAP-implied value in the other token,
    ///         using the average price from the most recently completed window.
    /// @dev Reverts if `update()` has never been called yet (no average exists).
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        if (token == token0) {
            amountOut = _mulDecode(price0Average, amountIn);
        } else {
            require(token == token1, "ReefTWAPOracle: INVALID_TOKEN");
            amountOut = _mulDecode(price1Average, amountIn);
        }
    }

    /// @notice How many seconds remain before `update()` can succeed again. Returns 0 if it's
    ///         already callable. Convenient for a keeper or the frontend to poll cheaply.
    function secondsUntilNextUpdate() external view returns (uint256) {
        (, , uint32 blockTimestamp) = currentCumulativePrices();
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed >= PERIOD) return 0;
        return PERIOD - timeElapsed;
    }

    /// @dev Reads the pair's live cumulative prices, extrapolating for the current block the way
    ///      ReefPair itself does internally, so a value is correct even if the pair hasn't had a
    ///      swap/mint/burn in this exact block.
    function currentCumulativePrices()
        public
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = uint32(block.timestamp % 2**32);
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 pairBlockTimestampLast) = pair.getReserves();
        if (pairBlockTimestampLast != blockTimestamp) {
            unchecked {
                uint32 timeElapsed = blockTimestamp - pairBlockTimestampLast;
                price0Cumulative += uint256(FixedPoint.encode(reserve1).divUq112x112(reserve0)._x) * timeElapsed;
                price1Cumulative += uint256(FixedPoint.encode(reserve0).divUq112x112(reserve1)._x) * timeElapsed;
            }
        }
    }

    function _mulDecode(FixedPoint.uq112x112 memory average, uint256 amountIn) private pure returns (uint256) {
        return (uint256(average._x) * amountIn) >> 112;
    }
}
