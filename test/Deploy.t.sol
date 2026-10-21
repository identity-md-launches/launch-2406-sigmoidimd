// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeploySigmoid} from "../script/Deploy.s.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployTest is Test {
    DeploySigmoid script;
    PoolManager manager;
    MockERC20 imd;
    address treasury = makeAddr("treasury");

    function setUp() public {
        script = new DeploySigmoid();
        manager = new PoolManager(address(this));
        imd = new MockERC20("IMD", "IMD");
    }

    function _config() internal view returns (DeploySigmoid.Config memory cfg) {
        cfg = DeploySigmoid.Config({
            poolManager: IPoolManager(address(manager)), pairCurrency: address(imd), treasury: treasury, hookSalt: 0
        });
    }

    function test_deployWiresEverything() public {
        DeploySigmoid.Config memory cfg = _config();
        (address predicted, bytes32 salt) = script.mineHookSalt(address(script), cfg);
        cfg.hookSalt = salt;

        DeploySigmoid.Deployment memory d = script.deploy(cfg);

        assertEq(address(d.hook), predicted, "the hook landed on its mined address");
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, HookMiner.SIGMOID_FLAGS);
        assertEq(address(d.hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(d.hook.pairCurrency()), address(imd));
        assertEq(d.hook.treasury(), treasury);
        assertEq(address(d.launchpad.poolManager()), address(manager));
        assertEq(address(d.launchpad.hook()), address(d.hook));
        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(address(script)), 1e27, "the token mints to its deployer");
    }

    function test_deployWithWrongSaltReverts() public {
        DeploySigmoid.Config memory cfg = _config();
        (, bytes32 salt) = script.mineHookSalt(address(script), cfg);
        cfg.hookSalt = bytes32(uint256(salt) + 1);
        vm.expectRevert();
        script.deploy(cfg);
    }

    function test_constantsAreTheRobinhoodChainValues() public view {
        assertEq(script.ROBINHOOD_CHAIN_ID(), 4663);
        assertEq(script.ROBINHOOD_POOL_MANAGER(), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(script.ROBINHOOD_IMD(), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    }

    function test_runRefusesOtherChains() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeploySigmoid.WrongChain.selector, 1, 4663));
        script.run();
    }
}
