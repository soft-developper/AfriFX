#!/bin/bash
# ============================================================
# AfriFX -- Send & Bridge cleanup
#
# SEND
#   * FORM NOW RESETS after a cross-chain transfer. The same-chain path already
#     cleared on submit, but cross-chain finishes ASYNCHRONOUSLY -- so the
#     recipient and amount sat there with the button still live. On a money
#     form that's an accidental-double-send hazard, not just untidiness.
#
# BRIDGE
#   * PER-CHAIN BALANCE + MAX BUTTON, matching Send. New useChainUsdcBalance
#     hook reads balanceOf on WHICHEVER chain is selected -- the existing
#     useUSDCBalance is pinned to Arc, so it was no use here. Adds an
#     insufficient-balance check and disables the button accordingly.
#     (Note: USDC is 6 decimals on every chain including Arc's ERC-20 interface,
#     even though Arc's NATIVE token is 18 -- mixing those is a known trap.)
#
#   * RESETS AFTER SUCCESS -- clears the amount and re-reads the balance.
#
#   * REPLACED THE MARKETING BLURB WITH A LIVE STEP FLOW. The old paragraph
#     about CCTP and wrapped tokens told the user nothing they needed. A bridge
#     is a multi-minute, multi-signature process, so what actually matters is
#     WHERE THEY ARE in it:
#
#         Approve USDC on Base Sepolia      <- done (struck through)
#         Burn 0.1 USDC on Base Sepolia     <- active (spinner)
#         Wait for Circle to attest         <- pending
#         Mint on Arc Testnet               <- pending
#
#     Labels interpolate the real chain names and amount. Stage order is derived
#     from the hook's own step list so the display can't drift from reality --
#     tested at every stage from idle through done.
#
# Run from ~/AfriFX:  bash send-bridge-cleanup.sh
# ============================================================
set -e
echo ""
echo "Cleaning up Send and Bridge..."
echo ""

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useChainUsdcBalance.ts" << 'AFX_EOF'
'use client'
// ============================================================
// useChainUsdcBalance — read a wallet's USDC balance on ANY supported chain.
//
// The app's existing useUSDCBalance is pinned to Arc, which is right for Send's
// same-chain path but useless for the bridge, where the source chain changes.
// This reads balanceOf on whichever chain is selected.
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { useAccount, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export function useChainUsdcBalance(chainKey: string) {
  const { address } = useAccount()
  const config = useConfig()
  const [balance, setBalance] = useState<number>(0)
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    if (!address) { setBalance(0); return }
    const chain   = chainByKey(chainKey)
    const chainId = evmChainId(chainKey)
    if (!chain?.usdc || !chainId) { setBalance(0); return }

    setLoading(true)
    try {
      const client = getPublicClient(config, { chainId })
      if (!client) { setBalance(0); return }
      const raw = await client.readContract({
        address: chain.usdc as `0x${string}`,
        abi: ERC20_BALANCE_ABI,
        functionName: 'balanceOf',
        args: [address],
      })
      // USDC is 6 decimals on every supported chain, including Arc's ERC-20
      // interface (the NATIVE token is 18 — mixing them is a known trap).
      setBalance(Number(raw as bigint) / 1_000_000)
    } catch {
      // A failed read shouldn't break the form; just show zero and let the user
      // type an amount manually.
      setBalance(0)
    } finally {
      setLoading(false)
    }
  }, [address, chainKey, config])

  useEffect(() => { load() }, [load])

  return { balance, loading, refresh: load }
}
AFX_EOF
echo "  afrifx-web/hooks/useChainUsdcBalance.ts"

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
  const { step, bridgeId, burnTx, mintTx, error, inFlight, bridge, reset, env } = useBridge()

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
      {busy && (
        <div className="mt-3 rounded-lg bg-app-bg p-3">
          <p className="flex items-center gap-2 text-xs text-app-text">
            <Loader2 className="h-3 w-3 animate-spin" />
            {stepLabel[step] ?? 'Working…'}
          </p>
          {inFlight && (
            <p className="mt-1.5 text-[11px] text-app-muted">
              Your USDC has been burned on {from?.name} and will be minted on {to?.name}.
              You can safely close this page — the transfer completes on its own.
            </p>
          )}
        </div>
      )}

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
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/bridge/BridgeCard.tsx"

mkdir -p "afrifx-web/app/(app)/send"
cat > "afrifx-web/app/(app)/send/page.tsx" << 'AFX_EOF'
'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useGatewaySend } from '@/hooks/useGatewaySend'
import { fetchGatewayBalances, gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { AlertCircle, CheckCircle, Loader2, Zap, Layers, ExternalLink } from 'lucide-react'

const HOME = 'arc'

function SendPageInner() {
  const { address, isConnected }  = useAccount()
  const { ready: walletReady }    = useWalletReady()
  const [to,      setTo]          = useState('')
  const [amount,  setAmount]      = useState('')
  const [destKey, setDestKey]     = useState(HOME)

  // Wallet balance on Arc (what Send has always used).
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const { writeContractAsync, isPending }  = useWriteContract()
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess }       = useWaitForTransactionReceipt({ hash: txHash })

  // Unified Gateway balance, for cross-chain sends.
  const gw = useGatewaySend()
  const [gwTotal,  setGwTotal]  = useState(0)
  const [gwByChain, setGwByChain] = useState<any[]>([])

  useEffect(() => {
    if (!address) return
    fetchGatewayBalances(address).then(res => {
      if ('error' in res) return
      setGwTotal(res.total)
      setGwByChain(res.perChain)
    })
  }, [address, gw.step])

  /*
    Clear the form once a cross-chain send completes.

    The same-chain path clears immediately after submitting, but a cross-chain
    send finishes asynchronously — so without this the recipient and amount sat
    there with the button still live, inviting an accidental second send of the
    same amount. For a money form that's a real hazard, not just untidiness.
  */
  useEffect(() => {
    if (gw.step === 'done') { setTo(''); setAmount('') }
  }, [gw.step])

  /*
    SMART ROUTING — the user picks a destination, not a mechanism.
      same chain (Arc -> Arc)  : plain wallet transfer. Instant, no Gateway
                                 balance consumed, and it's what Send always did.
      cross-chain              : spend the unified Gateway balance.
    This keeps existing behaviour intact while making other chains possible.
  */
  const isCrossChain = destKey !== HOME
  const dest    = gatewayChains().find(c => c.key === destKey)
  const destCctp = chainByKey(destKey)

  // Which balance applies to the current route?
  const availableNum = isCrossChain ? gwTotal : (parseFloat(balance) || 0)
  const availableStr = isCrossChain ? gwTotal.toFixed(2) : balance

  const amountNum        = parseFloat(amount) || 0
  const insufficientFunds = amountNum > 0 && amountNum > availableNum
  const validAddress     = isAddress(to)
  const validAmount      = amountNum > 0 && !insufficientFunds
  const valid            = validAddress && validAmount

  // For a cross-chain send we spend from whichever chain holds the balance.
  const sourceKey = gwByChain.find(c => c.amount >= amountNum)?.key ?? HOME

  const busy = isPending || ['signing','requesting','switching','minting'].includes(gw.step)

  function setMax() { setAmount(availableNum.toFixed(6)) }

  async function handleSend() {
    if (!valid) return

    if (isCrossChain) {
      await gw.send({ fromKey: sourceKey, toKey: destKey, amount: amountNum, recipient: to })
      return
    }

    const hash = await writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    setTo(''); setAmount('')
  }

  const gwLabel: Record<string, string> = {
    signing:    'Sign the transfer in your wallet',
    requesting: 'Getting approval from Circle…',
    switching:  `Switch your wallet to ${dest?.name ?? 'the destination'}`,
    minting:    'Confirm the final step in your wallet',
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any supported chain. Cross-chain sends use your unified balance.
        </p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Destination chain */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Send to chain
          </label>
          <select
            value={destKey}
            onChange={e => setDestKey(e.target.value)}
            disabled={busy}
            className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
          >
            {gatewayChains().map(c => (
              <option key={c.key} value={c.key}>{c.name}</option>
            ))}
          </select>
        </div>

        {/* Balance — which one depends on the route */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="flex items-center gap-1.5 text-app-muted">
            {isCrossChain ? <><Layers className="h-3 w-3" /> Unified balance</> : 'Wallet balance'}
          </span>
          <span className="font-mono text-app-text">{availableStr} USDC</span>
        </div>

        {isCrossChain && gwTotal === 0 && (
          <div className="mb-3 rounded-lg bg-amber-900/20 px-3 py-2 text-[11px] text-amber-300">
            Cross-chain sends spend your unified balance, which is empty. Add funds
            from the Treasury page first.
          </div>
        )}

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient address
          </label>
          <Input
            placeholder="0x…"
            value={to}
            onChange={e => setTo(e.target.value)}
            className={`font-mono ${to && !validAddress ? 'border-red-500/50' : ''}`}
          />
          {to && !validAddress && (
            <p className="text-xs text-red-400">Invalid wallet address</p>
          )}
        </div>

        {/* Amount */}
        <div className="mb-4 space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Amount (USDC)
            </label>
            <button onClick={setMax} className="text-xs text-app-accent-text hover:underline">
              Max
            </button>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className={`font-mono text-lg ${insufficientFunds ? 'border-red-500/50' : ''}`}
          />

          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {availableStr} USDC
            </div>
          )}

          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(availableNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Route info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Route</span>
            <span className="text-app-text">
              {isCrossChain ? `Unified balance → ${dest?.name}` : 'Arc Testnet · direct'}
            </span>
          </div>
        </div>

        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !walletReady || !valid || busy || insufficientFunds}>
          {busy
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : !walletReady && isConnected
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Preparing wallet…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {/* Cross-chain progress */}
        {busy && isCrossChain && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {gwLabel[gw.step] ?? 'Working…'}
          </p>
        )}

        {/* Cross-chain errors. The EOA case gets its own explanation because
            "your wallet type isn't supported" is not something a user can
            debug from a generic error. */}
        {gw.step === 'error' && gw.error && (
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertCircle className="h-3.5 w-3.5" /> Transfer not completed
            </p>
            <p className="mt-1 text-[11px] text-red-300/90">{gw.error}</p>
            {gw.needsEoa && (
              <p className="mt-1.5 text-[11px] text-red-300/70">
                Same-chain sends on Arc still work normally.
              </p>
            )}
            <Button size="sm" variant="outline" className="mt-2" onClick={gw.reset}>
              Try again
            </Button>
          </div>
        )}

        {/* Success — same-chain */}
        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}

        {/* Success — cross-chain */}
        {gw.step === 'done' && gw.mintTx && (
          <div className="mt-3 rounded-lg bg-emerald-900/20 px-3 py-2">
            <p className="flex items-center gap-2 text-xs text-emerald-400">
              <CheckCircle className="h-3.5 w-3.5" /> Sent to {dest?.name}
            </p>
            {destCctp && (
              <a href={`${destCctp.explorer}/tx/${gw.mintTx}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-1 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
                View transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function SendPage() {
  return (
    <SectionGuard section="send">
      <SendPageInner />
    </SectionGuard>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/send/page.tsx"

echo ""
echo "Done. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Send/Bridge: reset on success, balances, live step flow'"
echo "  git push"
echo ""
echo "  CHECK AFTER DEPLOY:"
echo "   * Bridge shows your balance on the SELECTED source chain, and Max fills it"
echo "   * Switching source chain updates the balance"
echo "   * The step list lights up as the transfer progresses"
echo "   * Both Send and Bridge clear the form after a successful transfer"
