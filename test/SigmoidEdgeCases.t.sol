// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SigmoidIMD} from "../src/SigmoidIMD.sol";
import {SigmoidLaunchpad} from "../src/SigmoidLaunchpad.sol";
import {SigmoidTestBase} from "./utils/SigmoidTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Failure paths and boundaries of the hook that the main suite does not pin to an exact reason.
contract SigmoidHookEdgeTest is SigmoidTestBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant LIQUIDITY = 1e26;

    function setUp() public {
        _setUpCore();
        _initPool(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        _addFullRangeLiquidity(LIQUIDITY);
        _startTokens = token.balanceOf(address(this));
    }

    // ------------------------------------------------------------------------------------------ exact reasons

    function test_buyCapRevertCarriesWalletTotalAndCap() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SigmoidIMD.WalletBuyCapExceeded.selector, alice, cap + 1, cap)
            )
        );
        _buyExactOut(alice, cap + 1);
    }

    function test_cumulativeBuyCapRevertCountsEarlierBuys() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        _buyExactOut(alice, cap - 10);
        vm.roll(block.number + 3);
        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SigmoidIMD.WalletBuyCapExceeded.selector, alice, cap + 1, cap)
            )
        );
        _buyExactOut(alice, 11);
        // Exactly up to the cap still fits.
        _buyExactOut(alice, 10);
        assertEq(hook.boughtInWindow(poolId, alice), cap);
    }

    function test_cooldownCountsSellsAndBuysAlike() public {
        _sell(alice, 1e21);
        vm.roll(block.number + 2);
        uint256 last = block.number - 2;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SigmoidIMD.WalletCooldown.selector, alice, last, last + 3)
            )
        );
        _buy(alice, 1e21);
    }

    // ------------------------------------------------------------------------------------------ atomicity

    function test_revertedSwapLeavesNoBookkeepingBehind() public {
        // A breaker-tripping buy reverts as a whole: neither the cooldown nor the buy tally nor the settled
        // price move, so the same wallet may trade again in the same block.
        vm.expectRevert();
        _buy(alice, LIQUIDITY / 4);
        assertEq(hook.lastSwapBlock(poolId, alice), 0);
        assertEq(hook.boughtInWindow(poolId, alice), 0);
        assertEq(hook.launches(poolId).lastSettledSqrtPriceX96, SQRT_PRICE_1_1);
        _buy(alice, 1e21);
        assertEq(hook.lastSwapBlock(poolId, alice), block.number);
    }

    function test_capRevertDoesNotConsumeCooldown() public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        vm.expectRevert();
        _buyExactOut(alice, cap + 1);
        _buyExactOut(alice, cap); // same block, same wallet: allowed because the failed swap left no trace
        assertEq(hook.boughtInWindow(poolId, alice), cap);
    }

    // ------------------------------------------------------------------------------------------ window edges

    function test_rulesStillApplyInLastWindowBlockAndStopAfter() public {
        uint256 creation = hook.launches(poolId).creationBlock;
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        vm.roll(creation + 99);
        _buy(alice, 1e21);
        vm.expectRevert(); // cooldown, last window block
        _buy(alice, 1e21);
        vm.expectRevert(); // cap, last window block
        _buyExactOut(bob, cap + 1);

        vm.roll(creation + 100);
        _buy(alice, 1e21); // one block later: no cooldown
        _buyExactOut(bob, cap + 1); // and no cap
        assertEq(hook.boughtInWindow(poolId, bob), 0);
    }

    function test_breakerAppliesInLastWindowBlockOnly() public {
        uint256 creation = hook.launches(poolId).creationBlock;
        vm.roll(creation + 99);
        vm.expectRevert();
        _sell(alice, LIQUIDITY / 4);
        vm.roll(creation + 100);
        _sell(alice, LIQUIDITY / 4);
    }

    // ------------------------------------------------------------------------------------------ fee

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactInputSurchargeNeverExceedsCapOfGrossOutput(uint256 imdIn, bool buy) public {
        _closeWindow();
        imdIn = bound(imdIn, 1e15, LIQUIDITY / 2);
        uint160 before = _sqrtPrice();
        BalanceDelta d = buy ? _buy(alice, imdIn) : _sell(alice, imdIn);
        uint256 net = buy ? uint256(uint128(_tokenDelta(d))) : uint256(uint128(_imdDelta(d)));
        uint256 fee = buy ? token.balanceOf(treasury) : imd.balanceOf(treasury);
        uint256 gross = net + fee;
        assertLe(fee * 1e6, gross * 897_000, "surcharge <= 89.7% of gross output");
        assertGe(net * 1e6, gross * 103_000 - 1e6, "trader keeps >= 10.3% of gross output");
        // The fee matches the formula for the measured impact (an oracle, not the hook's arithmetic: the impact
        // comes from the pool's prices before and after).
        uint256 impact = hook.priceImpactPips(before, _sqrtPrice());
        uint256 expectedPips = impact * 150 > 897_000 ? 897_000 : impact * 150;
        assertEq(fee, gross * expectedPips / 1e6);
    }

    function test_staticFeePoolIsNotOverridden() public {
        // A pool opened at a static LP fee keeps that fee: the hook only pins the fee on dynamic-fee pools.
        MockERC20 other = new MockERC20("Other", "OTHER");
        other.mint(address(this), 1e30);
        other.approve(address(swapRouter), type(uint256).max);
        other.approve(address(lpRouter), type(uint256).max);
        key = _keyFor(address(other), 12_500);
        poolId = key.toId();
        tokenIs0 = Currency.unwrap(key.currency0) == address(other);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(LIQUIDITY);
        _closeWindow();
        uint256 imdIn = 1e18;
        BalanceDelta d = _buy(alice, imdIn);
        uint256 out = uint256(uint128(_tokenDelta(d)));
        // 1.25% LP fee, negligible impact.
        assertGt(out, imdIn * 98_740 / 100_000);
        assertLt(out, imdIn * 98_760 / 100_000);
    }

    // ------------------------------------------------------------------------------------------ in-window fuzz

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_inWindowBuyObeysRulesOrRevertsWithOne(uint256 tokensOut, bool exactOut) public {
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        uint256 amount = bound(tokensOut, 1e15, 4 * cap);
        uint160 before = _sqrtPrice();
        vm.prank(address(this), alice);
        (bool ok, bytes memory reason) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(
                            !tokenIs0,
                            exactOut ? int256(amount) : -int256(amount),
                            tokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
                        ),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
        if (ok) {
            assertLe(hook.boughtInWindow(poolId, alice), cap);
            assertEq(hook.boughtInWindow(poolId, alice), token.balanceOf(address(this)) - _ownTokensBefore());
            assertLe(hook.priceImpactPips(before, _sqrtPrice()), 250_000);
        } else {
            (address target,, bytes memory inner,) = _unwrap(reason);
            assertEq(target, address(hook));
            bytes4 err = bytes4(inner);
            assertTrue(
                err == SigmoidIMD.WalletBuyCapExceeded.selector || err == SigmoidIMD.CircuitBreaker.selector,
                "a refused buy is refused by the cap or the breaker"
            );
        }
    }

    // ------------------------------------------------------------------------------------------ price impact

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_priceImpactIsZeroOnlyWithoutMoveAndGrowsWithDistance(uint160 a, uint160 b) public view {
        a = uint160(bound(a, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        b = uint160(bound(b, a, TickMath.MAX_SQRT_PRICE));
        assertEq(hook.priceImpactPips(a, a), 0);
        // Moving further up from `a` never measures less impact than moving to `b`.
        uint160 c = uint160(bound(uint256(b) + 1, b, TickMath.MAX_SQRT_PRICE));
        assertGe(hook.priceImpactPips(a, c), hook.priceImpactPips(a, b));
        // A move down never measures more than 100%.
        assertLe(hook.priceImpactPips(b, a), 1_000_000);
    }

    // ------------------------------------------------------------------------------------------ sweeping

    function test_sweepOfUnknownCurrencyReverts() public {
        vm.expectRevert(SigmoidIMD.NothingToSweep.selector);
        hook.sweepFees(Currency.wrap(address(token)));
    }

    function test_hookUnlockCallbackRefusesForgedCalls() public {
        // Nobody but the manager can drive the sweep callback, which burns claims and pays out.
        vm.prank(alice);
        vm.expectRevert(SigmoidIMD.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(Currency.wrap(address(imd)), uint256(1)));
    }

    // ------------------------------------------------------------------------------------------ helpers

    // The test contract starts with the whole token supply minus what it put into liquidity.
    uint256 internal _startTokens;

    function _ownTokensBefore() internal view returns (uint256) {
        return _startTokens;
    }

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

/// @dev Failure paths of the launchpad.
contract SigmoidLaunchpadEdgeTest is SigmoidTestBase {
    using PoolIdLibrary for PoolKey;

    SigmoidLaunchpad launchpad;
    address creator = makeAddr("creator");

    function setUp() public {
        _setUpCore();
        launchpad = new SigmoidLaunchpad(IPoolManager(address(manager)), hook);
    }

    function _nextTokenIs0() internal view returns (bool) {
        return vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad))) < address(imd);
    }

    function test_launchRejectsMisalignedTicks() public {
        (int24 lower, int24 upper) = _nextTokenIs0() ? (int24(0), int24(61)) : (int24(-61), int24(0));
        vm.expectRevert();
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, lower, upper);
        assertEq(launchpad.launchCount(), 0, "nothing recorded");
    }

    function test_launchRejectsEmptyRange() public {
        vm.expectRevert();
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, 0, 0);
        assertEq(launchpad.launchCount(), 0);
    }

    function test_launchRejectsPriceOutsideTickRange() public {
        vm.expectRevert();
        launchpad.launch("Bad", "BAD", TickMath.MIN_SQRT_PRICE - 1, -887_220, -600);
        vm.expectRevert();
        launchpad.launch("Bad", "BAD", 0, -887_220, -600);
        assertEq(launchpad.launchCount(), 0);
    }

    function test_launchRejectsTicksBeyondUsableRange() public {
        (int24 lower, int24 upper) = _nextTokenIs0() ? (int24(0), int24(887_280)) : (int24(-887_280), int24(0));
        vm.expectRevert();
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, lower, upper);
    }

    function test_twoLaunchesGetDistinctTokensAndPools() public {
        (int24 l0, int24 u0) = _nextTokenIs0() ? (int24(0), int24(887_220)) : (int24(-887_220), int24(0));
        vm.prank(creator);
        (, address t0, PoolKey memory k0) = launchpad.launch("A", "A", SQRT_PRICE_1_1, l0, u0);
        (int24 l1, int24 u1) = _nextTokenIs0() ? (int24(0), int24(887_220)) : (int24(-887_220), int24(0));
        vm.prank(alice);
        (, address t1, PoolKey memory k1) = launchpad.launch("B", "B", SQRT_PRICE_1_1, l1, u1);
        assertTrue(t0 != t1);
        assertTrue(PoolId.unwrap(k0.toId()) != PoolId.unwrap(k1.toId()));
        assertEq(launchpad.launches(1).creator, alice);
        assertEq(IERC20(t1).totalSupply(), 1e27);
        // Creator of launch 0 cannot collect launch 1 and vice versa.
        vm.prank(creator);
        vm.expectRevert(SigmoidLaunchpad.NotCreator.selector);
        launchpad.collectFees(1);
        vm.prank(alice);
        vm.expectRevert(SigmoidLaunchpad.NotCreator.selector);
        launchpad.collectFees(0);
    }

    function test_collectWithNoTradesPaysNothing() public {
        (int24 l0, int24 u0) = _nextTokenIs0() ? (int24(0), int24(887_220)) : (int24(-887_220), int24(0));
        vm.prank(creator);
        launchpad.launch("A", "A", SQRT_PRICE_1_1, l0, u0);
        vm.prank(creator);
        (uint256 a0, uint256 a1) = launchpad.collectFees(0);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_launchedPoolCannotBeReinitialized() public {
        (int24 l0, int24 u0) = _nextTokenIs0() ? (int24(0), int24(887_220)) : (int24(-887_220), int24(0));
        (,, PoolKey memory k) = launchpad.launch("A", "A", SQRT_PRICE_1_1, l0, u0);
        uint256 creation = hook.launches(k.toId()).creationBlock;
        vm.roll(block.number + 1000);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(hook.launches(k.toId()).creationBlock, creation, "the window cannot be restarted");
    }
}

