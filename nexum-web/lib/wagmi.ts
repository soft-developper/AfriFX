import { getDefaultConfig, getDefaultWallets } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'
// Bridge routes need the wallet to sign on OTHER chains too. Arc stays first,
// so it remains the app's default network and nothing existing changes.
import { activeChains, rpcUrlFor } from './bridge-chains'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo'

// Start from RainbowKit's default wallet groups (MetaMask, WalletConnect, etc.)
const { wallets: defaultWallets } = getDefaultWallets()

// Wallet options: RainbowKit defaults (MetaMask, WalletConnect, injected).
// Web3Auth social login was removed - users get wallets via Circle now;
// external payers still connect their own wallet here.
const wallets = defaultWallets

export const wagmiConfig = getDefaultConfig({
  appName:    'Nexum',
  appIcon:    'https://nexumpay.xyz/favicon.svg',
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
