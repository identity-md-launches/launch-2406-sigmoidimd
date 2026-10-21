// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedSupplyERC20} from "./FixedSupplyERC20.sol";
import {SigmoidIMD} from "./SigmoidIMD.sol";

/// @title SigmoidLaunchpad
/// @notice Launches fair-launch tokens on Uniswap v4: deploys a fixed-supply token (1,000,000,000 at 18
/// decimals), opens its IMD pool with the `SigmoidIMD` hook attached and a dynamic LP fee, and seeds the whole
/// supply as single-sided liquidity on the token side of the opening price.
///
/// The liquidity position belongs to the launchpad and can never be withdrawn: launched liquidity is locked for
/// good. LP fees earned by the position can be collected by the launch's creator with `collectFees`.
contract SigmoidLaunchpad is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error NotPoolManager();
    error ZeroAddress();
    error NotCreator();
    error UnknownLaunch();
    error RangeNotSingleSided();
    error UnexpectedPairDelta(int128 amount);
    error ZeroLiquidity();

    event Launched(
        uint256 indexed launchId,
        address indexed token,
        PoolId indexed poolId,
        address creator,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event FeesCollected(uint256 indexed launchId, address indexed creator, uint256 amount0, uint256 amount1);

    /// @notice Tick spacing of every launched pool.
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    SigmoidIMD public immutable hook;

    struct LaunchInfo {
        address token;
        address creator;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    LaunchInfo[] internal _launches;

    enum Action {
        Seed,
        Collect
    }

    constructor(IPoolManager poolManager_, SigmoidIMD hook_) {
        if (address(poolManager_) == address(0) || address(hook_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        hook = hook_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    function launches(uint256 launchId) external view returns (LaunchInfo memory) {
        if (launchId >= _launches.length) revert UnknownLaunch();
        return _launches[launchId];
    }

    /// @notice Deploys a new token, opens its IMD pool on the hook and seeds the full supply single-sided.
    /// @param name The token's name.
    /// @param symbol The token's symbol.
    /// @param sqrtPriceX96 The opening sqrt price of the pool (currency1 per currency0, Q64.96).
    /// @param tickLower Lower tick of the seeded range (multiple of `TICK_SPACING`).
    /// @param tickUpper Upper tick of the seeded range (multiple of `TICK_SPACING`).
    /// @dev The range must lie entirely on the token side of the opening price: at or above it when the token is
    /// currency0, at or below it when the token is currency1. Which side that is depends on how the new token's
    /// address sorts against IMD. Callers predict the token address (CREATE from this contract's nonce) or
    /// simulate the call first and pass the price and ticks for the side that results.
    function launch(
        string calldata name,
        string calldata symbol,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256 launchId, address token, PoolKey memory key) {
        token = address(new FixedSupplyERC20(name, symbol));
        bool tokenIs0;
        (key, tokenIs0) = _poolKey(token);
        poolManager.initialize(key, sqrtPriceX96);

        uint128 liquidity =
            _singleSidedLiquidity(tokenIs0, sqrtPriceX96, tickLower, tickUpper, IERC20(token).balanceOf(address(this)));

        launchId = _launches.length;
        _launches.push(
            LaunchInfo({
                token: token,
                creator: msg.sender,
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity
            })
        );

        poolManager.unlock(abi.encode(Action.Seed, launchId, address(0)));

        // Rounding can leave a few wei of the supply unseeded; they go to the creator.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(msg.sender, dust);

        _emitLaunched(launchId, sqrtPriceX96);
    }

    /// @notice The pool key a token launched here gets: paired with IMD, dynamic fee, `TICK_SPACING`, this hook.
    function _poolKey(address token) internal view returns (PoolKey memory key, bool tokenIs0) {
        Currency pair = hook.pairCurrency();
        tokenIs0 = token < Currency.unwrap(pair);
        key = PoolKey({
            currency0: tokenIs0 ? Currency.wrap(token) : pair,
            currency1: tokenIs0 ? pair : Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Liquidity that places `amount` of the token in [tickLower, tickUpper] with none of the pair currency.
    function _singleSidedLiquidity(
        bool tokenIs0,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tokenIs0) {
            if (sqrtLower < sqrtPriceX96) revert RangeNotSingleSided();
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount);
        } else {
            if (sqrtUpper > sqrtPriceX96) revert RangeNotSingleSided();
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
        }
        if (liquidity == 0) revert ZeroLiquidity();
    }

    function _emitLaunched(uint256 launchId, uint160 sqrtPriceX96) internal {
        LaunchInfo storage info = _launches[launchId];
        emit Launched(
            launchId,
            info.token,
            info.key.toId(),
            info.creator,
            sqrtPriceX96,
            info.tickLower,
            info.tickUpper,
            info.liquidity
        );
    }

    /// @notice Collects the LP fees the launch's position has earned and sends them to the creator.
    function collectFees(uint256 launchId) external returns (uint256 amount0, uint256 amount1) {
        if (launchId >= _launches.length) revert UnknownLaunch();
        LaunchInfo storage info = _launches[launchId];
        if (msg.sender != info.creator) revert NotCreator();
        bytes memory result = poolManager.unlock(abi.encode(Action.Collect, launchId, msg.sender));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        emit FeesCollected(launchId, msg.sender, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (Action action, uint256 launchId, address recipient) = abi.decode(data, (Action, uint256, address));
        LaunchInfo storage info = _launches[launchId];

        if (action == Action.Seed) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                info.key,
                ModifyLiquidityParams({
                    tickLower: info.tickLower,
                    tickUpper: info.tickUpper,
                    liquidityDelta: int256(uint256(info.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            bool tokenIs0 = Currency.unwrap(info.key.currency0) == info.token;
            int128 tokenDelta = tokenIs0 ? delta.amount0() : delta.amount1();
            int128 pairDelta = tokenIs0 ? delta.amount1() : delta.amount0();
            if (pairDelta != 0) revert UnexpectedPairDelta(pairDelta);
            if (tokenDelta < 0) _pay(Currency.wrap(info.token), uint256(uint128(-tokenDelta)));
            return "";
        }

        // Collect: a zero liquidity change pays out the position's accrued fees.
        (, BalanceDelta fees) = poolManager.modifyLiquidity(
            info.key,
            ModifyLiquidityParams({
                tickLower: info.tickLower, tickUpper: info.tickUpper, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );
        uint256 amount0 = fees.amount0() > 0 ? uint256(uint128(fees.amount0())) : 0;
        uint256 amount1 = fees.amount1() > 0 ? uint256(uint128(fees.amount1())) : 0;
        if (amount0 > 0) poolManager.take(info.key.currency0, recipient, amount0);
        if (amount1 > 0) poolManager.take(info.key.currency1, recipient, amount1);
        return abi.encode(amount0, amount1);
    }

    function _pay(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}
