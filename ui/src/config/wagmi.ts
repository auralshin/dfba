import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { mainnet, sepolia, arbitrumSepolia } from 'wagmi/chains'

export const config = getDefaultConfig({
  appName: 'DFBA Exchange',
  projectId: import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || 'YOUR_PROJECT_ID',
  chains: [arbitrumSepolia, sepolia, mainnet],
  ssr: false,
})

declare module 'wagmi' {
  interface Register {
    config: typeof config
  }
}
