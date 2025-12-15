// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";

/// @title SpotVault
/// @notice Custody and internal balance accounting for spot trading
/// @dev Uses internal balances to minimize ERC20 transfers
contract SpotVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal balances: user => token => balance
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Authorized settlement contracts
    mapping(address => bool) public authorized;

    /// @notice Admin
    address public admin;
    
    /// @notice Pending admin for 2-step transfer
    address public pendingAdmin;

    /// @notice Paused state for emergency stops
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Transfer(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event AuthorizedUpdated(address indexed account, bool authorized);
    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
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
        require(msg.sender == admin, "SpotVault: not admin");
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        require(
            authorized[msg.sender] || msg.sender == admin,
            "SpotVault: not authorized"
        );
    }

    modifier whenNotPaused() {
        require(!paused, "SpotVault: paused");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        admin = msg.sender;
        authorized[msg.sender] = true;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setAuthorized(
        address account,
        bool _authorized
    ) external onlyAdmin {
        authorized[account] = _authorized;
        emit AuthorizedUpdated(account, _authorized);
    }

    /// @notice Pause all settlement operations
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause settlement operations
    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Initiate admin transfer (step 1)
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "SpotVault: zero address");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    /// @notice Accept admin transfer (step 2)
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "SpotVault: not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    /*//////////////////////////////////////////////////////////////
                         USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens into vault
    function deposit(address token, uint256 amount, address to) external whenNotPaused {
        require(amount > 0, "SpotVault: zero amount");

        // VAULT-M1 FIX: Measure actual received tokens for fee-on-transfer protection
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        balances[to][token] += actualReceived;

        emit Deposit(to, token, actualReceived);
    }

    /// @notice Withdraw tokens from vault
    function withdraw(address token, uint256 amount, address to) external whenNotPaused {
        require(amount > 0, "SpotVault: zero amount");
        require(
            balances[msg.sender][token] >= amount,
            "SpotVault: insufficient balance"
        );

        balances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      SETTLEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer between accounts (settlement only)
    function debitCredit(
        address token,
        address from,
        address to,
        uint256 amount
    ) external onlyAuthorized whenNotPaused {
        require(
            balances[from][token] >= amount,
            "SpotVault: insufficient balance"
        );

        balances[from][token] -= amount;
        balances[to][token] += amount;

        emit Transfer(token, from, to, amount);
    }

    /// @notice Batch transfer (settlement only)
    function batchDebitCredit(
        address token,
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts
    ) external onlyAuthorized whenNotPaused {
        require(
            from.length == to.length && to.length == amounts.length,
            "SpotVault: length mismatch"
        );

        for (uint256 i = 0; i < from.length; i++) {
            require(
                balances[from[i]][token] >= amounts[i],
                "SpotVault: insufficient balance"
            );
            balances[from[i]][token] -= amounts[i];
            balances[to[i]][token] += amounts[i];
            emit Transfer(token, from[i], to[i], amounts[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function balanceOf(
        address user,
        address token
    ) external view returns (uint256) {
        return balances[user][token];
    }
}
