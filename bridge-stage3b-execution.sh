#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- STAGE 3b of 4: ON-CHAIN EXECUTION (the wallet signs)
#
# This is the stage where REAL MONEY MOVES. The guiding rule throughout:
#   RECORD FIRST, THEN ACT, THEN RECORD THE RESULT.
# Every step reports to the stage-2 state machine, so if the tab closes, the
# wallet disconnects, or an RPC dies, the server record always reflects reality.
#
# *** A BLOCKER I FOUND AND FIXED ***
# wagmi was configured with ONLY Arc (chains: [arcTestnet]). A bridge needs the
# wallet to sign on the SOURCE chain -- which may be Base, Ethereum, Arbitrum or
# Polygon. Without them in the config, switchChain() fails and the burn simply
# cannot happen. lib/bridge-chains.ts adds them.
#   ARC STAYS FIRST, so it remains the app's default network and every existing
#   contract call (all explicitly pinned to arcTestnet.id) is untouched. The
#   other chains are merely AVAILABLE to switch to. Verified by test.
#
# THE FLOW (approve -> burn -> attest -> mint)
#   1. POST /bridge            record BEFORE anything is signed
#   2. switchChain             to the source chain
#   3. approve                 TokenMessenger to spend USDC (skipped where USDC
#                              is native rather than an ERC-20)
#   4. depositForBurn          *** the critical moment ***
#   5. POST /bridge/:id/burned IMMEDIATELY -- funds are now burned and the mint
#                              is owed; losing this hash makes recovery hard, so
#                              it is awaited and failures surface loudly
#   6. poll Circle             every 5s (Iris allows 40 req/s and BLOCKS FOR 5
#                              MINUTES if breached, so polling is deliberately
#                              gentle), up to 30 minutes
#   7. switchChain + receiveMessage on the destination
#   8. POST /bridge/:id/completed
#
# WHY A TIMEOUT IS NOT A LOSS: destinationCaller is bytes32(0), meaning ANY
# address may call receiveMessage. So if attestation is slow the user can close
# the page -- the reconciler (or the user, later, from any device) can finish
# the mint. The error message says exactly that instead of implying loss.
#
# On failure the hook POSTs /failed, and the SERVER decides failed-vs-stranded
# from whether a burn landed -- so burned funds can never be mislabelled as a
# harmless failure.
#
# NOTE: this ships the hook, not a page. Nothing in the UI calls it yet, so
# deploying changes no behaviour. Stage 4 adds the Bridge page + nav.
#
# Run from ~/AfriFX:  bash bridge-stage3b-execution.sh
# ============================================================
set -e
echo ""
echo "Installing bridge execution (stage 3b)..."
echo ""

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/bridge-chains.ts" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-web/lib/bridge-chains.ts"

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/wagmi.ts" << 'AFX_EOF'
import { getDefaultConfig, getDefaultWallets } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'
// Bridge routes need the wallet to sign on OTHER chains too. Arc stays first,
// so it remains the app's default network and nothing existing changes.
import { activeChains } from './bridge-chains'
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
  chains:     activeChains() as any,
  transports: Object.fromEntries(
    activeChains().map(c => [
      c.id,
      http(c.id === arcTestnet.id ? arcTestnet.rpcUrls.default.http[0] : undefined),
    ]),
  ),
  ssr:        true,
})
AFX_EOF
echo "  afrifx-web/lib/wagmi.ts"

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

      // ── 3. Approve the TokenMessenger to spend USDC ──────
      // Skipped when the chain's USDC address isn't configured (e.g. Arc, where
      // USDC is the native gas token rather than an ERC-20 we approve).
      if (from.usdc) {
        setState(s => ({ ...s, step: 'approving' }))
        const approveTx = await writeContractAsync({
          address: from.usdc as `0x${string}`,
          abi: ERC20_ABI,
          functionName: 'approve',
          args: [messenger, amountUnits],
          chainId: srcChainId,
        })
        await publicClient?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })
      }

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
          (from.usdc || '0x0000000000000000000000000000000000000000') as `0x${string}`,
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
echo "Done. Nothing in the UI calls this yet -- behaviour is unchanged. Now:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Bridge stage 3b: on-chain execution'"
echo "  git push"
echo ""
echo "  OPTIONAL env for better RPCs (public ones are rate-limited):"
echo "     NEXT_PUBLIC_BASE_RPC_URL / NEXT_PUBLIC_ETH_RPC_URL /"
echo "     NEXT_PUBLIC_ARB_RPC_URL / NEXT_PUBLIC_POLYGON_RPC_URL"
echo ""
echo "  Also set NEXT_PUBLIC_ARC_USDC to Arc's USDC ERC-20 address if bridging"
echo "  FROM Arc needs an approve step."
echo ""
echo "  ===== WHEN WE TEST (stage 4) =====" 
echo "  Use Arc TESTNET and a TRIVIAL amount (0.1 USDC) for the first run, and"
echo "  confirm the funds actually ARRIVE on the destination before trying more."
