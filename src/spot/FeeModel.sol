// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeModel
/// @notice Fee calculation for spot trading
/// @dev Separate maker/taker fees per market
contract FeeModel {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee configuration per market
    struct MarketFees {
        uint16 makerFeeBps;
        uint16 takerFeeBps;
        address feeRecipient;
    }

    /// @notice Market fees: marketId => fees
    mapping(uint64 => MarketFees) public marketFees;

    /// @notice Default fees
    uint16 public defaultMakerFeeBps = 5;
    uint16 public defaultTakerFeeBps = 10;
    address public defaultFeeRecipient;

    /// @notice Admin
    address public admin;
    
    /// @notice Pending admin for 2-step transfer
    address public pendingAdmin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketFeesUpdated(uint64 indexed marketId, uint16 makerFeeBps, uint16 takerFeeBps, address feeRecipient);
    event DefaultFeesUpdated(uint16 makerFeeBps, uint16 takerFeeBps, address feeRecipient);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "FeeModel: not admin");
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "FeeModel: zero address");
        admin = msg.sender;
        defaultFeeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setMarketFees(
        uint64 marketId,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeRecipient
    ) external onlyAdmin {
        require(makerFeeBps <= 10000 && takerFeeBps <= 10000, "FeeModel: invalid bps");
        require(feeRecipient != address(0), "FeeModel: zero address");

        marketFees[marketId] = MarketFees({
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeRecipient: feeRecipient
        });

        emit MarketFeesUpdated(marketId, makerFeeBps, takerFeeBps, feeRecipient);
    }

    function setDefaultFees(
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeRecipient
    ) external onlyAdmin {
        require(makerFeeBps <= 10000 && takerFeeBps <= 10000, "FeeModel: invalid bps");
        require(feeRecipient != address(0), "FeeModel: zero address");

        defaultMakerFeeBps = makerFeeBps;
        defaultTakerFeeBps = takerFeeBps;
        defaultFeeRecipient = feeRecipient;

        emit DefaultFeesUpdated(makerFeeBps, takerFeeBps, feeRecipient);
    }

    /// @notice Initiate admin transfer (step 1)
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "FeeModel: zero address");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    /// @notice Accept admin transfer (step 2)
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "FeeModel: not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate fee for an order
    /// @param marketId Market ID
    /// @param isMaker True if maker order
    /// @param notional Notional value of the trade
    /// @return fee Fee amount
    /// @return recipient Fee recipient
    function feeFor(uint64 marketId, bool isMaker, uint256 notional)
        external
        view
        returns (uint256 fee, address recipient)
    {
        MarketFees storage fees = marketFees[marketId];
        
        uint16 feeBps;
        if (fees.feeRecipient != address(0)) {
            feeBps = isMaker ? fees.makerFeeBps : fees.takerFeeBps;
            recipient = fees.feeRecipient;
        } else {
            feeBps = isMaker ? defaultMakerFeeBps : defaultTakerFeeBps;
            recipient = defaultFeeRecipient;
        }

        fee = (notional * feeBps) / 10000;
    }

    /// @notice Get fees for a market
    function getMarketFees(uint64 marketId)
        external
        view
        returns (uint16 makerFeeBps, uint16 takerFeeBps, address feeRecipient)
    {
        MarketFees storage fees = marketFees[marketId];
        if (fees.feeRecipient != address(0)) {
            return (fees.makerFeeBps, fees.takerFeeBps, fees.feeRecipient);
        }
        return (defaultMakerFeeBps, defaultTakerFeeBps, defaultFeeRecipient);
    }
}
