import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'
import { makeWeb3AuthConnector } from './web3auth'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo'

// Web3Auth social-login connector (Google + Email -> embedded wallet).
// Built lazily; null on the server or when no client ID is set, in which case
// we simply fall back to the default injected / WalletConnect wallets.
const web3authConnector = makeWeb3AuthConnector()

export const wagmiConfig = getDefaultConfig({
  appName:     'AfriFX',
  appIcon:     'https://afrifx.xyz/favicon.svg',
  projectId,
  chains:      [arcTestnet],
  transports:  { [arcTestnet.id]: http(arcTestnet.rpcUrls.default.http[0]) },
  ssr:         true,
  // Add the Web3Auth connector ALONGSIDE RainbowKit's default wallets
  // (MetaMask, WalletConnect, etc.) rather than replacing them.
  ...(web3authConnector ? { connectors: [web3authConnector] } : {}),
})
