// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SigmoidToken} from "../src/SigmoidToken.sol";
import {FixedSupplyERC20} from "../src/FixedSupplyERC20.sol";

contract SigmoidTokenTest is Test {
    SigmoidToken token;

    function setUp() public {
        token = new SigmoidToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "SigmoidIMD");
        assertEq(token.symbol(), "SIGMOID");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
    }

    function test_transferMovesExactly() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1e24));
        assertEq(token.balanceOf(to), 1e24);
        assertEq(token.balanceOf(address(this)), 1e27 - 1e24);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromNeedsAllowance() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), spender, 1);
        token.approve(spender, 5);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, 5));
        assertEq(token.balanceOf(spender), 5);
    }

    function test_hasNoMintOrAdminFunctions() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "pause()",
            "transferOwnership(address)",
            "owner()",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function test_launchpadTokenTakesNameAndSymbol() public {
        FixedSupplyERC20 t = new FixedSupplyERC20("Any Name", "ANY");
        assertEq(t.name(), "Any Name");
        assertEq(t.symbol(), "ANY");
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.balanceOf(address(this)), 1e27);
    }
}
