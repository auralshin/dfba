// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DummyOracle
/// @notice Simple mock oracle for testing and demo purposes
/// @dev Returns configurable prices, not for production use
contract DummyOracle {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Current price
    uint256 public price;

    /// @notice Last update timestamp
    uint256 public updatedAt;

    /// @notice Price decimals (default 8 for USD pricing)
    uint8 public constant decimals = 8;

    /// @notice Admin who can update prices
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PriceUpdated(uint256 price, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(uint256 initialPrice) {
        admin = msg.sender;
        price = initialPrice;
        updatedAt = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the oracle price
    function updatePrice(uint256 newPrice) external {
        require(msg.sender == admin, "DummyOracle: not admin");
        price = newPrice;
        updatedAt = block.timestamp;
        emit PriceUpdated(newPrice, block.timestamp);
    }

    /// @notice Transfer admin rights
    function setAdmin(address newAdmin) external {
        require(msg.sender == admin, "DummyOracle: not admin");
        require(newAdmin != address(0), "DummyOracle: zero address");
        admin = newAdmin;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get latest price data (Chainlink-style interface)
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 timestamp, uint80 answeredInRound)
    {
        return (
            1, // roundId
            int256(price),
            updatedAt,
            updatedAt,
            1 // answeredInRound
        );
    }

    /// @notice Get current price
    function getPrice() external view returns (uint256) {
        return price;
    }

    /// @notice Check if price is stale
    function isStale(uint256 stalenessThreshold) external view returns (bool) {
        return block.timestamp - updatedAt > stalenessThreshold;
    }
}
