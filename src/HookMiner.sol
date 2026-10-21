// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook on an address whose low 14 bits equal its permission flags.
/// @dev Every function is internal so nothing here is ever linked into deployed bytecode.
library HookMiner {
    error NoSaltFound();

    /// @notice The flags SigmoidIMD's address must carry.
    uint160 internal constant SIGMOID_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @notice Searches salts from 0 upwards until CREATE2 from `deployer` lands on an address carrying `flags`.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 maxIterations
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < maxIterations; i++) {
            hookAddress = computeAddress(deployer, bytes32(i), initCodeHash);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags) return (hookAddress, bytes32(i));
        }
        revert NoSaltFound();
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
