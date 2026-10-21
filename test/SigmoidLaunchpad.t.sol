// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SigmoidIMD} from "../src/SigmoidIMD.sol";
import {SigmoidLaunchpad} from "../src/SigmoidLaunchpad.sol";
import {SigmoidTestBase} from "./utils/SigmoidTestBase.sol";

contract SigmoidLaunchpadTest is SigmoidTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SigmoidLaunchpad launchpad;
    address creator = makeAddr("creator");

    int24 constant MAX_TICK = 887_220; // maxUsableTick(60)
    int24 constant MIN_TICK = -887_220;

    function setUp() public {
        _setUpCore();
        launchpad = new SigmoidLaunchpad(IPoolManager(address(manager)), hook);
    }

    /// @dev Predicts which side the next launched token sorts on and returns a 1:1 opening with the whole range
    /// on the token side.
    function _singleSidedParams() internal view returns (bool nextTokenIs0, uint160 price, int24 lower, int24 upper) {
        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        nextTokenIs0 = predicted < address(imd);
        price = SQRT_PRICE_1_1;
        // Token is currency0: token-only liquidity sits above the price. Token is currency1: below it.
        (lower, upper) = nextTokenIs0 ? (int24(0), MAX_TICK) : (MIN_TICK, int24(0));
    }

    function _launch() internal returns (uint256 id, address launched) {
        (, uint160 price, int24 lower, int24 upper) = _singleSidedParams();
        vm.prank(creator);
        (id, launched, key) = launchpad.launch("Fair Coin", "FAIR", price, lower, upper);
        poolId = key.toId();
        tokenIs0 = Currency.unwrap(key.currency0) == launched;
        IERC20(launched).approve(address(swapRouter), type(uint256).max);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(SigmoidLaunchpad.ZeroAddress.selector);
        new SigmoidLaunchpad(IPoolManager(address(0)), hook);
        vm.expectRevert(SigmoidLaunchpad.ZeroAddress.selector);
        new SigmoidLaunchpad(IPoolManager(address(manager)), SigmoidIMD(address(0)));
    }

    function test_launchDeploysTokenPoolAndLiquidity() public {
        (uint256 id, address launched) = _launch();
        assertEq(id, 0);
        assertEq(launchpad.launchCount(), 1);

        // The token: 1B supply, requested name and symbol, all of it in the pool (dust aside).
        assertEq(IERC20(launched).totalSupply(), 1e27);
        assertEq(IERC20Metadata(launched).name(), "Fair Coin");
        assertEq(IERC20Metadata(launched).symbol(), "FAIR");
        uint256 inPool = IERC20(launched).balanceOf(address(manager));
        assertGt(inPool, 1e27 - 1e6, "virtually the whole supply is seeded");
        assertEq(IERC20(launched).balanceOf(address(launchpad)), 0, "nothing stuck in the launchpad");
        assertEq(IERC20(launched).balanceOf(creator), 1e27 - inPool, "dust went to the creator");

        // The pool: IMD pair, dynamic fee, the hook, registered with the hook.
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
        assertTrue(Currency.unwrap(key.currency0) == address(imd) || Currency.unwrap(key.currency1) == address(imd));
        assertEq(hook.launches(poolId).token, launched);
        assertTrue(hook.inOpeningWindow(poolId));
        assertEq(imd.balanceOf(address(manager)), 0, "single-sided: no IMD was needed");

        // The position: held by the launchpad, in range at the opening price.
        SigmoidLaunchpad.LaunchInfo memory info = launchpad.launches(id);
        assertEq(info.creator, creator);
        assertEq(info.token, launched);
        assertGt(info.liquidity, 0);
        // Token as currency0: the range [0, max] is in range at tick 0. Token as currency1: the range [min, 0]
        // is one tick below the price and becomes active with the first buy.
        if (tokenIs0) {
            assertEq(IPoolManager(address(manager)).getLiquidity(poolId), info.liquidity, "seeded liquidity is active");
        } else {
            assertEq(
                IPoolManager(address(manager)).getLiquidity(poolId), 0, "seeded liquidity sits just below the price"
            );
            _buyExactOut(alice, 1e18);
            assertEq(IPoolManager(address(manager)).getLiquidity(poolId), info.liquidity, "active after the first buy");
        }
    }

    function test_launchRejectsRangeOnWrongSide() public {
        (bool nextTokenIs0,,,) = _singleSidedParams();
        // The pair side of the price instead of the token side.
        (int24 lower, int24 upper) = nextTokenIs0 ? (MIN_TICK, int24(0)) : (int24(0), MAX_TICK);
        vm.expectRevert(SigmoidLaunchpad.RangeNotSingleSided.selector);
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, lower, upper);
    }

    function test_launchRejectsRangeStraddlingPrice() public {
        vm.expectRevert(SigmoidLaunchpad.RangeNotSingleSided.selector);
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, -600, 600);
    }

    function test_launchRejectsRangeWithAGapFromTheOpeningPrice() public {
        (bool nextTokenIs0,,,) = _singleSidedParams();
        // Right side, but starting 3000 ticks (35% / 26%) away from the opening price: the first buy would jump
        // the gap and trip the breaker for the whole window.
        (int24 lower, int24 upper) = nextTokenIs0 ? (int24(3000), MAX_TICK) : (MIN_TICK, int24(-3000));
        vm.expectRevert(SigmoidLaunchpad.RangeNotAtOpeningPrice.selector);
        launchpad.launch("Bad", "BAD", SQRT_PRICE_1_1, lower, upper);
    }

    function test_launchAtTickOpensAtTheTokenPriceWhicheverSideItSortsOn() public {
        int24 priceTick = 6000; // 1.0001^6000 = 1.822 IMD per token
        vm.prank(creator);
        (uint256 id, address launched, PoolKey memory k) =
            launchpad.launchAtTick("Tick Coin", "TICK", priceTick, 60_000);
        bool is0 = Currency.unwrap(k.currency0) == launched;
        (uint160 sqrtPrice, int24 tick,,) = IPoolManager(address(manager)).getSlot0(k.toId());
        assertEq(tick, is0 ? priceTick : -priceTick, "pool tick is the token price tick on the token's side");
        assertEq(sqrtPrice, TickMath.getSqrtPriceAtTick(is0 ? priceTick : -priceTick));
        SigmoidLaunchpad.LaunchInfo memory info = launchpad.launches(id);
        assertEq(info.tickLower, is0 ? priceTick : -priceTick - 60_000);
        assertEq(info.tickUpper, is0 ? priceTick + 60_000 : -priceTick);
        assertGt(info.liquidity, 0);
        assertEq(info.creator, creator);
        assertGt(IERC20(launched).balanceOf(address(manager)), 1e27 - 1e6, "whole supply seeded");

        // The first buy trades at about the opening price: 1 IMD buys about 1/1.822 tokens minus the LP fee.
        key = k;
        poolId = k.toId();
        tokenIs0 = is0;
        IERC20(launched).approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = _buyExactOut(alice, 1e18);
        uint256 paid = _abs(_imdDelta(d));
        uint256 expected = uint256(1.822e18) * 1e6 / (1e6 - 3_000); // opening price plus the 0.30% LP fee
        assertApproxEqRel(paid, expected, 2e15, "paid at the opening price");
    }

    function test_launchAtTickIsIndependentOfTheNonce() public {
        // Two launches in a row land on whichever side their addresses sort to; both open at 1:1 with the range
        // starting at the opening price, with no side to predict.
        (, address a, PoolKey memory ka) = launchpad.launchAtTick("A", "A", 0, MAX_TICK);
        (, address b, PoolKey memory kb) = launchpad.launchAtTick("B", "B", 0, MAX_TICK);
        (uint160 pa,,,) = IPoolManager(address(manager)).getSlot0(ka.toId());
        (uint160 pb,,,) = IPoolManager(address(manager)).getSlot0(kb.toId());
        assertEq(pa, SQRT_PRICE_1_1);
        assertEq(pb, SQRT_PRICE_1_1);
        assertEq(hook.launches(ka.toId()).token, a);
        assertEq(hook.launches(kb.toId()).token, b);
    }

    function test_launchAtTickRejectsUnalignedTicks() public {
        vm.expectRevert(SigmoidLaunchpad.TickNotAligned.selector);
        launchpad.launchAtTick("X", "X", 30, 600);
        vm.expectRevert(SigmoidLaunchpad.TickNotAligned.selector);
        launchpad.launchAtTick("X", "X", 0, 630);
        vm.expectRevert(SigmoidLaunchpad.TickNotAligned.selector);
        launchpad.launchAtTick("X", "X", 0, 0);
        vm.expectRevert(SigmoidLaunchpad.TickNotAligned.selector);
        launchpad.launchAtTick("X", "X", 0, -600);
    }

    /// @dev A swap of 1 wei of the token into the empty side of the pool: fills nothing, only slides the price.
    function _push(address origin, uint256 sqrtRatioBps) internal {
        uint160 cur = _sqrtPrice();
        uint160 limit =
            tokenIs0 ? uint160(uint256(cur) * 10_000 / sqrtRatioBps) : uint160(uint256(cur) * sqrtRatioBps / 10_000);
        vm.prank(address(this), origin);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: tokenIs0, amountSpecified: -1, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_zeroFillPushIsNotSettledAndDoesNotTripTheBreaker() public {
        _launch();
        uint160 opening = _sqrtPrice();
        _push(address(0xA1), 11_135); // sqrt ratio 1.1135: a 24% price move, for free, inside the window
        _push(address(0xA2), 11_135);
        assertTrue(_sqrtPrice() != opening, "the pool price slid");
        SigmoidIMD.Launch memory l = hook.launches(poolId);
        assertEq(l.lastSettledSqrtPriceX96, opening, "nothing settled");
        assertEq(l.latestSqrtPriceX96, opening);
        assertEq(IERC20(hook.launches(poolId).token).balanceOf(treasury), 0, "no surcharge on a zero fill");
        // An ordinary buy still goes through and is measured from the opening price.
        BalanceDelta d = _buyExactOut(alice, 1e24);
        assertEq(uint256(uint128(_tokenDelta(d))), 1e24);
        assertLt(hook.tokenPriceImpactPips(tokenIs0, opening, _sqrtPrice()), 10_000);
    }

    function test_zeroFillPushDoesNotChangeTheNextBuyersFee() public {
        (, address launched) = _launch();
        _closeWindow();
        uint256 snap = vm.snapshotState();
        BalanceDelta d = _buy(alice, 1e24);
        uint256 netUntouched = uint256(uint128(_tokenDelta(d)));
        uint256 feeUntouched = IERC20(launched).balanceOf(treasury);
        vm.revertToState(snap);
        _push(address(0xA1), 30_000); // sqrt ratio 3: price slid 9x into the empty side
        d = _buy(alice, 1e24);
        assertEq(uint256(uint128(_tokenDelta(d))), netUntouched, "same output as on the untouched pool");
        assertEq(IERC20(launched).balanceOf(treasury), feeUntouched, "same fee as on the untouched pool");
    }

    function test_unknownLaunchReverts() public {
        vm.expectRevert(SigmoidLaunchpad.UnknownLaunch.selector);
        launchpad.launches(0);
        vm.expectRevert(SigmoidLaunchpad.UnknownLaunch.selector);
        launchpad.collectFees(0);
    }

    function test_unlockCallbackRefusesNonManager() public {
        vm.expectRevert(SigmoidLaunchpad.NotPoolManager.selector);
        launchpad.unlockCallback("");
    }

    function test_firstBuyInsideWindowWorksAndSurchargeBecomesClaimOnFreshManager() public {
        (, address launched) = _launch();
        // Exact-output buy: the surcharge is taken from the IMD input, and a fresh manager holding no IMD
        // cannot pay the treasury at once, so the hook keeps an ERC-6909 claim.
        uint256 want = 1e24; // 0.1% of supply, inside the cap and well inside the breaker
        BalanceDelta d = _buyExactOut(alice, want);
        assertEq(uint256(uint128(_tokenDelta(d))), want);
        assertEq(IERC20(launched).balanceOf(address(this)), want);
        uint256 pending = hook.pendingFees(Currency.wrap(address(imd)));
        assertGt(pending, 0, "surcharge held as a claim");
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), pending);

        // Now the manager holds IMD (the swap settled), so anyone can sweep the claim to the treasury.
        vm.prank(bob);
        uint256 swept = hook.sweepFees(Currency.wrap(address(imd)));
        assertEq(swept, pending);
        assertEq(imd.balanceOf(treasury), pending);
        assertEq(hook.pendingFees(Currency.wrap(address(imd))), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), 0);
    }

    function test_exactInputBuyOnFreshManagerPaysTreasuryDirectly() public {
        (, address launched) = _launch();
        uint160 before = _sqrtPrice();
        BalanceDelta d = _buy(alice, 1e24);
        uint256 netOut = uint256(uint128(_tokenDelta(d)));
        uint256 fee = IERC20(launched).balanceOf(treasury);
        uint256 surcharge = hook.surchargePips(hook.tokenPriceImpactPips(tokenIs0, before, _sqrtPrice()));
        assertGt(fee, 0, "the output token is in the pool, so it is paid out at once");
        assertEq(fee, (netOut + fee) * surcharge / 1e6);
        assertEq(hook.pendingFees(Currency.wrap(launched)), 0);
    }

    function test_launchedPoolEnforcesWindowRules() public {
        _launch();
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        assertEq(cap, 5e24);
        vm.expectRevert();
        _buyExactOut(alice, cap + 1);
        _buyExactOut(alice, 1e24);
        vm.expectRevert(); // cooldown
        _buyExactOut(alice, 1e24);
        vm.roll(block.number + 3);
        _buyExactOut(alice, 1e24);
    }

    function test_sellingBackEverythingBoughtCannotDrainThePool() public {
        (, address launched) = _launch();
        uint160 opening = _sqrtPrice();
        IERC20(launched).approve(address(swapRouter), type(uint256).max);
        // Every token outside the pool came out of it, and the LP fee keeps a little IMD behind on each buy, so
        // selling back everything that was bought never exhausts the pool's IMD: the price returns to about the
        // opening, stays inside the liquidity, and the breaker does not trip.
        _buyExactOut(alice, 1e24);
        vm.roll(block.number + 3);
        BalanceDelta d = _sell(alice, 1e24);
        assertEq(_abs(_tokenDelta(d)), 1e24, "fully filled");
        assertGt(IPoolManager(address(manager)).getLiquidity(poolId), 0, "the price is still inside the range");
        assertApproxEqRel(uint256(_sqrtPrice()), uint256(opening), 1e15);
        assertEq(hook.launches(poolId).latestSqrtPriceX96, _sqrtPrice());
    }

    function test_collectFeesPaysCreatorOnly() public {
        (, address launched) = _launch();
        _closeWindow();
        _buy(alice, 1e24);
        vm.roll(block.number + 1);
        _sell(alice, 5e23);

        vm.prank(bob);
        vm.expectRevert(SigmoidLaunchpad.NotCreator.selector);
        launchpad.collectFees(0);

        uint256 imdBefore = imd.balanceOf(creator);
        uint256 tokBefore = IERC20(launched).balanceOf(creator);
        vm.prank(creator);
        (uint256 a0, uint256 a1) = launchpad.collectFees(0);
        assertGt(a0 + a1, 0, "the position earned LP fees");
        assertEq(imd.balanceOf(creator) - imdBefore + IERC20(launched).balanceOf(creator) - tokBefore, a0 + a1);
        assertEq(
            IPoolManager(address(manager)).getLiquidity(poolId),
            launchpad.launches(0).liquidity,
            "liquidity stays locked"
        );
    }

    function test_secondLaunchGetsItsOwnPoolAndWindow() public {
        _launch();
        vm.roll(block.number + 500);
        (uint256 id2,) = _launch();
        assertEq(id2, 1);
        assertEq(hook.launches(poolId).creationBlock, block.number);
        assertTrue(hook.inOpeningWindow(poolId));
        assertFalse(hook.inOpeningWindow(launchpad.launches(0).key.toId()));
    }
}
