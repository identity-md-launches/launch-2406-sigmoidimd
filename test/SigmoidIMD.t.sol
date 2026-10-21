// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SigmoidIMD} from "../src/SigmoidIMD.sol";
import {SigmoidTestBase} from "./utils/SigmoidTestBase.sol";
import {MockERC20, NotAnERC20} from "./mocks/MockERC20.sol";

contract SigmoidIMDTest is SigmoidTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant LIQUIDITY = 1e26;

    function setUp() public {
        _setUpCore();
        _initPool(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        _addFullRangeLiquidity(LIQUIDITY);
    }

    // ---------------------------------------------------------------------------------------------- deployment

    function test_permissionsMatchAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        uint160 expected = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expected);
    }

    function test_immutables() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.pairCurrency()), address(imd));
        assertEq(hook.treasury(), treasury);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(SigmoidIMD.ZeroAddress.selector);
        new SigmoidIMD(IPoolManager(address(0)), address(imd), treasury);
        vm.expectRevert(SigmoidIMD.ZeroAddress.selector);
        new SigmoidIMD(IPoolManager(address(manager)), address(0), treasury);
        vm.expectRevert(SigmoidIMD.ZeroAddress.selector);
        new SigmoidIMD(IPoolManager(address(manager)), address(imd), address(0));
    }

    function test_constructorRejectsAddressWithoutFlags() public {
        // A plain CREATE lands on an address whose low bits almost surely do not match.
        vm.expectRevert();
        new SigmoidIMD(IPoolManager(address(manager)), address(imd), treasury);
    }

    // ---------------------------------------------------------------------------------------------- access control

    function test_callbacksRefuseNonManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(SigmoidIMD.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(SigmoidIMD.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(SigmoidIMD.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(SigmoidIMD.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_disabledCallbacksRevert() public {
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(SigmoidIMD.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(SigmoidIMD.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(SigmoidIMD.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, mp, "");
        vm.expectRevert(SigmoidIMD.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(SigmoidIMD.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------- initialization

    function test_initializeRecordsLaunch() public view {
        SigmoidIMD.Launch memory l = hook.launches(poolId);
        assertEq(l.token, address(token));
        assertEq(l.tokenIsCurrency0, tokenIs0);
        assertEq(l.creationBlock, block.number);
        assertEq(l.lastSettledSqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(l.maxBuyPerWallet, token.totalSupply() / 200);
        assertTrue(hook.inOpeningWindow(poolId));
    }

    function test_initializeAcceptsStaticLaunchFeeFromAnyFactory() public {
        MockERC20 other = new MockERC20("Other", "OTHER");
        other.mint(address(this), 1);
        PoolKey memory k = _keyFor(address(other), 12_500);
        address factory = makeAddr("factory");
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        SigmoidIMD.Launch memory l = hook.launches(k.toId());
        assertEq(l.token, address(other));
        assertEq(l.maxBuyPerWallet, 0, "a 1-wei supply has a zero cap");
    }

    function test_initializeRejectsPoolWithoutImd() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(hook)));
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SigmoidIMD.NotImdPair.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRejectsNativePair() public {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 3000, 60, IHooks(address(hook)));
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SigmoidIMD.LaunchTokenNotERC20.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRejectsNonErc20Token() public {
        NotAnERC20 junk = new NotAnERC20();
        PoolKey memory k = _keyFor(address(junk), 3000);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SigmoidIMD.LaunchTokenNotERC20.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------------------------------------- dynamic fee

    function test_tinySwapPaysOnlyBaseFee() public {
        _closeWindow();
        uint256 imdIn = 1e18; // 1e-8 of the liquidity: impact rounds to ~0 pips
        BalanceDelta d = _buy(alice, imdIn);
        uint256 out = uint256(uint128(_tokenDelta(d)));
        // 0.30% LP fee at a 1:1 price with negligible impact: output within 0.31% of input.
        assertGt(out, imdIn * 9969 / 10_000);
        assertLt(out, imdIn * 9971 / 10_000);
        assertEq(token.balanceOf(treasury), 0, "no surcharge on a zero-impact swap");
    }

    function test_surchargeExactInputBuy() public {
        _closeWindow();
        uint160 before = _sqrtPrice();
        uint256 imdIn = 1e23;
        BalanceDelta d = _buy(alice, imdIn);
        uint256 netOut = uint256(uint128(_tokenDelta(d)));
        uint256 fee = token.balanceOf(treasury);
        uint256 impact = _impact(before, _sqrtPrice());
        uint256 surcharge = hook.surchargePips(impact);
        assertGt(impact, 0);
        assertGt(fee, 0, "treasury received the surcharge in the output token");
        assertEq(fee, (netOut + fee) * surcharge / 1e6, "fee is surcharge x gross output");
        assertEq(imd.balanceOf(treasury), 0, "nothing taken from the input side");
        SigmoidIMD.Launch memory l = hook.launches(poolId);
        assertEq(l.latestSqrtPriceX96, _sqrtPrice(), "price recorded after the swap");
        assertEq(l.lastSettledSqrtPriceX96, before, "the block anchor only moves in a later block");
    }

    function test_surchargeExactOutputBuy() public {
        _closeWindow();
        uint160 before = _sqrtPrice();
        uint256 tokensOut = 1e23;
        BalanceDelta d = _buyExactOut(alice, tokensOut);
        assertEq(uint256(uint128(_tokenDelta(d))), tokensOut, "exact output honoured");
        uint256 grossIn = _abs(_imdDelta(d)); // what the trader pays, fee included
        uint256 fee = imd.balanceOf(treasury);
        uint256 surcharge = hook.surchargePips(_impact(before, _sqrtPrice()));
        assertGt(fee, 0, "treasury received the surcharge in IMD, the input side");
        // The fee is a markup on the pool's input scaled so the treasury keeps `surcharge` of what is paid.
        assertEq(fee, (grossIn - fee) * surcharge / (1e6 - surcharge));
        assertApproxEqAbs(fee * 1e6 / grossIn, surcharge, 1, "same share of the payment as on exact input");
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_surchargeExactInputSell() public {
        _closeWindow();
        uint160 before = _sqrtPrice();
        BalanceDelta d = _sell(alice, 1e23);
        uint256 netOut = uint256(uint128(_imdDelta(d)));
        uint256 fee = imd.balanceOf(treasury);
        uint256 surcharge = hook.surchargePips(_impact(before, _sqrtPrice()));
        assertGt(fee, 0, "treasury received the surcharge in IMD, the output side");
        assertEq(fee, (netOut + fee) * surcharge / 1e6);
    }

    function test_surchargeExactOutputSell() public {
        _closeWindow();
        uint160 before = _sqrtPrice();
        uint256 imdOut = 1e23;
        BalanceDelta d = _sellExactOut(alice, imdOut);
        assertEq(uint256(uint128(_imdDelta(d))), imdOut);
        uint256 grossIn = _abs(_tokenDelta(d));
        uint256 fee = token.balanceOf(treasury);
        uint256 surcharge = hook.surchargePips(_impact(before, _sqrtPrice()));
        assertGt(fee, 0, "treasury received the surcharge in the token, the input side");
        assertEq(fee, (grossIn - fee) * surcharge / (1e6 - surcharge));
        assertApproxEqAbs(fee * 1e6 / grossIn, surcharge, 1, "same share of the payment as on exact input");
    }

    function test_exactOutputAndExactInputPayTheSameShareAtTheCap() public {
        _closeWindow();
        uint256 snap = vm.snapshotState();
        // Exact input, far past the cap: the treasury keeps 89.7% of the gross output.
        BalanceDelta d = _buy(alice, LIQUIDITY / 10);
        uint256 grossOut = uint256(uint128(_tokenDelta(d))) + token.balanceOf(treasury);
        assertApproxEqAbs(token.balanceOf(treasury) * 1e6 / grossOut, 897_000, 1);
        vm.revertToState(snap);
        // Exact output of the same size: the treasury keeps 89.7% of the gross IMD paid, not 47.3%.
        d = _buyExactOut(alice, grossOut);
        uint256 grossIn = _abs(_imdDelta(d));
        assertApproxEqAbs(imd.balanceOf(treasury) * 1e6 / grossIn, 897_000, 1);
    }

    function test_surchargeCapRespectsStaticLpFee() public {
        // The IMD launch factory opens the pool at the static 1.25% tier: the surcharge cap shrinks so the
        // total stays at 90%.
        assertEq(hook.surchargePips(1e18, 12_500), 887_500);
        assertEq(hook.surchargePips(1e18, 3_000), 897_000);
        assertEq(hook.surchargePips(1e18, 900_000), 0);
        assertEq(hook.surchargePips(1_000, 12_500), 150_000, "below the cap the LP fee does not matter");

        _initPool(12_500);
        _addFullRangeLiquidity(LIQUIDITY);
        _closeWindow();
        uint160 before = _sqrtPrice();
        BalanceDelta d = _buy(alice, LIQUIDITY / 10);
        uint256 grossOut = uint256(uint128(_tokenDelta(d))) + token.balanceOf(treasury);
        assertGt(_impact(before, _sqrtPrice()) * 150, 887_500, "the cap binds");
        assertApproxEqAbs(token.balanceOf(treasury) * 1e6 / grossOut, 887_500, 1);
        assertLe(token.balanceOf(treasury) * 1e6 / grossOut + key.fee, 900_000, "LP fee + surcharge <= 90%");
    }

    function test_splittingASwapWithinABlockDoesNotCutTheSurcharge() public {
        _closeWindow();
        uint256 snap = vm.snapshotState();
        _buy(alice, LIQUIDITY / 1000);
        uint256 feeOne = token.balanceOf(treasury);
        uint160 priceOne = _sqrtPrice();
        vm.revertToState(snap);
        for (uint256 i = 0; i < 20; i++) {
            _buy(alice, LIQUIDITY / 20_000);
        }
        uint256 feeMany = token.balanceOf(treasury);
        assertApproxEqRel(uint256(_sqrtPrice()), uint256(priceOne), 1e14, "same end price");
        assertGt(feeOne, 0);
        // Every piece is measured from the block anchor, so piece k pays the rate of the cumulative move up to
        // k: the sum is about two thirds of the single-swap fee here, against one twentieth when each piece was
        // measured from the previous piece.
        assertGe(feeMany, feeOne / 2, "the split does not cut the surcharge");
    }

    function test_blockAnchorAdvancesOnlyInALaterBlock() public {
        _closeWindow();
        uint160 opening = _sqrtPrice();
        _sell(alice, LIQUIDITY / 100);
        uint160 afterFirst = _sqrtPrice();
        _sell(alice, LIQUIDITY / 100);
        uint160 afterSecond = _sqrtPrice();
        SigmoidIMD.Launch memory l = hook.launches(poolId);
        assertEq(l.lastSettledSqrtPriceX96, opening, "both swaps in this block measure from the opening price");
        assertEq(l.latestSqrtPriceX96, afterSecond);
        assertEq(l.latestBlock, block.number);
        assertTrue(afterFirst != afterSecond);

        vm.roll(block.number + 1);
        _sell(alice, 1e18);
        l = hook.launches(poolId);
        assertEq(l.lastSettledSqrtPriceX96, afterSecond, "the next block measures from where the last one ended");
    }

    function test_breakerUsesTheCumulativeInBlockMove() public {
        // Inside the window, two different wallets each moving the price ~13% in one block: the second trips the
        // breaker because the block's cumulative move passes 25%. In the next block it goes through.
        _sell(alice, LIQUIDITY / 10);
        uint256 first = _impact(SQRT_PRICE_1_1, _sqrtPrice());
        assertGt(first, 150_000);
        assertLe(first, 250_000);
        vm.expectRevert();
        _sell(bob, LIQUIDITY / 10);
        vm.roll(block.number + 1);
        _sell(bob, LIQUIDITY / 10);
    }

    function test_surchargeIsCappedAtNinetyPercentTotal() public {
        _closeWindow();
        // A swap of a tenth of the liquidity moves the price ~20%: 150 x 20% is far past the cap.
        uint160 before = _sqrtPrice();
        BalanceDelta d = _buy(alice, LIQUIDITY / 10);
        uint256 netOut = uint256(uint128(_tokenDelta(d)));
        uint256 fee = token.balanceOf(treasury);
        uint256 impact = hook.priceImpactPips(before, _sqrtPrice());
        assertGt(impact, 60_000, "impact well above the point where the cap binds");
        assertEq(hook.surchargePips(impact), 897_000);
        assertEq(fee, (netOut + fee) * 897_000 / 1e6);
    }

    function test_feeFormula() public view {
        assertEq(hook.surchargePips(0), 0);
        assertEq(hook.surchargePips(1_000), 150_000); // 0.1% impact -> 15% surcharge
        assertEq(hook.surchargePips(5_000), 750_000); // 0.5% impact -> 75% surcharge
        assertEq(hook.surchargePips(5_980), 897_000); // 0.598% impact -> capped: total 90%
        assertEq(hook.surchargePips(1e18), 897_000);
        assertEq(hook.BASE_LP_FEE() + hook.surchargePips(1e18), hook.MAX_TOTAL_FEE());
    }

    function testFuzz_surchargeNeverExceedsCap(uint256 impactPips) public view {
        impactPips = bound(impactPips, 0, 1e18);
        uint256 s = hook.surchargePips(impactPips);
        assertLe(s, 897_000);
        assertLe(s, impactPips * 150);
        if (impactPips * 150 <= 897_000) assertEq(s, impactPips * 150);
    }

    function testFuzz_priceImpactNeverReverts(uint160 a, uint160 b) public view {
        a = uint160(bound(a, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        b = uint160(bound(b, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 impact = hook.priceImpactPips(a, b);
        if (a == b) assertEq(impact, 0);
        assertLe(impact, 1e18);
    }

    function test_priceImpactExamples() public view {
        // Doubling the sqrt price quadruples the price: +300%.
        assertEq(hook.priceImpactPips(SQRT_PRICE_1_1, SQRT_PRICE_1_1 * 2), 3_000_000);
        // Halving the sqrt price quarters the price: -75%.
        assertEq(hook.priceImpactPips(SQRT_PRICE_1_1, SQRT_PRICE_1_1 / 2), 750_000);
        // Saturation for astronomic moves, in both directions.
        assertEq(hook.priceImpactPips(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE), 1e18);
        assertEq(hook.priceImpactPips(TickMath.MAX_SQRT_PRICE, TickMath.MIN_SQRT_PRICE), 1_000_000);
    }

    function test_priceImpactKeepsPrecisionNearMinSqrtPrice() public view {
        // sqrt price x1.4 is a price x1.96: 96% impact, also right at the bottom of the sqrt-price range.
        assertApproxEqAbs(hook.priceImpactPips(4_295_128_739, 6_013_180_234), 960_000, 500);
        assertApproxEqAbs(hook.priceImpactPips(uint160(1 << 40), uint160(uint256(1 << 40) * 1118 / 1000)), 250_000, 500);
    }

    function test_tokenPriceImpactIsNormalisedForTheTokenSide() public view {
        // Raw price 1 -> 0.75. Token as currency0: its price fell 25%. Token as currency1: its price rose 33.3%.
        uint160 sqrt075 = uint160(uint256(SQRT_PRICE_1_1) * 866_025 / 1e6);
        assertApproxEqAbs(hook.tokenPriceImpactPips(true, SQRT_PRICE_1_1, sqrt075), 250_000, 10);
        assertApproxEqAbs(hook.tokenPriceImpactPips(false, SQRT_PRICE_1_1, sqrt075), 333_333, 10);
        // Raw price 1 -> 1.3333: the mirror image.
        uint160 sqrt133 = uint160(uint256(SQRT_PRICE_1_1) * 1_154_700 / 1e6);
        assertApproxEqAbs(hook.tokenPriceImpactPips(true, SQRT_PRICE_1_1, sqrt133), 333_333, 10);
        assertApproxEqAbs(hook.tokenPriceImpactPips(false, SQRT_PRICE_1_1, sqrt133), 250_000, 10);
    }

    function test_breakerMeasuresTheTokenPriceWhicheverSideItSortsOn() public {
        // A sell that stops where the token's IMD price is 31.6% below the opening trips the breaker whether the
        // token is currency0 (raw price down 31.6%) or currency1 (raw price up 46%, which is 1/0.684). Sells,
        // so the wallet buy cap does not interfere.
        uint160 limit = tokenIs0
            ? uint160(uint256(SQRT_PRICE_1_1) * 827_000 / 1e6)  // sqrt(0.684)
            : uint160(uint256(SQRT_PRICE_1_1) * 1_209_100 / 1e6); // sqrt(1/0.684)
        vm.prank(address(this), alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: tokenIs0, amountSpecified: -int256(LIQUIDITY), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        // The same sell stopped at a 24% fall of the token's price passes.
        limit = tokenIs0
            ? uint160(uint256(SQRT_PRICE_1_1) * 871_780 / 1e6)  // sqrt(0.76)
            : uint160(uint256(SQRT_PRICE_1_1) * 1_147_080 / 1e6); // sqrt(1/0.76)
        vm.prank(address(this), bob);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: tokenIs0, amountSpecified: -int256(LIQUIDITY), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 impact = _impact(SQRT_PRICE_1_1, _sqrtPrice());
        assertGt(impact, 230_000);
        assertLe(impact, 250_000);
    }

    function test_swapEndingInEmptyRangeSettlesAtTheLiquidityEdge() public {
        // A second pool with token-only liquidity next to the opening price, like a launchpad pool, but on a
        // token this contract still holds: so a sell can exhaust the pool's IMD and slide into empty space.
        _initPool(500);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(tokenIs0 ? int24(0) : int24(-6000), tokenIs0 ? int24(6000) : int24(0), 1e24, 0),
            ""
        );
        uint160 opening = _sqrtPrice();
        _buyExactOut(alice, 1e22);
        uint160 afterBuy = _sqrtPrice();
        vm.roll(block.number + 3);
        // Sell ten times what was bought with the default (widest) price limit, inside the window: the fill
        // ends at the opening tick, the price slides to the limit, and nothing trips.
        BalanceDelta d = _sell(alice, 1e23);
        assertLt(_abs(_tokenDelta(d)), 1e23, "only the part with liquidity was filled");
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0, "the price slid out of the range");
        assertTrue(_sqrtPrice() != opening);
        SigmoidIMD.Launch memory l = hook.launches(poolId);
        assertEq(l.latestSqrtPriceX96, opening, "settled at the liquidity edge, not at the slid price");
        assertEq(l.lastSettledSqrtPriceX96, afterBuy, "this block measured from the price after the buy");
        // The next block's buy is measured from the edge: a small one is well inside the breaker.
        vm.roll(block.number + 3);
        d = _buyExactOut(alice, 1e21);
        assertEq(uint256(uint128(_tokenDelta(d))), 1e21);
        assertLt(_impact(opening, _sqrtPrice()), 5_000);
        assertEq(hook.launches(poolId).lastSettledSqrtPriceX96, opening, "measured from the edge");
    }

    function test_liquidityEdgeFindsTheFullRangeBounds() public view {
        (bool found, int24 edge) = hook.liquidityEdge(poolId, 0, TICK_SPACING, true);
        assertTrue(found);
        assertEq(edge, TickMath.maxUsableTick(TICK_SPACING), "searching up from the middle finds the upper bound");
        (found, edge) = hook.liquidityEdge(poolId, 0, TICK_SPACING, false);
        assertTrue(found);
        assertEq(edge, TickMath.minUsableTick(TICK_SPACING), "searching down finds the lower bound");
        (found,) = hook.liquidityEdge(poolId, TickMath.maxUsableTick(TICK_SPACING), TICK_SPACING, true);
        assertFalse(found, "nothing above the upper bound");
    }

    // ---------------------------------------------------------------------------------------------- circuit breaker

    function test_circuitBreakerTripsInsideWindow() public {
        // A quarter of the liquidity moves the price by well over 25%.
        vm.expectRevert();
        _buy(alice, LIQUIDITY / 4);
        assertEq(hook.launches(poolId).lastSettledSqrtPriceX96, SQRT_PRICE_1_1, "nothing settled");
    }

    function test_circuitBreakerRevertReason() public {
        uint256 amount = LIQUIDITY / 4;
        vm.prank(address(this), alice);
        (bool ok, bytes memory reason) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(
                            !tokenIs0,
                            -int256(amount),
                            tokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
                        ),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
        assertFalse(ok);
        // WrappedError(hook, afterSwap selector, reason, HookCallFailed) carries the CircuitBreaker error inside.
        (address target, bytes4 selector, bytes memory inner,) = _unwrap(reason);
        assertEq(target, address(hook));
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(bytes4(inner), SigmoidIMD.CircuitBreaker.selector);
    }

    function test_circuitBreakerAllowsUpToTwentyFivePercent() public {
        // ~0.1 of the liquidity moves the price ~21%: under the breaker, over the fee cap.
        uint160 before = _sqrtPrice();
        _closeWindow(); // avoid the buy cap: this is a breaker test
        vm.roll(block.number - hook.OPENING_WINDOW_BLOCKS()); // back inside the window
        assertTrue(hook.inOpeningWindow(poolId));
        // Sell instead of buy so the wallet buy cap does not interfere.
        _sell(alice, LIQUIDITY / 10);
        uint256 impact = hook.priceImpactPips(before, _sqrtPrice());
        assertGt(impact, 150_000);
        assertLe(impact, 250_000);
    }

    function test_circuitBreakerOffOutsideWindow() public {
        _closeWindow();
        assertFalse(hook.inOpeningWindow(poolId));
        uint160 before = _sqrtPrice();
        _buy(alice, LIQUIDITY / 4);
        assertGt(hook.priceImpactPips(before, _sqrtPrice()), 250_000, "the same swap moves more than 25%");
    }

    function test_circuitBreakerMeasuresFromLastSettledPrice() public {
        // Four 10% moves in a row are each allowed although the price drifts far from the opening.
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 3);
            _sell(alice, LIQUIDITY / 20);
        }
        assertGt(hook.priceImpactPips(_sqrtPrice(), SQRT_PRICE_1_1), 250_000);
    }

    // ---------------------------------------------------------------------------------------------- wallet buy cap

    function test_buyCapBlocksLargeBuyInsideWindow() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        assertEq(cap, 5e24);
        vm.expectRevert();
        _buyExactOut(alice, cap + 1);
    }

    function test_buyCapAllowsUpToCapAndCountsNet() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        BalanceDelta d = _buyExactOut(alice, cap);
        assertEq(uint256(uint128(_tokenDelta(d))), cap);
        assertEq(hook.boughtInWindow(poolId, alice), cap);
        // One more wei over the cap, three blocks later, is refused.
        vm.roll(block.number + 3);
        vm.expectRevert();
        _buyExactOut(alice, 1);
        // Another wallet is unaffected.
        _buyExactOut(bob, 1e18);
        assertEq(hook.boughtInWindow(poolId, bob), 1e18);
    }

    function test_buyCapIsCumulativeAcrossSwaps() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        _buyExactOut(alice, cap / 2);
        vm.roll(block.number + 3);
        _buyExactOut(alice, cap / 2);
        vm.roll(block.number + 3);
        vm.expectRevert();
        _buyExactOut(alice, 1);
    }

    function test_buyCapCountsGrossOfSurchargeOnExactInput() public {
        BalanceDelta d = _buy(alice, 1e23);
        uint256 netOut = uint256(uint128(_tokenDelta(d)));
        uint256 fee = token.balanceOf(treasury);
        assertGt(fee, 0);
        assertEq(hook.boughtInWindow(poolId, alice), netOut + fee, "every token the swap took out of the pool counts");
    }

    function test_buyCapBindsOnGrossOutputInsideWindow() public {
        // An exact-input buy whose gross output (fee included) would pass the cap is refused even though the
        // wallet would keep far less than the cap after the surcharge.
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        uint256 snap = vm.snapshotState();
        _closeWindow();
        BalanceDelta d = _buy(alice, cap * 12 / 10);
        uint256 gross = uint256(uint128(_tokenDelta(d))) + token.balanceOf(treasury);
        uint256 net = uint256(uint128(_tokenDelta(d)));
        vm.revertToState(snap);
        assertGt(gross, cap, "the gross output passes the cap");
        assertLt(net, cap, "but the net output does not");
        vm.expectRevert();
        _buy(alice, cap * 12 / 10);
    }

    function test_sellsDoNotCountTowardsBuyCap() public {
        _sell(alice, 1e23);
        assertEq(hook.boughtInWindow(poolId, alice), 0);
    }

    function test_buyCapOffOutsideWindow() public {
        _closeWindow();
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        _buyExactOut(alice, cap * 2);
        assertEq(hook.boughtInWindow(poolId, alice), 0, "nothing counted outside the window");
    }

    // ---------------------------------------------------------------------------------------------- cooldown

    function test_cooldownBlocksSecondSwapWithinThreeBlocks() public {
        _buy(alice, 1e21);
        assertEq(hook.lastSwapBlock(poolId, alice), block.number);
        vm.expectRevert();
        _sell(alice, 1e21);
        vm.roll(block.number + 2);
        vm.expectRevert();
        _sell(alice, 1e21);
        vm.roll(block.number + 1);
        _sell(alice, 1e21);
    }

    function test_cooldownRevertReason() public {
        _buy(alice, 1e21);
        uint256 first = block.number;
        vm.prank(address(this), alice);
        (bool ok, bytes memory reason) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(
                            tokenIs0, -1e21, tokenIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                        ),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
        assertFalse(ok);
        (, bytes4 selector, bytes memory inner,) = _unwrap(reason);
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(inner, abi.encodeWithSelector(SigmoidIMD.WalletCooldown.selector, alice, first, first + 3));
    }

    function test_cooldownIsPerWallet() public {
        _buy(alice, 1e21);
        _buy(bob, 1e21);
        assertEq(hook.lastSwapBlock(poolId, bob), block.number);
    }

    function test_cooldownOffOutsideWindow() public {
        _closeWindow();
        _buy(alice, 1e21);
        _sell(alice, 1e21);
        assertEq(hook.lastSwapBlock(poolId, alice), 0, "no cooldown bookkeeping outside the window");
    }

    function test_windowEdge() public {
        uint256 creation = hook.launches(poolId).creationBlock;
        vm.roll(creation + 99);
        assertTrue(hook.inOpeningWindow(poolId));
        vm.roll(creation + 100);
        assertFalse(hook.inOpeningWindow(poolId));
    }

    // ---------------------------------------------------------------------------------------------- sweeping

    function test_sweepRevertsWithNothingPending() public {
        vm.expectRevert(SigmoidIMD.NothingToSweep.selector);
        hook.sweepFees(Currency.wrap(address(imd)));
    }

    // ---------------------------------------------------------------------------------------------- helpers

    /// @dev The launch token's price move between two pool sqrt prices, as the hook measures it.
    function _impact(uint160 before, uint160 after_) internal view returns (uint256) {
        return hook.tokenPriceImpactPips(tokenIs0, before, after_);
    }

    /// @dev The ERC-7751 wrapped revert the pool manager raises when a hook callback reverts with `reason`.
    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _unwrap(bytes memory data)
        internal
        pure
        returns (address target, bytes4 selector, bytes memory reason, bytes memory details)
    {
        assertEq(bytes4(data), CustomRevert.WrappedError.selector);
        bytes memory tail = new bytes(data.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = data[i + 4];
        }
        return abi.decode(tail, (address, bytes4, bytes, bytes));
    }
}
