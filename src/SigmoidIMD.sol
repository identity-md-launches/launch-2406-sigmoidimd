// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SigmoidIMD
/// @notice Fair-launch hook for Uniswap v4 pools that pair a launch token with IMD.
///
/// For every pool it is attached to, the hook records the block the pool was created in and protects the
/// first `OPENING_WINDOW_BLOCKS` blocks (the opening window):
///
///  1. Dynamic swap fee. On a dynamic-fee pool the LP fee is pinned to `BASE_LP_FEE` (0.30%). On top of the LP
///     fee the hook charges a surcharge of `IMPACT_MULTIPLIER` x the swap's price impact, so that the total fee
///     is 0.30% + 150 x impact, capped at `MAX_TOTAL_FEE` (90%) whatever the pool's LP fee. The surcharge is
///     taken from the swap's unspecified currency with `afterSwapReturnDelta` and sent to the immutable
///     `treasury`. It applies inside and outside the window.
///  2. Circuit breaker. Inside the window any swap that would move the launch token's price by more than
///     `MAX_PRICE_MOVE_PIPS` (25%) from the last settled price reverts.
///  3. Wallet protection. Inside the window a wallet (`tx.origin`) may buy at most `MAX_BUY_BPS` (0.5%) of the
///     launch token's total supply in total and may swap at most once every `SWAP_COOLDOWN_BLOCKS` blocks.
///
/// Outside the window only the dynamic fee remains. The hook has no owner and no switches.
///
/// Price impact is always the move of the launch token's price in the pair currency (normalised for which
/// currency the token sorts as), measured from the price settled at the end of the last block that had a filled
/// swap. Every swap in one block is measured from that block anchor, so splitting a trade within a block does
/// not reduce the surcharge or evade the breaker. A swap that fills nothing (it only slid the pool price through
/// a region with no liquidity) is ignored entirely: it is not settled, not breaker-checked and not surcharged.
/// A swap that ends in a region with no liquidity is measured and settled at the edge of the liquidity it
/// consumed, not at the price it slid to.
///
/// @dev Callbacks enabled: beforeInitialize, beforeSwap, afterSwap, afterSwapReturnDelta. The pool manager
/// and the pair currency are constructor arguments; nothing is hardcoded. The constructor calls no other
/// contract. One hook instance serves any number of pools, as long as each pairs an ERC-20 with IMD.
contract SigmoidIMD is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // ------------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------------

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error NotImdPair();
    error LaunchTokenNotERC20();
    error UnknownPool();
    error NothingToSweep();
    error CircuitBreaker(uint160 settledSqrtPriceX96, uint160 newSqrtPriceX96, uint256 impactPips);
    error WalletBuyCapExceeded(address wallet, uint256 wouldHold, uint256 cap);
    error WalletCooldown(address wallet, uint256 lastSwapBlock, uint256 nextAllowedBlock);

    // ------------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------------

    event LaunchRegistered(
        PoolId indexed poolId, address indexed token, uint256 creationBlock, uint256 maxBuyPerWallet
    );
    event PriceSettled(PoolId indexed poolId, uint160 sqrtPriceX96);
    event SurchargeCollected(
        PoolId indexed poolId,
        Currency indexed currency,
        uint256 amount,
        uint256 impactPips,
        uint256 surchargePips,
        bool direct
    );
    event FeesSwept(Currency indexed currency, uint256 amount);

    // ------------------------------------------------------------------------------------------------------
    // Constants (named, documented in the README)
    // ------------------------------------------------------------------------------------------------------

    /// @notice One million pips = 100%.
    uint256 public constant PIPS = 1_000_000;
    /// @notice Blocks after pool creation during which the protections apply (the opening window).
    uint256 public constant OPENING_WINDOW_BLOCKS = 100;
    /// @notice Minimum spacing, in blocks, between two swaps of the same wallet inside the window.
    uint256 public constant SWAP_COOLDOWN_BLOCKS = 3;
    /// @notice Largest share of the token supply one wallet may buy inside the window, in basis points.
    uint256 public constant MAX_BUY_BPS = 50;
    /// @notice LP fee pinned on dynamic-fee pools: 0.30%.
    uint24 public constant BASE_LP_FEE = 3_000;
    /// @notice Surcharge multiplier: total fee = 0.30% + 150 x price impact.
    uint256 public constant IMPACT_MULTIPLIER = 150;
    /// @notice Cap on the total fee (LP fee + surcharge): 90%.
    uint24 public constant MAX_TOTAL_FEE = 900_000;
    /// @notice Largest price move allowed by one swap inside the window: 25%.
    uint256 public constant MAX_PRICE_MOVE_PIPS = 250_000;
    /// @notice Saturation value for the price impact when the move is astronomically large (a 1e12x price move).
    uint256 internal constant IMPACT_SATURATION = 1e18;
    /// @notice Sqrt-price ratio (1e6x, so a 1e12x price move) above which the impact saturates.
    uint256 internal constant SQRT_RATIO_SATURATION = 1e6;
    /// @notice Most tick-bitmap words scanned to find the liquidity edge a sliding swap came from. 128 words cover
    /// the whole tick range at tick spacing 60; a wider search gives up and uses the raw pool price.
    uint256 internal constant MAX_EDGE_WORDS = 128;

    // ------------------------------------------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    /// @notice The pair currency every pool on this hook must contain (IMD).
    Currency public immutable pairCurrency;
    /// @notice Receives the surcharge.
    address public immutable treasury;

    // ------------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------------

    struct Launch {
        address token;
        bool tokenIsCurrency0;
        uint64 creationBlock;
        /// @dev The block anchor: the price every swap in the current block is measured from. It is the price
        /// settled by the last filled swap of an earlier block (the opening price before any swap).
        uint160 lastSettledSqrtPriceX96;
        /// @dev The price after the latest filled swap; becomes the anchor when a later block has a filled swap.
        uint160 latestSqrtPriceX96;
        /// @dev Block of the latest filled swap (the creation block before any swap).
        uint64 latestBlock;
        uint256 maxBuyPerWallet;
    }

    mapping(PoolId poolId => Launch) internal _launches;
    /// @notice Launch tokens a wallet took out of the pool inside the window, gross of the hook's fee.
    mapping(PoolId poolId => mapping(address wallet => uint256)) public boughtInWindow;
    /// @notice Block of a wallet's last swap inside the window (0 = never).
    mapping(PoolId poolId => mapping(address wallet => uint256)) public lastSwapBlock;
    /// @notice Surcharge held as ERC-6909 claims because the manager could not pay it out at once.
    mapping(Currency currency => uint256) public pendingFees;

    // ------------------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------------------

    constructor(IPoolManager poolManager_, address pairCurrency_, address treasury_) {
        if (address(poolManager_) == address(0) || pairCurrency_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        pairCurrency = Currency.wrap(pairCurrency_);
        treasury = treasury_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------

    function launches(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @notice True while the pool is inside its opening window.
    function inOpeningWindow(PoolId poolId) public view returns (bool) {
        Launch storage l = _launches[poolId];
        if (l.token == address(0)) return false;
        return block.number < uint256(l.creationBlock) + OPENING_WINDOW_BLOCKS;
    }

    /// @notice Price impact in pips of moving from one sqrt price to another: |p1 - p0| / p0 with p = sqrt^2.
    /// @dev Computed on the sqrt prices at full precision (no truncation near MIN_SQRT_PRICE). Saturates at
    /// `IMPACT_SATURATION` for moves above 1e12x so it can never revert.
    function priceImpactPips(uint160 sqrtPriceBeforeX96, uint160 sqrtPriceAfterX96) public pure returns (uint256) {
        uint256 s0 = sqrtPriceBeforeX96;
        uint256 s1 = sqrtPriceAfterX96;
        if (s0 == 0) return s1 == 0 ? 0 : IMPACT_SATURATION;
        if (s1 >= s0 * SQRT_RATIO_SATURATION) return IMPACT_SATURATION;
        // ratio = p1 / p0 in pips = s1^2 / s0^2 * 1e6; s1 < s0 * 1e6 so s1^2 / s0 < 2^200 and nothing overflows.
        uint256 ratioPips = FullMath.mulDiv(FullMath.mulDiv(s1, s1, s0), PIPS, s0);
        return ratioPips >= PIPS ? ratioPips - PIPS : PIPS - ratioPips;
    }

    /// @notice The move of the launch token's price, in pips, between two pool sqrt prices.
    /// @dev The pool price is currency1 per currency0. When the token is currency1 its price in the pair currency
    /// is the inverse, so the roles of before and after swap: |1/p1 - 1/p0| / (1/p0) = |p0 - p1| / p1.
    function tokenPriceImpactPips(bool tokenIsCurrency0, uint160 sqrtPriceBeforeX96, uint160 sqrtPriceAfterX96)
        public
        pure
        returns (uint256)
    {
        return tokenIsCurrency0
            ? priceImpactPips(sqrtPriceBeforeX96, sqrtPriceAfterX96)
            : priceImpactPips(sqrtPriceAfterX96, sqrtPriceBeforeX96);
    }

    /// @notice The surcharge, in pips, for a given price impact on a pool whose LP fee is `BASE_LP_FEE`.
    function surchargePips(uint256 impactPips) public pure returns (uint256) {
        return surchargePips(impactPips, BASE_LP_FEE);
    }

    /// @notice The surcharge, in pips, for a given price impact on a pool with LP fee `lpFee`: 150 x impact,
    /// capped so that LP fee + surcharge never exceeds `MAX_TOTAL_FEE`.
    function surchargePips(uint256 impactPips, uint24 lpFee) public pure returns (uint256) {
        uint256 raw = impactPips * IMPACT_MULTIPLIER;
        uint256 cap = lpFee < MAX_TOTAL_FEE ? uint256(MAX_TOTAL_FEE) - uint256(lpFee) : 0;
        return raw > cap ? cap : raw;
    }

    /// @notice The surcharge amount for an unspecified amount of `amount` at `surcharge` pips.
    /// @dev When the unspecified currency is the swap's output (exact input) the fee is taken out of it, so the
    /// treasury keeps `surcharge` of the gross output. When it is the input (exact output) the fee is added on
    /// top, so it is scaled up to `amount x s / (1 - s)`: the treasury then keeps `surcharge` of what the trader
    /// pays in total, the same share as on an exact-input swap.
    function surchargeAmount(uint256 amount, uint256 surcharge, bool unspecifiedIsInput) public pure returns (uint256) {
        if (surcharge >= PIPS) return 0; // unreachable: the cap is below 100%
        return unspecifiedIsInput
            ? FullMath.mulDiv(amount, surcharge, PIPS - surcharge)
            : FullMath.mulDiv(amount, surcharge, PIPS);
    }

    /// @notice The nearest initialized tick on the side a swap in direction `zeroForOne` came from: strictly above
    /// `tick` after a zeroForOne swap, at or below it otherwise. Used when a swap ends in a region with no
    /// liquidity, where the pool price is wherever the swap slid to and the real price is the liquidity edge.
    /// @return found False when no initialized tick lies within `MAX_EDGE_WORDS` words.
    /// @return edgeTick The initialized tick, when found.
    function liquidityEdge(PoolId poolId, int24 tick, int24 tickSpacing, bool zeroForOne)
        public
        view
        returns (bool found, int24 edgeTick)
    {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        if (zeroForOne) compressed += 1;
        for (uint256 i = 0; i < MAX_EDGE_WORDS; i++) {
            if (int256(compressed) * tickSpacing > TickMath.MAX_TICK) break;
            if (int256(compressed) * tickSpacing < TickMath.MIN_TICK) break;
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
            uint256 word = poolManager.getTickBitmap(poolId, wordPos);
            int24 wordStart = compressed - int24(uint24(bitPos));
            if (zeroForOne) {
                uint256 masked = word & (type(uint256).max << bitPos); // bits at or above bitPos
                if (masked != 0) {
                    return (true, (wordStart + int24(uint24(BitMath.leastSignificantBit(masked)))) * tickSpacing);
                }
                compressed = wordStart + 256;
            } else {
                uint256 masked = word & ((uint256(1) << bitPos) | ((uint256(1) << bitPos) - 1)); // at or below
                if (masked != 0) {
                    return (true, (wordStart + int24(uint24(BitMath.mostSignificantBit(masked)))) * tickSpacing);
                }
                compressed = wordStart - 1;
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Accepts any pool that pairs an ERC-20 launch token with the pair currency, at any LP fee, static
    /// or dynamic. Records the launch token, the creation block, the wallet buy cap and the opening price.
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        bool pairIs0 = key.currency0 == pairCurrency;
        bool pairIs1 = key.currency1 == pairCurrency;
        if (pairIs0 == pairIs1) revert NotImdPair();
        Currency tokenCurrency = pairIs0 ? key.currency1 : key.currency0;
        if (tokenCurrency.isAddressZero()) revert LaunchTokenNotERC20();
        address token = Currency.unwrap(tokenCurrency);

        uint256 supply;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        if (!ok || ret.length < 32) revert LaunchTokenNotERC20();
        supply = abi.decode(ret, (uint256));

        PoolId poolId = key.toId();
        uint256 cap = supply * MAX_BUY_BPS / 10_000;
        _launches[poolId] = Launch({
            token: token,
            tokenIsCurrency0: pairIs1,
            creationBlock: uint64(block.number),
            lastSettledSqrtPriceX96: sqrtPriceX96,
            latestSqrtPriceX96: sqrtPriceX96,
            latestBlock: uint64(block.number),
            maxBuyPerWallet: cap
        });
        emit LaunchRegistered(poolId, token, block.number, cap);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Inside the window, enforces the per-wallet cooldown. Pins the LP fee on dynamic-fee pools.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];
        if (l.token == address(0)) revert UnknownPool();

        if (block.number < uint256(l.creationBlock) + OPENING_WINDOW_BLOCKS) {
            address wallet = tx.origin;
            uint256 last = lastSwapBlock[poolId][wallet];
            if (last != 0 && block.number < last + SWAP_COOLDOWN_BLOCKS) {
                revert WalletCooldown(wallet, last, last + SWAP_COOLDOWN_BLOCKS);
            }
            lastSwapBlock[poolId][wallet] = block.number;
        }

        uint24 lpFeeOverride = key.fee.isDynamicFee() ? BASE_LP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG : 0;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /// @inheritdoc IHooks
    /// @dev Ignores swaps that filled nothing. Otherwise measures the launch token's price move against the block
    /// anchor, trips the circuit breaker and the wallet buy cap inside the window, charges the surcharge on the
    /// unspecified currency and records the new price.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (delta.amount0() == 0 && delta.amount1() == 0) return (IHooks.afterSwap.selector, 0);
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        uint24 lpFee = key.fee.isDynamicFee() ? BASE_LP_FEE : key.fee;
        uint256 fee = _afterSwap(
            key.toId(),
            specifiedIs0 ? key.currency1 : key.currency0,
            specifiedIs0,
            params.amountSpecified > 0,
            params.zeroForOne,
            key.tickSpacing,
            lpFee,
            delta
        );
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    /// @dev The body of `afterSwap`, with the calldata structs reduced to what it needs.
    function _afterSwap(
        PoolId poolId,
        Currency feeCurrency,
        bool specifiedIs0,
        bool exactOutput,
        bool zeroForOne,
        int24 tickSpacing,
        uint24 lpFee,
        BalanceDelta delta
    ) internal returns (uint256 fee) {
        Launch storage l = _launches[poolId];
        if (l.token == address(0)) revert UnknownPool();

        (uint256 impact, uint160 sqrtPriceAfter) = _measureImpact(poolId, l, zeroForOne, tickSpacing);

        // The surcharge comes out of the unspecified currency: the output of an exact-input swap, the input of
        // an exact-output swap. On exact output it is scaled so the treasury's share of what the trader pays is
        // the same as on exact input.
        uint256 surcharge = surchargePips(impact, lpFee);
        fee = surchargeAmount(_abs(specifiedIs0 ? delta.amount1() : delta.amount0()), surcharge, exactOutput);

        _enforceBuyCap(poolId, l, delta);
        if (fee > 0) _collect(poolId, feeCurrency, fee, impact, surcharge);

        l.latestSqrtPriceX96 = sqrtPriceAfter;
        emit PriceSettled(poolId, sqrtPriceAfter);
    }

    /// @dev Moves the block anchor forward when this is the first filled swap of a new block, reads the post-swap
    /// price (the liquidity edge when the swap slid into empty space), computes the token's price move against
    /// the anchor and trips the breaker inside the window.
    function _measureImpact(PoolId poolId, Launch storage l, bool zeroForOne, int24 tickSpacing)
        internal
        returns (uint256 impact, uint160 sqrtPriceAfter)
    {
        if (l.latestBlock != uint64(block.number)) {
            l.lastSettledSqrtPriceX96 = l.latestSqrtPriceX96;
            l.latestBlock = uint64(block.number);
        }
        uint160 anchor = l.lastSettledSqrtPriceX96;

        int24 tick;
        (sqrtPriceAfter, tick,,) = poolManager.getSlot0(poolId);
        if (poolManager.getLiquidity(poolId) == 0) {
            (bool found, int24 edge) = liquidityEdge(poolId, tick, tickSpacing, zeroForOne);
            if (found) sqrtPriceAfter = TickMath.getSqrtPriceAtTick(edge);
        }

        impact = tokenPriceImpactPips(l.tokenIsCurrency0, anchor, sqrtPriceAfter);
        bool inWindow = block.number < uint256(l.creationBlock) + OPENING_WINDOW_BLOCKS;
        if (inWindow && impact > MAX_PRICE_MOVE_PIPS) revert CircuitBreaker(anchor, sqrtPriceAfter, impact);
    }

    /// @dev Inside the window, counts every launch token the swap takes out of the pool for the wallet, gross of
    /// the hook's fee (the fee is taken from that output when the token is the unspecified currency), and
    /// enforces the cap.
    function _enforceBuyCap(PoolId poolId, Launch storage l, BalanceDelta delta) internal {
        if (block.number >= uint256(l.creationBlock) + OPENING_WINDOW_BLOCKS) return;
        int128 tokenDelta = l.tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        if (tokenDelta <= 0) return;
        uint256 received = uint256(uint128(tokenDelta));
        address wallet = tx.origin;
        uint256 total = boughtInWindow[poolId][wallet] + received;
        if (total > l.maxBuyPerWallet) revert WalletBuyCapExceeded(wallet, total, l.maxBuyPerWallet);
        boughtInWindow[poolId][wallet] = total;
    }

    /// @dev Pays the treasury at once when the manager holds the currency; otherwise keeps an ERC-6909 claim that
    /// anyone can redeem later with `sweepFees`.
    function _collect(PoolId poolId, Currency feeCurrency, uint256 fee, uint256 impact, uint256 surcharge) internal {
        bool direct = feeCurrency.balanceOf(address(poolManager)) >= fee;
        if (direct) {
            poolManager.take(feeCurrency, treasury, fee);
        } else {
            poolManager.mint(address(this), feeCurrency.toId(), fee);
            pendingFees[feeCurrency] += fee;
        }
        emit SurchargeCollected(poolId, feeCurrency, fee, impact, surcharge, direct);
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    // ------------------------------------------------------------------------------------------------------
    // Fee sweeping
    // ------------------------------------------------------------------------------------------------------

    /// @notice Redeems surcharge held as ERC-6909 claims and pays it to the treasury. Anyone may call it.
    /// @dev Pays out as much as the manager's balance covers; the rest stays claimable.
    function sweepFees(Currency currency) external returns (uint256 amount) {
        amount = pendingFees[currency];
        uint256 available = currency.balanceOf(address(poolManager));
        if (amount > available) amount = available;
        if (amount == 0) revert NothingToSweep();
        pendingFees[currency] -= amount;
        poolManager.unlock(abi.encode(currency, amount));
        emit FeesSwept(currency, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, treasury, amount);
        return "";
    }

    // ------------------------------------------------------------------------------------------------------
    // Callbacks this hook does not enable. They are never called by the pool manager because the address does
    // not carry their flags; they revert so a misconfigured address cannot pass them silently.
    // ------------------------------------------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
