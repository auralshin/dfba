// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {CoreVault} from "../core/CoreVault.sol";
import {AuctionHouse} from "../core/AuctionHouse.sol";
import {PerpRisk} from "../perp/PerpRisk.sol";
import {IOracleSource} from "../interfaces/IOracleSource.sol";

interface IOraclePriceNoMarket {
    function getPrice() external view returns (uint256);
}

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
        "PerpOrder(address trader,uint64 marketId,uint8 side,uint8 flow,int24 priceTick,uint128 qty,uint128 nonce,uint64 expiry,address collateral)"
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

    /// @notice Entry price for net position (WAD): user => marketId => price
    mapping(address => mapping(uint64 => uint256)) public entryPrices;

    /// @notice IM tracking per order: orderId => (user, subaccount, collateral, amount)
    mapping(bytes32 => IMReserve) public imReserves;

    /// @notice Margin locked for open positions: user => marketId => amount
    mapping(address => mapping(uint64 => uint256)) public positionMargin;

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
            mstore(add(ptr, 0x120), collateral)
            structHash := keccak256(ptr, 0x140)
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
        (OrderTypes.MarketType marketType,, address quoteToken,) = AUCTION_HOUSE.markets(order.marketId);
        require(marketType == OrderTypes.MarketType.Perp, "PerpRouter: not perp market");
        require(collateral == quoteToken, "PerpRouter: invalid collateral");

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
        // Calculate new position if order fully fills
        int256 orderDelta = order.side == OrderTypes.Side.Buy ? int256(uint256(order.qty)) : -int256(uint256(order.qty));

        int256 newPosition = currentPosition + orderDelta;

        // Use trusted mark price for IM, bounded by the order limit for safety.
        uint256 markPrice = _getMarkPrice(order.marketId);
        uint256 orderPrice = OrderTypes.tickToPrice(order.priceTick);
        uint256 worstPrice = markPrice > orderPrice ? markPrice : orderPrice;

        // Simplified: reserve worst-case IM for order size
        // Production: should consider cross-margining effects
        imRequired = RISK.initialMarginRequired(order.marketId, order.qty, worstPrice);
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
        OrderTypes.Side side,
        uint256 fillPrice
    ) external onlyRole(SETTLEMENT_ROLE) {
        require(fillPrice > 0, "PerpRouter: invalid fill price");

        int256 delta = side == OrderTypes.Side.Buy ? int256(uint256(fillQty)) : -int256(uint256(fillQty));
        int256 previousPosition = positions[user][marketId];
        int256 nextPosition = previousPosition + delta;
        uint256 currentEntry = entryPrices[user][marketId];

        int256 realizedPnl = _calculateRealizedPnl(previousPosition, nextPosition, currentEntry, fillPrice);
        if (realizedPnl != 0) {
            (,, address quoteToken,) = AUCTION_HOUSE.markets(marketId);
            VAULT.applyPnl(user, DEFAULT_SUBACCOUNT, quoteToken, realizedPnl);
        }

        positions[user][marketId] = nextPosition;
        entryPrices[user][marketId] =
            _calculateEntryPrice(previousPosition, nextPosition, currentEntry, fillQty, fillPrice);

        if (nextPosition == 0) {
            entryPrices[user][marketId] = 0;
            uint256 locked = positionMargin[user][marketId];
            if (locked > 0) {
                positionMargin[user][marketId] = 0;
                (,, address quoteToken,) = AUCTION_HOUSE.markets(marketId);
                VAULT.releasePositionMargin(user, DEFAULT_SUBACCOUNT, quoteToken, locked);
            }
        }

        emit PositionUpdated(user, marketId, nextPosition);
    }

    function _calculateRealizedPnl(
        int256 previousPosition,
        int256 nextPosition,
        uint256 entryPrice,
        uint256 fillPrice
    ) internal pure returns (int256) {
        if (previousPosition == 0 || entryPrice == 0) return 0;

        uint256 absPrev = uint256(previousPosition > 0 ? previousPosition : -previousPosition);
        uint256 absNext = uint256(nextPosition > 0 ? nextPosition : -nextPosition);

        bool sameSign = (previousPosition > 0 && nextPosition > 0) || (previousPosition < 0 && nextPosition < 0);
        uint256 reducedSize = 0;

        if (sameSign) {
            if (absNext >= absPrev) return 0;
            reducedSize = absPrev - absNext;
        } else {
            reducedSize = absPrev;
        }

        if (reducedSize == 0) return 0;

        if (previousPosition > 0) {
            return _pnlFromPrices(entryPrice, fillPrice, reducedSize);
        }

        return _pnlFromPrices(fillPrice, entryPrice, reducedSize);
    }

    function _pnlFromPrices(uint256 entryPrice, uint256 exitPrice, uint256 size) internal pure returns (int256) {
        if (exitPrice >= entryPrice) {
            uint256 gain = Math.mulDiv(size, exitPrice - entryPrice, 1e18);
            return int256(gain);
        }

        uint256 loss = Math.mulDiv(size, entryPrice - exitPrice, 1e18);
        return -int256(loss);
    }

    function _calculateEntryPrice(
        int256 previousPosition,
        int256 nextPosition,
        uint256 currentEntryPrice,
        uint128 fillQty,
        uint256 fillPrice
    ) internal pure returns (uint256) {
        if (nextPosition == 0) return 0;

        int256 absPrev = previousPosition >= 0 ? previousPosition : -previousPosition;
        int256 absNext = nextPosition >= 0 ? nextPosition : -nextPosition;

        if (
            previousPosition == 0 || (previousPosition > 0 && nextPosition > 0 && absNext > absPrev)
                || (previousPosition < 0 && nextPosition < 0 && absNext > absPrev)
        ) {
            uint256 prevNotional = (uint256(absPrev) * currentEntryPrice) / 1e18;
            uint256 addNotional = (uint256(fillQty) * fillPrice) / 1e18;
            uint256 newNotional = prevNotional + addNotional;
            return (newNotional * 1e18) / uint256(absNext);
        }

        if (
            (previousPosition > 0 && nextPosition > 0 && absNext < absPrev)
                || (previousPosition < 0 && nextPosition < 0 && absNext < absPrev)
        ) {
            return currentEntryPrice;
        }

        // Position flipped; reset entry to fill price
        return fillPrice;
    }

    function _getMarkPrice(
        uint64 marketId
    ) internal view returns (uint256) {
        address oracle = AUCTION_HOUSE.marketOracles(marketId);
        require(oracle != address(0), "PerpRouter: oracle missing");

        try IOracleSource(oracle).getPrice(marketId) returns (uint256 price) {
            return price;
        } catch {}

        try IOraclePriceNoMarket(oracle).getPrice() returns (uint256 price) {
            return price;
        } catch {}

        revert("PerpRouter: oracle unsupported");
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
        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        _releaseIM(orderId, order, state);
    }

    function releaseIMForTrader(
        bytes32 orderId
    ) external {
        (OrderTypes.Order memory order, OrderTypes.OrderState memory state) = AUCTION_HOUSE.getOrder(orderId);
        require(order.trader == msg.sender, "PerpRouter: not order owner");
        _releaseIM(orderId, order, state);
    }

    function _releaseIM(bytes32 orderId, OrderTypes.Order memory order, OrderTypes.OrderState memory state) internal {
        IMReserve memory reserve = imReserves[orderId];
        if (reserve.amount == 0) return;

        require(state.cancelled || state.remainingQty == 0, "PerpRouter: order not terminal");

        if (state.cancelled) {
            VAULT.releaseInitialMargin(orderId, reserve.user, reserve.subaccountId, reserve.collateral);
            delete imReserves[orderId];
            emit IMReleased(orderId, reserve.amount);
            return;
        }

        // Filled orders convert reserved IM into position margin until the position is closed.
        VAULT.releaseInitialMargin(orderId, reserve.user, reserve.subaccountId, reserve.collateral);
        VAULT.lockPositionMargin(reserve.user, reserve.subaccountId, reserve.collateral, reserve.amount);
        positionMargin[reserve.user][order.marketId] += reserve.amount;

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

    function getEntryPrice(address user, uint64 marketId) external view returns (uint256) {
        return entryPrices[user][marketId];
    }

    /// @notice Get IM reserve for order
    function getIMReserve(
        bytes32 orderId
    ) external view returns (IMReserve memory) {
        return imReserves[orderId];
    }
}
