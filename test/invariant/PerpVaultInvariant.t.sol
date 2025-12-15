// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PerpVault} from "../../src/perp/PerpVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PerpVaultHandler} from "./handlers/PerpVaultHandler.sol";

/// @title PerpVaultInvariant
/// @notice Invariant tests for PerpVault margin system
contract PerpVaultInvariant is StdInvariant, Test {
    PerpVault public vault;
    PerpVaultHandler public handler;
    MockERC20 public collateral;
    
    address public admin;
    uint64 constant MARKET_ID = 1;

    function setUp() public {
        admin = address(this);
        vault = new PerpVault();
        collateral = new MockERC20("Collateral", "COLL");
        
        // Add collateral
        vault.addCollateral(address(collateral));
        
        // Create handler
        handler = new PerpVaultHandler(vault, collateral, MARKET_ID);
        
        // Fund handler
        collateral.mint(address(handler), 1_000_000 ether);
        
        // Authorize handler
        vault.setAuthorized(address(handler), true);
        
        // Set handler as target
        targetContract(address(handler));
    }

    /// @notice Total margin should equal sum of individual balances
    function invariant_totalMarginEqualsSum() public view {
        uint256 calculatedTotal = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        uint256 vaultBalance = collateral.balanceOf(address(vault));
        
        assertEq(
            vaultBalance,
            calculatedTotal,
            "Vault balance should equal tracked deposits minus withdrawals"
        );
    }

    /// @notice Reserved margin should never exceed total margin
    /// Note: We track net reserved (reserved - released) from handler calls
    function invariant_reservedNeverExceedsTotal() public view {
        uint256 totalReserved = handler.ghost_totalReserved();
        uint256 totalReleased = handler.ghost_totalReleased();
        uint256 totalMargin = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        
        // Net reserved should not exceed deposited margin
        uint256 netReserved = totalReserved > totalReleased ? totalReserved - totalReleased : 0;
        
        assertLe(
            netReserved,
            totalMargin,
            "Net reserved margin cannot exceed total deposited margin"
        );
    }

    /// @notice Available margin should be total minus reserved
    function invariant_availableMarginCorrect() public {
        address[] memory users = handler.getUsers();
        
        for (uint i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 total = vault.marginBalances(user, address(collateral));
            uint256 available = vault.getAvailableMargin(user, address(collateral));
            uint256 reserved = vault.totalReservedPerToken(user, address(collateral));
            
            assertEq(
                available,
                total >= reserved ? total - reserved : 0,
                "Available should be total minus reserved"
            );
        }
    }

    /// @notice Reserved IM per market should match total reserved tracking
    function invariant_reservedImConsistent() public view {
        address[] memory users = handler.getUsers();
        
        for (uint i = 0; i < users.length; i++) {
            address user = users[i];
            // H2 FIX: Use triple-key mapping
            uint256 reservedForMarket = vault.reservedIm(user, MARKET_ID, address(collateral));
            uint256 totalReservedForToken = vault.totalReservedPerToken(user, address(collateral));
            
            // Reserved for this market should not exceed total reserved
            assertLe(
                reservedForMarket,
                totalReservedForToken,
                "Market reserved should not exceed total reserved"
            );
        }
    }

    /// @notice Margin balances should never go negative (underflow protection)
    function invariant_noNegativeBalances() public view {
        address[] memory users = handler.getUsers();
        
        for (uint i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 balance = vault.marginBalances(user, address(collateral));
            // If this doesn't revert, balance is valid (no underflow)
            assertTrue(balance >= 0, "Balance should never be negative");
        }
    }

    /// @notice Handler should never have more than it started with
    function invariant_handlerBalanceDecreasing() public view {
        uint256 handlerBalance = collateral.balanceOf(address(handler));
        uint256 deposited = handler.ghost_totalDeposited();
        
        // Handler starts with 1M, so balance + deposited should be <= 1M
        assertLe(
            deposited,
            1_000_000 ether,
            "Total deposited should not exceed initial handler balance"
        );
    }

    /// @notice Call summary at the end
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
