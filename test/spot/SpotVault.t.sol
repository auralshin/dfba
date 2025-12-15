// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpotVault} from "../../src/spot/SpotVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SpotVaultTest is Test {
    SpotVault public vault;
    MockERC20 public token;
    
    address public admin = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        vault = new SpotVault();
        token = new MockERC20("Test", "TEST");
        
        // Mint tokens to users
        token.mint(user1, 10000 ether);
        token.mint(user2, 10000 ether);
    }

    function test_deposit() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        vault.deposit(address(token), amount, user1);
        vm.stopPrank();
        
        assertEq(vault.balances(user1, address(token)), amount, "Balance should be updated");
        assertEq(token.balanceOf(address(vault)), amount, "Vault should hold tokens");
    }

    function test_withdraw() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        vault.deposit(address(token), amount, user1);
        
        uint256 withdrawAmount = 500 ether;
        vault.withdraw(address(token), withdrawAmount, user1);
        vm.stopPrank();
        
        assertEq(vault.balances(user1, address(token)), amount - withdrawAmount, "Balance should be reduced");
        assertEq(token.balanceOf(user1), 10000 ether - amount + withdrawAmount, "User should receive tokens");
    }

    function test_withdraw_revertsInsufficientBalance() public {
        vm.startPrank(user1);
        vm.expectRevert("SpotVault: insufficient balance");
        vault.withdraw(address(token), 1000 ether, user1);
        vm.stopPrank();
    }

    function test_debitCredit() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        vault.deposit(address(token), amount, user1);
        vm.stopPrank();
        
        // Authorize this contract
        vault.setAuthorized(admin, true);
        
        // Transfer from user1 to user2
        vault.debitCredit(address(token), user1, user2, 500 ether);
        
        assertEq(vault.balances(user1, address(token)), 500 ether, "User1 balance should decrease");
        assertEq(vault.balances(user2, address(token)), 500 ether, "User2 balance should increase");
    }

    function test_debitCredit_revertsUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.debitCredit(address(token), user1, user2, 100 ether);
    }

    function test_batchDebitCredit() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        vault.deposit(address(token), amount, user1);
        vm.stopPrank();
        
        vault.setAuthorized(admin, true);
        
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        
        froms[0] = user1;
        froms[1] = user1;
        tos[0] = user2;
        tos[1] = admin;
        amounts[0] = 300 ether;
        amounts[1] = 200 ether;
        
        vault.batchDebitCredit(address(token), froms, tos, amounts);
        
        assertEq(vault.balances(user1, address(token)), 500 ether, "User1 should have 500");
        assertEq(vault.balances(user2, address(token)), 300 ether, "User2 should have 300");
        assertEq(vault.balances(admin, address(token)), 200 ether, "Admin should have 200");
    }

    function test_setAuthorized() public {
        address authorized = address(0x123);
        
        vault.setAuthorized(authorized, true);
        
        // Can't directly check authorization, but can verify it doesn't revert
        // when authorized address calls protected function
    }
}
