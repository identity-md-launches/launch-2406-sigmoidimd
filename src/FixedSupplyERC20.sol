// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FixedSupplyERC20
/// @notice A plain, fixed-supply ERC-20: exactly 1,000,000,000 tokens (18 decimals) are minted once to the
/// deployer in the constructor. There is no owner, no mint, no pause, no blocklist, no fee and no upgrade path.
/// @dev `SigmoidToken` is the no-argument launch token built on this; `SigmoidLaunchpad` deploys fresh
/// instances with a caller-chosen name and symbol.
contract FixedSupplyERC20 is ERC20 {
    /// @notice The whole supply, in minor units (1e9 tokens at 18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
