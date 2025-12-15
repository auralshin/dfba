import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { mainnet, sepolia } from 'wagmi/chains'
import { defineChain } from 'viem'

// Define localhost chain with correct chainId for Foundry anvil
const localhost = defineChain({
  id: 31337,
  name: 'Localhost',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: ['http://127.0.0.1:8545'] },
  },
  testnet: true,
})

export const config = getDefaultConfig({
  appName: 'DFBA Exchange',
  projectId: import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || 'YOUR_PROJECT_ID',
  chains: [localhost, sepolia, mainnet],
  ssr: false,
})

declare module 'wagmi' {
  interface Register {
    config: typeof config
  }
}
