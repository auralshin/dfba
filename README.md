# Dual Flow Batch Auction (DFBA)

> **⚠️ EXPERIMENTAL - NOT AUDITED**  
> This is an experimental implementation for research and educational purposes only.  
> **DO NOT USE IN PRODUCTION**. The contracts have not been audited and may contain critical bugs.  
> Use at your own risk.

A decentralized exchange protocol using time-based batch auctions to achieve fair price discovery and eliminate MEV extraction. Orders accumulate for fixed 1-second batches, then clear atomically at uniform prices for buyers and sellers.

Inspired by [Jump Crypto's DFBA design](https://www-webflow.jumpcrypto.com/resources/dual-flow-batch-auction)

## How DFBA Works

### Time-Based Batching
- **Fixed duration**: Each batch runs for 200ms on L2 deployment (`BATCH_DURATION`)
  - Demo uses 1 second due to Anvil's `block.timestamp` update behavior
  - L2s like Arbitrum, Optimism support subsecond block times for true 200ms batches
- **Batch ID**: `floor(block.timestamp / BATCH_DURATION)` - guarantees liveness even if finalization is delayed
- **Order submission**: Users submit orders for current or near-future batches (up to +10 batches ahead)
- **Cutoff**: Orders must arrive before batch end timestamp

### Dual Auction Mechanism
Each batch runs TWO separate auctions simultaneously:

1. **Bid Auction**: Maker-Buy vs Taker-Sell
   - Maker-Buy orders: Limit bids to buy at specific prices
   - Taker-Sell orders: Market sells willing to accept bid-side prices
   - Clearing: Highest bid that matches supply/demand

2. **Ask Auction**: Maker-Sell vs Taker-Buy
   - Maker-Sell orders: Limit asks to sell at specific prices
   - Taker-Buy orders: Market buys willing to pay ask-side prices
   - Clearing: Lowest ask that matches supply/demand

### Four Order Types
- **Maker-Buy (MB)**: "I want to buy X at price P or better" → contributes to bid liquidity
- **Maker-Sell (MS)**: "I want to sell X at price P or better" → contributes to ask liquidity
- **Taker-Buy (TB)**: "I want to buy X, willing to pay up to P" → crosses into ask auction
- **Taker-Sell (TS)**: "I want to sell X, need at least P" → crosses into bid auction

### Clearing Process
After batch ends, finalization processes orders in phases:

1. **DiscoverBid**: Find clearing price for bid auction (MB vs TS)
2. **ConsumeBidDemand**: Fill taker-sell orders from bid auction
3. **ConsumeBidSupply**: Fill maker-buy orders from bid auction
4. **DiscoverAsk**: Find clearing price for ask auction (MS vs TB)
5. **ConsumeAskSupply**: Fill maker-sell orders from ask auction
6. **ConsumeAskDemand**: Fill taker-buy orders from ask auction
7. **Finalized**: Batch complete

Orders are processed incrementally (100 ticks per `finalizeStep`) to avoid gas limits.

## Architecture

### Core Contracts

- **AuctionHouse** (`src/core/AuctionHouse.sol`): Central batch auction mechanism with incremental finalization
- **CoreVault** (`src/core/CoreVault.sol`): Unified collateral vault with subaccount support, manages deposits/withdrawals and reserves
- **SpotRouter** (`src/core/SpotRouter.sol`): Handles spot order submission with automatic escrow locking and EIP-712 signatures
- **PerpRouter** (`src/core/PerpRouter.sol`): Manages perp orders with position tracking, initial margin reserves, and risk checks
- **PerpRisk** (`src/perp/PerpRisk.sol`): Risk engine for calculating initial margin requirements for perp positions

### Supporting Components

- **Scripts** (`script/`): Foundry scripts for deployment, testing, and batch management
- **Tests** (`test/`): Comprehensive test suites including unit, fuzz, and invariant tests

### Key Features

- **L2-optimized**: 200ms batch windows on Arbitrum/Optimism/Base
- **Tick-based pricing**: Bitmap storage for gas-efficient price level management
- **Dual clearing**: Independent uniform-price auctions for bid and ask sides
- **Role-based access**: Routers enforce pre-funding (spot) and margin requirements (perp)
- **Subaccounts**: Multi-subaccount support for isolated positions
- **Incremental finalization**: Gas-efficient batch processing

## Project Structure

```
.
├── src/
│   ├── core/           # Core protocol contracts
│   │   ├── AuctionHouse.sol
│   │   ├── CoreVault.sol
│   │   ├── PerpRouter.sol
│   │   └── SpotRouter.sol
│   ├── perp/           # Perp-specific modules
│   │   ├── PerpRisk.sol
│   │   └── OracleAdapter.sol
│   ├── libraries/      # Shared libraries
│   │   ├── OrderTypes.sol
│   │   ├── Math.sol
│   │   └── TickBitmap.sol
│   └── interfaces/     # Contract interfaces
├── test/               # Foundry test suites
└── script/             # Deployment & management scripts
```

## Development

```bash
# Install Foundry dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run tests with coverage
forge coverage

# Deploy (local Anvil)
forge script script/Deploy.s.sol --broadcast --rpc-url http://localhost:8545 --private-key <key>
```

## Available Scripts

- **Deploy.s.sol**: Deploy all core contracts and set up markets
- **PlaceOrders.s.sol**: Submit test orders to the auction house
- **FinalizeBatch.s.sol**: Manually finalize a batch
- **Keeper.s.sol**: Automated keeper for batch finalization
- **CheckMatches.s.sol**: Debug script to check order matching results
- **CheckOrders.s.sol**: Debug script to inspect order details

## License

MIT
