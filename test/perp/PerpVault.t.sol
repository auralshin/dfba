// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpVault} from "../../src/perp/PerpVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title PerpVault Comprehensive Test Suite
/// @notice Tests both functionality AND security properties
contract PerpVaultTest is Test {
    PerpVault public vault;
    MockERC20 public collateralToken;
    MockERC20 public collateralToken2;
    
    address public admin = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public perpEngine = address(0x999);
    address public attacker = address(0x666);
    
    uint64 public constant MARKET_ID = 1;
    uint64 public constant MARKET_ID_2 = 2;

    function setUp() public {
        vault = new PerpVault();
        collateralToken = new MockERC20("Collateral", "COLL");
        collateralToken2 = new MockERC20("Collateral2", "COLL2");
        
        // Mint tokens to users
        collateralToken.mint(user1, 10000 ether);
        collateralToken.mint(user2, 10000 ether);
        collateralToken.mint(attacker, 10000 ether);
        
        collateralToken2.mint(user1, 10000 ether);
        
        // Add collateral tokens as supported
        vault.addCollateral(address(collateralToken));
        vault.addCollateral(address(collateralToken2));
        
        // Authorize perpEngine
        vault.setAuthorized(perpEngine, true);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_depositMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        assertEq(vault.marginBalances(user1, address(collateralToken)), amount);
    }

    function test_withdrawMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        
        vault.withdrawMargin(address(collateralToken), 500 ether, user1);
        vm.stopPrank();
        
        assertEq(vault.marginBalances(user1, address(collateralToken)), 500 ether);
    }

    function test_reserveInitialMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.prank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 500 ether);
        
        assertEq(vault.reservedIm(user1, MARKET_ID, address(collateralToken)), 500 ether);
        assertEq(vault.marginBalances(user1, address(collateralToken)), 1000 ether);
        assertEq(vault.getAvailableMargin(user1, address(collateralToken)), 500 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Only authorized contracts can reserve IM
    function test_security_onlyAuthorizedCanReserveIM() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.prank(attacker);
        vm.expectRevert("PerpVault: not authorized");
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 500 ether);
    }

    function test_security_onlyAuthorizedCanReleaseIM() public {
        vm.prank(attacker);
        vm.expectRevert("PerpVault: not authorized");
        vault.releaseInitialMargin(user1, MARKET_ID, address(collateralToken), 100 ether);
    }

    function test_security_onlyAuthorizedCanAdjustMargin() public {
        vm.prank(attacker);
        vm.expectRevert("PerpVault: not authorized");
        vault.adjustMargin(user1, address(collateralToken), 100 ether);
    }

    function test_security_onlyAdminCanAddCollateral() public {
        MockERC20 newToken = new MockERC20("New", "NEW");
        
        vm.prank(attacker);
        vm.expectRevert("PerpVault: not admin");
        vault.addCollateral(address(newToken));
    }

    /*//////////////////////////////////////////////////////////////
                SECURITY: WITHDRAWAL ATTACKS (C4)
    //////////////////////////////////////////////////////////////*/

    /// @notice C4: Cannot withdraw below maintenance margin
    function test_security_cannotWithdrawBelowMaintenance() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        // Reserve 600 ether as IM
        vm.prank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 600 ether);
        
        // Try to withdraw 500 ether (would leave only 500 ether, below 600 reserved)
        vm.prank(user1);
        vm.expectRevert("PerpVault: insufficient available margin");
        vault.withdrawMargin(address(collateralToken), 500 ether, user1);
    }

    /// @notice Cannot withdraw more than deposited
    function test_security_cannotWithdrawMoreThanBalance() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        
        vm.expectRevert("PerpVault: insufficient available margin");
        vault.withdrawMargin(address(collateralToken), 1500 ether, user1);
        vm.stopPrank();
    }

    /// @notice Cannot withdraw someone else's margin
    function test_security_cannotWithdrawOthersMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        // Attacker tries to withdraw user1's margin
        vm.prank(attacker);
        vm.expectRevert("PerpVault: insufficient available margin");
        vault.withdrawMargin(address(collateralToken), 100 ether, user1);
    }

    /*//////////////////////////////////////////////////////////////
            SECURITY: MULTI-COLLATERAL (H2 FIX VALIDATION)
    //////////////////////////////////////////////////////////////*/

    /// @notice H2: Multi-collateral IM tracking must not overwrite
    function test_security_multiCollateralDoesNotOverwrite() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 2000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount1);
        vault.depositMargin(address(collateralToken), amount1, user1);
        
        collateralToken2.approve(address(vault), amount2);
        vault.depositMargin(address(collateralToken2), amount2, user1);
        vm.stopPrank();
        
        vm.startPrank(perpEngine);
        // Reserve IM for token1
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 400 ether);
        
        // Reserve IM for token2 (should NOT overwrite token1's reservation)
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken2), 800 ether);
        vm.stopPrank();
        
        // Verify both reservations exist independently
        assertEq(vault.reservedIm(user1, MARKET_ID, address(collateralToken)), 400 ether, "Token1 IM should be preserved");
        assertEq(vault.reservedIm(user1, MARKET_ID, address(collateralToken2)), 800 ether, "Token2 IM should be set");
        
        // Verify available margins are correct
        assertEq(vault.getAvailableMargin(user1, address(collateralToken)), 600 ether);
        assertEq(vault.getAvailableMargin(user1, address(collateralToken2)), 1200 ether);
    }

    /// @notice Multi-market IM tracking per collateral
    function test_security_multiMarketMultiCollateralTracking() public {
        uint256 amount = 2000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.startPrank(perpEngine);
        // Reserve IM for market1
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 500 ether);
        
        // Reserve IM for market2 (should be additive)
        vault.reserveInitialMargin(user1, MARKET_ID_2, address(collateralToken), 700 ether);
        vm.stopPrank();
        
        // Verify both market reservations
        assertEq(vault.reservedIm(user1, MARKET_ID, address(collateralToken)), 500 ether);
        assertEq(vault.reservedIm(user1, MARKET_ID_2, address(collateralToken)), 700 ether);
        
        // Available margin should account for BOTH reservations
        assertEq(vault.getAvailableMargin(user1, address(collateralToken)), 800 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY: MARGIN MANIPULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Cannot reserve more IM than available margin
    function test_security_cannotReserveMoreThanAvailable() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.prank(perpEngine);
        vm.expectRevert("PerpVault: insufficient margin");
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 1500 ether);
    }

    /// @notice Cannot release more IM than reserved
    function test_security_cannotReleaseMoreThanReserved() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.startPrank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 500 ether);
        
        vm.expectRevert("PerpVault: insufficient reserved");
        vault.releaseInitialMargin(user1, MARKET_ID, address(collateralToken), 600 ether);
        vm.stopPrank();
    }

    /// @notice Negative margin adjustment cannot make balance negative
    function test_security_negativeAdjustmentBounded() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.prank(perpEngine);
        vm.expectRevert("PerpVault: insufficient margin");
        vault.adjustMargin(user1, address(collateralToken), -1500 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        SECURITY: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Cannot deposit unsupported collateral
    function test_security_cannotDepositUnsupportedCollateral() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNSUP");
        unsupportedToken.mint(user1, 1000 ether);
        
        vm.startPrank(user1);
        unsupportedToken.approve(address(vault), 100 ether);
        vm.expectRevert("PerpVault: unsupported collateral");
        vault.depositMargin(address(unsupportedToken), 100 ether, user1);
        vm.stopPrank();
    }

    function test_security_cannotDepositZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("PerpVault: zero amount");
        vault.depositMargin(address(collateralToken), 0, user1);
    }

    function test_security_cannotWithdrawZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("PerpVault: zero amount");
        vault.withdrawMargin(address(collateralToken), 0, user1);
    }

    /*//////////////////////////////////////////////////////////////
                    LEGACY TESTS (UPDATED)
    //////////////////////////////////////////////////////////////*/

    function test_reserveInitialMargin_revertsInsufficientMargin() public {
        vm.prank(perpEngine);
        vm.expectRevert("PerpVault: insufficient margin");
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 100 ether);
    }

    function test_releaseInitialMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.startPrank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 500 ether);
        vault.releaseInitialMargin(user1, MARKET_ID, address(collateralToken), 200 ether);
        vm.stopPrank();
        
        assertEq(vault.reservedIm(user1, MARKET_ID, address(collateralToken)), 300 ether);
    }

    function test_adjustMargin_positive() public {
        uint256 initialAmount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), initialAmount);
        vault.depositMargin(address(collateralToken), initialAmount, user1);
        vm.stopPrank();
        
        // Mint tokens to vault for positive adjustment
        collateralToken.mint(address(vault), 500 ether);
        
        vm.prank(perpEngine);
        vault.adjustMargin(user1, address(collateralToken), 500 ether);
        
        assertEq(vault.marginBalances(user1, address(collateralToken)), 1500 ether);
    }

    function test_adjustMargin_negative() public {
        uint256 initialAmount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), initialAmount);
        vault.depositMargin(address(collateralToken), initialAmount, user1);
        vm.stopPrank();
        
        vm.prank(perpEngine);
        vault.adjustMargin(user1, address(collateralToken), -500 ether);
        
        assertEq(vault.marginBalances(user1, address(collateralToken)), 500 ether);
    }

    function test_getAvailableMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        uint256 available = vault.getAvailableMargin(user1, address(collateralToken));
        assertEq(available, amount);
        
        // Reserve some margin
        vm.prank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 300 ether);
        
        available = vault.getAvailableMargin(user1, address(collateralToken));
        assertEq(available, 700 ether);
    }

    function test_getReservedInitialMargin() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount);
        vault.depositMargin(address(collateralToken), amount, user1);
        vm.stopPrank();
        
        vm.prank(perpEngine);
        vault.reserveInitialMargin(user1, MARKET_ID, address(collateralToken), 400 ether);
        
        uint256 reserved = vault.getReservedInitialMargin(user1, MARKET_ID, address(collateralToken));
        assertEq(reserved, 400 ether);
    }
}
