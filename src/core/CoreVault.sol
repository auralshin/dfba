// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPerpRisk} from "../interfaces/IPerpRisk.sol";

contract CoreVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Subaccount balance tracking: user => subaccountId => token => balance
    mapping(address => mapping(uint256 => mapping(address => uint256))) public balances;

    /// @notice Spot escrow (locked for pending orders): marketId => token => amount
    /// @dev Funds locked when orders submitted, released when claimed or cancelled
    mapping(uint64 => mapping(address => uint256)) public escrowSpot;

    /// @notice Perp initial margin reserves: orderId => amount
    /// @dev Reserves worst-case IM per order, released when order filled/cancelled
    mapping(bytes32 => mapping(address => uint256)) public reserveIM;

    /// @notice Total reserved IM per user per token: user => subaccountId => token => amount
    /// @dev Used for withdrawal checks - can't withdraw reserved IM
    mapping(address => mapping(uint256 => mapping(address => uint256))) public totalReservedPerToken;

    /// @notice Authorized movers (routers, settlement contracts)
    mapping(address => bool) public authorized;

    /// @notice Supported collateral tokens
    mapping(address => bool) public supportedCollateral;

    /// @notice Admin address
    address public admin;

    /// @notice Risk module for withdrawal checks
    IPerpRisk public riskModule;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 indexed subaccountId, address indexed token, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed subaccountId, address indexed token, uint256 amount);
    event Move(
        address indexed token,
        address indexed from,
        uint256 fromSubaccount,
        address indexed to,
        uint256 toSubaccount,
        uint256 amount
    );
    event EscrowLocked(uint64 indexed marketId, address indexed token, uint256 amount);
    event EscrowReleased(uint64 indexed marketId, address indexed token, uint256 amount);
    event IMReserved(bytes32 indexed orderId, address indexed token, uint256 amount);
    event IMReleased(bytes32 indexed orderId, address indexed token, uint256 amount);
    event CollateralAdded(address indexed token);
    event CollateralRemoved(address indexed token);
    event AuthorizedUpdated(address indexed account, bool authorized);
    event RiskModuleUpdated(address indexed riskModule);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        require(msg.sender == admin, "CoreVault: not admin");
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        require(authorized[msg.sender] || msg.sender == admin, "CoreVault: not authorized");
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

    function setAuthorized(address account, bool _authorized) external onlyAdmin {
        authorized[account] = _authorized;
        emit AuthorizedUpdated(account, _authorized);
    }

    function addCollateral(address token) external onlyAdmin {
        require(token != address(0), "CoreVault: zero address");
        require(token.code.length > 0, "CoreVault: not contract");
        supportedCollateral[token] = true;
        emit CollateralAdded(token);
    }

    function removeCollateral(address token) external onlyAdmin {
        supportedCollateral[token] = false;
        emit CollateralRemoved(token);
    }

    function setRiskModule(address _riskModule) external onlyAdmin {
        riskModule = IPerpRisk(_riskModule);
        emit RiskModuleUpdated(_riskModule);
    }

    /*//////////////////////////////////////////////////////////////
                          USER DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens into a subaccount
    /// @param subaccountId The subaccount to deposit into (0 = default)
    /// @param token The token to deposit
    /// @param amount The amount to deposit
    function deposit(uint256 subaccountId, address token, uint256 amount) external {
        require(supportedCollateral[token], "CoreVault: unsupported collateral");
        require(amount > 0, "CoreVault: zero amount");

        // Fee-on-transfer safe: measure actual received amount
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;

        balances[msg.sender][subaccountId][token] += actualAmount;

        emit Deposit(msg.sender, subaccountId, token, actualAmount);
    }

    /// @notice Withdraw tokens from a subaccount
    /// @param subaccountId The subaccount to withdraw from
    /// @param token The token to withdraw
    /// @param amount The amount to withdraw
    /// @dev Risk-gated: checks maintenance margin requirements if risk module set
    function withdraw(uint256 subaccountId, address token, uint256 amount) external {
        require(amount > 0, "CoreVault: zero amount");

        uint256 available = getAvailableBalance(msg.sender, subaccountId, token);
        require(amount <= available, "CoreVault: insufficient available balance");

        // Risk check: ensure withdrawal doesn't violate maintenance margin
        if (address(riskModule) != address(0)) {
            require(
                riskModule.canWithdraw(msg.sender, subaccountId, token, amount), "CoreVault: withdrawal violates MM"
            );
        }

        balances[msg.sender][subaccountId][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, subaccountId, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        AUTHORIZED MOVE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal move between accounts (authorized routers only)
    /// @dev Used by settlement contracts to transfer collateral
    function move(
        address token,
        address from,
        uint256 fromSubaccount,
        address to,
        uint256 toSubaccount,
        uint256 amount
    )
        external
        onlyAuthorized
    {
        require(amount > 0, "CoreVault: zero amount");
        require(balances[from][fromSubaccount][token] >= amount, "CoreVault: insufficient balance");

        balances[from][fromSubaccount][token] -= amount;
        balances[to][toSubaccount][token] += amount;

        emit Move(token, from, fromSubaccount, to, toSubaccount, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          SPOT ESCROW OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock spot collateral into escrow (SpotRouter only)
    /// @param marketId The market ID
    /// @param token The token to lock
    /// @param amount The amount to lock
    function lockSpotEscrow(uint64 marketId, address token, uint256 amount) external onlyAuthorized {
        require(amount > 0, "CoreVault: zero amount");
        escrowSpot[marketId][token] += amount;
        emit EscrowLocked(marketId, token, amount);
    }

    /// @notice Release spot escrow (settlement contracts)
    /// @param marketId The market ID
    /// @param token The token to release
    /// @param amount The amount to release
    function releaseSpotEscrow(uint64 marketId, address token, uint256 amount) external onlyAuthorized {
        require(escrowSpot[marketId][token] >= amount, "CoreVault: insufficient escrow");
        escrowSpot[marketId][token] -= amount;
        emit EscrowReleased(marketId, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         PERP IM RESERVE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve initial margin for a perp order (PerpRouter only)
    /// @param orderId The order ID
    /// @param user The user address
    /// @param subaccountId The subaccount ID
    /// @param token The collateral token
    /// @param amount The IM amount to reserve
    function reserveInitialMargin(
        bytes32 orderId,
        address user,
        uint256 subaccountId,
        address token,
        uint256 amount
    )
        external
        onlyAuthorized
    {
        require(amount > 0, "CoreVault: zero amount");
        require(reserveIM[orderId][token] == 0, "CoreVault: already reserved"); // CRITICAL: Prevent double-call corruption
        require(balances[user][subaccountId][token] >= amount, "CoreVault: insufficient balance");

        reserveIM[orderId][token] = amount;
        totalReservedPerToken[user][subaccountId][token] += amount;

        emit IMReserved(orderId, token, amount);
    }

    /// @notice Release initial margin for an order (settlement/cancellation)
    /// @param orderId The order ID
    /// @param user The user address
    /// @param subaccountId The subaccount ID
    /// @param token The collateral token
    function releaseInitialMargin(
        bytes32 orderId,
        address user,
        uint256 subaccountId,
        address token
    )
        external
        onlyAuthorized
    {
        uint256 amount = reserveIM[orderId][token];
        if (amount == 0) return;

        delete reserveIM[orderId][token];
        totalReservedPerToken[user][subaccountId][token] -= amount;

        emit IMReleased(orderId, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get available balance (total - reserved IM)
    /// @param user The user address
    /// @param subaccountId The subaccount ID
    /// @param token The token address
    /// @return available The available (withdrawable) balance
    function getAvailableBalance(
        address user,
        uint256 subaccountId,
        address token
    )
        public
        view
        returns (uint256 available)
    {
        uint256 total = balances[user][subaccountId][token];
        uint256 reserved = totalReservedPerToken[user][subaccountId][token];
        return total > reserved ? total - reserved : 0;
    }

    /// @notice Get reserved IM for a specific order
    /// @param orderId The order ID
    /// @param token The collateral token
    /// @return amount The reserved IM amount
    function getReservedIM(bytes32 orderId, address token) external view returns (uint256) {
        return reserveIM[orderId][token];
    }
}
