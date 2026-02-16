# Dual Flow Batch Auction (DFBA)

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

## Why DFBA is Better Than CLOB

### 1. **MEV Elimination**
**CLOB**: Searchers can frontrun, backrun, and sandwich user orders for profit
- High-value trades leak ~0.5-2% to MEV
- Users suffer worse execution prices
- Gas wars for priority ordering

**DFBA**: Time-based batching makes MEV extraction impossible
- All orders in a batch see the same price
- No order within batch can be frontrun by another
- No sandwich attacks possible (orders clear atomically)

### 2. **Fair Price Discovery**
**CLOB**: First-come-first-served execution advantages fast traders
- HFT firms with co-located servers get priority
- Retail users disadvantaged by latency
- Price impact depends on order arrival time

**DFBA**: Uniform price auction ensures fairness
- All orders in batch execute at same clearing price
- No advantage to faster submission (within batch window)
- Marginal orders partially filled pro-rata

### 3. **Gas Efficiency**
**CLOB**: Every order update requires a transaction
- Cancel/replace orders cost gas
- Market makers pay gas to maintain spreads
- Aggregate gas cost scales linearly with order flow

**DFBA**: Batching amortizes costs
- Single clearing transaction processes entire batch
- Failed orders don't consume gas (rejected in simulation)
- Incremental finalization handles large batches efficiently

### 4. **No Spread Rent Extraction**
**CLOB**: Market makers earn bid-ask spread on every trade
- Spread widens with volatility (risk premium)
- Users pay implicit fees via worse prices
- Makers extract value without adding liquidity

**DFBA**: Dual auctions eliminate spread
- Bid and ask auctions clear independently
- No middleman collecting spread
- True maker-taker model: makers provide liquidity, takers cross

### 5. **Guaranteed Execution at Best Price**
**CLOB**: Limit orders may not fill or fill at suboptimal prices
- Partial fills at multiple price levels
- Slippage depends on order book depth
- No guarantee of best available price

**DFBA**: Clearing algorithm finds optimal price
- All participants get the uniform clearing price
- Marginal orders filled proportionally
- Maximum liquidity utilization

### 6. **Liveness Guarantees**
**CLOB**: Requires continuous liquidity provision
- Order book can become thin/illiquid
- Halts possible if makers withdraw
- Chicken-egg problem for new markets

**DFBA**: Time-based batches always open
- Users can submit orders even if no liquidity yet
- Batch will finalize (possibly with no fills)
- No dependence on always-on market makers

## Trade-Offs

**Latency**: 200ms batch window means slightly slower execution than instant CLOB fills
- Negligible for most users (~1 block delay on most L2s)
- Acceptable trade-off for MEV protection and fair pricing

**Complexity**: Dual auction mechanism more complex than simple limit order matching
- Requires understanding of maker/taker + bid/ask interaction
- Finalization logic iterative (gas considerations)

**Price Discovery**: Batch auctions update prices less frequently than continuous CLOBs

According to Jump Crypto's analysis:
- **100ms-1s batches** are optimal for natural-flow traders
- Below 100ms provides no UX benefit (human reaction time is ~200-250ms)
- At 100ms: market mispriced only 4% of the time, 0.008 bps average error (negligible)
- At 1s: market mispriced ~40% of time, 0.08 bps average error (still acceptable)
- This implementation uses **1-second batches** (demo compatible, within Jump's recommended range)
- Production L2 deployment can use 200ms batches for "instantaneous feel" UX
- Future batches allow pre-positioning for expected price moves

## Architecture

### Core Contracts

- **AuctionHouse** (`src/core/AuctionHouse.sol`): Central batch auction mechanism with incremental finalization
- **CoreVault** (`src/core/CoreVault.sol`): Unified collateral vault with subaccount support, manages deposits/withdrawals and reserves
- **SpotRouter** (`src/core/SpotRouter.sol`): Handles spot order submission with automatic escrow locking and EIP-712 signatures
- **PerpRouter** (`src/core/PerpRouter.sol`): Manages perp orders with position tracking, initial margin reserves, and risk checks
- **PerpRisk** (`src/perp/PerpRisk.sol`): Risk engine for calculating initial margin requirements for perp positions

### Supporting Components

- **Indexer** (`indexer/`): Real-time TypeScript indexer using polling + SSE for event tracking and order/fill data
- **UI** (`ui/`): React-based trading interface with Vite, wagmi, and RainbowKit integration
- **Scripts** (`script/`): Foundry scripts for deployment, testing, and batch management

### Key Features

- **L2-optimized**: 200ms batch windows on Arbitrum/Optimism/Base
- **Tick-based pricing**: Bitmap storage for gas-efficient price level management
- **Dual clearing**: Independent uniform-price auctions for bid and ask sides
- **Role-based access**: Routers enforce pre-funding (spot) and margin requirements (perp)
- **Subaccounts**: Multi-subaccount support for isolated positions
- **Real-time updates**: SSE-based indexer for live order book and fill data

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
├── script/             # Deployment & management scripts
├── indexer/            # Real-time TypeScript indexer
│   └── src/
│       └── index.ts
└── ui/                 # React trading interface
    └── src/
```

## Development

### Smart Contracts

```bash
# Install Foundry dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Deploy (local)
forge script script/Deploy.s.sol --broadcast --rpc-url http://localhost:8545
```

### Indexer

```bash
cd indexer
npm install
cp .env.example .env
# Edit .env with RPC_URL and contract addresses
npm run dev
```

### UI

```bash
cd ui
npm install
npm run dev
```
