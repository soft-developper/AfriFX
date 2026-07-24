'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { CheckCircle, Clock, AlertTriangle, ExternalLink, RefreshCw, Loader2 } from 'lucide-react'
import { useCompleteBridge } from '@/hooks/useCompleteBridge'
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
  Without this list, a bridge that outlives the page is INVISIBLE, the user has
  burned funds and no way to see what became of them. On an Ethereum-source
  bridge that's the normal case, not an edge case: finality alone takes 13-19
  minutes, far longer than anyone will sit and watch a spinner.
*/
export function BridgeHistory() {
  const { address } = useAccount()
  const [rows, setRows]       = useState<BridgeRow[]>([])
  const [loading, setLoading] = useState(false)
  const finish = useCompleteBridge()

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

  // Refresh once a manual completion lands, so the row flips to Complete.
  useEffect(() => {
    if (finish.step === 'done') { load(); finish.reset() }
  }, [finish.step, load, finish])

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
                <div className="mt-1.5">
                  {/* HONEST copy. The mint does NOT happen on its own: the
                      platform holds no key (non-custodial by design), so the
                      owner of the funds finishes it. Attestations never expire
                      and destinationCaller is bytes32(0), so this always works,
                      however long it has been. */}
                  <p className="text-[10px] leading-relaxed text-amber-700 dark:text-amber-200/70">
                    Your USDC is burned and recorded. Nothing is lost, but the final
                    step needs your signature to release it on {chainByKey(r.to_chain)?.name ?? r.to_chain}.
                  </p>

                  <button
                    onClick={() => finish.complete(r)}
                    disabled={finish.busyId === r.id}
                    className="mt-1.5 inline-flex items-center gap-1.5 rounded-md bg-app-accent px-2.5 py-1 text-[11px] font-medium text-app-on-accent hover:opacity-90 disabled:opacity-50"
                  >
                    {finish.busyId === r.id
                      ? <><Loader2 className="h-3 w-3 animate-spin" /> Completing...</>
                      : 'Complete transfer'}
                  </button>

                  {finish.busyId === r.id && finish.step === 'checking' && (
                    <p className="mt-1 text-[10px] text-app-muted">Checking with Circle...</p>
                  )}
                  {finish.error && finish.busyId === null && (
                    <p className="mt-1 text-[10px] text-red-700 dark:text-red-300">{finish.error}</p>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
