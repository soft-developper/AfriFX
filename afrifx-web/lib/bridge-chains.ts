// ============================================================
// Chain definitions for every CCTP route we support.
//
// WHY THIS EXISTS: wagmi was configured with ONLY Arc. A bridge needs the
// user's wallet to sign on the SOURCE chain, which may be Base, Ethereum,
// Arbitrum or Polygon — if those aren't in the wagmi config, switchChain()
// fails and the burn simply can't happen. So they're defined here and added to
// the config.
//
// Adding a chain to wagmi does NOT change any existing behaviour: the app still
// defaults to Arc, and every existing contract call is explicitly pinned to
// arcTestnet.id. This only makes the other chains *available* to switch to.
// ============================================================

import { defineChain } from 'viem'
import {
  base, baseSepolia, mainnet, sepolia,
  arbitrum, arbitrumSepolia, polygon, polygonAmoy,
} from 'viem/chains'
import { arcTestnet } from './arc-chain'
import { CCTP_ENV } from './cctp-chains'

// Re-export the stock viem chains we use, so callers have one import site.
export {
  base, baseSepolia, mainnet, sepolia,
  arbitrum, arbitrumSepolia, polygon, polygonAmoy,
}
export { arcTestnet }

/*
  The chain list handed to wagmi. Arc stays FIRST so it remains the default
  network for the rest of the app.

  Testnet and mainnet sets are separate — mixing them would let a user bridge
  from Base Sepolia to Polygon mainnet, which fails in confusing ways.
*/
export const TESTNET_CHAINS = [
  arcTestnet, baseSepolia, sepolia, arbitrumSepolia, polygonAmoy,
] as const

export const MAINNET_CHAINS = [
  base, mainnet, arbitrum, polygon,
] as const

export function activeChains() {
  return CCTP_ENV === 'mainnet' ? MAINNET_CHAINS : TESTNET_CHAINS
}

/*
  RPC URL per chain id, so wagmi doesn't fall back to viem's DEFAULT PUBLIC RPCs.
  Those defaults are heavily rate-limited and often reject browser requests
  outright (CORS / 429), which surfaces in the UI as "RPC Request failed" with
  NOTHING having failed on-chain — because the request never reached a node.

  Each is overridable by env so you can drop in Alchemy/Infura keys for
  production without a code change.
*/
export function rpcUrlFor(chainId: number): string | undefined {
  const map: Record<number, string | undefined> = {
    [arcTestnet.id]:      process.env.NEXT_PUBLIC_ARC_RPC_URL     ?? arcTestnet.rpcUrls.default.http[0],
    [baseSepolia.id]:     process.env.NEXT_PUBLIC_BASE_RPC_URL    ?? 'https://sepolia.base.org',
    [sepolia.id]:         process.env.NEXT_PUBLIC_ETH_RPC_URL     ?? 'https://ethereum-sepolia-rpc.publicnode.com',
    [arbitrumSepolia.id]: process.env.NEXT_PUBLIC_ARB_RPC_URL     ?? 'https://sepolia-rollup.arbitrum.io/rpc',
    [polygonAmoy.id]:     process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://rpc-amoy.polygon.technology',
    [base.id]:            process.env.NEXT_PUBLIC_BASE_RPC_URL    ?? 'https://mainnet.base.org',
    [mainnet.id]:         process.env.NEXT_PUBLIC_ETH_RPC_URL,
    [arbitrum.id]:        process.env.NEXT_PUBLIC_ARB_RPC_URL     ?? 'https://arb1.arbitrum.io/rpc',
    [polygon.id]:         process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://polygon-rpc.com',
  }
  return map[chainId]
}

// Map our internal chain key -> the numeric EVM chain id for the active env.
export function evmChainId(key: string): number | undefined {
  const testnet: Record<string, number> = {
    arc: arcTestnet.id, base: baseSepolia.id, ethereum: sepolia.id,
    arbitrum: arbitrumSepolia.id, polygon: polygonAmoy.id,
  }
  const main: Record<string, number> = {
    arc: 0, base: base.id, ethereum: mainnet.id,
    arbitrum: arbitrum.id, polygon: polygon.id,
  }
  return (CCTP_ENV === 'mainnet' ? main : testnet)[key]
}
