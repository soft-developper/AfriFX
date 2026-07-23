import { getDefaultConfig, getDefaultWallets } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'
// Bridge routes need the wallet to sign on OTHER chains too. Arc stays first,
// so it remains the app's default network and nothing existing changes.
import { activeChains, rpcUrlFor } from './bridge-chains'
import { web3AuthWallet, hasWeb3Auth } from './web3auth'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo'

// Start from RainbowKit's default wallet groups (MetaMask, WalletConnect, etc.)
const { wallets: defaultWallets } = getDefaultWallets()

// Add Web3Auth social login (Google + Email) as its own group at the top, so it
// appears INSIDE the same Connect modal alongside the default wallets. Only
// added when a client ID is configured.
const wallets = hasWeb3Auth
  ? [
      { groupName: 'Social login', wallets: [web3AuthWallet] },
      ...defaultWallets,
    ]
  : defaultWallets

export const wagmiConfig = getDefaultConfig({
  appName:    'AfriFX',
  appIcon:    'https://afrifx.xyz/favicon.svg',
  projectId,
  wallets,
  chains:     activeChains() as any,
  transports: Object.fromEntries(
    activeChains().map(c => [
      c.id,
      // Explicit RPC per chain viem's default public endpoints are
      // rate-limited and often blocked in-browser, which looks like
      // "RPC Request failed" even though nothing reached the chain.
      http(rpcUrlFor(c.id)),
    ]),
  ),
  ssr:        true,
})
