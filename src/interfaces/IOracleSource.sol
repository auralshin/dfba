// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracleSource {
    function getPrice(
        uint64 marketId
    ) external view returns (uint256);
}
