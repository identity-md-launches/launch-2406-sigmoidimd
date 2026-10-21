// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SigmoidIMD} from "../../src/SigmoidIMD.sol";
import {SigmoidLaunchpad} from "../../src/SigmoidLaunchpad.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Drives a launched pool with random buys and sells (both exact-input and exact-output), block rolls,
/// fee sweeps and LP-fee collection, from several wallets (`tx.origin`). Records what the hook should have
/// done in ghost state; invariants compare it with what the contracts report. A handler call that reverts is
/// discarded by the fuzzer, so rule violations are recorded as counters instead of assertions.
contract SigmoidHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager public immutable manager;
    PoolSwapTest public immutable router;
    SigmoidIMD public immutable hook;
    SigmoidLaunchpad public immutable launchpad;
    MockERC20 public immutable imd;
    IERC20 public immutable token;
    address public immutable creator;
    bool public immutable tokenIs0;
    PoolKey internal key;
    PoolId public immutable poolId;

    uint256 public constant IMD_FUNDS = 1e30;

    address[] public actors;

    // Ghost state.
    mapping(address => uint256) public ghostBought; // tokens a wallet received from buys inside the window
    mapping(address => uint256) public ghostLastSwap; // block of a wallet's last successful in-window swap
    uint256 public breakerViolations; // in-window swaps that moved the raw price more than 25%
    uint256 public cooldownViolations; // in-window swaps by one wallet less than 3 blocks apart
    uint256 public capViolations; // a wallet's in-window buys above 0.5% of supply
    uint256 public unexpectedHookReverts; // the hook reverted with an error that is none of its three rules
    uint256 public successfulSwaps;
    uint256 public ruleReverts;
    uint256 public sweeps;
    uint256 public collects;

    constructor(
        PoolManager manager_,
        PoolSwapTest router_,
        SigmoidIMD hook_,
        SigmoidLaunchpad launchpad_,
        MockERC20 imd_,
        PoolKey memory key_,
        address creator_
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        launchpad = launchpad_;
        imd = imd_;
        key = key_;
        poolId = key_.toId();
        creator = creator_;
        tokenIs0 = Currency.unwrap(key_.currency1) == address(imd_);
        token = IERC20(Currency.unwrap(tokenIs0 ? key_.currency0 : key_.currency1));
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        imd_.mint(address(this), IMD_FUNDS);
        imd_.approve(address(router_), type(uint256).max);
        token.approve(address(router_), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    // -------------------------------------------------------------------------------------------- actions

    function buyExactIn(uint256 actorSeed, uint256 imdIn, bool limited) external {
        _swap(actorSeed, !tokenIs0, -int256(bound(imdIn, 1e12, 3e24)), limited);
    }

    function buyExactOut(uint256 actorSeed, uint256 tokensOut, bool limited) external {
        _swap(actorSeed, !tokenIs0, int256(bound(tokensOut, 1e12, 3e24)), limited);
    }

    function sellExactIn(uint256 actorSeed, uint256 tokensIn, bool limited) external {
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;
        _swap(actorSeed, tokenIs0, -int256(bound(tokensIn, 1, held)), limited);
    }

    function sellExactOut(uint256 actorSeed, uint256 imdOut, bool limited) external {
        uint256 inPool = imd.balanceOf(address(manager));
        if (inPool < 2) return;
        _swap(actorSeed, tokenIs0, int256(bound(imdOut, 1, inPool / 2)), limited);
    }

    function roll(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 40));
    }

    function sweep(bool imdSide) external {
        Currency c = imdSide ? Currency.wrap(address(imd)) : Currency.wrap(address(token));
        try hook.sweepFees(c) {
            sweeps++;
        } catch {}
    }

    function collect() external {
        vm.prank(creator);
        launchpad.collectFees(0);
        collects++;
    }

    // -------------------------------------------------------------------------------------------- internals

    function _swap(uint256 actorSeed, bool zeroForOne, int256 amountSpecified, bool limited) internal {
        address actor = actors[actorSeed % actors.length];
        (uint160 before,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        bool inWindow = hook.inOpeningWindow(poolId);
        uint256 tokenBefore = token.balanceOf(address(this));

        uint160 limit;
        if (limited) {
            // Keep the raw price move under ~19%: sqrt price within x0.9 .. x1.09.
            limit = zeroForOne ? uint160(uint256(before) * 9 / 10) : uint160(uint256(before) * 109 / 100);
            if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
            if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        } else {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        vm.prank(address(this), actor);
        try router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            successfulSwaps++;
            (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
            if (!inWindow) return;
            if (_rawMoveOver25Percent(before, afterPrice)) breakerViolations++;
            uint256 last = ghostLastSwap[actor];
            if (last != 0 && block.number < last + 3) cooldownViolations++;
            ghostLastSwap[actor] = block.number;
            uint256 tokenAfter = token.balanceOf(address(this));
            if (tokenAfter > tokenBefore) {
                ghostBought[actor] += tokenAfter - tokenBefore;
                if (ghostBought[actor] > token.totalSupply() / 200) capViolations++;
            }
        } catch (bytes memory reason) {
            _classify(reason);
        }
    }

    /// @dev |p1 - p0| > p0 / 4 on the raw price p = sqrtP^2, computed with the sqrt prices squared in Q64.
    function _rawMoveOver25Percent(uint160 s0, uint160 s1) internal pure returns (bool) {
        uint256 p0 = FullMath.mulDiv(s0, s0, 1 << 64);
        uint256 p1 = FullMath.mulDiv(s1, s1, 1 << 64);
        uint256 diff = p1 > p0 ? p1 - p0 : p0 - p1;
        return diff * 4 > p0;
    }

    /// @dev Reverts from the hook come wrapped by the pool manager; anything else (a price limit already
    /// passed, an unfillable exact output, an empty balance) is the router's or the pool's business.
    function _classify(bytes memory reason) internal {
        if (reason.length < 4 || bytes4(reason) != CustomRevert.WrappedError.selector) return;
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = reason[i + 4];
        }
        (address target,, bytes memory inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
        if (target != address(hook)) return;
        bytes4 err = inner.length >= 4 ? bytes4(inner) : bytes4(0);
        if (
            err == SigmoidIMD.CircuitBreaker.selector || err == SigmoidIMD.WalletCooldown.selector
                || err == SigmoidIMD.WalletBuyCapExceeded.selector
        ) {
            ruleReverts++;
        } else {
            unexpectedHookReverts++;
        }
    }
}

contract SigmoidInvariantTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolSwapTest router;
    MockERC20 imd;
    SigmoidIMD hook;
    SigmoidLaunchpad launchpad;
    SigmoidHandler handler;
    IERC20 token;
    PoolKey key;
    PoolId poolId;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    SigmoidLaunchpad.LaunchInfo info;

    uint256 constant SUPPLY = 1e27;

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        imd = new MockERC20("IMD", "IMD");
        bytes memory args = abi.encode(IPoolManager(address(manager)), address(imd), treasury);
        (, bytes32 salt) =
            HookMiner.find(address(this), HookMiner.SIGMOID_FLAGS, type(SigmoidIMD).creationCode, args, 500_000);
        hook = new SigmoidIMD{salt: salt}(IPoolManager(address(manager)), address(imd), treasury);
        launchpad = new SigmoidLaunchpad(IPoolManager(address(manager)), hook);

        // Launch with the whole supply single-sided on the token side of a 1:1 opening price, on a fresh
        // manager that holds no IMD: the claim fallback for the surcharge is exercised too.
        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        (int24 lower, int24 upper) = predicted < address(imd) ? (int24(0), int24(887_220)) : (int24(-887_220), int24(0));
        vm.prank(creator);
        (, address launched, PoolKey memory k) =
            launchpad.launch("Fair", "FAIR", 79228162514264337593543950336, lower, upper);
        key = k;
        poolId = k.toId();
        token = IERC20(launched);
        info = launchpad.launches(0);

        handler = new SigmoidHandler(manager, router, hook, launchpad, imd, k, creator);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = SigmoidHandler.buyExactIn.selector;
        selectors[1] = SigmoidHandler.buyExactOut.selector;
        selectors[2] = SigmoidHandler.sellExactIn.selector;
        selectors[3] = SigmoidHandler.sellExactOut.selector;
        selectors[4] = SigmoidHandler.roll.selector;
        selectors[5] = SigmoidHandler.sweep.selector;
        selectors[6] = SigmoidHandler.collect.selector;
        selectors[7] = SigmoidHandler.buyExactIn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_launchTokenSupplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY, "fixed supply");
        uint256 accounted = token.balanceOf(address(manager)) + token.balanceOf(address(handler))
            + token.balanceOf(treasury) + token.balanceOf(creator) + token.balanceOf(address(hook))
            + token.balanceOf(address(launchpad));
        assertEq(accounted, SUPPLY, "every token is in the pool, with a trader, the treasury or the creator");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_imdIsConservedAndTradersNeverProfit() public view {
        uint256 accounted = imd.balanceOf(address(manager)) + imd.balanceOf(address(handler)) + imd.balanceOf(treasury)
            + imd.balanceOf(creator) + imd.balanceOf(address(hook)) + imd.balanceOf(address(launchpad));
        assertEq(accounted, imd.totalSupply(), "IMD only moves between known parties");
        // All IMD in the system came from the traders; together they can never take out more than they put in.
        assertLe(imd.balanceOf(address(handler)), handler.IMD_FUNDS(), "traders extracted IMD they never paid");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_claimsMatchPendingFeesAndAreBacked() public view {
        Currency[2] memory cs = [Currency.wrap(address(imd)), Currency.wrap(address(token))];
        for (uint256 i = 0; i < 2; i++) {
            uint256 pending = hook.pendingFees(cs[i]);
            assertEq(manager.balanceOf(address(hook), cs[i].toId()), pending, "claim balance == pendingFees");
            assertGe(IERC20(Currency.unwrap(cs[i])).balanceOf(address(manager)), pending, "claims are backed");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_nothingIsStuckInHookOrLaunchpad() public view {
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(launchpad)), 0);
        assertEq(imd.balanceOf(address(launchpad)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_launchLiquidityStaysLocked() public view {
        (uint128 liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(poolId, address(launchpad), info.tickLower, info.tickUpper, bytes32(0));
        assertEq(liquidity, info.liquidity, "the seeded position never shrinks or grows");
        assertEq(launchpad.launchCount(), 1);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_settledPriceTracksThePool() public view {
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(hook.launches(poolId).lastSettledSqrtPriceX96, sqrtPriceX96, "settled price == pool price");
        assertEq(hook.launches(poolId).token, address(token));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_windowRulesHold() public view {
        assertEq(handler.breakerViolations(), 0, "an in-window swap moved the raw price more than 25%");
        assertEq(handler.cooldownViolations(), 0, "a wallet swapped twice within 3 blocks in the window");
        assertEq(handler.capViolations(), 0, "a wallet bought more than 0.5% of supply in the window");
        assertEq(handler.unexpectedHookReverts(), 0, "the hook reverted for a reason that is not a rule");
        uint256 cap = hook.launches(poolId).maxBuyPerWallet;
        assertEq(cap, SUPPLY / 200);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 counted = hook.boughtInWindow(poolId, a);
            assertEq(counted, handler.ghostBought(a), "hook counts exactly what the wallet received");
            assertLe(counted, cap);
        }
    }

    /// @dev The handler is not vacuous: a fixed sequence through it trades, trips rules and sweeps.
    function test_handlerExercisesEveryPath() public {
        handler.buyExactOut(0, 1e24, false); // fresh manager: surcharge in IMD becomes a claim
        assertEq(handler.successfulSwaps(), 1);
        assertGt(hook.pendingFees(Currency.wrap(address(imd))), 0);
        handler.buyExactOut(0, 1e24, false); // same wallet, same block: cooldown
        assertEq(handler.ruleReverts(), 1);
        handler.buyExactIn(1, 3e24, false); // a second wallet
        handler.roll(3);
        handler.sellExactIn(2, 1e23, true);
        handler.sweep(true);
        assertEq(handler.sweeps(), 1);
        assertGt(imd.balanceOf(treasury), 0);
        handler.roll(40);
        handler.roll(40);
        handler.roll(40); // window over
        handler.buyExactIn(3, 3e24, false);
        handler.collect();
        assertEq(handler.collects(), 1);
        assertGt(handler.successfulSwaps(), 3);
        invariant_windowRulesHold();
        invariant_claimsMatchPendingFeesAndAreBacked();
        invariant_imdIsConservedAndTradersNeverProfit();
        invariant_launchTokenSupplyIsFixedAndFullyAccounted();
        invariant_settledPriceTracksThePool();
        invariant_launchLiquidityStaysLocked();
    }
}
