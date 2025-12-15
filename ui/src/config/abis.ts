export const AUCTION_HOUSE_ABI = [
  {
    "type": "function",
    "name": "submitOrder",
    "inputs": [
      {
        "name": "order",
        "type": "tuple",
        "components": [
          { "name": "trader", "type": "address" },
          { "name": "marketId", "type": "uint64" },
          { "name": "auctionId", "type": "uint64" },
          { "name": "side", "type": "uint8" },
          { "name": "flow", "type": "uint8" },
          { "name": "priceTick", "type": "int24" },
          { "name": "qty", "type": "uint128" },
          { "name": "nonce", "type": "uint128" },
          { "name": "expiry", "type": "uint64" }
        ]
      }
    ],
    "outputs": [{ "name": "orderId", "type": "bytes32" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getAuctionId",
    "inputs": [{ "name": "marketId", "type": "uint64" }],
    "outputs": [{ "name": "", "type": "uint64" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "finalizeAuction",
    "inputs": [
      { "name": "marketId", "type": "uint64" },
      { "name": "auctionId", "type": "uint64" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getClearing",
    "inputs": [
      { "name": "marketId", "type": "uint64" },
      { "name": "auctionId", "type": "uint64" }
    ],
    "outputs": [
      {
        "name": "buyClearing",
        "type": "tuple",
        "components": [
          { "name": "clearingTick", "type": "int24" },
          { "name": "marginalFillMakerBps", "type": "uint16" },
          { "name": "marginalFillTakerBps", "type": "uint16" },
          { "name": "clearedQty", "type": "uint128" },
          { "name": "finalized", "type": "bool" }
        ]
      },
      {
        "name": "sellClearing",
        "type": "tuple",
        "components": [
          { "name": "clearingTick", "type": "int24" },
          { "name": "marginalFillMakerBps", "type": "uint16" },
          { "name": "marginalFillTakerBps", "type": "uint16" },
          { "name": "clearedQty", "type": "uint128" },
          { "name": "finalized", "type": "bool" }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getOrder",
    "inputs": [{ "name": "orderId", "type": "bytes32" }],
    "outputs": [
      {
        "name": "order",
        "type": "tuple",
        "components": [
          { "name": "trader", "type": "address" },
          { "name": "marketId", "type": "uint64" },
          { "name": "auctionId", "type": "uint64" },
          { "name": "side", "type": "uint8" },
          { "name": "flow", "type": "uint8" },
          { "name": "priceTick", "type": "int24" },
          { "name": "qty", "type": "uint128" },
          { "name": "nonce", "type": "uint128" },
          { "name": "expiry", "type": "uint64" }
        ]
      },
      {
        "name": "state",
        "type": "tuple",
        "components": [
          { "name": "remainingQty", "type": "uint128" },
          { "name": "claimedQty", "type": "uint128" },
          { "name": "cancelled", "type": "bool" }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "markets",
    "inputs": [{ "name": "marketId", "type": "uint64" }],
    "outputs": [
      { "name": "marketType", "type": "uint8" },
      { "name": "baseToken", "type": "address" },
      { "name": "quoteToken", "type": "address" },
      { "name": "startTime", "type": "uint64" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "AUCTION_DURATION",
    "inputs": [],
    "outputs": [{ "name": "", "type": "uint64" }],
    "stateMutability": "view"
  }
] as const

export const PERP_ENGINE_ABI = [
  {
    "type": "function",
    "name": "placePerpOrder",
    "inputs": [
      {
        "name": "order",
        "type": "tuple",
        "components": [
          { "name": "trader", "type": "address" },
          { "name": "marketId", "type": "uint64" },
          { "name": "auctionId", "type": "uint64" },
          { "name": "side", "type": "uint8" },
          { "name": "flow", "type": "uint8" },
          { "name": "priceTick", "type": "int24" },
          { "name": "qty", "type": "uint128" },
          { "name": "nonce", "type": "uint128" },
          { "name": "expiry", "type": "uint64" }
        ]
      },
      { "name": "collateralToken", "type": "address" }
    ],
    "outputs": [{ "name": "orderId", "type": "bytes32" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claimPerp",
    "inputs": [
      { "name": "orderId", "type": "bytes32" },
      { "name": "collateralToken", "type": "address" }
    ],
    "outputs": [
      { "name": "fillQty", "type": "uint128" },
      { "name": "realizedPnL", "type": "int128" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getPosition",
    "inputs": [
      { "name": "trader", "type": "address" },
      { "name": "marketId", "type": "uint64" }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "components": [
          { "name": "size", "type": "int128" },
          { "name": "entryPrice", "type": "uint128" },
          { "name": "marginBalance", "type": "int128" },
          { "name": "lastFundingIndex", "type": "int64" }
        ]
      }
    ],
    "stateMutability": "view"
  }
] as const

export const PERP_VAULT_ABI = [
  {
    "type": "function",
    "name": "depositMargin",
    "inputs": [
      { "name": "token", "type": "address" },
      { "name": "amount", "type": "uint256" },
      { "name": "to", "type": "address" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawMargin",
    "inputs": [
      { "name": "token", "type": "address" },
      { "name": "amount", "type": "uint256" },
      { "name": "to", "type": "address" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getAvailableMargin",
    "inputs": [
      { "name": "user", "type": "address" },
      { "name": "token", "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "marginBalances",
    "inputs": [
      { "name": "user", "type": "address" },
      { "name": "token", "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  }
] as const

export const SPOT_SETTLEMENT_ABI = [
  {
    "type": "function",
    "name": "claimSpot",
    "inputs": [{ "name": "orderId", "type": "bytes32" }],
    "outputs": [
      { "name": "fillQty", "type": "uint128" },
      { "name": "fillPrice", "type": "uint256" }
    ],
    "stateMutability": "nonpayable"
  }
] as const

export const ERC20_ABI = [
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      { "name": "spender", "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      { "name": "owner", "type": "address" },
      { "name": "spender", "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [{ "name": "account", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [{ "name": "", "type": "uint8" }],
    "stateMutability": "view"
  }
] as const
