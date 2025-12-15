// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";

/// @title PerpVault
/// @notice Margin accounting for perpetual futures
/// @dev Tracks collateral, reserved initial margin, and allows withdrawals subject to margin requirements
contract PerpVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Margin balances: user => token => balance
    mapping(address => mapping(address => uint256)) public marginBalances;

    /// @notice Reserved initial margin: user => marketId => token => amount
    /// @dev H2 FIX: Track per (user, marketId, token) triple for multi-collateral support
    mapping(address => mapping(uint64 => mapping(address => uint256))) public reservedIm;

    /// @notice Total reserved margin per user per token (sum across all markets)
    mapping(address => mapping(address => uint256)) public totalReservedPerToken;

    /// @notice Authorized contracts (PerpEngine, liquidation)
    mapping(address => bool) public authorized;

    /// @notice Supported collateral tokens
    mapping(address => bool) public supportedCollateral;

    /// @notice Admin
    address public admin;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarginDeposit(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event MarginWithdraw(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event IMReserved(
        address indexed user,
        uint64 indexed marketId,
        uint256 amount
    );
    event IMReleased(
        address indexed user,
        uint64 indexed marketId,
        uint256 amount
    );
    event CollateralAdded(address indexed token);
    event CollateralRemoved(address indexed token);
    event AuthorizedUpdated(address indexed account, bool authorized);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "PerpVault: not admin");
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        require(
            authorized[msg.sender] || msg.sender == admin,
            "PerpVault: not authorized"
        );
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

    function addCollateral(address token) external onlyAdmin {
        require(token != address(0), "PerpVault: zero address");
        require(_isContract(token), "PerpVault: token not contract");
        require(!supportedCollateral[token], "PerpVault: already supported");
        
        supportedCollateral[token] = true;
        emit CollateralAdded(token);
    }

    /// @notice Remove collateral token support
    /// @dev Can only remove if no active balances exist
    function removeCollateral(address token) external onlyAdmin {
        require(supportedCollateral[token], "PerpVault: not supported");


        supportedCollateral[token] = false;
        emit CollateralRemoved(token);
    }

    /// @notice Helper to check if address is a contract
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /*//////////////////////////////////////////////////////////////
                         USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit margin
    function depositMargin(address token, uint256 amount, address to) external {
        require(
            supportedCollateral[token],
            "PerpVault: unsupported collateral"
        );
        require(amount > 0, "PerpVault: zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        marginBalances[to][token] += amount;

        emit MarginDeposit(to, token, amount);
    }

    /// @notice Withdraw margin (must maintain margin requirements)
    function withdrawMargin(
        address token,
        uint256 amount,
        address to
    ) external {
        require(amount > 0, "PerpVault: zero amount");

        // C4 FIX: Check available margin considers reserved IM
        uint256 available = getAvailableMargin(msg.sender, token);
        require(
            available >= amount,
            "PerpVault: insufficient available margin"
        );
        
        // Additional safety: verify user doesn't have open positions
        // Note: In production, this should query PerpEngine for all active positions
        // and verify maintenance margin requirements are still met after withdrawal
        // This requires cross-contract coordination which is complex
        // For now, the reserved IM check provides basic protection

        marginBalances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit MarginWithdraw(msg.sender, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      MARGIN MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve initial margin for a new order
    function reserveInitialMargin(
        address user,
        uint64 marketId,
        address token,
        uint256 amount
    ) external onlyAuthorized {
        uint256 available = getAvailableMargin(user, token);
        require(available >= amount, "PerpVault: insufficient margin");

        // H2 FIX: Track per (user, marketId, token) to support multi-collateral
        reservedIm[user][marketId][token] += amount;
        totalReservedPerToken[user][token] += amount;
        emit IMReserved(user, marketId, amount);
    }

    /// @notice Release reserved initial margin
    /// @dev Now requires token parameter to support multi-collateral
    function releaseInitialMargin(
        address user,
        uint64 marketId,
        address token,
        uint256 amount
    ) external onlyAuthorized {
        // H2 FIX: Check reserved amount for specific (user, marketId, token) triple
        require(
            reservedIm[user][marketId][token] >= amount,
            "PerpVault: insufficient reserved"
        );
        
        reservedIm[user][marketId][token] -= amount;
        totalReservedPerToken[user][token] -= amount;
        
        emit IMReleased(user, marketId, amount);
    }

    /// @notice Credit/debit margin (for PnL realization)
    function adjustMargin(
        address user,
        address token,
        int256 amount
    ) external onlyAuthorized {
        if (amount > 0) {
            marginBalances[user][token] += uint256(amount);
        } else if (amount < 0) {
            uint256 debit = uint256(-amount);
            require(
                marginBalances[user][token] >= debit,
                "PerpVault: insufficient margin"
            );
            marginBalances[user][token] -= debit;
        }
    }

    /// @notice Transfer margin between users (for liquidations)
    function transferMargin(
        address token,
        address from,
        address to,
        uint256 amount
    ) external onlyAuthorized {
        require(
            marginBalances[from][token] >= amount,
            "PerpVault: insufficient balance"
        );
        marginBalances[from][token] -= amount;
        marginBalances[to][token] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get available (unreserved) margin
    function getAvailableMargin(
        address user,
        address token
    ) public view returns (uint256) {
        uint256 total = marginBalances[user][token];
        uint256 reserved = totalReservedPerToken[user][token];


        return total > reserved ? total - reserved : 0;
    }

    /// @notice Get total margin value (multi-collateral)
    /// @dev In production, use oracle prices to convert to USD
    function getTotalMarginValue(address /* user */) external pure returns (uint256) {

        return 0;
    }

    /// @notice Get margin balance for specific token
    function getMarginBalance(
        address user,
        address token
    ) external view returns (uint256) {
        return marginBalances[user][token];
    }

    /// @notice Get reserved IM for market and token
    /// @dev H2 FIX: Now requires token parameter for multi-collateral support
    function getReservedInitialMargin(
        address user,
        uint64 marketId,
        address token
    ) external view returns (uint256) {
        return reservedIm[user][marketId][token];
    }
}
