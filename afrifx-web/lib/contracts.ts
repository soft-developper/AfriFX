// All Arc Testnet addresses: docs.arc.io/arc/references/contract-addresses
const ZERO = '0x0000000000000000000000000000000000000000' as `0x${string}`

export const CONTRACTS = {
  // Stablecoins
  USDC: '0x3600000000000000000000000000000000000000' as `0x${string}`,
  EURC: '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a' as `0x${string}`,

  // Transaction Memos — docs.arc.io/arc/concepts/transaction-memos
  MEMO: '0x5294E9927c3306DcBaDb03fe70b92e01cCede505' as `0x${string}`,

  // FX + payments
  STABLE_FX_ESCROW: '0x867650F5eAe8df91445971f14d89fd84F0C9a9f8' as `0x${string}`,
  PERMIT2:          '0x000000000022D473030F116dDEE9F6B43aC78BA3' as `0x${string}`,

  // Gateway
  GATEWAY_WALLET: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9' as `0x${string}`,
  GATEWAY_MINTER: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B' as `0x${string}`,

  // CCTP (Arc = domain 26)
  CCTP_TOKEN_MESSENGER: '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA' as `0x${string}`,
  CCTP_MSG_TRANSMITTER: '0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275' as `0x${string}`,

  MULTICALL3: '0xcA11bde05977b3631167028862bE2a173976CA11' as `0x${string}`,

  // AfriFX deployed contracts — from .env.local
  AFRIFX_VAULT:    (process.env.NEXT_PUBLIC_AFRIFX_VAULT    || ZERO) as `0x${string}`,
  AFRIFX_EXCHANGE: (process.env.NEXT_PUBLIC_AFRIFX_EXCHANGE || ZERO) as `0x${string}`,
} as const

export const ARC_CHAIN_ID  = 5042002
export const ARC_RPC_URL   = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
export const ARC_DOMAIN    = 26
export const USDC_DECIMALS = 6
export const SPREAD_BPS    = 50
