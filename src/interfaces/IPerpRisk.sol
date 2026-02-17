// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPerpRisk {
    function canWithdraw(
        address user,
        uint256 subaccountId,
        address token,
        uint256 amount
    )
        external
        view
        returns (bool);
}
