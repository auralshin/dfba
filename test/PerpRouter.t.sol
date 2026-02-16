// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PerpRouter} from "../src/core/PerpRouter.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {PerpRisk} from "../src/perp/PerpRisk.sol";
import {OracleAdapter} from "../src/perp/OracleAdapter.sol";
import {DummyOracle} from "../src/mocks/DummyOracle.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PerpRouterTest is Test {
    PerpRouter public router;
    CoreVault public vault;
    AuctionHouse public auctionHouse;
    PerpRisk public risk;
    DummyOracle public oracle;
    
    MockERC20 public collateralToken;
    MockERC20 public perpBaseToken; // Dummy token for perp market
    
    address public admin = address(this);
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    
    uint64 public perpMarketId;
    uint256 constant DEFAULT_SUBACCOUNT = 0;
    
    function setUp() public {
        // Deploy contracts
        vault = new CoreVault();
        auctionHouse = new AuctionHouse();
        oracle = new DummyOracle(50000 * 10**8); // BTC price $50k
        risk = new PerpRisk(address(oracle));
        router = new PerpRouter(address(vault), address(auctionHouse), address(risk));
        
        // Deploy collateral token
        collateralToken = new MockERC20("USDC", "USDC");
        perpBaseToken = new MockERC20("BTC", "BTC"); // Dummy for perp market
        
        // Setup vault
        vault.addCollateral(address(collateralToken));
        vault.setAuthorized(address(router), true);
        vault.setAuthorized(address(auctionHouse), true);
        
        // Grant router ROUTER_ROLE in AuctionHouse
        bytes32 routerRole = keccak256("ROUTER_ROLE");
        auctionHouse.grantRole(routerRole, address(router));
        
        // Grant settlement role to admin for testing
        bytes32 settlementRole = keccak256("SETTLEMENT_ROLE");
        router.grantRole(settlementRole, admin);
        
        // Create perp market
        perpMarketId = auctionHouse.createMarketWithOracle(
            OrderTypes.MarketType.Perp,
            address(perpBaseToken), // Use dummy token
            address(collateralToken),
            address(oracle)
        );
        
        // Setup risk parameters
        PerpRisk.RiskParams memory riskParams = PerpRisk.RiskParams({
            initialMarginBps: 1000, // 10%
            maintenanceMarginBps: 500, // 5%
            liquidationFeeBps: 50, // 0.5%
            maxLeverage: 10,
            maxPositionSize: type(uint128).max
        });
        risk.setRiskParams(perpMarketId, riskParams);
        
        // Mint tokens to traders
        collateralToken.mint(trader1, 1_000_000 * 10**18);
        collateralToken.mint(trader2, 1_000_000 * 10**18);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ORDER SUBMISSION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testSubmitPerpOrder() public {
        uint256 depositAmount = 100_000 * 10**18;
        
        // Deposit collateral
        vm.startPrank(trader1);
        collateralToken.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), depositAmount);
        vm.stopPrank();
        
        // Create perp order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0, // At market price
            qty: 1 * 10**18, // 1 BTC
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        vm.prank(trader1);
        (bytes32 orderId, uint64 batchId) = router.submitOrder(order, address(collateralToken));
        
        assertTrue(orderId != bytes32(0));
        assertTrue(batchId > 0);
        
        // Check IM was reserved
        PerpRouter.IMReserve memory reserve = router.getIMReserve(orderId);
        assertGt(reserve.amount, 0);
        assertEq(reserve.user, trader1);
        assertEq(reserve.collateral, address(collateralToken));
    }
    
    function testCannotSubmitUnauthorized() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        vm.prank(trader2);
        vm.expectRevert("PerpRouter: unauthorized");
        router.submitOrder(order, address(collateralToken));
    }
    
    function testCannotSubmitInsufficientIM() public {
        // Create large order without enough collateral
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10**18, // 1000 BTC
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        vm.prank(trader1);
        vm.expectRevert("PerpRouter: insufficient IM");
        router.submitOrder(order, address(collateralToken));
    }
    
    /*//////////////////////////////////////////////////////////////
                      POSITION UPDATE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testUpdatePosition() public {
        // Initial position is 0
        assertEq(router.getPosition(trader1, perpMarketId), 0);
        
        // Update position (as settlement contract)
        router.updatePosition(trader1, perpMarketId, 5 * 10**18, OrderTypes.Side.Buy);
        
        // Check position increased
        assertEq(router.getPosition(trader1, perpMarketId), int256(5 * 10**18));
        
        // Sell some
        router.updatePosition(trader1, perpMarketId, 2 * 10**18, OrderTypes.Side.Sell);
        
        // Check position decreased
        assertEq(router.getPosition(trader1, perpMarketId), int256(3 * 10**18));
    }
    
    function testCannotUpdatePositionUnauthorized() public {
        vm.prank(trader1);
        vm.expectRevert(); // AccessControl revert
        router.updatePosition(trader1, perpMarketId, 1 * 10**18, OrderTypes.Side.Buy);
    }
    
    /*//////////////////////////////////////////////////////////////
                        IM RELEASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testReleaseIM() public {
        // Setup and submit order
        vm.startPrank(trader1);
        collateralToken.approve(address(vault), 100_000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 100_000 * 10**18);
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        (bytes32 orderId,) = router.submitOrder(order, address(collateralToken));
        vm.stopPrank();
        
        // Cancel order
        vm.prank(trader1);
        auctionHouse.cancelOrder(orderId);
        
        // Release IM
        uint256 balanceBefore = vault.getAvailableBalance(trader1, DEFAULT_SUBACCOUNT, address(collateralToken));
        router.releaseIM(orderId);
        uint256 balanceAfter = vault.getAvailableBalance(trader1, DEFAULT_SUBACCOUNT, address(collateralToken));
        
        // Verify IM was released
        assertGt(balanceAfter, balanceBefore);
        
        // Check reserve is cleared
        PerpRouter.IMReserve memory reserve = router.getIMReserve(orderId);
        assertEq(reserve.amount, 0);
    }
    
    function testCannotReleaseIMNonTerminal() public {
        // Submit order
        vm.startPrank(trader1);
        collateralToken.approve(address(vault), 100_000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 100_000 * 10**18);
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        (bytes32 orderId,) = router.submitOrder(order, address(collateralToken));
        vm.stopPrank();
        
        // Try to release without canceling (order is still Open)
        vm.expectRevert("PerpRouter: order not terminal");
        router.releaseIM(orderId);
    }
    
    function testReleaseIMNoReserve() public {
        bytes32 fakeOrderId = keccak256("fake");
        
        // Should not revert, just return early
        router.releaseIM(fakeOrderId);
    }
    
    /*//////////////////////////////////////////////////////////////
                      REDUCE-ONLY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testReduceOnlyNoIM() public {
        // Setup position
        router.updatePosition(trader1, perpMarketId, 10 * 10**18, OrderTypes.Side.Buy);
        
        // Deposit minimal collateral
        vm.startPrank(trader1);
        collateralToken.approve(address(vault), 1000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 1000 * 10**18);
        
        // Submit reduce-only order (sell when long)
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 5 * 10**18, // Less than position
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        (bytes32 orderId,) = router.submitOrder(order, address(collateralToken));
        
        // Check no IM was reserved (reduce-only)
        PerpRouter.IMReserve memory reserve = router.getIMReserve(orderId);
        assertEq(reserve.amount, 0);
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testGetPositionEmpty() public {
        assertEq(router.getPosition(trader1, perpMarketId), 0);
    }
    
    function testGetIMReserveEmpty() public {
        bytes32 fakeOrderId = keccak256("nonexistent");
        PerpRouter.IMReserve memory reserve = router.getIMReserve(fakeOrderId);
        assertEq(reserve.amount, 0);
        assertEq(reserve.user, address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testSubmitOrderSigned() public {
        uint256 traderPrivateKey = 0x1234;
        address traderAddr = vm.addr(traderPrivateKey);
        
        // Mint and deposit
        collateralToken.mint(traderAddr, 100_000 * 10**18);
        vm.startPrank(traderAddr);
        collateralToken.approve(address(vault), 100_000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 100_000 * 10**18);
        vm.stopPrank();
        
        // Create order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: traderAddr,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        // Sign order
        bytes32 structHash = keccak256(abi.encode(
            router.ORDER_TYPEHASH(),
            order.trader,
            order.marketId,
            order.side,
            order.flow,
            order.priceTick,
            order.qty,
            order.nonce,
            order.expiry
        ));
        
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("PerpRouter"),
            keccak256("1"),
            block.chainid,
            address(router)
        ));
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPrivateKey, digest);
        
        // Submit signed order
        (bytes32 orderId, uint64 batchId) = router.submitOrderSigned(order, address(collateralToken), v, r, s);
        
        assertTrue(orderId != bytes32(0));
        assertTrue(batchId > 0);
    }
    
    function testCannotSubmitInvalidSignature() public {
        uint256 traderPrivateKey = 0x1234;
        address traderAddr = vm.addr(traderPrivateKey);
        uint256 wrongPrivateKey = 0x5678;
        
        // Mint and deposit
        collateralToken.mint(traderAddr, 100_000 * 10**18);
        vm.startPrank(traderAddr);
        collateralToken.approve(address(vault), 100_000 * 10**18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 100_000 * 10**18);
        vm.stopPrank();
        
        // Create order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: traderAddr,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1 * 10**18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        // Sign with wrong key
        bytes32 structHash = keccak256(abi.encode(
            router.ORDER_TYPEHASH(),
            order.trader,
            order.marketId,
            order.side,
            order.flow,
            order.priceTick,
            order.qty,
            order.nonce,
            order.expiry
        ));
        
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("PerpRouter"),
            keccak256("1"),
            block.chainid,
            address(router)
        ));
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);
        
        // Should revert with invalid signature
        vm.expectRevert("PerpRouter: invalid signature");
        router.submitOrderSigned(order, address(collateralToken), v, r, s);
    }
    
    function testFuzz_SubmitOrder(uint128 qty) public {
        qty = uint128(bound(uint256(qty), 1 * 10**16, 10 * 10**18)); // 0.01 to 10 BTC
        
        // Deposit large amount
        vm.startPrank(trader1);
        collateralToken.approve(address(vault), type(uint256).max);
        vault.deposit(DEFAULT_SUBACCOUNT, address(collateralToken), 1_000_000 * 10**18);
        
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: perpMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: qty,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });
        
        (bytes32 orderId,) = router.submitOrder(order, address(collateralToken));
        
        assertTrue(orderId != bytes32(0));
        vm.stopPrank();
    }
}
