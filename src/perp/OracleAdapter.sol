// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OracleAdapter
/// @notice Price oracle interface for perp markets
/// @dev Provides index price for funding rate calculations and mark price for margin
contract OracleAdapter {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Oracle sources per market
    mapping(uint64 => address) public oracles;

    /// @notice Cached prices: marketId => price
    mapping(uint64 => uint256) public cachedPrices;

    /// @notice Last update time: marketId => timestamp
    mapping(uint64 => uint256) public lastUpdate;

    /// @notice Price staleness threshold
    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    /// @notice Admin
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OracleSet(uint64 indexed marketId, address indexed oracle);
    event PriceUpdated(uint64 indexed marketId, uint256 price, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "OracleAdapter: not admin");
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set oracle for a market
    function setOracle(uint64 marketId, address oracle) external onlyAdmin {
        oracles[marketId] = oracle;
        emit OracleSet(marketId, oracle);
    }

    /// @notice Manually update price (for testing or backup)
    function updatePrice(uint64 marketId, uint256 price) external onlyAdmin {
        cachedPrices[marketId] = price;
        lastUpdate[marketId] = block.timestamp;
        emit PriceUpdated(marketId, price, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get index price for a market
    /// @dev Uses external oracle or cached price
    function getIndexPrice(uint64 marketId) external view returns (uint256) {
        address oracle = oracles[marketId];
        
        if (oracle != address(0)) {


            try IOracleSource(oracle).getPrice(marketId) returns (uint256 oraclePrice) {
                return oraclePrice;
            } catch {

            }
        }


        uint256 price = cachedPrices[marketId];
        require(price > 0, "OracleAdapter: no price");
        

        require(
            block.timestamp - lastUpdate[marketId] <= STALENESS_THRESHOLD,
            "OracleAdapter: stale price"
        );

        return price;
    }

    /// @notice Get mark price (can differ from index for perp-specific logic)
    /// @dev Simplified: returns index price. In production, might use TWAP or other logic
    function getMarkPrice(uint64 marketId) external view returns (uint256) {
        return this.getIndexPrice(marketId);
    }

    /// @notice Check if price is fresh
    function isPriceFresh(uint64 marketId) external view returns (bool) {
        return block.timestamp - lastUpdate[marketId] <= STALENESS_THRESHOLD;
    }
}

/// @notice Simplified oracle source interface
interface IOracleSource {
    function getPrice(uint64 marketId) external view returns (uint256);
}
