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
