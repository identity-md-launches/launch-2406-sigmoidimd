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
        uint256 surcharge = hook.surchargePips(hook.priceImpactPips(before, _sqrtPrice()));
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

    function test_sellBeforeAnyBuyFindsNoLiquidity() public {
        (, address launched) = _launch();
        IERC20(launched).approve(address(swapRouter), type(uint256).max);
        // The creator holds only dust; mint-less token, so borrow some by buying first, then try to push the
        // price into the empty side: the swap has nothing to fill and the router refuses it.
        _buyExactOut(alice, 1e24);
        vm.roll(block.number + 3);
        vm.expectRevert();
        _sell(alice, 2e24);
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
