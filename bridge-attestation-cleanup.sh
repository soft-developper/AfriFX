#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- remove the duplicate panel + WHY ETH->ARC IS SLOW
#
# *** IMPORTANT: AN EARLIER SCRIPT NEVER GOT DEPLOYED ***
# While making this change I found that bridge-attestation-ux-fix.sh is NOT in
# the repo. So you've been running the ORIGINAL attestation code the whole time:
#     * 30-MINUTE timeout instead of 5
#     * NO elapsed timer
#     * an UNGUARDED poll loop -- one transient network error escaped it
#       entirely and left the spinner running forever with no explanation
#     * NO "Recent bridges" list, so a bridge that outlived the page vanished
# Those fixes are FOLDED INTO THIS SCRIPT so everything lands together.
#
# WHY "Wait for Circle to attest" TAKES SO LONG FROM ETHEREUM SEPOLIA
# It is not a bug, and not our code. Circle will not attest a burn until the
# source chain considers it FINAL, and their published figure for Ethereum is
# ~13-19 MINUTES. Arc, by contrast, finalises in about half a second. So:
#     Arc      -> anywhere : attestation is near-instant
#     Ethereum -> anywhere : 13-19 minutes, every time
#     Base     -> anywhere : 13-19 minutes, every time
# The old 30-minute spinner made this look broken. Now we wait 5 minutes
# actively, then hand off to the reconciler and TELL the user, with the transfer
# visible in "Recent bridges" until it completes.
#
# WHAT CHANGED IN THE UI
#   * REMOVED the duplicate progress panel ("Waiting for Circle to attest…",
#     "You can safely close this page…"). It repeated what the step flow already
#     shows.
#   * KEPT the two useful parts and folded them INTO the step flow: a live mm:ss
#     clock on the attestation row (a silent spinner with no clock feels broken),
#     and after 45s a "Stop waiting — this completes on its own" link.
#   * ADDED "Recent bridges" under the card. For an Ethereum-source bridge this
#     is the NORMAL case, not an edge case: nobody watches a spinner for 15
#     minutes, so the transfer must remain visible after they navigate away.
#
# Run from ~/AfriFX:  bash bridge-attestation-cleanup.sh
# ============================================================
set -e
echo ""
echo "Cleaning up the bridge attestation UX..."
echo ""

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
import { useAccount, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
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
  /** Seconds spent waiting for Circle, so the UI isn't a black box. */
  waitedSec: number
}

const INITIAL: BridgeState = {
  step: 'idle', bridgeId: null, burnTx: null, mintTx: null,
  error: null, inFlight: false, waitedSec: 0,
}

// Iris allows 40 req/s and blocks for 5 minutes if breached, so poll gently.
const POLL_MS       = 5_000
/*
  Five minutes of ACTIVE waiting, not thirty. Ethereum Sepolia needs ~13-19 min
  to finalise before Circle will even attest, so a spinner that waits the whole
  time makes a working transfer look broken. We wait a sensible while, then hand
  off to the reconciler — which was always the design.
*/
const POLL_MAX_MIN  = 5

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
  /*
    We deliberately do NOT use usePublicClient() here. It returns a client for
    whatever chain wagmi currently considers active — but this hook SWITCHES
    CHAINS mid-flow, so that client can end up pointed at the wrong chain when
    we wait for a receipt, which surfaces as "RPC Request failed" without any
    on-chain failure. Instead we fetch a client pinned to the exact chain for
    each wait.
  */
  const config = useConfig()
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
      await getPublicClient(config, { chainId: srcChainId })
        ?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })

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

      const receipt = await getPublicClient(config, { chainId: srcChainId })
        ?.waitForTransactionReceipt({ hash: burnTx as `0x${string}` })
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
      const startedAt = Date.now()
      const deadline  = startedAt + POLL_MAX_MIN * 60_000

      /*
        Poll DEFENSIVELY. Previously fetchAttestation() was called unguarded
        inside this loop, so one transient network error escaped it entirely and
        the spinner ran forever with no explanation. Each attempt is wrapped, and
        elapsed time is published so the UI can show a clock.
      */
      let att: Awaited<ReturnType<typeof fetchAttestation>> = { status: 'pending' }
      while (Date.now() < deadline) {
        try {
          att = await fetchAttestation(irisBase(), from.domain, burnTx as string)
          if (att.status === 'complete') break
        } catch {
          // swallow and retry — the burn is safe either way
        }
        setState(s => ({ ...s, waitedSec: Math.floor((Date.now() - startedAt) / 1000) }))
        await new Promise(r => setTimeout(r, POLL_MS))
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        // NOT a loss: the burn is recorded and the reconciler will finish it.
        throw new Error(
          'Circle is still attesting this transfer. Your USDC is burned and ' +
          'safely recorded — the mint completes automatically, and you can close ' +
          'this page. Check "Recent bridges" below for the final status.')
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
      await getPublicClient(config, { chainId: dstChainId })
        ?.waitForTransactionReceipt({ hash: mintTx as `0x${string}` })

      await api(`/bridge/${bridgeId}/completed`, { mintTx })
      setState(s => ({ ...s, step: 'done', mintTx: mintTx as string, inFlight: false }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Bridge failed'

      /*
        "RPC Request failed" is unhelpful and alarming — it means the request
        never reached a node (rate-limited public endpoint, CORS, or the wallet
        being on a chain we have no transport for). Say that, since the user's
        next step is completely different from a real on-chain failure.
      */
      if (/rpc request failed|fetch failed|failed to fetch|network request/i.test(message)) {
        message =
          'Could not reach the network. This is usually a busy public RPC ' +
          'endpoint rather than a problem with your transfer — nothing was ' +
          'submitted to the chain. Please try again in a moment.'
      }

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
  }, [address, writeContractAsync, switchChainAsync, config])

  return { ...state, bridge, reset, env: CCTP_ENV }
}
AFX_EOF
echo "  afrifx-web/hooks/useBridge.ts"

mkdir -p "afrifx-web/components/bridge"
cat > "afrifx-web/components/bridge/BridgeHistory.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { CheckCircle, Clock, AlertTriangle, ExternalLink, RefreshCw } from 'lucide-react'
import { chainByKey } from '@/lib/cctp-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface BridgeRow {
  id: string
  from_chain: string
  to_chain:   string
  amount:     number
  status:     string
  burn_tx?:   string | null
  mint_tx?:   string | null
  created_at: number
}

/*
  Without this list, a bridge that outlives the page is INVISIBLE — the user has
  burned funds and no way to see what became of them. On an Ethereum-source
  bridge that's the normal case, not an edge case: finality alone takes 13-19
  minutes, far longer than anyone will sit and watch a spinner.
*/
export function BridgeHistory() {
  const { address } = useAccount()
  const [rows, setRows]       = useState<BridgeRow[]>([])
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    if (!address) { setRows([]); return }
    setLoading(true)
    try {
      const res  = await fetch(`${API}/bridge?wallet=${address}`)
      const data = await res.json()
      setRows(Array.isArray(data) ? data : [])
    } catch { /* keep the previous list rather than blanking it */ }
    finally { setLoading(false) }
  }, [address])

  useEffect(() => { load() }, [load])

  // Poll while anything is still moving, so a completed mint appears without a
  // manual refresh.
  useEffect(() => {
    const pending = rows.some(r =>
      ['attesting', 'minting', 'stranded', 'burning'].includes(r.status))
    if (!pending) return
    const t = setInterval(load, 15_000)
    return () => clearInterval(t)
  }, [rows, load])

  if (!address || (!rows.length && !loading)) return null

  const chip = (status: string) => {
    switch (status) {
      case 'completed': return { icon: CheckCircle,   cls: 'text-emerald-400', label: 'Complete' }
      case 'failed':    return { icon: AlertTriangle, cls: 'text-red-400',     label: 'Not started' }
      default:          return { icon: Clock,         cls: 'text-amber-400',   label: 'In progress' }
    }
  }

  return (
    <div className="mt-6 w-full max-w-md">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-app-muted">
          Recent bridges
        </h3>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      <div className="space-y-2">
        {rows.slice(0, 8).map(r => {
          const c = chip(r.status)
          const Icon = c.icon
          const fromC = chainByKey(r.from_chain)
          const toC   = chainByKey(r.to_chain)
          return (
            <div key={r.id} className="rounded-lg border border-app-border bg-app-surface p-3">
              <div className="flex items-center justify-between">
                <span className="text-xs text-app-text">
                  {r.amount} USDC
                  <span className="text-app-muted">
                    {' '}· {fromC?.name ?? r.from_chain} → {toC?.name ?? r.to_chain}
                  </span>
                </span>
                <span className={`flex items-center gap-1 text-[11px] ${c.cls}`}>
                  <Icon className="h-3 w-3" /> {c.label}
                </span>
              </div>

              <div className="mt-1 flex flex-wrap gap-3 text-[10px]">
                <span className="text-app-muted">
                  {new Date(r.created_at * 1000).toLocaleString()}
                </span>
                {r.burn_tx && fromC && (
                  <a href={`${fromC.explorer}/tx/${r.burn_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    burn <ExternalLink className="h-2 w-2" />
                  </a>
                )}
                {r.mint_tx && toC && (
                  <a href={`${toC.explorer}/tx/${r.mint_tx}`} target="_blank" rel="noopener noreferrer"
                    className="inline-flex items-center gap-0.5 text-app-accent-text hover:underline">
                    mint <ExternalLink className="h-2 w-2" />
                  </a>
                )}
              </div>

              {r.status !== 'completed' && r.status !== 'failed' && r.burn_tx && (
                <p className="mt-1.5 text-[10px] leading-relaxed text-amber-200/70">
                  Funds are burned and recorded. The mint completes automatically —
                  nothing is lost.
                </p>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/bridge/BridgeHistory.tsx"

mkdir -p "afrifx-web/components/bridge"
cat > "afrifx-web/components/bridge/BridgeCard.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import {
  ArrowDown, Loader2, CheckCircle, AlertTriangle, ExternalLink, Info,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useBridge } from '@/hooks/useBridge'
import { cctpChains, chainByKey, isRouteSupported } from '@/lib/cctp-chains'
import { useChainUsdcBalance } from '@/hooks/useChainUsdcBalance'

/*
  Bridge UI for CCTP transfers.

  The single most important job of this component is being HONEST about where
  the money is. Once the burn lands, funds are mid-flight and the mint is owed —
  so the copy at that point must never look like a plain error, or a user will
  think their money is gone when it isn't.
*/

/*
  The bridge is a multi-minute, multi-signature process. Rather than a paragraph
  explaining CCTP, the card shows WHERE THE USER IS — each stage marked done,
  active, or pending.

  Stage order mirrors the hook's own steps so the two can't drift.
*/
const FLOW: { key: string; label: (from: string, to: string, amt: string) => string }[] = [
  { key: 'approving', label: (f)         => `Approve USDC on ${f}` },
  { key: 'burning',   label: (f, _t, a)  => `Burn ${a} USDC on ${f}` },
  { key: 'attesting', label: ()          => 'Wait for Circle to attest' },
  { key: 'minting',   label: (_f, t)     => `Mint on ${t}` },
]

const ORDER = ['creating', 'switching', 'approving', 'burning', 'attesting', 'minting', 'done']

function stageState(stage: string, current: string): 'done' | 'active' | 'pending' {
  if (current === 'done') return 'done'
  const ci = ORDER.indexOf(current)
  const si = ORDER.indexOf(stage)
  if (ci < 0 || si < 0) return 'pending'
  if (si < ci)  return 'done'
  if (si === ci) return 'active'
  return 'pending'
}

export function BridgeCard() {
  const { address, isConnected } = useAccount()
  const { step, bridgeId, burnTx, mintTx, error, inFlight, waitedSec, bridge, reset, env } = useBridge()

  const chains = cctpChains()
  const [fromKey, setFromKey] = useState('arc')
  const [toKey,   setToKey]   = useState('base')
  const [amount,  setAmount]  = useState('')

  // Balance on the SOURCE chain, so Max and the insufficient check are correct
  // for whichever direction the user picks.
  const { balance, loading: balLoading, refresh: refreshBalance } =
    useChainUsdcBalance(fromKey)

  /*
    Clear the amount once a bridge completes, and re-read the balance.
    Leaving the amount populated with the button live is how someone
    accidentally bridges twice.
  */
  useEffect(() => {
    if (step === 'done') { setAmount(''); refreshBalance() }
  }, [step, refreshBalance])

  const from = chainByKey(fromKey)
  const to   = chainByKey(toKey)
  const routeOk = isRouteSupported(fromKey, toKey)
  const amt = Number(amount)
  const busy = ['creating','switching','approving','burning','attesting','minting'].includes(step)
  const insufficient = amt > 0 && amt > balance

  const canSubmit = isConnected && routeOk && amt > 0 && !busy && !insufficient

  function swapDirection() {
    setFromKey(toKey); setToKey(fromKey)
  }

  const stepLabel: Record<string, string> = {
    creating:  'Preparing transfer…',
    switching: `Switch your wallet to ${from?.name ?? 'the source chain'}`,
    approving: 'Approve USDC spending in your wallet',
    burning:   'Confirm the transfer in your wallet',
    attesting: 'Waiting for Circle to attest (usually under a minute)',
    minting:   `Switch to ${to?.name ?? 'the destination'} and confirm the final step`,
  }

  const explorerTx = (chainKey: string, hash: string) => {
    const c = chainByKey(chainKey)
    return c ? `${c.explorer}/tx/${hash}` : '#'
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-base font-semibold text-app-text">Bridge USDC</h2>
        <span className="rounded-full bg-app-bg px-2 py-0.5 text-[10px] uppercase tracking-wide text-app-muted">
          {env}
        </span>
      </div>

      {/* From */}
      <label className="mb-1 block text-xs text-app-muted">From</label>
      <select
        value={fromKey}
        onChange={e => setFromKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      <div className="my-1 flex justify-center">
        <button
          onClick={swapDirection}
          disabled={busy}
          title="Swap direction"
          className="flex h-8 w-8 items-center justify-center rounded-full border border-app-border bg-app-bg text-app-muted hover:text-app-text disabled:opacity-40"
        >
          <ArrowDown className="h-4 w-4" />
        </button>
      </div>

      {/* To */}
      <label className="mb-1 block text-xs text-app-muted">To</label>
      <select
        value={toKey}
        onChange={e => setToKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      {/* Amount */}
      <div className="mb-1 flex items-center justify-between">
        <label className="text-xs text-app-muted">Amount (USDC)</label>
        <span className="flex items-center gap-2 text-[11px]">
          <span className="text-app-muted">
            Balance:{' '}
            <span className="font-mono text-app-text">
              {balLoading ? '…' : balance.toFixed(2)}
            </span>
          </span>
          <button
            onClick={() => setAmount(String(balance))}
            disabled={busy || balance <= 0}
            className="text-app-accent-text hover:underline disabled:opacity-40"
          >
            Max
          </button>
        </span>
      </div>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-4 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      {!routeOk && fromKey === toKey && (
        <p className="mb-3 text-xs text-amber-400">Source and destination must be different chains.</p>
      )}

      {insufficient && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
          You only have {balance.toFixed(2)} USDC on {from?.name}
        </p>
      )}

      {/* Action */}
      {step === 'done' ? (
        <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">Bridge complete</p>
          <p className="mt-1 text-xs text-emerald-600">
            {amount} USDC arrived on {to?.name}
          </p>
          <div className="mt-3 flex flex-col gap-1 text-[11px]">
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
            {mintTx && (
              <a href={explorerTx(toKey, mintTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Mint transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
          <Button size="sm" variant="outline" className="mt-3" onClick={reset}>
            Bridge again
          </Button>
        </div>
      ) : (
        <Button
          className="w-full"
          disabled={!canSubmit}
          onClick={() => bridge({ fromKey, toKey, amount: amt })}
        >
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
                : !isConnected ? 'Connect a wallet'
                : insufficient ? 'Insufficient balance'
                : 'Bridge USDC'}
        </Button>
      )}

      {/* Progress */}
      {/* Errors — tone depends ENTIRELY on whether funds already moved */}
      {step === 'error' && error && (
        inFlight ? (
          // Burned but not minted. NOT a loss. Never show this as a plain error.
          <div className="mt-3 rounded-lg border border-amber-700/50 bg-amber-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-amber-400">
              <Info className="h-3.5 w-3.5" /> Transfer in progress
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-amber-200/90">
              {error}
            </p>
            <p className="mt-1.5 text-[11px] text-amber-200/70">
              Your funds are burned on {from?.name} and the mint on {to?.name} is
              still owed. It will be completed automatically — nothing is lost.
            </p>
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-[11px] text-amber-400 hover:underline">
                View burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        ) : (
          // Failed before the burn: nothing moved, safe to retry.
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertTriangle className="h-3.5 w-3.5" /> Transfer not started
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-red-300/90">{error}</p>
            <p className="mt-1.5 text-[11px] text-red-300/60">
              No funds were moved. You can safely try again.
            </p>
            <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
          </div>
        )
      )}

      {/* Live flow. Replaces the old marketing blurb: what the user needs is
          to know WHERE THEY ARE in a multi-minute, multi-signature process, not
          a paragraph about CCTP. Each stage shows done / active / pending. */}
      <div className="mt-4 border-t border-app-border pt-3">
        <p className="mb-2 text-[10px] font-semibold uppercase tracking-wide text-app-muted">
          Transfer steps
        </p>
        <div className="space-y-1.5">
          {FLOW.map(f => {
            const state = stageState(f.key, step)
            return (
              <div key={f.key} className="flex items-center gap-2">
                <span className="flex h-4 w-4 shrink-0 items-center justify-center">
                  {state === 'done'
                    ? <CheckCircle className="h-3.5 w-3.5 text-emerald-400" />
                    : state === 'active'
                    ? <Loader2 className="h-3.5 w-3.5 animate-spin text-app-accent-text" />
                    : <span className="h-1.5 w-1.5 rounded-full bg-app-border" />}
                </span>
                <span className={`text-[11px] ${
                  state === 'done'   ? 'text-app-muted line-through decoration-app-border'
                  : state === 'active' ? 'text-app-text'
                  : 'text-app-muted/60'}`}>
                  {f.label(from?.name ?? 'source', to?.name ?? 'destination', amount || '0')}
                </span>
                {/* Elapsed time on the attestation step — it's the long one, and
                    a silent spinner with no clock makes it feel broken. */}
                {f.key === 'attesting' && state === 'active' && waitedSec > 0 && (
                  <span className="ml-auto font-mono text-[10px] text-app-muted">
                    {Math.floor(waitedSec / 60)}:{String(waitedSec % 60).padStart(2, '0')}
                  </span>
                )}
              </div>
            )
          })}
        </div>

        {/* Once the burn lands the funds are safe and the mint is owed, so the
            user should never feel trapped by a spinner. */}
        {inFlight && waitedSec > 45 && (
          <button
            onClick={reset}
            className="mt-2 text-[11px] text-app-muted underline underline-offset-2 hover:text-app-text"
          >
            Stop waiting — this completes on its own
          </button>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/bridge/BridgeCard.tsx"

mkdir -p "afrifx-web/app/(app)/bridge"
cat > "afrifx-web/app/(app)/bridge/page.tsx" << 'AFX_EOF'
import { BridgeCard } from '@/components/bridge/BridgeCard'
import { BridgeHistory } from '@/components/bridge/BridgeHistory'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Bridge, AfriFX' }

function BridgeSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 h-5 w-32 animate-pulse rounded bg-app-border" />
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="mb-4 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="h-11 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

/*
  No SectionGuard here on purpose: the maintenance sections are a fixed list
  ('convert' | 'corridor' | 'send' | ...) and 'bridge' isn't one of them.
  Adding a new section would mean a backend change; that can come later if you
  want to be able to take the bridge down independently.
*/
export default function BridgePage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
        <p className="text-sm text-app-muted">
          Move native USDC between Arc and other chains using Circle&apos;s CCTP.
        </p>
      </div>
      <ClientOnly fallback={<BridgeSkeleton />}>
        <BridgeCard />
        {/* A bridge that outlives the page must never become invisible. */}
        <BridgeHistory />
      </ClientOnly>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/bridge/page.tsx"

echo ""
echo "Done. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Bridge: fold progress into step flow, add history'"
echo "  git push"
echo ""
echo "  ===== VERIFY THE FIX ACTUALLY LANDED THIS TIME ====="
echo "  After deploying, run:"
echo "     grep -c waitedSec afrifx-web/hooks/useBridge.ts"
echo "  It should print 3 or more. If it prints 0, the script didn't apply --"
echo "  check you ran it from ~/AfriFX (pwd should end in /AfriFX)."
echo ""
echo "  PRACTICAL ADVICE: for testing, bridge FROM ARC. It finalises in ~0.5s so"
echo "  you see the whole flow in seconds. Ethereum and Base sources will ALWAYS"
echo "  take 13-19 minutes at the attestation step -- that's Circle's finality"
echo "  requirement, not something we can speed up."
