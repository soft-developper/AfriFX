import { defineChain } from 'viem'

const RPC = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'

export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: {
    decimals: 18,
    name: 'USD Coin',
    symbol: 'USDC',
  },
  rpcUrls: {
    default: {
      http:      [RPC],
      webSocket: [RPC.replace('https://', 'wss://')],
    },
    blockdaemon: {
      http: ['https://rpc.blockdaemon.testnet.arc.network'],
    },
  },
  blockExplorers: {
    default: {
      name: 'ArcScan',
      url:  'https://testnet.arcscan.app',
    },
  },
  testnet: true,
})
