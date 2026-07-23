'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Info, ExternalLink } from 'lucide-react'
import {
  fetchGatewayBalances, gatewayChains, treasuryAddress, gatewayConfigured,
  GATEWAY_ENV, gatewayContracts,
} from '@/lib/gateway'

/*
  READ-ONLY view of AfriFX's Circle Gateway unified balance.

  Stage 2 of the Gateway work: this panel only LOOKS. It cannot deposit,
  transfer or withdraw — those need a signer and are deliberately not wired up
  yet. The value of shipping it first is that treasury across chains becomes
  visible in one place, which it isn't today.
*/
export function GatewayBalancePanel() {
  const [data, setData]       = useState<any>(null)
  const [error, setError]     = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const addr = treasuryAddress()

  const load = useCallback(async () => {
    if (!addr) return
    setLoading(true); setError(null)
    const res = await fetchGatewayBalances(addr)
    if ('error' in res) setError(res.error)
    else setData(res)
    setLoading(false)
  }, [addr])

  useEffect(() => { load() }, [load])

  // Not configured yet — explain rather than render an empty box.
  if (!gatewayConfigured()) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <h3 className="mb-1 flex items-center gap-2 text-sm font-semibold text-app-text">
          <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
        </h3>
        <p className="text-xs leading-relaxed text-app-muted">
          Circle Gateway isn&apos;t set up yet. Once a treasury wallet address is
          configured, this shows a single USDC balance spendable on any supported
          chain — so a payout on Base can settle instantly without bridging
          mid-transaction.
        </p>
        <p className="mt-2 text-[11px] text-app-muted">
          Set <code className="rounded bg-app-bg px-1">NEXT_PUBLIC_TREASURY_ADDRESS</code> to enable.
        </p>
      </div>
    )
  }

  const chains = gatewayChains()

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5">
      <div className="mb-3 flex items-start justify-between">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-semibold text-app-text">
            <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
          </h3>
          <p className="mt-0.5 font-mono text-[10px] text-app-muted">{addr}</p>
        </div>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {error ? (
        <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
          <p className="flex items-center gap-1.5 text-xs text-amber-400">
            <AlertCircle className="h-3.5 w-3.5" /> Couldn&apos;t read the Gateway balance
          </p>
          <p className="mt-1 text-[11px] text-amber-200/80">{error}</p>
          <p className="mt-1 text-[11px] text-amber-200/60">
            This is a read failure only — no funds are affected.
          </p>
        </div>
      ) : (
        <>
          <div className="mb-4 rounded-lg bg-app-bg p-4">
            <p className="text-[10px] uppercase tracking-wide text-app-muted">
              Spendable on any chain
            </p>
            <p className="font-mono text-2xl text-app-text">
              {loading && !data ? '—' : (data?.total ?? 0).toLocaleString(undefined, {
                minimumFractionDigits: 2, maximumFractionDigits: 2,
              })}
              <span className="ml-1 text-sm text-app-muted">USDC</span>
            </p>
          </div>

          <p className="mb-2 text-[10px] font-semibold uppercase tracking-wide text-app-muted">
            Deposited per chain
          </p>
          <div className="space-y-1.5">
            {(data?.perChain ?? chains.map(c => ({ ...c, amount: 0 }))).map((c: any) => (
              <div key={c.key} className="flex items-center justify-between rounded-lg bg-app-bg/60 px-3 py-2">
                <span className="flex items-center gap-2 text-xs text-app-text">
                  {c.name}
                  {c.isHome || c.key === 'arc' ? (
                    <span className="rounded-full bg-app-accent/15 px-1.5 py-0.5 text-[9px] text-app-accent-text">
                      home
                    </span>
                  ) : null}
                </span>
                <span className="text-right">
                  <span className="block font-mono text-xs text-app-text">
                    {(c.amount ?? 0).toFixed(2)}
                  </span>
                  {/* Finality is the honest cost of depositing from that chain. */}
                  <span className="block text-[9px] text-app-muted">
                    deposits clear in {c.finality}
                  </span>
                </span>
              </div>
            ))}
          </div>
        </>
      )}

      {/* The two things anyone operating this must know. */}
      <div className="mt-4 space-y-2 border-t border-app-border pt-3">
        <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-app-muted">
          <Info className="mt-0.5 h-3 w-3 shrink-0" />
          Arc deposits clear in about half a second, so topping up from Arc is
          effectively instant. Deposits from Base or Ethereum take 13–19 minutes
          to finalise before they can be spent.
        </p>
        <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-200/70">
          <AlertCircle className="mt-0.5 h-3 w-3 shrink-0" />
          Withdrawing without Circle&apos;s API takes 7 days. Treat this as working
          capital, not the whole reserve.
        </p>
        <a
          href={`https://developers.circle.com/gateway`}
          target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-[11px] text-app-accent-text hover:underline"
        >
          Circle Gateway docs <ExternalLink className="h-2.5 w-2.5" />
        </a>
      </div>

      <p className="mt-2 text-[10px] text-app-muted">
        {GATEWAY_ENV} · wallet {gatewayContracts().wallet.slice(0, 10)}…
      </p>
    </div>
  )
}
