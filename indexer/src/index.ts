import { createPublicClient, http, parseAbiItem, type Address, type Log } from 'viem';
import { localhost } from 'viem/chains';
import express from 'express';
import cors from 'cors';
import { config } from 'dotenv';

config();

const app = express();
app.use(cors());
app.use(express.json());

// SSE clients
const clients = new Set<express.Response>();

// In-memory cache
interface BatchData {
  batchId: string;
  marketId: string;
  timestamp: number;
  orders: OrderData[];
  cleared: boolean;
}

interface OrderData {
  orderId: string;
  trader: Address;
  marketId: string;
  batchId: string;
  side: number;
  flow: number;
  priceTick: number;
  qty: string;
  filledQty?: string;
  timestamp: number;
  txHash: string;
}

const batches = new Map<string, BatchData>();
const orders = new Map<string, OrderData>();
const userOrders = new Map<Address, Set<string>>();

// Viem client
const client = createPublicClient({
  chain: localhost,
  transport: http(process.env.RPC_URL || 'http://127.0.0.1:8545'),
});

const AUCTION_HOUSE = (process.env.AUCTION_HOUSE_ADDRESS || '0x5FbDB2315678afecb367f032d93F642f64180aa3') as Address;

// ABI events
const ORDER_SUBMITTED_EVENT = parseAbiItem(
  'event OrderSubmitted(bytes32 indexed orderId, address indexed trader, uint64 indexed marketId, uint64 batchId)'
);

const ORDER_CANCELLED_EVENT = parseAbiItem(
  'event OrderCancelled(bytes32 indexed orderId, address indexed trader)'
);

const BATCH_FINALIZED_EVENT = parseAbiItem(
  'event BatchFinalized(uint64 indexed marketId, uint64 indexed batchId, uint8 side)'
);

let lastProcessedBlock = 0n;

// Polling function
async function pollChain() {
  try {
    const latestBlock = await client.getBlockNumber();
    
    if (lastProcessedBlock === 0n) {
      // First run - start from deployment (block 0 for local testing)
      lastProcessedBlock = 0n;
    }

    if (latestBlock <= lastProcessedBlock) {
      return; // No new blocks
    }

    console.log(`Processing blocks ${lastProcessedBlock + 1n} to ${latestBlock}`);

    // Get order submitted events
    const orderLogs = await client.getLogs({
      address: AUCTION_HOUSE,
      event: ORDER_SUBMITTED_EVENT,
      fromBlock: lastProcessedBlock + 1n,
      toBlock: latestBlock,
    });

    // Get cancelled events
    const cancelLogs = await client.getLogs({
      address: AUCTION_HOUSE,
      event: ORDER_CANCELLED_EVENT,
      fromBlock: lastProcessedBlock + 1n,
      toBlock: latestBlock,
    });

    // Get finalized events
    const finalizedLogs = await client.getLogs({
      address: AUCTION_HOUSE,
      event: BATCH_FINALIZED_EVENT,
      fromBlock: lastProcessedBlock + 1n,
      toBlock: latestBlock,
    });

    // Process order submitted
    for (const log of orderLogs) {
      await processOrderSubmitted(log);
    }

    // Process cancellations
    for (const log of cancelLogs) {
      await processOrderCancelled(log);
    }

    // Process batch finalized
    for (const log of finalizedLogs) {
      await processBatchFinalized(log);
    }

    lastProcessedBlock = latestBlock;

    // Notify SSE clients
    if (orderLogs.length > 0 || cancelLogs.length > 0 || finalizedLogs.length > 0) {
      broadcastUpdate();
    }
  } catch (error) {
    console.error('Polling error:', error);
  }
}

async function processOrderSubmitted(log: Log) {
  const { args, transactionHash } = log as any;
  
  const orderId = args.orderId as string;
  const trader = args.trader as Address;
  const marketId = args.marketId.toString();
  const batchId = args.batchId.toString();

  // Store basic order data from event (will fetch details later if needed)
  const orderData: OrderData = {
    orderId,
    trader,
    marketId,
    batchId,
    side: 0, // Will fetch from contract later
    flow: 0,
    priceTick: 0,
    qty: "0",
    timestamp: Date.now(),
    txHash: transactionHash || '',
  };

  orders.set(orderId, orderData);

  // Add to user orders
  if (!userOrders.has(trader)) {
    userOrders.set(trader, new Set());
  }
  userOrders.get(trader)!.add(orderId);

  // Add to batch
  const batchKey = `${marketId}-${batchId}`;
  if (!batches.has(batchKey)) {
    batches.set(batchKey, {
      batchId,
      marketId,
      timestamp: Date.now(),
      orders: [],
      cleared: false,
    });
  }
  batches.get(batchKey)!.orders.push(orderData);

  console.log(`Order submitted: ${orderId.slice(0, 10)}... by ${trader}`);
}

async function processOrderCancelled(log: Log) {
  const { args } = log as any;
  const orderId = args.orderId as string;
  
  const order = orders.get(orderId);
  if (order) {
    orders.delete(orderId);
    console.log(`Order cancelled: ${orderId.slice(0, 10)}...`);
  }
}

async function processBatchFinalized(log: Log) {
  const { args } = log as any;
  const marketId = args.marketId.toString();
  const batchId = args.batchId.toString();
  const batchKey = `${marketId}-${batchId}`;

  const batch = batches.get(batchKey);
  if (batch) {
    batch.cleared = true;
    
    // Fetch filled quantities for all orders in this batch
    for (const order of batch.orders) {
      try {
        const filledQty = await client.readContract({
          address: AUCTION_HOUSE,
          abi: [{
            name: 'getOrderFilledQty',
            type: 'function',
            stateMutability: 'view',
            inputs: [{ name: 'orderId', type: 'bytes32' }],
            outputs: [{ name: 'filledQty', type: 'uint128' }],
          }],
          functionName: 'getOrderFilledQty',
          args: [order.orderId as `0x${string}`],
        });
        order.filledQty = filledQty.toString();
      } catch (err) {
        console.error(`Error fetching fill for ${order.orderId}:`, err);
      }
    }

    console.log(`Batch finalized: ${batchKey} with ${batch.orders.length} orders`);
  }
}

function broadcastUpdate() {
  const data = JSON.stringify({
    type: 'update',
    timestamp: Date.now(),
    stats: {
      totalBatches: batches.size,
      totalOrders: orders.size,
      activeUsers: userOrders.size,
    },
  });

  clients.forEach(client => {
    client.write(`data: ${data}\n\n`);
  });
}

// API Routes
app.get('/health', (req, res) => {
  res.json({ status: 'ok', lastBlock: lastProcessedBlock.toString() });
});

app.get('/stats', (req, res) => {
  res.json({
    totalBatches: batches.size,
    totalOrders: orders.size,
    activeUsers: userOrders.size,
    lastProcessedBlock: lastProcessedBlock.toString(),
  });
});

app.get('/batches', (req, res) => {
  const marketId = req.query.marketId as string;
  const limit = Math.min(parseInt(req.query.limit as string) || 10, 100);
  
  let batchList = Array.from(batches.values());
  
  if (marketId) {
    batchList = batchList.filter(b => b.marketId === marketId);
  }
  
  batchList.sort((a, b) => b.timestamp - a.timestamp);
  
  res.json({
    batches: batchList.slice(0, limit),
    total: batchList.length,
  });
});

app.get('/batch/:marketId/:batchId', (req, res) => {
  const { marketId, batchId } = req.params;
  const batchKey = `${marketId}-${batchId}`;
  const batch = batches.get(batchKey);
  
  if (!batch) {
    return res.status(404).json({ error: 'Batch not found' });
  }
  
  res.json(batch);
});

app.get('/orders/user/:address', (req, res) => {
  const address = req.params.address.toLowerCase() as Address;
  const orderIds = userOrders.get(address);
  
  if (!orderIds) {
    return res.json({ orders: [] });
  }
  
  const userOrderList = Array.from(orderIds)
    .map(id => orders.get(id))
    .filter(Boolean)
    .sort((a, b) => (b?.timestamp || 0) - (a?.timestamp || 0));
  
  res.json({ orders: userOrderList });
});

app.get('/order/:orderId', (req, res) => {
  const orderId = req.params.orderId;
  const order = orders.get(orderId);
  
  if (!order) {
    return res.status(404).json({ error: 'Order not found' });
  }
  
  res.json(order);
});

// SSE endpoint
app.get('/events', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  
  clients.add(res);
  console.log(`SSE client connected. Total clients: ${clients.size}`);
  
  // Send initial connection message
  res.write(`data: ${JSON.stringify({ type: 'connected', timestamp: Date.now() })}\n\n`);
  
  req.on('close', () => {
    clients.delete(res);
    console.log(`SSE client disconnected. Total clients: ${clients.size}`);
  });
});

// Start polling
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL_MS || '2000');
setInterval(pollChain, POLL_INTERVAL);

// Initial poll
pollChain();

// Start server
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(`DFBA Indexer running on port ${PORT}`);
  console.log(`SSE endpoint: http://localhost:${PORT}/events`);
  console.log(`Polling interval: ${POLL_INTERVAL}ms`);
});
