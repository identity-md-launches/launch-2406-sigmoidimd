// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSupplyERC20} from "./FixedSupplyERC20.sol";

/// @title SigmoidToken
/// @notice The launch token: "SigmoidIMD" (SIGMOID), 1,000,000,000 tokens at 18 decimals minted once to the
/// deployer (the launch factory). No constructor arguments and no privileged functions of any kind.
contract SigmoidToken is FixedSupplyERC20 {
    constructor() FixedSupplyERC20("SigmoidIMD", "SIGMOID") {}
}
