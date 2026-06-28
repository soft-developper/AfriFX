import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo'

export const wagmiConfig = getDefaultConfig({
  appName:     'AfriFX',
  appIcon:     'https://afrifx.app/icon.png',
  projectId,
  chains:      [arcTestnet],
  transports:  { [arcTestnet.id]: http(arcTestnet.rpcUrls.default.http[0]) },
  ssr:         true,
})
