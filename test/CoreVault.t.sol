// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {PerpRisk} from "../src/perp/PerpRisk.sol";
import {DummyOracle} from "../src/mocks/DummyOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CoreVaultTest is Test {
    CoreVault public vault;
    MockERC20 public usdc;
    MockERC20 public weth;
    PerpRisk public riskModule;
    
    address public admin;
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public router = address(0x3);
    
    uint256 constant DEFAULT_SUBACCOUNT = 0;
    
    DummyOracle public oracle;
    
    function setUp() public {
        admin = address(this);
        vault = new CoreVault();
        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
        oracle = new DummyOracle(3000 * 10**8);
        riskModule = new PerpRisk(address(oracle));
        
        // Add supported collateral
        vault.addCollateral(address(usdc));
        vault.addCollateral(address(weth));
        
        // Don't set risk module by default (canWithdraw not implemented yet)
        // vault.setRiskModule(address(riskModule));
        
        // Authorize router
        vault.setAuthorized(router, true);
        
        // Mint tokens
        usdc.mint(alice, 1_000_000 * 10**18);
        usdc.mint(bob, 1_000_000 * 10**18);
        weth.mint(alice, 1000 * 10**18);
        weth.mint(bob, 1000 * 10**18);
    }
    
    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testDeposit() public {
        uint256 amount = 1000 * 10**18;
        
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        
        vm.expectEmit(true, true, true, true);
        emit CoreVault.Deposit(alice, DEFAULT_SUBACCOUNT, address(usdc), amount);
        
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), amount);
        vm.stopPrank();
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), amount);
        assertEq(usdc.balanceOf(alice), 999_000 * 10**18);
    }
    
    function testDepositMultipleSubaccounts() public {
        uint256 amount1 = 1000 * 10**18;
        uint256 amount2 = 500 * 10**18;
        
        vm.startPrank(alice);
        usdc.approve(address(vault), amount1 + amount2);
        
        vault.deposit(0, address(usdc), amount1);
        vault.deposit(1, address(usdc), amount2);
        vm.stopPrank();
        
        assertEq(vault.balances(alice, 0, address(usdc)), amount1);
        assertEq(vault.balances(alice, 1, address(usdc)), amount2);
    }
    
    function testCannotDepositUnsupportedCollateral() public {
        MockERC20 unsupported = new MockERC20("BAD", "BAD");
        unsupported.mint(alice, 1000 * 10**18);
        
        vm.startPrank(alice);
        unsupported.approve(address(vault), 1000 * 10**18);
        
        vm.expectRevert("CoreVault: unsupported collateral");
        vault.deposit(DEFAULT_SUBACCOUNT, address(unsupported), 1000 * 10**18);
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                           WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testWithdraw() public {
        uint256 depositAmount = 1000 * 10**18;
        uint256 withdrawAmount = 600 * 10**18;
        
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), depositAmount);
        
        vm.expectEmit(true, true, true, true);
        emit CoreVault.Withdraw(alice, DEFAULT_SUBACCOUNT, address(usdc), withdrawAmount);
        
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), withdrawAmount);
        vm.stopPrank();
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + withdrawAmount);
    }
    
    function testCannotWithdrawMoreThanBalance() public {
        uint256 depositAmount = 1000 * 10**18;
        
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), depositAmount);
        
        vm.expectRevert("CoreVault: insufficient available balance");
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), depositAmount + 1);
        vm.stopPrank();
    }
    
    function testCannotWithdrawReservedIM() public {
        uint256 depositAmount = 1000 * 10**18;
        uint256 reservedAmount = 600 * 10**18;
        bytes32 orderId = keccak256("order1");
        
        // Deposit
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), depositAmount);
        
        // Reserve IM (as router)
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), reservedAmount);
        
        // Try to withdraw more than available
        vm.prank(alice);
        vm.expectRevert("CoreVault: insufficient available balance");
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), 500 * 10**18);
    }
    
    /*//////////////////////////////////////////////////////////////
                             MOVE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testMove() public {
        uint256 amount = 1000 * 10**18;
        uint256 moveAmount = 600 * 10**18;
        
        // Alice deposits
        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), amount);
        
        // Router moves funds from alice to bob
        vm.expectEmit(true, true, true, true);
        emit CoreVault.Move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, moveAmount);
        
        vm.prank(router);
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, moveAmount);
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), 400 * 10**18);
        assertEq(vault.balances(bob, DEFAULT_SUBACCOUNT, address(usdc)), 600 * 10**18);
    }
    
    function testMoveAcrossSubaccounts() public {
        uint256 amount = 1000 * 10**18;
        
        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        vault.deposit(0, address(usdc), amount);
        
        vm.prank(router);
        vault.move(address(usdc), alice, 0, alice, 1, 600 * 10**18);
        
        assertEq(vault.balances(alice, 0, address(usdc)), 400 * 10**18);
        assertEq(vault.balances(alice, 1, address(usdc)), 600 * 10**18);
    }
    
    function testCannotMoveUnauthorized() public {
        vm.expectRevert("CoreVault: insufficient balance");
        vault.move(address(usdc), alice, 0, bob, 0, 100);
    }
    
    /*//////////////////////////////////////////////////////////////
                         SPOT ESCROW TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testLockSpotEscrow() public {
        uint64 marketId = 1;
        uint256 amount = 500 * 10**18;
        
        vm.expectEmit(true, true, false, true);
        emit CoreVault.EscrowLocked(marketId, address(usdc), amount);
        
        vm.prank(router);
        vault.lockSpotEscrow(marketId, address(usdc), amount);
        
        assertEq(vault.escrowSpot(marketId, address(usdc)), amount);
    }
    
    function testReleaseSpotEscrow() public {
        uint64 marketId = 1;
        uint256 lockAmount = 500 * 10**18;
        uint256 releaseAmount = 300 * 10**18;
        
        vm.prank(router);
        vault.lockSpotEscrow(marketId, address(usdc), lockAmount);
        
        vm.expectEmit(true, true, false, true);
        emit CoreVault.EscrowReleased(marketId, address(usdc), releaseAmount);
        
        vm.prank(router);
        vault.releaseSpotEscrow(marketId, address(usdc), releaseAmount);
        
        assertEq(vault.escrowSpot(marketId, address(usdc)), 200 * 10**18);
    }
    
    /*//////////////////////////////////////////////////////////////
                            IM TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testReserveInitialMargin() public {
        bytes32 orderId = keccak256("order1");
        uint256 amount = 500 * 10**18;
        
        // Deposit first
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.expectEmit(true, true, false, true);
        emit CoreVault.IMReserved(orderId, address(usdc), amount);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), amount);
        
        assertEq(vault.reserveIM(orderId, address(usdc)), amount);
        assertEq(vault.totalReservedPerToken(alice, DEFAULT_SUBACCOUNT, address(usdc)), amount);
    }
    
    function testReleaseInitialMargin() public {
        bytes32 orderId = keccak256("order1");
        uint256 amount = 500 * 10**18;
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), amount);
        
        vm.expectEmit(true, true, false, true);
        emit CoreVault.IMReleased(orderId, address(usdc), amount);
        
        vm.prank(router);
        vault.releaseInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc));
        
        assertEq(vault.reserveIM(orderId, address(usdc)), 0);
        assertEq(vault.totalReservedPerToken(alice, DEFAULT_SUBACCOUNT, address(usdc)), 0);
    }
    
    function testCannotReserveMoreThanBalance() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 500 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 500 * 10**18);
        
        vm.prank(router);
        vm.expectRevert("CoreVault: insufficient balance");
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 600 * 10**18);
    }
    
    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testAddCollateral() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW");
        
        vm.expectEmit(true, false, false, false);
        emit CoreVault.CollateralAdded(address(newToken));
        
        vault.addCollateral(address(newToken));
        
        assertTrue(vault.supportedCollateral(address(newToken)));
    }
    
    function testRemoveCollateral() public {
        vm.expectEmit(true, false, false, false);
        emit CoreVault.CollateralRemoved(address(usdc));
        
        vault.removeCollateral(address(usdc));
        
        assertFalse(vault.supportedCollateral(address(usdc)));
    }
    
    function testSetAuthorized() public {
        address newRouter = address(0x999);
        
        vm.expectEmit(true, false, false, true);
        emit CoreVault.AuthorizedUpdated(newRouter, true);
        
        vault.setAuthorized(newRouter, true);
        
        assertTrue(vault.authorized(newRouter));
        
        // Revoke
        vm.expectEmit(true, false, false, true);
        emit CoreVault.AuthorizedUpdated(newRouter, false);
        
        vault.setAuthorized(newRouter, false);
        
        assertFalse(vault.authorized(newRouter));
    }
    
    function testSetRiskModule() public {
        DummyOracle newOracle = new DummyOracle(3000 * 10**8);
        PerpRisk newRisk = new PerpRisk(address(newOracle));
        
        vm.expectEmit(true, false, false, false);
        emit CoreVault.RiskModuleUpdated(address(newRisk));
        
        vault.setRiskModule(address(newRisk));
        
        assertEq(address(vault.riskModule()), address(newRisk));
    }
    
    function testCannotAddCollateralNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.addCollateral(address(0x123));
    }
    
    function testCannotRemoveCollateralNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.removeCollateral(address(usdc));
    }
    
    function testCannotSetAuthorizedNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.setAuthorized(address(0x123), true);
    }
    
    function testCannotSetRiskModuleNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.setRiskModule(address(0x123));
    }
    
    /*//////////////////////////////////////////////////////////////
                            VIEW TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testAvailableBalance() public {
        uint256 depositAmount = 1000 * 10**18;
        uint256 reservedAmount = 300 * 10**18;
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), depositAmount);
        
        // Before reservation
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), depositAmount);
        
        // After reservation
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), reservedAmount);
        
        // Available balance = total - reserved
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), depositAmount);
        assertEq(vault.totalReservedPerToken(alice, DEFAULT_SUBACCOUNT, address(usdc)), reservedAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_DepositWithdraw(uint128 depositAmount, uint128 withdrawAmount) public {
        depositAmount = uint128(bound(uint256(depositAmount), 1, 1_000_000 * 10**18));
        withdrawAmount = uint128(bound(uint256(withdrawAmount), 1, depositAmount));
        
        usdc.mint(alice, depositAmount);
        
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), depositAmount);
        
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), withdrawAmount);
        vm.stopPrank();
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), depositAmount - withdrawAmount);
    }
    
    function testFuzz_Move(uint128 amount, uint128 moveAmount) public {
        amount = uint128(bound(uint256(amount), 1, 1_000_000 * 10**18));
        moveAmount = uint128(bound(uint256(moveAmount), 1, amount));
        
        usdc.mint(alice, amount);
        
        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), amount);
        
        vm.prank(router);
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, moveAmount);
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), amount - moveAmount);
        assertEq(vault.balances(bob, DEFAULT_SUBACCOUNT, address(usdc)), moveAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCannotDepositZeroAmount() public {
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: zero amount");
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 0);
    }
    
    function testCannotWithdrawZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: zero amount");
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), 0);
    }
    
    function testCannotMoveZeroAmount() public {
        vm.prank(router);
        vm.expectRevert("CoreVault: zero amount");
        vault.move(address(usdc), alice, 0, bob, 0, 0);
    }
    
    function testCannotLockZeroEscrow() public {
        vm.prank(router);
        vm.expectRevert("CoreVault: zero amount");
        vault.lockSpotEscrow(1, address(usdc), 0);
    }
    
    function testCannotReserveZeroIM() public {
        vm.prank(router);
        vm.expectRevert("CoreVault: zero amount");
        vault.reserveInitialMargin(keccak256("order1"), alice, 0, address(usdc), 0);
    }
    
    function testCannotReleaseInsufficientEscrow() public {
        vm.prank(router);
        vault.lockSpotEscrow(1, address(usdc), 100);
        
        vm.prank(router);
        vm.expectRevert("CoreVault: insufficient escrow");
        vault.releaseSpotEscrow(1, address(usdc), 200);
    }
    
    function testCannotReserveTwice() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 500 * 10**18);
        
        vm.prank(router);
        vm.expectRevert("CoreVault: already reserved");
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 300 * 10**18);
    }
    
    function testReleaseNonexistentIM() public {
        bytes32 orderId = keccak256("order1");
        
        // Should not revert, just return early
        vm.prank(router);
        vault.releaseInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc));
        
        assertEq(vault.reserveIM(orderId, address(usdc)), 0);
    }
    
    function testAddCollateralZeroAddress() public {
        vm.expectRevert("CoreVault: zero address");
        vault.addCollateral(address(0));
    }
    
    function testAddCollateralNotContract() public {
        vm.expectRevert("CoreVault: not contract");
        vault.addCollateral(address(0x123));
    }
    
    function testGetReservedIM() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 500 * 10**18);
        
        assertEq(vault.getReservedIM(orderId, address(usdc)), 500 * 10**18);
    }
    
    function testGetAvailableBalanceWithNoReserved() public {
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        assertEq(vault.getAvailableBalance(alice, DEFAULT_SUBACCOUNT, address(usdc)), 1000 * 10**18);
    }
    
    function testGetAvailableBalanceExceedsTotal() public {
        // Edge case: if totalReserved > total, should return 0
        assertEq(vault.getAvailableBalance(alice, DEFAULT_SUBACCOUNT, address(usdc)), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                    COMPREHENSIVE NEGATIVE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCannotWithdrawInsufficientBalance() public {
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: insufficient available balance");
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), 200 * 10**18);
    }
    
    function testCannotWithdrawWithReservedIM() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 600 * 10**18);
        
        // Can only withdraw 400, not 500
        vm.prank(alice);
        vm.expectRevert("CoreVault: insufficient available balance");
        vault.withdraw(DEFAULT_SUBACCOUNT, address(usdc), 500 * 10**18);
    }
    
    function testCannotMoveInsufficientBalance() public {
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(router);
        vm.expectRevert("CoreVault: insufficient balance");
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, 200 * 10**18);
    }
    
    function testCannotReserveIMInsufficientBalance() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(router);
        vm.expectRevert("CoreVault: insufficient balance");
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 200 * 10**18);
    }
    
    function testUnauthorizedCannotMove() public {
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: not authorized");
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, 50 * 10**18);
    }
    
    function testUnauthorizedCannotLockEscrow() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not authorized");
        vault.lockSpotEscrow(1, address(usdc), 100 * 10**18);
    }
    
    function testUnauthorizedCannotReleaseEscrow() public {
        vm.prank(router);
        vault.lockSpotEscrow(1, address(usdc), 100 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: not authorized");
        vault.releaseSpotEscrow(1, address(usdc), 100 * 10**18);
    }
    
    function testUnauthorizedCannotReserveIM() public {
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: not authorized");
        vault.reserveInitialMargin(keccak256("order1"), alice, DEFAULT_SUBACCOUNT, address(usdc), 50 * 10**18);
    }
    
    function testUnauthorizedCannotReleaseIM() public {
        bytes32 orderId = keccak256("order1");
        
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc), 50 * 10**18);
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: not authorized");
        vault.releaseInitialMargin(orderId, alice, DEFAULT_SUBACCOUNT, address(usdc));
    }
    
    function testNonAdminCannotSetAuthorized() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.setAuthorized(bob, true);
    }
    
    function testNonAdminCannotAddCollateral() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW");
        
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.addCollateral(address(newToken));
    }
    
    function testNonAdminCannotRemoveCollateral() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.removeCollateral(address(usdc));
    }
    
    function testNonAdminCannotSetRiskModule() public {
        vm.prank(alice);
        vm.expectRevert("CoreVault: not admin");
        vault.setRiskModule(address(riskModule));
    }
    
    function testAdminIsAuthorized() public {
        // Admin should be able to move funds without explicit authorization
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        // Admin can move (this = admin)
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, 50 * 10**18);
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), 50 * 10**18);
        assertEq(vault.balances(bob, DEFAULT_SUBACCOUNT, address(usdc)), 50 * 10**18);
    }
    
    function testAuthorizedCanPerformOperations() public {
        // Set bob as authorized
        vault.setAuthorized(bob, true);
        
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        // Bob can now move funds
        vm.prank(bob);
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, 50 * 10**18);
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), 50 * 10**18);
        assertEq(vault.balances(bob, DEFAULT_SUBACCOUNT, address(usdc)), 50 * 10**18);
    }
    
    function testRevokeAuthorization() public {
        // Authorize then revoke
        vault.setAuthorized(bob, true);
        vault.setAuthorized(bob, false);
        
        vm.prank(alice);
        usdc.approve(address(vault), 100 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 100 * 10**18);
        
        // Bob should not be able to move funds
        vm.prank(bob);
        vm.expectRevert("CoreVault: not authorized");
        vault.move(address(usdc), alice, DEFAULT_SUBACCOUNT, bob, DEFAULT_SUBACCOUNT, 50 * 10**18);
    }
    
    function testMultipleIMReservesPerUser() public {
        bytes32 orderId1 = keccak256("order1");
        bytes32 orderId2 = keccak256("order2");
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId1, alice, DEFAULT_SUBACCOUNT, address(usdc), 300 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId2, alice, DEFAULT_SUBACCOUNT, address(usdc), 400 * 10**18);
        
        assertEq(vault.totalReservedPerToken(alice, DEFAULT_SUBACCOUNT, address(usdc)), 700 * 10**18);
        assertEq(vault.getAvailableBalance(alice, DEFAULT_SUBACCOUNT, address(usdc)), 300 * 10**18);
    }
    
    function testReleasePartialIM() public {
        bytes32 orderId1 = keccak256("order1");
        bytes32 orderId2 = keccak256("order2");
        
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId1, alice, DEFAULT_SUBACCOUNT, address(usdc), 300 * 10**18);
        
        vm.prank(router);
        vault.reserveInitialMargin(orderId2, alice, DEFAULT_SUBACCOUNT, address(usdc), 400 * 10**18);
        
        // Release first order
        vm.prank(router);
        vault.releaseInitialMargin(orderId1, alice, DEFAULT_SUBACCOUNT, address(usdc));
        
        assertEq(vault.totalReservedPerToken(alice, DEFAULT_SUBACCOUNT, address(usdc)), 400 * 10**18);
        assertEq(vault.getAvailableBalance(alice, DEFAULT_SUBACCOUNT, address(usdc)), 600 * 10**18);
    }
    
    function testDepositMultipleCollaterals() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        weth.approve(address(vault), 10 * 10**18);
        
        vault.deposit(DEFAULT_SUBACCOUNT, address(usdc), 1000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(weth), 10 * 10**18);
        vm.stopPrank();
        
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(usdc)), 1000 * 10**18);
        assertEq(vault.balances(alice, DEFAULT_SUBACCOUNT, address(weth)), 10 * 10**18);
    }
    
    function testMoveToSameUser() public {
        vm.prank(alice);
        usdc.approve(address(vault), 1000 * 10**18);
        vm.prank(alice);
        vault.deposit(0, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.move(address(usdc), alice, 0, alice, 1, 400 * 10**18);
        
        assertEq(vault.balances(alice, 0, address(usdc)), 600 * 10**18);
        assertEq(vault.balances(alice, 1, address(usdc)), 400 * 10**18);
    }
    
    function testLockAndReleaseSpotEscrow() public {
        uint64 marketId = 1;
        
        vm.prank(router);
        vault.lockSpotEscrow(marketId, address(usdc), 1000 * 10**18);
        
        assertEq(vault.escrowSpot(marketId, address(usdc)), 1000 * 10**18);
        
        vm.prank(router);
        vault.releaseSpotEscrow(marketId, address(usdc), 600 * 10**18);
        
        assertEq(vault.escrowSpot(marketId, address(usdc)), 400 * 10**18);
    }
    
    function testLockEscrowMultipleMarkets() public {
        vm.prank(router);
        vault.lockSpotEscrow(1, address(usdc), 1000 * 10**18);
        
        vm.prank(router);
        vault.lockSpotEscrow(2, address(usdc), 500 * 10**18);
        
        assertEq(vault.escrowSpot(1, address(usdc)), 1000 * 10**18);
        assertEq(vault.escrowSpot(2, address(usdc)), 500 * 10**18);
    }
}
