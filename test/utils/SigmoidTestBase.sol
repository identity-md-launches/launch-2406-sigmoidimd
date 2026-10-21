// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SigmoidIMD} from "../../src/SigmoidIMD.sol";
import {SigmoidToken} from "../../src/SigmoidToken.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Shared scaffolding: a PoolManager, routers, a mock IMD, the launch token and a mined hook.
abstract contract SigmoidTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    MockERC20 internal imd;
    SigmoidToken internal token;
    SigmoidIMD internal hook;
    address internal treasury = makeAddr("treasury");

    PoolKey internal key;
    PoolId internal poolId;
    bool internal tokenIs0;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _setUpCore() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        imd = new MockERC20("IMD", "IMD");
        token = new SigmoidToken();
        hook = _deployHook(address(imd), treasury);

        imd.mint(address(this), 1e30);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
    }

    function _deployHook(address pair, address treasury_) internal returns (SigmoidIMD deployed) {
        bytes memory args = abi.encode(IPoolManager(address(manager)), pair, treasury_);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookMiner.SIGMOID_FLAGS, type(SigmoidIMD).creationCode, args, 500_000);
        deployed = new SigmoidIMD{salt: salt}(IPoolManager(address(manager)), pair, treasury_);
        assertEq(address(deployed), predicted, "hook landed off its mined address");
    }

    /// @dev Builds the launch pool key for `fee` and initializes it at 1:1.
    function _initPool(uint24 fee) internal {
        key = _keyFor(address(token), fee);
        poolId = key.toId();
        tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function _keyFor(address launchToken, uint24 fee) internal view returns (PoolKey memory k) {
        (address c0, address c1) =
            launchToken < address(imd) ? (launchToken, address(imd)) : (address(imd), launchToken);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Two-sided full-range liquidity so both directions trade in tests.
    function _addFullRangeLiquidity(uint256 liquidity) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Swaps as `wallet` (tx.origin), paying from this contract's balances through the test router.
    function _swapAs(address wallet, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(address(this), wallet);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev IMD in, token out, exact input.
    function _buy(address wallet, uint256 imdIn) internal returns (BalanceDelta) {
        return _swapAs(wallet, !tokenIs0, -int256(imdIn));
    }

    /// @dev IMD in, token out, exact output.
    function _buyExactOut(address wallet, uint256 tokensOut) internal returns (BalanceDelta) {
        return _swapAs(wallet, !tokenIs0, int256(tokensOut));
    }

    /// @dev Token in, IMD out, exact input.
    function _sell(address wallet, uint256 tokensIn) internal returns (BalanceDelta) {
        return _swapAs(wallet, tokenIs0, -int256(tokensIn));
    }

    /// @dev Token in, IMD out, exact output.
    function _sellExactOut(address wallet, uint256 imdOut) internal returns (BalanceDelta) {
        return _swapAs(wallet, tokenIs0, int256(imdOut));
    }

    function _tokenDelta(BalanceDelta d) internal view returns (int128) {
        return tokenIs0 ? d.amount0() : d.amount1();
    }

    function _imdDelta(BalanceDelta d) internal view returns (int128) {
        return tokenIs0 ? d.amount1() : d.amount0();
    }

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    /// @dev Rolls past the opening window.
    function _closeWindow() internal {
        vm.roll(block.number + hook.OPENING_WINDOW_BLOCKS());
    }
}
