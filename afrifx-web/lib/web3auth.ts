import { Web3AuthConnector } from '@web3auth/web3auth-wagmi-connector'
import { Web3Auth } from '@web3auth/modal'
import { CHAIN_NAMESPACES, WEB3AUTH_NETWORK, WALLET_ADAPTERS } from '@web3auth/base'
import { EthereumPrivateKeyProvider } from '@web3auth/ethereum-provider'
import { AuthAdapter } from '@web3auth/auth-adapter'
import { arcTestnet } from './arc-chain'

/*
  Web3Auth social-login connector (Google + Email) that produces an embedded,
  non-custodial wallet on Arc. Added ALONGSIDE the existing MetaMask /
  WalletConnect connectors — it does not replace them.

  Client ID comes from the Web3Auth dashboard; set NEXT_PUBLIC_WEB3AUTH_CLIENT_ID
  in .env.local and in Vercel. The chain values mirror lib/arc-chain.ts.
*/

const clientId = process.env.NEXT_PUBLIC_WEB3AUTH_CLIENT_ID ?? ''

const chainConfig = {
  chainNamespace: CHAIN_NAMESPACES.EIP155,
  chainId:        '0x' + arcTestnet.id.toString(16), // 5042002 -> 0x4ce2b2
  rpcTarget:      arcTestnet.rpcUrls.default.http[0],
  displayName:    arcTestnet.name,
  tickerName:     arcTestnet.nativeCurrency.name,
  ticker:         arcTestnet.nativeCurrency.symbol,
  blockExplorerUrl: arcTestnet.blockExplorers?.default.url ?? '',
}

// Build the connector lazily so it only runs in the browser (Web3Auth touches
// window). Returns null if no client ID is configured, so the app still works
// with just the injected/WalletConnect wallets.
export function makeWeb3AuthConnector() {
  if (typeof window === 'undefined' || !clientId) return null

  const privateKeyProvider = new EthereumPrivateKeyProvider({
    config: { chainConfig },
  })

  const web3AuthInstance = new Web3Auth({
    clientId,
    web3AuthNetwork: WEB3AUTH_NETWORK.SAPPHIRE_MAINNET, // production network for the Base plan
    privateKeyProvider,
    uiConfig: {
      appName: 'AfriFX',
      mode:    'dark',
      logoLight: 'https://afrifx.xyz/favicon.svg',
      logoDark:  'https://afrifx.xyz/favicon.svg',
      defaultLanguage: 'en',
      theme: { primary: '#D9A441' },
    },
  })

  // Configure the Auth adapter to show ONLY Google + Email (hide the rest).
  const authAdapter = new AuthAdapter({
    loginSettings: { mfaLevel: 'optional' },
    adapterSettings: {
      uxMode: 'popup',
    },
  })
  web3AuthInstance.configureAdapter(authAdapter)

  return Web3AuthConnector({
    web3AuthInstance,
    loginParams: { loginProvider: '' }, // let the modal show the enabled methods
    modalConfig: {
      [WALLET_ADAPTERS.AUTH]: {
        label: 'auth',
        loginMethods: {
          google:   { name: 'Google',   showOnModal: true },
          email_passwordless: { name: 'Email', showOnModal: true },
          // hide everything else
          facebook: { name: 'facebook', showOnModal: false },
          twitter:  { name: 'twitter',  showOnModal: false },
          discord:  { name: 'discord',  showOnModal: false },
          twitch:   { name: 'twitch',   showOnModal: false },
          github:   { name: 'github',   showOnModal: false },
          apple:    { name: 'apple',    showOnModal: false },
          linkedin: { name: 'linkedin', showOnModal: false },
          reddit:   { name: 'reddit',   showOnModal: false },
          line:     { name: 'line',     showOnModal: false },
          kakao:    { name: 'kakao',     showOnModal: false },
          weibo:    { name: 'weibo',    showOnModal: false },
          wechat:   { name: 'wechat',   showOnModal: false },
          sms_passwordless: { name: 'sms', showOnModal: false },
        },
      },
    },
  })
}
