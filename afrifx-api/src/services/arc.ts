import { createPublicClient, http, parseAbiItem } from 'viem'
import { defineChain } from 'viem'

// Arc Testnet Chain ID 5042002
export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { decimals: 18, name: 'USD Coin', symbol: 'USDC' },
  rpcUrls: {
    default: { http: [process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://testnet.arcscan.app' },
  },
  testnet: true,
})

export const arcClient = createPublicClient({
  chain: arcTestnet,
  transport: http(process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'),
})

// Arc contract addresses
export const USDC_ADDRESS = '0x3600000000000000000000000000000000000000' as const

// Watch USDC Transfer events used to detect incoming vault deposits
export function watchUSDCTransfers(
  toAddress: `0x${string}`,
  onTransfer: (from: string, value: bigint, txHash: string) => void,
) {
  return arcClient.watchEvent({
    address: USDC_ADDRESS,
    event:   parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args:    { to: toAddress },
    onLogs: (logs) => {
      for (const log of logs) {
        const { from, value } = log.args as { from: string; value: bigint }
        onTransfer(from, value, log.transactionHash ?? '')
      }
    },
  })
}

export async function getLatestBlock() {
  return arcClient.getBlockNumber()
}
