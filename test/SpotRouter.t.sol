// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SpotRouter} from "../src/core/SpotRouter.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SpotRouterTest is Test {
    SpotRouter public router;
    CoreVault public vault;
    AuctionHouse public auctionHouse;

    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public admin = address(this);
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    address public relayer = address(0x3);

    uint64 public spotMarketId;
    uint256 constant DEFAULT_SUBACCOUNT = 0;

    function setUp() public {
        // Deploy contracts
        vault = new CoreVault();
        auctionHouse = new AuctionHouse();
        router = new SpotRouter(address(vault), address(auctionHouse));

        // Deploy tokens
        baseToken = new MockERC20("Base", "BASE");
        quoteToken = new MockERC20("Quote", "QUOTE");

        // Setup vault
        vault.addCollateral(address(baseToken));
        vault.addCollateral(address(quoteToken));
        vault.setAuthorized(address(router), true);
        vault.setAuthorized(address(auctionHouse), true);

        // Grant SpotRouter the ROUTER_ROLE in AuctionHouse
        bytes32 routerRole = keccak256("ROUTER_ROLE");
        auctionHouse.grantRole(routerRole, address(router));

        // Create spot market
        spotMarketId = auctionHouse.createMarket(OrderTypes.MarketType.Spot, address(baseToken), address(quoteToken));

        // Grant router settlement role for testing releaseEscrow
        router.grantRole(router.SETTLEMENT_ROLE(), address(this));

        // Mint tokens to traders
        baseToken.mint(trader1, 1_000_000 * 10 ** 18);
        quoteToken.mint(trader1, 1_000_000 * 10 ** 18);
        baseToken.mint(trader2, 1_000_000 * 10 ** 18);
        quoteToken.mint(trader2, 1_000_000 * 10 ** 18);
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER SUBMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSubmitBuyOrder() public {
        uint256 depositAmount = 10_000 * 10 ** 18;

        // Deposit quote tokens
        vm.startPrank(trader1);
        quoteToken.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), depositAmount);
        vm.stopPrank();

        // Create buy order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0, // Price = 1.0
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        vm.prank(trader1);
        (bytes32 orderId, uint64 batchId) = router.submitOrder(order);

        // Verify order was submitted
        assertTrue(orderId != bytes32(0));
        assertTrue(batchId > 0);

        // Check escrow was locked
        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 0);
        assertGt(quoteEscrow, 0); // Should have locked quote + fee buffer
    }

    function testSubmitSellOrder() public {
        uint256 depositAmount = 10_000 * 10 ** 18;

        // Deposit base tokens
        vm.startPrank(trader1);
        baseToken.approve(address(vault), depositAmount);
        vault.deposit(DEFAULT_SUBACCOUNT, address(baseToken), depositAmount);
        vm.stopPrank();

        // Create sell order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        vm.prank(trader1);
        (bytes32 orderId,) = router.submitOrder(order);

        // Check escrow was locked
        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 1000 * 10 ** 18);
        assertEq(quoteEscrow, 0);
    }

    function testCannotSubmitUnauthorized() public {
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        // Try to submit as different user
        vm.prank(trader2);
        vm.expectRevert("SpotRouter: unauthorized");
        router.submitOrder(order);
    }

    function testCannotSubmitInsufficientBase() public {
        // Try to submit sell order without depositing base
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        vm.prank(trader1);
        vm.expectRevert("SpotRouter: insufficient base");
        router.submitOrder(order);
    }

    function testCannotSubmitInsufficientQuote() public {
        // Try to submit buy order without depositing quote
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        vm.prank(trader1);
        vm.expectRevert("SpotRouter: insufficient quote");
        router.submitOrder(order);
    }

    /*//////////////////////////////////////////////////////////////
                         SIGNATURE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSubmitOrderSigned() public {
        uint256 traderPrivateKey = 0x1234;
        address traderAddress = vm.addr(traderPrivateKey);

        // Mint and deposit for the trader
        baseToken.mint(traderAddress, 10_000 * 10 ** 18);
        quoteToken.mint(traderAddress, 10_000 * 10 ** 18);

        vm.startPrank(traderAddress);
        quoteToken.approve(address(vault), 10_000 * 10 ** 18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), 10_000 * 10 ** 18);
        vm.stopPrank();

        // Create order
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: traderAddress,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 100 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        // Create EIP-712 signature (without batchId - it's assigned at submission)
        bytes32 structHash = keccak256(
            abi.encode(
                router.ORDER_TYPEHASH(),
                order.trader,
                order.marketId,
                order.side,
                order.flow,
                order.priceTick,
                order.qty,
                order.nonce,
                order.expiry
            )
        );

        // Compute domain separator manually
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpotRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPrivateKey, digest);

        // Submit via relayer
        vm.prank(relayer);
        (bytes32 orderId, uint64 batchId) = router.submitOrderSigned(order, v, r, s);

        assertTrue(orderId != bytes32(0));
        assertTrue(batchId > 0);
    }

    function testCannotSubmitInvalidSignature() public {
        uint256 wrongPrivateKey = 0x5678;

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 100 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        bytes32 structHash = keccak256(
            abi.encode(
                router.ORDER_TYPEHASH(),
                order.trader,
                order.marketId,
                order.side,
                order.flow,
                order.priceTick,
                order.qty,
                order.nonce,
                order.expiry
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpotRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        vm.prank(relayer);
        vm.expectRevert("SpotRouter: invalid signature");
        router.submitOrderSigned(order, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                      ESCROW RELEASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testReleaseEscrowAfterCancel() public {
        // Setup and submit order
        vm.startPrank(trader1);
        quoteToken.approve(address(vault), 10_000 * 10 ** 18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), 10_000 * 10 ** 18);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId, uint64 batchId) = router.submitOrder(order);
        vm.stopPrank();

        // Cancel the order
        vm.prank(trader1);
        auctionHouse.cancelOrder(orderId);

        // Release escrow
        uint256 balanceBefore = vault.balances(trader1, DEFAULT_SUBACCOUNT, address(quoteToken));
        router.releaseEscrow(orderId);
        uint256 balanceAfter = vault.balances(trader1, DEFAULT_SUBACCOUNT, address(quoteToken));

        // Verify escrow was released
        assertGt(balanceAfter, balanceBefore);
        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 0);
        assertEq(quoteEscrow, 0);
    }

    function testCannotReleaseEscrowNonTerminal() public {
        // Setup and submit order
        vm.startPrank(trader1);
        quoteToken.approve(address(vault), 10_000 * 10 ** 18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), 10_000 * 10 ** 18);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = router.submitOrder(order);
        vm.stopPrank();

        // Try to release without canceling
        vm.expectRevert("SpotRouter: order not terminal");
        router.releaseEscrow(orderId);
    }

    function testCannotReleaseNoEscrow() public {
        bytes32 fakeOrderId = keccak256("fake");

        vm.expectRevert("SpotRouter: no escrow");
        router.releaseEscrow(fakeOrderId);
    }

    function testCannotReleaseUnauthorized() public {
        bytes32 fakeOrderId = keccak256("fake");

        vm.prank(trader1);
        vm.expectRevert(); // AccessControl revert
        router.releaseEscrow(fakeOrderId);
    }

    /*//////////////////////////////////////////////////////////////
                         ESCROW CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testEscrowCalculationBuyOrder() public {
        vm.startPrank(trader1);
        quoteToken.approve(address(vault), 100_000 * 10 ** 18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), 100_000 * 10 ** 18);

        // Buy order at different price levels
        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: 100, // Higher price
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = router.submitOrder(order);

        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 0);
        assertGt(quoteEscrow, 1000 * 10 ** 18); // Should be > qty due to price and fee
        vm.stopPrank();
    }

    function testEscrowCalculationSellOrder() public {
        vm.startPrank(trader1);
        baseToken.approve(address(vault), 100_000 * 10 ** 18);
        vault.deposit(DEFAULT_SUBACCOUNT, address(baseToken), 100_000 * 10 ** 18);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: -100,
            qty: 1000 * 10 ** 18,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = router.submitOrder(order);

        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 1000 * 10 ** 18); // Exactly qty
        assertEq(quoteEscrow, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetEscrowLockEmpty() public {
        bytes32 nonExistentOrderId = keccak256("nonexistent");
        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(nonExistentOrderId);
        assertEq(baseEscrow, 0);
        assertEq(quoteEscrow, 0);
    }

    function testDomainSeparator() public {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpotRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        assertTrue(domainSeparator != bytes32(0));
    }

    function testOrderTypehash() public view {
        bytes32 typehash = router.ORDER_TYPEHASH();
        assertEq(
            typehash,
            keccak256(
                "SpotOrder(address trader,uint64 marketId,uint8 side,uint8 flow,int24 priceTick,uint128 qty,uint128 nonce,uint64 expiry)"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SubmitBuyOrder(uint128 qty, int24 priceTick) public {
        qty = uint128(bound(uint256(qty), 1 * 10 ** 18, 100_000 * 10 ** 18)); // Start from 1 token minimum
        priceTick = int24(bound(int256(priceTick), -50, 50)); // Reduce price range

        // Mint and deposit enough quote tokens to cover worst case
        quoteToken.mint(trader1, 100_000_000 * 10 ** 18);

        vm.startPrank(trader1);
        quoteToken.approve(address(vault), type(uint256).max);
        vault.deposit(DEFAULT_SUBACCOUNT, address(quoteToken), 100_000_000 * 10 ** 18);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Buy,
            flow: OrderTypes.Flow.Maker,
            priceTick: priceTick,
            qty: qty,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = router.submitOrder(order);

        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, 0);
        assertGt(quoteEscrow, 0);
        vm.stopPrank();
    }

    function testFuzz_SubmitSellOrder(
        uint128 qty
    ) public {
        qty = uint128(bound(uint256(qty), 1 * 10 ** 18, 100_000 * 10 ** 18)); // Start from 1 token minimum

        // Mint exact amount needed
        baseToken.mint(trader1, qty);

        vm.startPrank(trader1);
        baseToken.approve(address(vault), type(uint256).max);
        vault.deposit(DEFAULT_SUBACCOUNT, address(baseToken), qty);

        OrderTypes.Order memory order = OrderTypes.Order({
            trader: trader1,
            marketId: spotMarketId,
            side: OrderTypes.Side.Sell,
            flow: OrderTypes.Flow.Maker,
            priceTick: 0,
            qty: qty,
            nonce: 1,
            expiry: uint64(block.timestamp + 1 hours)
        });

        (bytes32 orderId,) = router.submitOrder(order);

        (uint128 baseEscrow, uint128 quoteEscrow) = router.getEscrowLock(orderId);
        assertEq(baseEscrow, qty);
        assertEq(quoteEscrow, 0);
        vm.stopPrank();
    }
}
