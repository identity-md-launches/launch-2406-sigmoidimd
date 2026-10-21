// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Freely mintable ERC-20 standing in for IMD in tests.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A contract with code but no `totalSupply`, to stand in for a non-ERC-20 currency.
contract NotAnERC20 {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
