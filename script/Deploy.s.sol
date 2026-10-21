// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SigmoidToken} from "../src/SigmoidToken.sol";
import {SigmoidIMD} from "../src/SigmoidIMD.sol";
import {SigmoidLaunchpad} from "../src/SigmoidLaunchpad.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title DeploySigmoid
/// @notice Reviewable deployment of the token, the hook (at a mined CREATE2 address) and the launchpad.
/// @dev `run()` reads only what the operator must supply (the treasury) from the environment and uses the
/// Robinhood Chain constants below. `deploy()` takes the whole configuration as an argument so tests exercise it
/// directly with their own PoolManager and without any environment.
contract DeploySigmoid is Script {
    /// @notice Robinhood Chain mainnet.
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;
    /// @notice Canonical Uniswap v4 PoolManager on Robinhood Chain.
    address public constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @notice IMD on Robinhood Chain, the pair currency of every pool on the hook.
    address public constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    /// @notice forge's deterministic CREATE2 deployer, used for `new X{salt: ...}` inside a broadcast.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        IPoolManager poolManager;
        address pairCurrency;
        address treasury;
        bytes32 hookSalt;
    }

    struct Deployment {
        SigmoidToken token;
        SigmoidIMD hook;
        SigmoidLaunchpad launchpad;
    }

    error WrongChain(uint256 actual, uint256 expected);

    function run() external returns (Deployment memory d) {
        if (block.chainid != ROBINHOOD_CHAIN_ID) revert WrongChain(block.chainid, ROBINHOOD_CHAIN_ID);
        Config memory cfg = Config({
            poolManager: IPoolManager(ROBINHOOD_POOL_MANAGER),
            pairCurrency: ROBINHOOD_IMD,
            treasury: vm.envAddress("TREASURY"),
            hookSalt: bytes32(0)
        });
        (, cfg.hookSalt) = mineHookSalt(CREATE2_DEPLOYER, cfg);
        vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice Finds the salt that lands the hook on an address carrying its permission flags when deployed by
    /// `deployer` through CREATE2.
    function mineHookSalt(address deployer, Config memory cfg) public pure returns (address hookAddress, bytes32 salt) {
        return HookMiner.find(
            deployer,
            HookMiner.SIGMOID_FLAGS,
            type(SigmoidIMD).creationCode,
            abi.encode(cfg.poolManager, cfg.pairCurrency, cfg.treasury),
            1_000_000
        );
    }

    /// @notice Deploys the three contracts for `cfg`. The hook is created with CREATE2 and `cfg.hookSalt`.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        d.token = new SigmoidToken();
        d.hook = new SigmoidIMD{salt: cfg.hookSalt}(cfg.poolManager, cfg.pairCurrency, cfg.treasury);
        d.launchpad = new SigmoidLaunchpad(cfg.poolManager, d.hook);
    }
}
