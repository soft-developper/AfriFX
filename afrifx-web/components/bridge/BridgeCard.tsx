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
