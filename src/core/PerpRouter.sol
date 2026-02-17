// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {CoreVault} from "../core/CoreVault.sol";
import {AuctionHouse} from "../core/AuctionHouse.sol";
import {PerpRisk} from "../perp/PerpRisk.sol";

/// @title PerpRouter
/// @notice Router for perp orders with account-level risk checks and IM reserves
/// @dev Ensures perp orders reserve proper IM considering existing positions
contract PerpRouter is EIP712, AccessControl {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                            EIP-712 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "PerpOrder(address trader,uint64 marketId,uint8 side,uint8 flow,int24 priceTick,uint128 qty,uint128 nonce,uint64 expiry)"
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CoreVault public immutable VAULT;
    AuctionHouse public immutable AUCTION_HOUSE;
    PerpRisk public immutable RISK;

    /// @notice Default subaccount
    uint256 public constant DEFAULT_SUBACCOUNT = 0;

    /// @notice Position tracking: user => marketId => netPosition (signed)
    mapping(address => mapping(uint64 => int256)) public positions;

    /// @notice IM tracking per order: orderId => (user, subaccount, collateral, amount)
    mapping(bytes32 => IMReserve) public imReserves;

    struct IMReserve {
        address user;
        uint256 subaccountId;
        address collateral;
        uint256 amount;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PerpOrderSubmitted(
        bytes32 indexed orderId, address indexed trader, uint64 indexed marketId, uint256 imReserved
    );
    event IMReleased(bytes32 indexed orderId, uint256 amount);
    event PositionUpdated(address indexed user, uint64 indexed marketId, int256 newPosition);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address vault, address auctionHouse, address risk) EIP712("PerpRouter", "1") {
        VAULT = CoreVault(vault);
        AUCTION_HOUSE = AuctionHouse(auctionHouse);
        RISK = PerpRisk(risk);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SETTLEMENT_ROLE, auctionHouse);
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER SUBMISSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit perp order with IM reservation
    /// @param order The perp order
    /// @param collateral The collateral token to use
    /// @dev Performs account-level risk check considering existing positions
    function submitOrder(
        OrderTypes.Order memory order,
        address collateral
    ) external returns (bytes32 orderId, uint64 batchId) {
        require(order.trader == msg.sender, "PerpRouter: unauthorized");
        return _submitOrderInternal(order, collateral);
    }

    /// @notice Submit perp order with EIP-712 signature
    function submitOrderSigned(
        OrderTypes.Order memory order,
        address collateral,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bytes32 orderId, uint64 batchId) {
        // Verify signature using OpenZeppelin
        bytes32 structHash;
        bytes32 typeHash = ORDER_TYPEHASH;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), mload(order)) // trader
            mstore(add(ptr, 0x40), mload(add(order, 0x20))) // marketId
            mstore(add(ptr, 0x60), mload(add(order, 0x40))) // side
            mstore(add(ptr, 0x80), mload(add(order, 0x60))) // flow
            mstore(add(ptr, 0xa0), mload(add(order, 0x80))) // priceTick
            mstore(add(ptr, 0xc0), mload(add(order, 0xa0))) // qty
            mstore(add(ptr, 0xe0), mload(add(order, 0xc0))) // nonce
            mstore(add(ptr, 0x100), mload(add(order, 0xe0))) // expiry
            structHash := keccak256(ptr, 0x120)
        }

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(v, r, s);
        require(signer == order.trader, "PerpRouter: invalid signature");

        return _submitOrderInternal(order, collateral);
    }

    /// @notice Internal order submission with account-level risk checks
    function _submitOrderInternal(
        OrderTypes.Order memory order,
        address collateral
    ) internal returns (bytes32 orderId, uint64 batchId) {
        // Verify market type
        (OrderTypes.MarketType marketType,,,) = AUCTION_HOUSE.markets(order.marketId);
        require(marketType == OrderTypes.MarketType.Perp, "PerpRouter: not perp market");

        // Check if order is reduce-only
        int256 currentPosition = positions[order.trader][order.marketId];
        bool isReduceOnly = _isReduceOnly(order, currentPosition);

        // Calculate required IM
        uint256 imRequired;
        if (isReduceOnly) {
            // Reduce-only orders don't need additional IM
            imRequired = 0;
        } else {
            // Calculate worst-case IM for this order considering position
            imRequired = _calculateRequiredIM(order, currentPosition, collateral);
        }

        // Reserve IM if needed
        if (imRequired > 0) {
            uint256 available = VAULT.getAvailableBalance(order.trader, DEFAULT_SUBACCOUNT, collateral);
            require(available >= imRequired, "PerpRouter: insufficient IM");

            // Reserve IM in vault
            orderId = OrderTypes.orderKey(order);
            VAULT.reserveInitialMargin(orderId, order.trader, DEFAULT_SUBACCOUNT, collateral, imRequired);

            // Track IM reserve
            imReserves[orderId] = IMReserve({
                user: order.trader,
                subaccountId: DEFAULT_SUBACCOUNT,
                collateral: collateral,
                amount: imRequired
            });
        }

        // Submit order to AuctionHouse and capture assigned batchId
        (orderId, batchId) = AUCTION_HOUSE.submitOrder(order);

        emit PerpOrderSubmitted(orderId, order.trader, order.marketId, imRequired);
    }

    /*//////////////////////////////////////////////////////////////
                           RISK CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if order is reduce-only
    /// @param order The order
    /// @param currentPosition Current position (positive = long, negative = short)
    /// @return True if order reduces position
    function _isReduceOnly(OrderTypes.Order memory order, int256 currentPosition) internal pure returns (bool) {
        if (currentPosition == 0) return false;

        int256 orderDelta = order.side == OrderTypes.Side.Buy ? int256(uint256(order.qty)) : -int256(uint256(order.qty));

        // Reduce-only if order and position have opposite signs
        // AND order size <= abs(position)
        if (currentPosition > 0 && orderDelta < 0) {
            return uint256(-orderDelta) <= uint256(currentPosition);
        } else if (currentPosition < 0 && orderDelta > 0) {
            return uint256(orderDelta) <= uint256(-currentPosition);
        }

        return false;
    }

    /// @notice Calculate required IM considering existing position
    /// @param order The order
    /// @param currentPosition Current net position
    /// @param collateral Collateral token
    /// @return imRequired Initial margin required
    function _calculateRequiredIM(
        OrderTypes.Order memory order,
        int256 currentPosition,
        address collateral
    ) internal view returns (uint256 imRequired) {
        // Get price from tick
        uint256 price = OrderTypes.tickToPrice(order.priceTick);

        // Calculate new position if order fully fills
        int256 orderDelta = order.side == OrderTypes.Side.Buy ? int256(uint256(order.qty)) : -int256(uint256(order.qty));

        int256 newPosition = currentPosition + orderDelta;

        // IM required = IM(new position) - IM(current position)
        // But we need worst-case, so use order price as worst execution

        // Simplified: just reserve worst-case IM for order size
        // Production: should consider cross-margining effects
        imRequired = RISK.initialMarginRequired(order.marketId, order.qty, price);
    }

    /*//////////////////////////////////////////////////////////////
                           POSITION UPDATES
    //////////////////////////////////////////////////////////////*/

    /// @notice Update position after settlement (called by PerpEngine)
    /// @param user The user
    /// @param marketId The market
    /// @param fillQty Fill quantity
    /// @param side Order side
    function updatePosition(
        address user,
        uint64 marketId,
        uint128 fillQty,
        OrderTypes.Side side
    ) external onlyRole(SETTLEMENT_ROLE) {
        int256 delta = side == OrderTypes.Side.Buy ? int256(uint256(fillQty)) : -int256(uint256(fillQty));

        positions[user][marketId] += delta;

        emit PositionUpdated(user, marketId, positions[user][marketId]);
    }

    /*//////////////////////////////////////////////////////////////
                           IM RELEASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Release IM after order settled/cancelled
    /// @param orderId The order ID
    /// @dev CRITICAL: Only authorized settlement contracts can release
    function releaseIM(
        bytes32 orderId
    ) external onlyRole(SETTLEMENT_ROLE) {
        IMReserve memory reserve = imReserves[orderId];
        if (reserve.amount == 0) return;

        // CRITICAL: Verify order is in terminal state (cancelled or fully filled)
        (, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        require(state.cancelled || state.remainingQty == 0, "PerpRouter: order not terminal");

        VAULT.releaseInitialMargin(orderId, reserve.user, reserve.subaccountId, reserve.collateral);

        delete imReserves[orderId];
        emit IMReleased(orderId, reserve.amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get position for user in market
    function getPosition(address user, uint64 marketId) external view returns (int256) {
        return positions[user][marketId];
    }

    /// @notice Get IM reserve for order
    function getIMReserve(
        bytes32 orderId
    ) external view returns (IMReserve memory) {
        return imReserves[orderId];
    }
}
