// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {PerpVault} from "../../../src/perp/PerpVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title PerpVaultHandler
/// @notice Handler for invariant testing of PerpVault
contract PerpVaultHandler is CommonBase, StdCheats, StdUtils {
    PerpVault public vault;
    MockERC20 public collateral;
    uint64 public marketId;
    
    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalReserved;
    uint256 public ghost_totalReleased;
    
    // Call counters
    uint256 public calls_depositMargin;
    uint256 public calls_withdrawMargin;
    uint256 public calls_reserveIM;
    uint256 public calls_releaseIM;
    uint256 public calls_adjustMargin;
    
    // Track users
    address[] public users;
    mapping(address => bool) public isUser;
    
    constructor(PerpVault _vault, MockERC20 _collateral, uint64 _marketId) {
        vault = _vault;
        collateral = _collateral;
        marketId = _marketId;
    }

    /// @notice Deposit margin for a user
    function depositMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_depositMargin++;
        
        address user = _getUser(userSeed);
        uint256 amount = bound(amountSeed, 1 ether, 10_000 ether);
        
        // Ensure handler has enough
        uint256 balance = collateral.balanceOf(address(this));
        if (balance < amount) return;
        
        collateral.approve(address(vault), amount);
        
        vm.prank(address(this));
        try vault.depositMargin(address(collateral), amount, user) {
            ghost_totalDeposited += amount;
        } catch {
            // Deposit failed, ignore
        }
    }

    /// @notice Withdraw margin
    function withdrawMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_withdrawMargin++;
        
        address user = _getUser(userSeed);
        uint256 balance = vault.marginBalances(user, address(collateral));
        
        if (balance == 0) return;
        
        uint256 amount = bound(amountSeed, 1, balance);
        
        vm.prank(user);
        try vault.withdrawMargin(address(collateral), amount, user) {
            ghost_totalWithdrawn += amount;
        } catch {
            // Withdraw failed (likely insufficient available margin)
        }
    }

    /// @notice Reserve initial margin
    function reserveInitialMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_reserveIM++;
        
        address user = _getUser(userSeed);
        uint256 available = vault.getAvailableMargin(user, address(collateral));
        
        if (available == 0) return;
        
        uint256 amount = bound(amountSeed, 1, available);
        
        try vault.reserveInitialMargin(user, marketId, address(collateral), amount) {
            ghost_totalReserved += amount;
        } catch {
            // Reserve failed
        }
    }

    /// @notice Release initial margin
    function releaseInitialMargin(uint256 userSeed, uint256 amountSeed) public {
        calls_releaseIM++;
        
        address user = _getUser(userSeed);
        // H2 FIX: Use new triple-key mapping signature
        uint256 reserved = vault.reservedIm(user, marketId, address(collateral));
        
        if (reserved == 0) return;
        
        uint256 amount = bound(amountSeed, 1, reserved);
        
        try vault.releaseInitialMargin(user, marketId, address(collateral), amount) {
            ghost_totalReleased += amount;
        } catch {
            // Release failed
        }
    }

    /// @notice Adjust margin (PnL) - Note: restricted to AuctionHouse, will always fail in handler
    /// We skip this function as it's onlyAuctionHouse
    function adjustMargin(uint256 userSeed, int256 amountSeed) public {
        calls_adjustMargin++;
        
        // This function is onlyAuctionHouse and will always revert
        // We don't attempt to call it and don't update ghost variables
        // This is correct behavior as only the AuctionHouse should adjust margin for PnL
        
        // Suppress unused variable warnings
        userSeed;
        amountSeed;
    }

    /// @notice Get a user address (create if doesn't exist)
    function _getUser(uint256 seed) internal returns (address) {
        uint256 index = bound(seed, 0, 9); // Max 10 users
        
        if (index < users.length) {
            return users[index];
        }
        
        address newUser = address(uint160(0x1000 + users.length));
        users.push(newUser);
        isUser[newUser] = true;
        return newUser;
    }

    /// @notice Get all users
    function getUsers() external view returns (address[] memory) {
        return users;
    }

    /// @notice Print call summary
    function callSummary() external view {
        console.log("\n=== PerpVault Call Summary ===");
        console.log("depositMargin calls:", calls_depositMargin);
        console.log("withdrawMargin calls:", calls_withdrawMargin);
        console.log("reserveIM calls:", calls_reserveIM);
        console.log("releaseIM calls:", calls_releaseIM);
        console.log("adjustMargin calls:", calls_adjustMargin);
        console.log("\n=== Ghost Variables ===");
        console.log("Total deposited:", ghost_totalDeposited);
        console.log("Total withdrawn:", ghost_totalWithdrawn);
        console.log("Total reserved:", ghost_totalReserved);
        console.log("Total released:", ghost_totalReleased);
        console.log("Number of users:", users.length);
    }
}
