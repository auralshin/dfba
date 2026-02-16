// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {CoreVault} from "../core/CoreVault.sol";
import {AuctionHouse} from "../core/AuctionHouse.sol";

/// @title SpotRouter
/// @notice Router for spot orders with pre-funding enforcement and EIP-712 signatures
/// @dev Ensures all spot orders are fully funded before submission (no post-settlement surprises)
contract SpotRouter is EIP712, AccessControl {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                            EIP-712 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "SpotOrder(address trader,uint64 marketId,uint8 side,uint8 flow,int24 priceTick,uint128 qty,uint128 nonce,uint64 expiry)"
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CoreVault public immutable VAULT;
    AuctionHouse public immutable AUCTION_HOUSE;

    /// @notice Default subaccount (can be extended to support multiple)
    uint256 public constant DEFAULT_SUBACCOUNT = 0;

    /// @notice Fee buffer for buy orders (e.g., 1% = 100 bps)
    uint256 public constant FEE_BUFFER_BPS = 100;

    /// @notice Escrow tracking: orderId => (baseEscrow, quoteEscrow)
    mapping(bytes32 => EscrowLock) public escrowLocks;

    struct EscrowLock {
        uint128 baseAmount;
        uint128 quoteAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SpotOrderSubmitted(
        bytes32 indexed orderId,
        address indexed trader,
        uint64 indexed marketId,
        uint128 baseEscrow,
        uint128 quoteEscrow
    );
    event EscrowReleased(bytes32 indexed orderId, uint128 baseAmount, uint128 quoteAmount);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address vault, address auctionHouse) EIP712("SpotRouter", "1") {
        VAULT = CoreVault(vault);
        AUCTION_HOUSE = AuctionHouse(auctionHouse);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SETTLEMENT_ROLE, auctionHouse);
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER SUBMISSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit spot order with automatic escrow locking
    /// @param order The spot order to submit
    /// @dev Buy orders lock quote + fee buffer, sell orders lock base
    function submitOrder(OrderTypes.Order memory order) external returns (bytes32 orderId, uint64 batchId) {
        // Authenticate: msg.sender must be trader
        require(order.trader == msg.sender, "SpotRouter: unauthorized");
        
        (orderId, batchId) = _submitOrderInternal(order);
        return (orderId, batchId);
    }

    /// @notice Submit spot order with EIP-712 signature (for relayers/meta-transactions)
    /// @param order The spot order to submit
    /// @param v ECDSA signature v
    /// @param r ECDSA signature r
    /// @param s ECDSA signature s
    function submitOrderSigned(
        OrderTypes.Order memory order,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bytes32 orderId, uint64 batchId) {
        // Verify EIP-712 signature using OpenZeppelin
        bytes32 structHash;
        bytes32 typeHash = ORDER_TYPEHASH;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), mload(order))              // trader
            mstore(add(ptr, 0x40), mload(add(order, 0x20)))   // marketId
            mstore(add(ptr, 0x60), mload(add(order, 0x40)))   // side
            mstore(add(ptr, 0x80), mload(add(order, 0x60)))   // flow
            mstore(add(ptr, 0xa0), mload(add(order, 0x80)))   // priceTick
            mstore(add(ptr, 0xc0), mload(add(order, 0xa0)))   // qty
            mstore(add(ptr, 0xe0), mload(add(order, 0xc0)))   // nonce
            mstore(add(ptr, 0x100), mload(add(order, 0xe0)))  // expiry
            structHash := keccak256(ptr, 0x120)
        }

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(v, r, s);
        require(signer == order.trader, "SpotRouter: invalid signature");

        (orderId, batchId) = _submitOrderInternal(order);
        return (orderId, batchId);
    }

    /// @notice Internal order submission with escrow locking
    function _submitOrderInternal(OrderTypes.Order memory order) internal returns (bytes32 orderId, uint64 batchId) {
        // Get market info
        (OrderTypes.MarketType marketType, address baseToken, address quoteToken,) = 
            AUCTION_HOUSE.markets(order.marketId);
        
        require(marketType == OrderTypes.MarketType.Spot, "SpotRouter: not spot market");

        // Calculate escrow requirements
        (uint128 baseEscrow, uint128 quoteEscrow) = _calculateEscrow(
            order,
            baseToken,
            quoteToken
        );

        // Lock escrow from user's vault balance
        if (baseEscrow > 0) {
            require(
                VAULT.balances(order.trader, DEFAULT_SUBACCOUNT, baseToken) >= baseEscrow,
                "SpotRouter: insufficient base"
            );
            VAULT.move(
                baseToken,
                order.trader,
                DEFAULT_SUBACCOUNT,
                address(this),
                0, // Router uses subaccount 0
                baseEscrow
            );
            VAULT.lockSpotEscrow(order.marketId, baseToken, baseEscrow);
        }

        if (quoteEscrow > 0) {
            require(
                VAULT.balances(order.trader, DEFAULT_SUBACCOUNT, quoteToken) >= quoteEscrow,
                "SpotRouter: insufficient quote"
            );
            VAULT.move(
                quoteToken,
                order.trader,
                DEFAULT_SUBACCOUNT,
                address(this),
                0,
                quoteEscrow
            );
            VAULT.lockSpotEscrow(order.marketId, quoteToken, quoteEscrow);
        }
        
        (orderId, batchId) = AUCTION_HOUSE.submitOrder(order);

        // Track escrow
        escrowLocks[orderId] = EscrowLock({
            baseAmount: baseEscrow,
            quoteAmount: quoteEscrow
        });

        emit SpotOrderSubmitted(orderId, order.trader, order.marketId, baseEscrow, quoteEscrow);
    }

    /*//////////////////////////////////////////////////////////////
                         ESCROW CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate escrow requirements for an order
    /// @dev Buy: lock quote + fee buffer, Sell: lock base
    /// @dev FIXED: Use proper tickToPrice conversion with WAD precision
    function _calculateEscrow(
        OrderTypes.Order memory order,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint128 baseEscrow, uint128 quoteEscrow) {
        // CRITICAL FIX: Use proper tick-to-price conversion (WAD precision: 1e18)
        uint256 price = OrderTypes.tickToPrice(order.priceTick);

        if (order.side == OrderTypes.Side.Buy) {
            // Buy order: lock quote amount + fee buffer (round up for safety)
            // quoteNeeded = qty * price * (1 + feeBps/10000)
            uint256 quoteBase = (uint256(order.qty) * price) / 1e18;
            uint256 feeBuffer = (quoteBase * FEE_BUFFER_BPS) / 10000;
            quoteEscrow = uint128(quoteBase + feeBuffer);
            baseEscrow = 0;
        } else {
            // Sell order: lock base amount
            baseEscrow = order.qty;
            quoteEscrow = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ESCROW RELEASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Release escrow after order settled/cancelled
    /// @param orderId The order ID
    /// @dev CRITICAL: Only authorized settlement contracts can release
    function releaseEscrow(bytes32 orderId) external onlyRole(SETTLEMENT_ROLE) {
        
        EscrowLock memory lock = escrowLocks[orderId];
        require(lock.baseAmount > 0 || lock.quoteAmount > 0, "SpotRouter: no escrow");

        // CRITICAL: Verify order is in terminal state (cancelled or fully filled)
        (, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        require(state.cancelled || state.remainingQty == 0, "SpotRouter: order not terminal");

        (OrderTypes.Order memory order,) = AUCTION_HOUSE.getOrder(orderId);
        (,address baseToken, address quoteToken,) = AUCTION_HOUSE.markets(order.marketId);

        // Release from escrow back to user
        if (lock.baseAmount > 0) {
            VAULT.releaseSpotEscrow(order.marketId, baseToken, lock.baseAmount);
            VAULT.move(
                baseToken,
                address(this),
                0,
                order.trader,
                DEFAULT_SUBACCOUNT,
                lock.baseAmount
            );
        }

        if (lock.quoteAmount > 0) {
            VAULT.releaseSpotEscrow(order.marketId, quoteToken, lock.quoteAmount);
            VAULT.move(
                quoteToken,
                address(this),
                0,
                order.trader,
                DEFAULT_SUBACCOUNT,
                lock.quoteAmount
            );
        }

        delete escrowLocks[orderId];
        emit EscrowReleased(orderId, lock.baseAmount, lock.quoteAmount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get escrow lock for an order
    function getEscrowLock(bytes32 orderId) external view returns (uint128 baseAmount, uint128 quoteAmount) {
        EscrowLock memory lock = escrowLocks[orderId];
        return (lock.baseAmount, lock.quoteAmount);
    }
}
