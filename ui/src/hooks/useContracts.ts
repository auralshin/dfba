import { useReadContract, useWriteContract, useWaitForTransactionReceipt, useAccount } from 'wagmi'
import { 
  AUCTION_HOUSE_ABI, 
  PERP_ENGINE_ABI, 
  PERP_VAULT_ABI, 
  SPOT_SETTLEMENT_ABI, 
  ERC20_ABI,
  SPOT_ROUTER_ABI,
  PERP_ROUTER_ABI,
  CORE_VAULT_ABI
} from '../config/abis'
import { getContracts } from '../config/contracts'
import { useCallback, useMemo } from 'react'
import type { Address } from 'viem'

// Order types matching Solidity
export const Side = {
  Buy: 0,
  Sell: 1,
} as const

export type Side = typeof Side[keyof typeof Side]

export const Flow = {
  Maker: 0,
  Taker: 1,
} as const

export type Flow = typeof Flow[keyof typeof Flow]

export type Order = {
  trader: Address
  marketId: bigint
  side: Side
  flow: Flow
  priceTick: number
  qty: bigint
  nonce: bigint
  expiry: bigint
}

/**
 * Hook to get current batch ID for a market
 */
export function useBatchId(marketId: bigint) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'getBatchId',
    args: [marketId],
    query: {
      refetchInterval: 1000, // Refresh every second for batch updates
    },
  })
}

/**
 * Hook to get batch end time for a market
 */
export function useBatchEnd(marketId: bigint) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'getBatchEnd',
    args: [marketId],
  })
}

/**
 * Hook to get batch duration constant
 */
export function useBatchDuration() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'BATCH_DURATION',
  })
}

/**
 * Hook to submit a spot order via SpotRouter (proper way for users)
 */
export function useSubmitSpotOrder() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const submitOrder = useCallback(
    (order: Order) => {
      writeContract({
        address: contracts.SPOT_ROUTER as Address,
        abi: SPOT_ROUTER_ABI,
        functionName: 'submitOrder',
        args: [order],
      })
    },
    [writeContract, contracts]
  )

  return {
    submitOrder,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to submit a perp order via PerpRouter (proper way for users)
 */
export function useSubmitPerpOrder() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const submitOrder = useCallback(
    (order: Order, collateral: Address) => {
      writeContract({
        address: contracts.PERP_ROUTER as Address,
        abi: PERP_ROUTER_ABI,
        functionName: 'submitOrder',
        args: [order, collateral],
      })
    },
    [writeContract, contracts]
  )

  return {
    submitOrder,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to submit an order directly to AuctionHouse (only for routers with ROUTER_ROLE)
 * Normal users should use useSubmitSpotOrder or useSubmitPerpOrder instead
 */
export function useSubmitOrder() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const submitOrder = useCallback(
    (order: Order) => {
      writeContract({
        address: contracts.AUCTION_HOUSE as Address,
        abi: AUCTION_HOUSE_ABI,
        functionName: 'submitOrder',
        args: [order],
      })
    },
    [writeContract, contracts]
  )

  return {
    submitOrder,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to finalize a batch (incremental processing)
 */
export function useFinalizeBatch() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const finalizeBatch = useCallback(
    (marketId: bigint, batchId: bigint, maxSteps: bigint = BigInt(100)) => {
      writeContract({
        address: contracts.AUCTION_HOUSE as Address,
        abi: AUCTION_HOUSE_ABI,
        functionName: 'finalizeStep',
        args: [marketId, batchId, maxSteps],
      })
    },
    [writeContract, contracts]
  )

  return {
    finalizeBatch,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to cancel an order
 */
export function useCancelOrder() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const cancelOrder = useCallback(
    (orderId: `0x${string}`) => {
      writeContract({
        address: contracts.AUCTION_HOUSE as Address,
        abi: AUCTION_HOUSE_ABI,
        functionName: 'cancelOrder',
        args: [orderId],
      })
    },
    [writeContract, contracts]
  )

  return {
    cancelOrder,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to get order details
 */
export function useOrder(orderId: `0x${string}` | undefined) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'orders',
    args: orderId ? [orderId] : undefined,
    query: {
      enabled: !!orderId,
    },
  })
}

/**
 * Hook to get order state (to calculate filled qty)
 */
export function useOrderState(orderId: `0x${string}` | undefined) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'orderStates',
    args: orderId ? [orderId] : undefined,
    query: {
      enabled: !!orderId,
    },
  })
}

/**
 * Hook to get order filled quantity (calculated from order and orderState)
 */
export function useOrderFilledQty(orderId: `0x${string}` | undefined) {
  const { data: order } = useOrder(orderId)
  const { data: state } = useOrderState(orderId)
  
  if (!order || !state) return { data: undefined }
  
  // FilledQty = originalQty - remainingQty
  const filledQty = order[5] - state[0] // qty is at index 5, remainingQty at index 0
  return { data: filledQty }
}

/**
 * Hook to deposit margin to CoreVault
 */
export function useDepositMargin() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const depositMargin = useCallback(
    (token: Address, amount: bigint, subaccountId: bigint = 0n) => {
      writeContract({
        address: contracts.CORE_VAULT as Address,
        abi: CORE_VAULT_ABI,
        functionName: 'deposit',
        args: [token, amount, subaccountId],
      })
    },
    [writeContract, contracts]
  )

  return {
    depositMargin,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to get available margin balance from CoreVault
 */
export function useAvailableMargin(user: Address | undefined, token: Address, subaccountId: bigint = 0n) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.CORE_VAULT as Address,
    abi: CORE_VAULT_ABI,
    functionName: 'getAvailableBalance',
    args: user ? [user, token, subaccountId] : undefined,
    query: {
      enabled: !!user,
    },
  })
}

/**
 * Hook to approve ERC20 token spending
 */
export function useApproveToken() {
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const approve = useCallback(
    (token: Address, spender: Address, amount: bigint) => {
      writeContract({
        address: token,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [spender, amount],
      })
    },
    [writeContract]
  )

  return {
    approve,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to check ERC20 allowance
 */
export function useTokenAllowance(owner: Address | undefined, token: Address, spender: Address) {
  return useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: owner ? [owner, spender] : undefined,
    query: {
      enabled: !!owner,
    },
  })
}

/**
 * Hook to get ERC20 balance
 */
export function useTokenBalance(account: Address | undefined, token: Address) {
  return useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: account ? [account] : undefined,
    query: {
      enabled: !!account,
    },
  })
}

/**
 * Hook to claim perp order fills
 */
export function useClaimPerp() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const claimPerp = useCallback(
    (orderId: `0x${string}`, collateralToken: Address) => {
      writeContract({
        address: contracts.PERP_ENGINE as Address,
        abi: PERP_ENGINE_ABI,
        functionName: 'claimPerp',
        args: [orderId, collateralToken],
      })
    },
    [writeContract, contracts]
  )

  return {
    claimPerp,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to claim spot order fills
 */
export function useClaimSpot() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const claimSpot = useCallback(
    (orderId: `0x${string}`) => {
      writeContract({
        address: contracts.SPOT_SETTLEMENT as Address,
        abi: SPOT_SETTLEMENT_ABI,
        functionName: 'claimSpot',
        args: [orderId],
      })
    },
    [writeContract, contracts]
  )

  return {
    claimSpot,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to get perp position
 */
export function usePerpPosition(trader: Address | undefined, marketId: bigint) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.PERP_ENGINE as Address,
    abi: PERP_ENGINE_ABI,
    functionName: 'getPosition',
    args: trader ? [trader, marketId] : undefined,
    query: {
      enabled: !!trader,
    },
  })
}

/**
 * Helper to convert price to tick
 * Formula: tick = log₁.₀₀₀₁(price) = ln(price) / ln(1.0001)
 * For DFBA, we use a 1:1 tick mapping where tick ≈ price for simplicity
 * TODO: Adjust if you implement actual logarithmic tick spacing
 */
export function priceToTick(price: number): number {
  // Simplified: Using price as tick directly (integer price points)
  // For proper implementation: Math.floor(Math.log(price) / Math.log(1.0001))
  return Math.floor(price)
}

/**
 * Helper to convert tick to price  
 */
export function tickToPrice(tick: number): number {
  // Price = 1.0001^(tick/10000)
  // Simplified version
  return tick
}

/**
 * Helper to parse Wei to readable format
 */
export function formatWei(value: bigint | undefined, decimals = 18): string {
  if (!value) return '0'
  const divisor = BigInt(10 ** decimals)
  const integer = value / divisor
  const fraction = value % divisor
  return `${integer}.${fraction.toString().padStart(decimals, '0').slice(0, 4)}`
}

/**
 * Helper to convert readable amount to Wei
 */
export function parseWei(value: string, decimals = 18): bigint {
  const [integer, fraction = '0'] = value.split('.')
  const paddedFraction = fraction.padEnd(decimals, '0').slice(0, decimals)
  return BigInt(integer + paddedFraction)
}
