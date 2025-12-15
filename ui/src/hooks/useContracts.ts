import { useReadContract, useWriteContract, useWaitForTransactionReceipt, useAccount } from 'wagmi'
import { AUCTION_HOUSE_ABI, PERP_ENGINE_ABI, PERP_VAULT_ABI, SPOT_SETTLEMENT_ABI, ERC20_ABI } from '../config/abis'
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
  auctionId: bigint
  side: Side
  flow: Flow
  priceTick: number
  qty: bigint
  nonce: bigint
  expiry: bigint
}

/**
 * Hook to get current auction ID for a market
 */
export function useAuctionId(marketId: bigint) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'getAuctionId',
    args: [marketId],
    query: {
      refetchInterval: 1000, // Refresh every second for auction updates
    },
  })
}

/**
 * Hook to get clearing results for an auction
 */
export function useClearing(marketId: bigint, auctionId: bigint) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.AUCTION_HOUSE as Address,
    abi: AUCTION_HOUSE_ABI,
    functionName: 'getClearing',
    args: [marketId, auctionId],
  })
}

/**
 * Hook to submit an order to the auction house
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
 * Hook to finalize an auction
 */
export function useFinalizeAuction() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const finalizeAuction = useCallback(
    (marketId: bigint, auctionId: bigint) => {
      writeContract({
        address: contracts.AUCTION_HOUSE as Address,
        abi: AUCTION_HOUSE_ABI,
        functionName: 'finalizeAuction',
        args: [marketId, auctionId],
      })
    },
    [writeContract, contracts]
  )

  return {
    finalizeAuction,
    hash,
    isPending,
    isConfirming,
    isSuccess,
    error,
  }
}

/**
 * Hook to deposit margin for perp trading
 */
export function useDepositMargin() {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])
  
  const { data: hash, writeContract, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const depositMargin = useCallback(
    (token: Address, amount: bigint, to: Address) => {
      writeContract({
        address: contracts.PERP_VAULT as Address,
        abi: PERP_VAULT_ABI,
        functionName: 'depositMargin',
        args: [token, amount, to],
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
 * Hook to get available margin balance
 */
export function useAvailableMargin(user: Address | undefined, token: Address) {
  const { chain } = useAccount()
  const contracts = useMemo(() => getContracts(chain?.id ?? 31337), [chain])

  return useReadContract({
    address: contracts.PERP_VAULT as Address,
    abi: PERP_VAULT_ABI,
    functionName: 'getAvailableMargin',
    args: user ? [user, token] : undefined,
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
 */
export function priceToTick(price: number): number {
  // Tick = log1.0001(price) * 10000
  // This is a simplified version - adjust based on your tick spacing
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
