// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeModel} from "../../src/spot/FeeModel.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";

contract FeeModelTest is Test {
    FeeModel public feeModel;
    
    uint64 public constant MARKET_ID = 1;
    address public feeRecipient = address(0x999);

    function setUp() public {
        feeModel = new FeeModel(feeRecipient);
    }

    function test_defaultFees() public {
        assertEq(feeModel.defaultMakerFeeBps(), 5, "Default maker fee should be 5 bps");
        assertEq(feeModel.defaultTakerFeeBps(), 10, "Default taker fee should be 10 bps");
    }

    function test_setMarketFees() public {
        feeModel.setMarketFees(MARKET_ID, 3, 7, feeRecipient);
        
        (uint16 makerBps, uint16 takerBps, address recipient) = feeModel.marketFees(MARKET_ID);
        assertEq(makerBps, 3, "Maker fee should be 3 bps");
        assertEq(takerBps, 7, "Taker fee should be 7 bps");
        assertEq(recipient, feeRecipient, "Fee recipient should match");
    }

    function test_feeFor_maker() public {
        feeModel.setMarketFees(MARKET_ID, 5, 10, feeRecipient);
        
        uint256 notional = 10000;
        (uint256 fee, address recipient) = feeModel.feeFor(MARKET_ID, true, notional);
        
        assertEq(fee, 5, "Maker fee should be 5 (0.05% of 10000)");
        assertEq(recipient, feeRecipient, "Recipient should match");
    }

    function test_feeFor_taker() public {
        feeModel.setMarketFees(MARKET_ID, 5, 10, feeRecipient);
        
        uint256 notional = 10000;
        (uint256 fee, address recipient) = feeModel.feeFor(MARKET_ID, false, notional);
        
        assertEq(fee, 10, "Taker fee should be 10 (0.10% of 10000)");
        assertEq(recipient, feeRecipient, "Recipient should match");
    }

    function test_feeFor_defaultFees() public {
        // No custom fees set for market
        uint256 notional = 10000;
        (uint256 fee,) = feeModel.feeFor(999, true, notional);
        
        assertEq(fee, 5, "Should use default maker fee");
        
        (fee,) = feeModel.feeFor(999, false, notional);
        assertEq(fee, 10, "Should use default taker fee");
    }

    function test_setDefaultFees() public {
        feeModel.setDefaultFees(8, 15, feeRecipient);
        
        assertEq(feeModel.defaultMakerFeeBps(), 8, "Default maker fee should be updated");
        assertEq(feeModel.defaultTakerFeeBps(), 15, "Default taker fee should be updated");
    }
}
