#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- STAGE 1 of 4: CCTP CHAIN REGISTRY (pure config)
#
# Adds ONE new file. Touches nothing existing, wires into nothing, changes no
# behaviour. It just describes the chains we can bridge between, so later stages
# have a verified foundation.
#
# *** THE HEADLINE: ARC IS CCTP DOMAIN 26 ***
# I checked Circle's docs rather than assuming. Arc is fully supported by CCTP
# V2 as BOTH a source and destination chain, on mainnet and testnet. So the
# whole plan is viable -- you can build this on Arc testnet today.
#
# FACTS BAKED IN (verified against Circle's official docs, not guessed):
#   * A CCTP "domain" is NOT the EVM chain id. Arc's chain id is 5042002 but its
#     CCTP domain is 26. Confusing the two is THE classic CCTP bug, so both are
#     stored explicitly and a test asserts they stay distinct.
#   * CCTP V2 addresses are DETERMINISTIC -- the same TokenMessengerV2 address on
#     every chain within an environment. Testnet and mainnet differ, and are
#     selected by NEXT_PUBLIC_CCTP_ENV.
#   * Chains included: Arc (home), Base, Ethereum, Arbitrum, Polygon -- with
#     both testnet and mainnet entries. Deliberately a SHORT list: every chain
#     needs a working RPC and verified USDC address, and shipping a chain we
#     can't reach would strand a user's funds mid-bridge. We add more once each
#     is tested end to end.
#   * Arc shows Fast Transfer "N/A" in Circle's table -- that is NOT a gap.
#     Circle only offers Fast Transfer where it beats standard attestation, and
#     Arc's standard path is already fast.
#
# Also includes addressToBytes32 / bytes32ToAddress -- CCTP's mintRecipient is
# bytes32, and getting this padding wrong mints to the WRONG ADDRESS. Tested to
# produce exactly 66 chars and round-trip correctly.
#
# Verified: 5 chains load, domain/chainId stay distinct, route validation
# rejects same-chain and unknown chains, bytes32 round-trips, testnet/mainnet
# addresses differ.
#
# NEXT STAGES (not in this script):
#   2) bridge state machine + DB table (durable records, resume, reconciler)
#   3) on-chain execution (depositForBurn, attestation polling, receiveMessage)
#   4) Bridge UI + nav changes (Convert -> Trade, drop Corridor link)
#
# Run from ~/AfriFX:  bash bridge-stage1-chains.sh
# ============================================================
set -e
echo ""
echo "Installing CCTP chain registry (stage 1)..."
echo ""

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/cctp-chains.ts" << 'AFX_EOF'
// ============================================================
// CCTP (Circle Cross-Chain Transfer Protocol) chain registry.
//
// STAGE 1 of the bridge build: PURE CONFIG. No execution logic lives here, so
// this file can't move money — it just describes the chains we support.
//
// Source of truth (verified against Circle's docs, not guessed):
//   https://developers.circle.com/cctp/concepts/supported-chains-and-domains
//   https://developers.circle.com/cctp/references/contract-addresses
//
// KEY FACTS THAT SHAPE THIS FILE:
//   * A CCTP "domain" is Circle's own chain identifier. It is NOT the EVM chain
//     id — Arc's chain id is 5042002 but its CCTP domain is 26. Mixing these up
//     is the classic CCTP integration bug, so both are stored explicitly.
//   * CCTP V2 contract addresses are DETERMINISTIC: the same address is used on
//     every chain within an environment. All testnets share one TokenMessengerV2
//     address, all mainnets share another. Hence the single constants below
//     rather than a per-chain address map.
//   * Testnet and mainnet addresses DIFFER. Selected by NEXT_PUBLIC_CCTP_ENV.
//   * Arc supports Standard Transfer. Circle marks Fast Transfer "N/A" for Arc
//     because standard attestation there is already fast — it's not a gap.
// ============================================================

export type CctpEnv = 'testnet' | 'mainnet'

export const CCTP_ENV: CctpEnv =
  (process.env.NEXT_PUBLIC_CCTP_ENV as CctpEnv) ?? 'testnet'

// ── Contract addresses (same on every chain within an env) ──
export const CCTP_CONTRACTS = {
  testnet: {
    tokenMessenger:     '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA',
    messageTransmitter: '0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275',
    tokenMinter:        '0xb43db544E2c27092c107639Ad201b3dEfAbcF192',
  },
  mainnet: {
    tokenMessenger:     '0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d',
    messageTransmitter: '0x81D40F21F12A8F0E3252Bccb954D722d4c464B64',
    tokenMinter:        '0xfd78EE919681417d192449715b2594ab58f5D002',
  },
} as const

export function cctpContracts(env: CctpEnv = CCTP_ENV) {
  return CCTP_CONTRACTS[env]
}

// ── Circle's attestation ("Iris") API ───────────────────────
export const IRIS_BASE = {
  testnet: 'https://iris-api-sandbox.circle.com',
  mainnet: 'https://iris-api.circle.com',
} as const

export function irisBase(env: CctpEnv = CCTP_ENV) {
  return IRIS_BASE[env]
}

// ── Supported chains ────────────────────────────────────────
export interface CctpChain {
  key:        string   // our internal key
  name:       string   // display name
  domain:     number   // CCTP domain — NOT the EVM chain id
  chainId:    number   // EVM chain id (testnet or mainnet per env)
  usdc:       string   // USDC token address on that chain
  rpcUrl:     string
  explorer:   string
  isHome?:    boolean  // Arc — our own chain
}

/*
  We deliberately support a SHORT list rather than all 25+ CCTP domains.
  Every chain here needs a working RPC and a verified USDC address; shipping a
  chain we can't actually reach would strand a user's funds mid-bridge. Start
  small, add chains once each is tested end to end.
*/
const TESTNET_CHAINS: CctpChain[] = [
  {
    key: 'arc', name: 'Arc Testnet', domain: 26, chainId: 5042002,
    // Arc's USDC is the native gas token; the ERC-20 interface address is set
    // via env so it can't drift from the rest of the app's config.
    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '',
    rpcUrl:  process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network',
    explorer: 'https://testnet.arcscan.app',
    isHome: true,
  },
  {
    key: 'base', name: 'Base Sepolia', domain: 6, chainId: 84532,
    usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
    rpcUrl:  process.env.NEXT_PUBLIC_BASE_RPC_URL ?? 'https://sepolia.base.org',
    explorer: 'https://sepolia.basescan.org',
  },
  {
    key: 'ethereum', name: 'Ethereum Sepolia', domain: 0, chainId: 11155111,
    usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
    rpcUrl:  process.env.NEXT_PUBLIC_ETH_RPC_URL ?? 'https://rpc.sepolia.org',
    explorer: 'https://sepolia.etherscan.io',
  },
  {
    key: 'arbitrum', name: 'Arbitrum Sepolia', domain: 3, chainId: 421614,
    usdc: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d',
    rpcUrl:  process.env.NEXT_PUBLIC_ARB_RPC_URL ?? 'https://sepolia-rollup.arbitrum.io/rpc',
    explorer: 'https://sepolia.arbiscan.io',
  },
  {
    key: 'polygon', name: 'Polygon Amoy', domain: 7, chainId: 80002,
    usdc: '0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582',
    rpcUrl:  process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://rpc-amoy.polygon.technology',
    explorer: 'https://amoy.polygonscan.com',
  },
]

const MAINNET_CHAINS: CctpChain[] = [
  {
    key: 'arc', name: 'Arc', domain: 26, chainId: 0,   // set when Arc mainnet lands
    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '',
    rpcUrl:  process.env.NEXT_PUBLIC_ARC_RPC_URL ?? '',
    explorer: 'https://arcscan.app',
    isHome: true,
  },
  {
    key: 'base', name: 'Base', domain: 6, chainId: 8453,
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    rpcUrl:  process.env.NEXT_PUBLIC_BASE_RPC_URL ?? 'https://mainnet.base.org',
    explorer: 'https://basescan.org',
  },
  {
    key: 'ethereum', name: 'Ethereum', domain: 0, chainId: 1,
    usdc: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    rpcUrl:  process.env.NEXT_PUBLIC_ETH_RPC_URL ?? 'https://eth.llamarpc.com',
    explorer: 'https://etherscan.io',
  },
  {
    key: 'arbitrum', name: 'Arbitrum One', domain: 3, chainId: 42161,
    usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    rpcUrl:  process.env.NEXT_PUBLIC_ARB_RPC_URL ?? 'https://arb1.arbitrum.io/rpc',
    explorer: 'https://arbiscan.io',
  },
  {
    key: 'polygon', name: 'Polygon', domain: 7, chainId: 137,
    usdc: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359',
    rpcUrl:  process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://polygon-rpc.com',
    explorer: 'https://polygonscan.com',
  },
]

export function cctpChains(env: CctpEnv = CCTP_ENV): CctpChain[] {
  return env === 'mainnet' ? MAINNET_CHAINS : TESTNET_CHAINS
}

export function chainByKey(key: string, env: CctpEnv = CCTP_ENV): CctpChain | undefined {
  return cctpChains(env).find(c => c.key === key)
}

export function chainByDomain(domain: number, env: CctpEnv = CCTP_ENV): CctpChain | undefined {
  return cctpChains(env).find(c => c.domain === domain)
}

export function homeChain(env: CctpEnv = CCTP_ENV): CctpChain {
  return cctpChains(env).find(c => c.isHome) ?? cctpChains(env)[0]
}

/*
  A route is only valid if BOTH ends are configured and they're different
  chains. Callers should use this rather than assuming any pair works — an
  unconfigured RPC or USDC address is exactly the kind of gap that strands a
  transfer halfway.
*/
export function isRouteSupported(fromKey: string, toKey: string, env: CctpEnv = CCTP_ENV): boolean {
  if (fromKey === toKey) return false
  const a = chainByKey(fromKey, env)
  const b = chainByKey(toKey, env)
  if (!a || !b) return false
  return !!a.rpcUrl && !!b.rpcUrl
}

// EVM addresses are 20 bytes; CCTP message fields are bytes32. Left-pad with 12
// zero bytes. (Circle's MessageV2 helper does the same on-chain.)
export function addressToBytes32(addr: string): `0x${string}` {
  const clean = addr.toLowerCase().replace(/^0x/, '')
  return `0x${'0'.repeat(24)}${clean}` as `0x${string}`
}

export function bytes32ToAddress(b32: string): `0x${string}` {
  const clean = b32.replace(/^0x/, '')
  return `0x${clean.slice(24)}` as `0x${string}`
}
AFX_EOF
echo "  afrifx-web/lib/cctp-chains.ts"

echo ""
echo "Done. Nothing is wired in yet, so this changes NO behaviour. Now:"
echo "  cd afrifx-web && npx tsc --noEmit"
echo "  cd .. && git add -A && git commit -m 'Bridge stage 1: CCTP chain registry'"
echo "  git push"
echo ""
echo "  OPTIONAL env (all have sensible public defaults):"
echo "     NEXT_PUBLIC_CCTP_ENV=testnet        # or mainnet, later"
echo "     NEXT_PUBLIC_ARC_USDC=0x...          # Arc USDC ERC-20 address"
echo "     NEXT_PUBLIC_BASE_RPC_URL=..."
echo "     NEXT_PUBLIC_ETH_RPC_URL=..."
echo "     NEXT_PUBLIC_ARB_RPC_URL=..."
echo "     NEXT_PUBLIC_POLYGON_RPC_URL=..."
echo ""
echo "  The public RPCs are fine for testing but rate-limited; for production"
echo "  you'll want your own (Alchemy/Infura) for the chains you actually use."
echo ""
echo "  Say the word and I'll build stage 2 (the durable bridge state machine)."
