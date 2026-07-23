'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Plus, ChevronDown, ChevronUp } from 'lucide-react'
import { GatewayDepositForm } from './GatewayDepositForm'
import { useAccount } from 'wagmi'
import { fetchGatewayBalances, gatewayChains, isValidAddress } from '@/lib/gateway'

/*
  READ-ONLY view of the CONNECTED USER'S Circle Gateway unified balance.

  Gateway is permissionless and non-custodial, so this is a genuine user
  feature: any AfriFX user can hold one USDC balance spendable across chains.
  AfriFX's own company treasury uses the same feature with its own wallet, it
  is not special-cased.

  Stage 2 of the Gateway work: this panel only LOOKS. It cannot deposit,
  transfer or withdraw, those need a signer and are deliberately not wired up
  yet.
*/
export function GatewayBalancePanel() {
  const [showDeposit, setShowDeposit] = useState(false)
  // Collapsed by default: the chain list only grows as Gateway adds chains,
  // and most of the time the single unified figure is what matters.
  const [showChains,  setShowChains]  = useState(false)
  const [data, setData]       = useState<any>(null)
  const [error, setError]     = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  /*
    The CONNECTED USER'S wallet, not a hardcoded company address. /treasury is
    a per-user page, so each user sees their own unified balance. AfriFX's own
    company treasury is just another wallet using the same feature.
  */
  const { address } = useAccount()
  const addr = isValidAddress(address) ? address : undefined

  const load = useCallback(async () => {
    if (!addr) return
    setLoading(true); setError(null)
    const res = await fetchGatewayBalances(addr)
    if ('error' in res) setError(res.error)
    else setData(res)
    setLoading(false)
  }, [addr])

  useEffect(() => { load() }, [load])

  // No wallet connected explain rather than render an empty box.
  if (!addr) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <h3 className="mb-1 flex items-center gap-2 text-sm font-semibold text-app-text">
          <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
        </h3>
        <p className="text-xs leading-relaxed text-app-muted">
          Connect your wallet to see your Circle Gateway balance, a single USDC
          balance you can spend on any supported chain, without bridging first.
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

      {/* A read failure is shown as a NOTICE above the balance, not instead of
          it, the rest of the panel (and the deposit button) stays usable. */}
      {error && (
        <div className="mb-3 rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
          <p className="flex items-center gap-1.5 text-xs text-amber-400">
            <AlertCircle className="h-3.5 w-3.5" /> Couldn&apos;t read your Gateway balance
          </p>
          <p className="mt-1 text-[11px] text-amber-800 dark:text-amber-200/80">{error}</p>
          <p className="mt-1 text-[11px] text-amber-700 dark:text-amber-200/60">
            Read-only problem, no funds are affected, and you can still deposit.
          </p>
        </div>
      )}

      {(
        <>
          <div className="mb-4 rounded-lg bg-app-bg p-4">
            <p className="text-[10px] uppercase tracking-wide text-app-muted">
              Spendable on any chain
            </p>
            <p className="font-mono text-2xl text-app-text">
              {loading && !data ? '-' : (data?.total ?? 0).toLocaleString(undefined, {
                minimumFractionDigits: 2, maximumFractionDigits: 2,
              })}
              <span className="ml-1 text-sm text-app-muted">USDC</span>
            </p>
          </div>

          <button
            onClick={() => setShowChains(v => !v)}
            className="mb-2 flex w-full items-center justify-between text-[10px] font-semibold uppercase tracking-wide text-app-muted hover:text-app-text"
          >
            <span>Deposited per chain</span>
            {showChains ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
          </button>
          <div className={`space-y-1.5 ${showChains ? '' : 'hidden'}`}>
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

      {/* Deposit deliberately NOT gated on the balance read succeeding.
          Failing to READ your balance is no reason to prevent you DEPOSITING;
          an earlier version hid this button behind !error, which meant one API
          hiccup made the whole feature look absent. */}
      {(
        <div className="mt-4">
          {showDeposit ? (
            <GatewayDepositForm onDone={() => { setShowDeposit(false); load() }} />
          ) : (
            <button
              onClick={() => setShowDeposit(true)}
              className="flex w-full items-center justify-center gap-1.5 rounded-lg border border-dashed border-app-border py-2 text-xs text-app-muted hover:border-app-accent hover:text-app-text"
            >
              <Plus className="h-3.5 w-3.5" /> Add funds
            </button>
          )}
        </div>
      )}

    </div>
  )
}
