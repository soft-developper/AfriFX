#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- FIX: bridging FROM Arc failed (you were right)
#
# THE CAUSE
# NEXT_PUBLIC_ARC_USDC was unset, and the code handled that badly in TWO ways
# that compounded:
#   1. the approve step was SKIPPED  (`if (from.usdc)`)
#   2. burnToken was passed as the ZERO ADDRESS as a "fallback"
# depositForBurn with burnToken = 0x000...0 reverts -- CCTP has no token
# registered at that address. So every Arc-source bridge failed at the burn.
#
# GOOD NEWS: it failed AT the burn, not after, so no funds were ever burned or
# stranded. The stage-2 classifier would have recorded these as 'failed'
# (harmless), not 'stranded'.
#
# THE FIX -- Arc's USDC ERC-20 interface address is now HARDCODED:
#     0x3600000000000000000000000000000000000000
# Taken from Arc's own contract-address docs: "Optional ERC-20 interface for
# interacting with the native USDC balance. Uses 6 decimals." Arc uses USDC as
# its NATIVE GAS token, but CCTP's depositForBurn needs an ERC-20 burnToken --
# this system contract is exactly that interface over the same balance.
#
# It's hardcoded rather than env-only ON PURPOSE. A silent misconfiguration that
# breaks every Arc-source bridge isn't worth the flexibility. (You can still
# override with NEXT_PUBLIC_ARC_USDC if it ever changes.)
#
# ALSO FIXED -- THE DEEPER BUG:
# The zero-address fallback is GONE, and there's now an explicit guard. If a
# chain has no USDC address, the bridge fails EARLY with a clear message instead
# of letting the user approve and sign, then hitting an opaque on-chain revert.
# Silently substituting a zero address for missing config was the real mistake.
#
# WHILE I WAS THERE -- two things worth knowing:
#   * Arc's CCTP domain is 26. A blog post I found claims "Arc uses domain 7" --
#     that is WRONG (7 is Polygon). Arc's own docs confirm 26, which is what we
#     already had.
#   * DECIMALS TRAP: Arc's native gas token uses 18 decimals, but the USDC
#     ERC-20 interface uses 6. CCTP amounts use the ERC-20 (6), which is what
#     our toUnits() already does. Arc's docs explicitly warn against mixing them.
#
# Verified: all five chains now have real (non-zero) USDC addresses, typechecks
# clean, builds clean.
#
# Run from ~/AfriFX:  bash bridge-arc-usdc-fix.sh
# ============================================================
set -e
echo ""
echo "Fixing Arc USDC configuration..."
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
    /*
      Arc's USDC ERC-20 INTERFACE address (from Arc's official contract-address
      docs). Arc uses USDC as its native gas token, but CCTP's depositForBurn
      needs an ERC-20 `burnToken` — this system contract is that interface, and
      it exposes approve/allowance/transferFrom over the same native balance.

      It is HARDCODED rather than env-only on purpose: when it was missing, the
      approve step was skipped AND burnToken was passed as the zero address,
      which makes depositForBurn revert. A silent misconfiguration that breaks
      every Arc-source bridge is not worth the flexibility.

      NOTE ON DECIMALS: the native gas token uses 18 decimals, but this ERC-20
      interface uses 6 — which is what CCTP amounts must use. Arc's docs
      explicitly warn against mixing the two.
    */
    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '0x3600000000000000000000000000000000000000',
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

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useBridge.ts" << 'AFX_EOF'
'use client'
// ============================================================
// useBridge — the CCTP flow, driven by the USER'S OWN WALLET.
//
// STAGE 3b. This is where real money moves, so the discipline is:
//   RECORD FIRST, THEN ACT, THEN RECORD THE RESULT.
//
// Every step is reported to the stage-2 state machine, so if the tab closes,
// the wallet disconnects, or the RPC dies, the record on the server always
// reflects reality and the transfer can be resumed or reconciled.
//
// THE ONE MOMENT THAT MATTERS: the instant the burn confirms, we POST the burn
// tx hash to /bridge/:id/burned BEFORE doing anything else. After that point
// the funds are burned and the mint is owed — if we lost the tx hash there,
// recovery would be far harder. Everything else is best-effort; that write is
// not.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useWriteContract, usePublicClient, useSwitchChain } from 'wagmi'
import {
  cctpContracts, irisBase, chainByKey, addressToBytes32, CCTP_ENV,
} from '@/lib/cctp-chains'
import {
  TOKEN_MESSENGER_V2_ABI, MESSAGE_TRANSMITTER_V2_ABI, ERC20_ABI,
  getBurnFee, fetchAttestation, toUnits, FINALITY,
} from '@/lib/cctp-client'
import { evmChainId } from '@/lib/bridge-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type BridgeStep =
  | 'idle' | 'creating' | 'switching' | 'approving' | 'burning'
  | 'attesting' | 'minting' | 'done' | 'error'

export interface BridgeState {
  step:     BridgeStep
  bridgeId: string | null
  burnTx:   string | null
  mintTx:   string | null
  error:    string | null
  /** Burned but not yet minted — funds are in flight and the mint is owed. */
  inFlight: boolean
}

const INITIAL: BridgeState = {
  step: 'idle', bridgeId: null, burnTx: null, mintTx: null,
  error: null, inFlight: false,
}

// Iris allows 40 req/s and blocks for 5 minutes if breached, so poll gently.
const POLL_MS       = 5_000
const POLL_MAX_MIN  = 30

async function api(path: string, body?: unknown) {
  const res = await fetch(`${API}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const d = await res.json().catch(() => ({}))
    throw new Error(d.error ?? `API ${res.status}`)
  }
  return res.json()
}

export function useBridge() {
  const { address } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const publicClient = usePublicClient()
  const [state, setState] = useState<BridgeState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const bridge = useCallback(async (params: {
    fromKey: string
    toKey:   string
    amount:  number
    recipient?: string
  }) => {
    if (!address) { setState(s => ({ ...s, step: 'error', error: 'Connect a wallet first' })); return }

    const from = chainByKey(params.fromKey)
    const to   = chainByKey(params.toKey)
    if (!from || !to) { setState(s => ({ ...s, step: 'error', error: 'Unsupported route' })); return }

    const recipient = params.recipient ?? address
    const amountUnits = toUnits(params.amount)
    let bridgeId: string | null = null
    let burnedYet = false

    try {
      // ── 1. Record BEFORE anything is signed ──────────────
      setState({ ...INITIAL, step: 'creating' })
      const created = await api('/bridge', {
        walletAddress: address,
        fromChain: from.key, toChain: to.key,
        fromDomain: from.domain, toDomain: to.domain,
        amount: params.amount, recipient,
      })
      bridgeId = created.id
      setState(s => ({ ...s, bridgeId }))

      // ── 2. Make sure the wallet is on the SOURCE chain ───
      const srcChainId = evmChainId(from.key)
      if (!srcChainId) throw new Error(`No EVM chain id configured for ${from.name}`)
      setState(s => ({ ...s, step: 'switching' }))
      await switchChainAsync({ chainId: srcChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${from.name} and try again`)
      })

      const contracts = cctpContracts()
      const messenger = contracts.tokenMessenger as `0x${string}`

      /*
        CCTP burns an ERC-20, so burnToken MUST be a real token address. If it's
        missing we fail HERE with a clear message rather than passing the zero
        address to depositForBurn, which reverts with an opaque error after the
        user has already approved and signed. This was the actual cause of
        Arc-source bridges failing.
      */
      if (!from.usdc || /^0x0+$/.test(from.usdc)) {
        throw new Error(
          `No USDC token address configured for ${from.name}. ` +
          `Bridging from this chain can't proceed until it's set.`)
      }

      // ── 3. Approve the TokenMessenger to spend USDC ──────
      setState(s => ({ ...s, step: 'approving' }))
      const approveTx = await writeContractAsync({
        address: from.usdc as `0x${string}`,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [messenger, amountUnits],
        chainId: srcChainId,
      })
      await publicClient?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })

      // ── 4. BURN on the source chain ──────────────────────
      setState(s => ({ ...s, step: 'burning' }))
      await api(`/bridge/${bridgeId}/burning`, {})

      const fee = await getBurnFee(irisBase(), from.domain, to.domain, amountUnits)

      const burnTx = await writeContractAsync({
        address: messenger,
        abi: TOKEN_MESSENGER_V2_ABI,
        functionName: 'depositForBurn',
        args: [
          amountUnits,
          to.domain,
          addressToBytes32(recipient),
          // Guarded above, so this is always a real token address.
          from.usdc as `0x${string}`,
          // bytes32(0) = ANY address may call receiveMessage on the destination.
          // That's what allows our reconciler (or the user from another device)
          // to finish a stranded mint.
          `0x${'0'.repeat(64)}` as `0x${string}`,
          fee.maxFeeUnits,
          FINALITY.FINALIZED,
        ],
        chainId: srcChainId,
      })

      const receipt = await publicClient?.waitForTransactionReceipt({
        hash: burnTx as `0x${string}`,
      })
      if (receipt && receipt.status !== 'success') throw new Error('Burn transaction failed')

      /*
        *** THE CRITICAL WRITE ***
        Funds are now burned. Persist the tx hash immediately — everything
        downstream depends on it, and without it recovery is much harder.
        We deliberately await this and let a failure surface loudly.
      */
      burnedYet = true
      setState(s => ({ ...s, burnTx: burnTx as string, inFlight: true }))
      await api(`/bridge/${bridgeId}/burned`, {
        burnTx,
        // Circle looks the message up by tx hash, so we store the hash in both
        // fields rather than computing a message hash client-side.
        messageBytes: burnTx,
        messageHash:  burnTx,
      })

      // ── 5. Wait for Circle's attestation ─────────────────
      setState(s => ({ ...s, step: 'attesting' }))
      const deadline = Date.now() + POLL_MAX_MIN * 60_000
      let att = await fetchAttestation(irisBase(), from.domain, burnTx as string)
      while (att.status !== 'complete' && Date.now() < deadline) {
        await new Promise(r => setTimeout(r, POLL_MS))
        att = await fetchAttestation(irisBase(), from.domain, burnTx as string)
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        // NOT a loss: the burn is recorded and the reconciler will finish it.
        throw new Error(
          'Attestation is taking longer than expected. Your funds are safe and ' +
          'the transfer will complete automatically — you can close this page.')
      }
      await api(`/bridge/${bridgeId}/attested`, { attestation: att.attestation })

      // ── 6. MINT on the destination chain ─────────────────
      setState(s => ({ ...s, step: 'minting' }))
      const dstChainId = evmChainId(to.key)
      if (!dstChainId) throw new Error(`No EVM chain id configured for ${to.name}`)
      await switchChainAsync({ chainId: dstChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${to.name} to finish the transfer`)
      })

      const mintTx = await writeContractAsync({
        address: contracts.messageTransmitter as `0x${string}`,
        abi: MESSAGE_TRANSMITTER_V2_ABI,
        functionName: 'receiveMessage',
        args: [att.message as `0x${string}`, att.attestation as `0x${string}`],
        chainId: dstChainId,
      })
      await publicClient?.waitForTransactionReceipt({ hash: mintTx as `0x${string}` })

      await api(`/bridge/${bridgeId}/completed`, { mintTx })
      setState(s => ({ ...s, step: 'done', mintTx: mintTx as string, inFlight: false }))
    } catch (err: any) {
      const message = err?.shortMessage ?? err?.message ?? 'Bridge failed'
      // Tell the server. It classifies failed-vs-stranded by whether a burn
      // landed, so burned funds can never be recorded as a harmless failure.
      if (bridgeId) {
        await api(`/bridge/${bridgeId}/failed`, { error: message }).catch(() => {})
      }
      setState(s => ({
        ...s, step: 'error', error: message,
        inFlight: burnedYet,
      }))
    }
  }, [address, writeContractAsync, switchChainAsync, publicClient])

  return { ...state, bridge, reset, env: CCTP_ENV }
}
AFX_EOF
echo "  afrifx-web/hooks/useBridge.ts"

echo ""
echo "Done. No env var needed now. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Fix: Arc USDC address for CCTP burns'"
echo "  git push"
echo ""
echo "  ===== RETRY THE BRIDGE ====="
echo "  Arc Testnet -> Base Sepolia, 0.1 USDC."
echo "  You should now see an APPROVE prompt first (you didn't before -- that"
echo "  step was being skipped), then the burn."
echo ""
echo "  If it still reverts, the next thing to check is whether the approve"
echo "  actually succeeded on the ERC-20 interface:"
echo "     https://testnet.arcscan.app/address/0x3600000000000000000000000000000000000000"
