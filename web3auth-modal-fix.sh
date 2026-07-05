#!/bin/bash
# ============================================================
# AfriFX -- FIX: social login + wallets not showing in Connect modal
#
# The first Web3Auth wiring passed the connector via getDefaultConfig's
# `connectors` option, which REPLACES RainbowKit's entire wallet list (so
# MetaMask/WalletConnect disappeared) and still didn't render the social
# option (RainbowKit's modal only renders RainbowKit "wallet" objects, not
# raw wagmi connectors). That's why the modal looked empty.
#
# This fix:
#   * lib/web3auth.ts -- exposes Web3Auth as a RainbowKit custom WALLET
#     (Google/Email), using the v2 createConnector -> CreateConnectorFn
#     contract, so it renders INSIDE the normal modal.
#   * lib/wagmi.ts    -- starts from getDefaultWallets() (the real default
#     list) and ADDS a "Social login" group, via the `wallets` option
#     (which RainbowKit merges) instead of `connectors` (which overrides).
#
# Result: the Connect modal shows a "Social login -> Google / Email" group
# ABOVE MetaMask/WalletConnect, all in one modal.
#
# Run from ~/AfriFX:  bash web3auth-modal-fix.sh
# ============================================================
set -e
echo ""
echo "Applying Web3Auth modal fix..."
echo ""

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/web3auth.ts" << 'AFX_EOF'
import { Web3Auth } from '@web3auth/modal'
import { CHAIN_NAMESPACES, WEB3AUTH_NETWORK, WALLET_ADAPTERS } from '@web3auth/base'
import { EthereumPrivateKeyProvider } from '@web3auth/ethereum-provider'
import { AuthAdapter } from '@web3auth/auth-adapter'
import { Web3AuthConnector } from '@web3auth/web3auth-wagmi-connector'
import type { Wallet } from '@rainbow-me/rainbowkit'
import { arcTestnet } from './arc-chain'

/*
  Web3Auth social login (Google + Email) exposed as a RainbowKit "wallet" so it
  shows up INSIDE the normal Connect modal, alongside MetaMask / WalletConnect.

  IMPORTANT: it must be added to getDefaultConfig via the `wallets` option
  (which RainbowKit merges), NOT the `connectors` option (which replaces the
  whole list and hides the default wallets).

  Client ID: NEXT_PUBLIC_WEB3AUTH_CLIENT_ID (set in .env.local and Vercel).
*/

const clientId = process.env.NEXT_PUBLIC_WEB3AUTH_CLIENT_ID ?? ''

const chainConfig = {
  chainNamespace:   CHAIN_NAMESPACES.EIP155,
  chainId:          '0x' + arcTestnet.id.toString(16), // 5042002 -> 0x4cef52
  rpcTarget:        arcTestnet.rpcUrls.default.http[0],
  displayName:      arcTestnet.name,
  tickerName:       arcTestnet.nativeCurrency.name,
  ticker:           arcTestnet.nativeCurrency.symbol,
  blockExplorerUrl: arcTestnet.blockExplorers?.default.url ?? '',
}

function buildWeb3Auth() {
  const privateKeyProvider = new EthereumPrivateKeyProvider({ config: { chainConfig } })

  const web3AuthInstance = new Web3Auth({
    clientId,
    web3AuthNetwork:    WEB3AUTH_NETWORK.SAPPHIRE_MAINNET,
    privateKeyProvider,
    uiConfig: {
      appName:         'AfriFX',
      mode:            'dark',
      defaultLanguage: 'en',
      theme:           { primary: '#D9A441' },
    },
  })

  const authAdapter = new AuthAdapter({
    adapterSettings: { uxMode: 'popup' },
  })
  web3AuthInstance.configureAdapter(authAdapter)

  return web3AuthInstance
}

// RainbowKit custom wallet. RainbowKit calls createConnector with its wallet
// details; we return the Web3Auth wagmi connector. Only Google + Email are
// enabled in the Web3Auth modal.
export function web3AuthWallet(): Wallet {
  return {
    id:             'web3auth',
    name:           'Google / Email',
    iconUrl:        'https://web3auth.io/images/web3authlog.png',
    iconBackground: '#ffffff',
    installed:      true,
    createConnector: (walletDetails: any) => {
      const web3AuthInstance = buildWeb3Auth()
      const connectorFn = Web3AuthConnector({
        web3AuthInstance,
        modalConfig: {
          [WALLET_ADAPTERS.AUTH]: {
            label: 'auth',
            loginMethods: {
              google:             { name: 'Google', showOnModal: true },
              email_passwordless: { name: 'Email',  showOnModal: true },
              facebook: { name: 'facebook', showOnModal: false },
              twitter:  { name: 'twitter',  showOnModal: false },
              discord:  { name: 'discord',  showOnModal: false },
              twitch:   { name: 'twitch',   showOnModal: false },
              github:   { name: 'github',   showOnModal: false },
              apple:    { name: 'apple',    showOnModal: false },
              linkedin: { name: 'linkedin', showOnModal: false },
              reddit:   { name: 'reddit',   showOnModal: false },
              line:     { name: 'line',     showOnModal: false },
              kakao:    { name: 'kakao',    showOnModal: false },
              wechat:   { name: 'wechat',   showOnModal: false },
              weibo:    { name: 'weibo',    showOnModal: false },
              sms_passwordless: { name: 'sms', showOnModal: false },
            },
          },
        },
      })
      // RainbowKit contract: return a CreateConnectorFn that merges the
      // rkDetails RainbowKit passes in onto the wagmi connector it creates.
      return (config: any) => ({
        ...connectorFn(config),
        ...walletDetails,
      })
    },
  }
}

export const hasWeb3Auth = !!clientId
AFX_EOF
echo "  afrifx-web/lib/web3auth.ts"

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/wagmi.ts" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-web/lib/wagmi.ts"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Fix: show Web3Auth social login + default wallets in Connect modal'"
echo "  git push"
echo ""
echo "  Make sure NEXT_PUBLIC_WEB3AUTH_CLIENT_ID is set in .env.local AND Vercel."
echo "  Then reload the deployed site and open Connect Wallet -- you should see"
echo "  a 'Social login' group (Google / Email) above MetaMask/WalletConnect."
