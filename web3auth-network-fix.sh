#!/bin/bash
# ============================================================
# AfriFX -- FIX: Web3Auth 400 "Failed to fetch project configurations"
#
# Cause: the code requested the Web3Auth SAPPHIRE_MAINNET network, but your
# dashboard project (and Client ID) are on SAPPHIRE_DEVNET. A Client ID is
# bound to the network it was created on, so the mismatch made the config
# call return 400 and blocked social login before it could start.
#
# Fix: default the network to Sapphire Devnet (matching your project), and
# make it env-configurable for the future:
#     NEXT_PUBLIC_WEB3AUTH_NETWORK=sapphire_mainnet   # only if you migrate
#
# Run from ~/AfriFX:  bash web3auth-network-fix.sh
# ============================================================
set -e
echo ""
echo "Fixing Web3Auth network (mainnet -> devnet to match your project)..."
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

// The network MUST match the network your Web3Auth project/Client ID was
// created on (a Client ID is bound to one network and can't be switched).
// Your dashboard project is on Sapphire Devnet, so default to that; override
// with NEXT_PUBLIC_WEB3AUTH_NETWORK=sapphire_mainnet if you move to a mainnet
// project later.
const web3AuthNetwork =
  process.env.NEXT_PUBLIC_WEB3AUTH_NETWORK === 'sapphire_mainnet'
    ? WEB3AUTH_NETWORK.SAPPHIRE_MAINNET
    : WEB3AUTH_NETWORK.SAPPHIRE_DEVNET

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
    web3AuthNetwork,
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
echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Fix: match Web3Auth network to devnet project (fixes 400 config error)'"
echo "  git push"
echo ""
echo "  (No env change needed -- it now defaults to sapphire_devnet, which"
echo "   matches your dashboard project.) Reload the site, pick Google/Email,"
echo "   and the login popup should now open instead of erroring."
