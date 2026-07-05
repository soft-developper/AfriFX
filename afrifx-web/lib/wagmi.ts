import { getDefaultConfig, getDefaultWallets } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'
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
  chains:     [arcTestnet],
  transports: { [arcTestnet.id]: http(arcTestnet.rpcUrls.default.http[0]) },
  ssr:        true,
})
