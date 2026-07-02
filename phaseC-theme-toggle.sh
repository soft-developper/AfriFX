#!/bin/bash
# ============================================================
# AfriFX -- Phase C: Dark / Light theme toggle
#
# Adds a full theme system on top of the Phase B token work:
#   * NEW  hooks/useTheme.tsx  -- ThemeProvider + useTheme()
#   * NEW  components/layout/ThemeToggle.tsx
#   * CSS  html.light overrides (warm ivory + deep bronze), all
#          contrast-checked to pass WCAG AA in BOTH themes
#   * Adds --app-on-accent / --app-accent-hover / --app-accent-text
#          tokens so text ON gold, hover states, and gold LINK text
#          stay readable when the palette flips
#   * Replaces text-white-on-gold with text-app-on-accent, and fixes
#          a leftover blue button hover (#2a6fc4) missed in Phase B
#   * Wires ThemeProvider into providers.tsx (incl. RainbowKit swap)
#          and the no-flash init script into layout.tsx
#   * Places the toggle in TopNav, MobileDrawer, and AdminShell
#
# Default: clock-based (light 06:00-17:59, dark otherwise); a manual
# toggle persists in localStorage and overrides the clock.
#
# OVERWRITES each listed file with the tested version, so it is safe
# to run even if your local copies have drifted.
#
# Run from ~/AfriFX:  bash phaseC-theme-toggle.sh
# ============================================================
set -e
echo ""
echo "Applying Phase C -- dark/light theme toggle..."
echo ""

mkdir -p "afrifx-web/app/(app)/dashboard"
cat > "afrifx-web/app/(app)/dashboard/page.tsx" << 'AFX_EOF'
'use client'
import { useAccount }        from 'wagmi'
import { useUSDCBalance }    from '@/hooks/useUSDCBalance'
import { useFXRates }        from '@/hooks/useFXRate'
import { useDashboardStats } from '@/hooks/useDashboardStats'
import { useProfile }        from '@/hooks/useProfile'
import { formatAmount }      from '@/lib/utils'
import { ClientOnly }        from '@/components/ui/client-only'
import { ProfileAvatar }     from '@/components/profile/ProfileAvatar'
import { Badge }             from '@/components/ui/badge'
import { useTokens }         from '@/lib/tokens'
import {
  BarChart, Bar, AreaChart, Area,
  XAxis, YAxis, Tooltip,
  ResponsiveContainer, Cell,
} from 'recharts'
import {
  TrendingUp, TrendingDown, ArrowLeftRight,
  ExternalLink, RefreshCw, Wallet,
  Store, AlertTriangle,
} from 'lucide-react'

// ── Types ─────────────────────────────────────────────────
interface ChartDay { label: string; volume: number }
interface FlowDay  { label: string; inflow: number; outflow: number }
interface PairStat { pair: string; volume: number; txs: number }
interface RecentTx {
  id: string; fromCurrency: string; toCurrency: string
  fromAmount: number; toAmount: number; usdVolume: number
  status: string; reference: string; arcTxHash: string; createdAt: number
}
interface DashboardStats {
  monthly:         { volume: number; txCount: number }
  allTime:         { totalVolume: number; txCount: number }
  p2p:             { completedTrades: number; activeTrades: number; openOffers: number }
  disputeWarnings: number
  chartData:       ChartDay[]
  flowData:        FlowDay[]
  pairBreakdown:   PairStat[]
  recent:          RecentTx[]
}

export default function DashboardPage() {
  return (
    <ClientOnly fallback={<DashboardSkeleton />}>
      <DashboardContent />
    </ClientOnly>
  )
}

function DashboardContent() {
  const t                      = useTokens()
  const { address }            = useAccount()
  const { formatted: balance } = useUSDCBalance()
  const { data: rates }        = useFXRates()
  const { data: profile }      = useProfile()
  const { data: stats, isLoading, refetch } =
    useDashboardStats() as { data: DashboardStats | undefined; isLoading: boolean; refetch: () => void }

  const statCards = [
    {
      label: 'USDC balance',
      value: `${balance}`,
      sub:   'on Arc Testnet',
      icon:  Wallet,
      color: 'text-app-accent-text',
    },
    {
      label: 'Volume (30d)',
      value: stats ? `$${formatAmount(stats.monthly.volume)}` : '—',
      sub:   `${stats?.monthly.txCount ?? 0} conversions this month`,
      icon:  TrendingUp,
      color: 'text-emerald-400',
    },
    {
      label: 'All-time volume',
      value: stats ? `$${formatAmount(stats.allTime.totalVolume)}` : '—',
      sub:   `${stats?.allTime.txCount ?? 0} total transactions`,
      icon:  TrendingUp,
      color: 'text-app-accent-text',
    },
    {
      label: 'Completed trades',
      value: stats ? String(stats.p2p?.completedTrades ?? 0) : '—',
      sub:   `${stats?.p2p?.activeTrades ?? 0} active · ${stats?.p2p?.openOffers ?? 0} open offers`,
      icon:  Store,
      color: 'text-emerald-400',
    },
  ]

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div className="flex items-center gap-3">
          {profile && (
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="md"
              verified={profile.verified}
            />
          )}
          <div>
            <h1 className="text-xl font-semibold text-app-text">
              {profile ? profile.display_name : 'Dashboard'}
            </h1>
            <p className="text-xs text-app-accent-text">
              {profile ? `@${profile.username}` : address?.slice(0,10).concat('…') ?? '—'}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          {(stats?.disputeWarnings ?? 0) > 0 && (
            <div className="flex items-center gap-1.5 rounded-lg border border-amber-900/50 bg-amber-900/20 px-3 py-1.5 text-xs text-amber-400">
              <AlertTriangle className="h-3.5 w-3.5" />
              {stats!.disputeWarnings} dispute warning{stats!.disputeWarnings > 1 ? 's' : ''}
            </div>
          )}
          <button
            onClick={() => refetch()}
            className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text"
          >
            <RefreshCw className={`h-3 w-3 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>
      </div>

      {/* Stat cards */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {statCards.map(({ label, value, sub, icon: Icon, color }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mb-2 flex items-center justify-between">
              <p className="text-xs text-app-muted">{label}</p>
              <Icon className={`h-3.5 w-3.5 ${color}`} />
            </div>
            <p className="font-mono text-xl font-semibold text-app-text">
              {isLoading && value === '—'
                ? <span className="inline-block h-6 w-20 animate-pulse rounded bg-app-border" />
                : value}
            </p>
            <p className="mt-1 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      {/* Row 1: Weekly volume + Top pairs */}
      <div className="mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Weekly volume (USDC)</p>
          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <RefreshCw className="h-5 w-5 animate-spin text-app-muted" />
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={160}>
              <BarChart data={stats?.chartData ?? []} barSize={24}>
                <XAxis dataKey="label" tick={{ fill: t.text, fontSize: 11 }} axisLine={{ stroke: t.border }} tickLine={false} />
                <YAxis tick={{ fill: t.text, fontSize: 11 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => v > 0 ? `$${v}` : '0'} />
                <Tooltip
                  contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: t.text }}
                  itemStyle={{ color: t.text }}
                  cursor={{ fill: t.border }}
                  formatter={(v: number) => [`$${formatAmount(v)}`, 'Volume']}
                />
                <Bar dataKey="volume" radius={[4, 4, 0, 0]}>
                  {(stats?.chartData ?? []).map((entry: ChartDay, i: number) => (
                    <Cell key={i} fill={entry.volume > 0 ? t.accent : t.border} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          )}
        </div>

        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Top pairs</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => <div key={i} className="h-8 animate-pulse rounded bg-app-border" />)}
            </div>
          ) : stats?.pairBreakdown.length ? (
            <div className="space-y-2.5">
              {stats.pairBreakdown.map((p: PairStat) => (
                <div key={p.pair} className="flex items-center justify-between text-xs">
                  <span className="font-medium text-app-text">{p.pair}</span>
                  <div className="text-right">
                    <p className="font-mono text-app-text">${formatAmount(Number(p.volume))}</p>
                    <p className="text-app-muted">{p.txs} txs</p>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-xs text-app-muted">No transactions yet</p>
          )}
        </div>
      </div>

      {/* Row 2: Inflow / Outflow */}
      <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-5">
        <div className="mb-4 flex items-center justify-between">
          <p className="text-sm font-medium text-app-text">Inflow vs Outflow (14 days)</p>
          <div className="flex items-center gap-4 text-xs text-app-muted">
            <span className="flex items-center gap-1.5">
              <span className="inline-block h-2.5 w-2.5 rounded-full bg-emerald-400" />
              Inflow
            </span>
            <span className="flex items-center gap-1.5">
              <span className="inline-block h-2.5 w-2.5 rounded-full bg-app-accent" />
              Outflow
            </span>
          </div>
        </div>
        {isLoading ? (
          <div className="flex h-40 items-center justify-center">
            <RefreshCw className="h-5 w-5 animate-spin text-app-muted" />
          </div>
        ) : (
          <ResponsiveContainer width="100%" height={180}>
            <AreaChart data={stats?.flowData ?? []} margin={{ top: 4, right: 4, left: 0, bottom: 0 }}>
              <defs>
                <linearGradient id="inflowGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor="#10B981" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#10B981" stopOpacity={0}   />
                </linearGradient>
                <linearGradient id="outflowGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor={t.accent} stopOpacity={0.3} />
                  <stop offset="95%" stopColor={t.accent} stopOpacity={0}   />
                </linearGradient>
              </defs>
              <XAxis dataKey="label" tick={{ fill: t.muted, fontSize: 10 }} axisLine={false} tickLine={false} interval={1} />
              <YAxis tick={{ fill: t.muted, fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => v > 0 ? `$${v}` : '0'} />
              <Tooltip
                contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 12 }}
                labelStyle={{ color: t.text }}
                itemStyle={{ color: t.text }}
                formatter={(v: number, name: string) => [`$${formatAmount(v)}`, name === 'inflow' ? 'Inflow' : 'Outflow']}
              />
              <Area type="monotone" dataKey="inflow"  stroke="#10B981" strokeWidth={2} fill="url(#inflowGrad)"  dot={false} />
              <Area type="monotone" dataKey="outflow" stroke={t.accent} strokeWidth={2} fill="url(#outflowGrad)" dot={false} />
            </AreaChart>
          </ResponsiveContainer>
        )}
        {stats?.flowData && (
          <div className="mt-3 flex items-center gap-6 border-t border-app-border pt-3">
            {(() => {
              const totalIn  = stats.flowData.reduce((s: number, d: FlowDay) => s + d.inflow,  0)
              const totalOut = stats.flowData.reduce((s: number, d: FlowDay) => s + d.outflow, 0)
              const net      = totalIn - totalOut
              return (
                <>
                  <div className="text-xs">
                    <p className="text-app-muted">Total inflow</p>
                    <p className="font-mono font-medium text-emerald-400">${formatAmount(totalIn)}</p>
                  </div>
                  <div className="text-xs">
                    <p className="text-app-muted">Total outflow</p>
                    <p className="font-mono font-medium text-app-accent-text">${formatAmount(totalOut)}</p>
                  </div>
                  <div className="text-xs">
                    <p className="text-app-muted">Net position</p>
                    <p className={`font-mono font-medium ${net >= 0 ? 'text-emerald-400' : 'text-red-400'}`}>
                      {net >= 0 ? '+' : ''}${formatAmount(Math.abs(net))}
                    </p>
                  </div>
                </>
              )
            })()}
          </div>
        )}
      </div>

      {/* Row 3: Recent activity + Live rates */}
      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Recent activity</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => <div key={i} className="h-12 animate-pulse rounded bg-app-border" />)}
            </div>
          ) : stats?.recent.length ? (
            <div className="space-y-2">
              {stats.recent.map((tx: RecentTx) => (
                <div key={tx.id} className="flex items-center gap-3 rounded-lg bg-app-bg px-3 py-2.5">
                  <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-app-accent/10">
                    <ArrowLeftRight className="h-3.5 w-3.5 text-app-accent-text" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium text-app-text">
                      {tx.fromCurrency} → {tx.toCurrency}
                    </p>
                    <p className="truncate font-mono text-[10px] text-app-muted">
                      {tx.reference ?? tx.id.slice(0,16) + '…'}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="font-mono text-xs text-emerald-400">
                      +{Number(tx.toAmount).toFixed(2)} {tx.toCurrency}
                    </p>
                    <Badge variant={tx.status === 'settled' ? 'success' : tx.status === 'failed' ? 'danger' : 'warning'}>
                      {tx.status}
                    </Badge>
                  </div>
                  {tx.arcTxHash && (
                    <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}
                      target="_blank" rel="noopener noreferrer" className="shrink-0">
                      <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent-text" />
                    </a>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <p className="text-xs text-app-muted">No transactions yet</p>
          )}
        </div>

        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Live rates</p>
          <div className="space-y-2.5">
            {(rates ?? []).map(r => {
              const up = r.change24h >= 0
              return (
                <div key={r.pair} className="flex items-center justify-between text-xs">
                  <span className="text-app-muted">{r.pair}</span>
                  <span className="font-mono text-app-text">{r.rate.toLocaleString()}</span>
                  <span className={`flex items-center gap-0.5 ${up ? 'text-emerald-400' : 'text-red-400'}`}>
                    {up ? <TrendingUp className="h-3 w-3" /> : <TrendingDown className="h-3 w-3" />}
                    {up ? '+' : ''}{r.change24h.toFixed(2)}%
                  </span>
                </div>
              )
            })}
          </div>
        </div>
      </div>
    </div>
  )
}

function DashboardSkeleton() {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {[1,2,3,4].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2 h-48 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
      </div>
      <div className="h-56 animate-pulse rounded-xl bg-app-surface" />
      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/dashboard/page.tsx"

mkdir -p "afrifx-web/app/(app)/history"
cat > "afrifx-web/app/(app)/history/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { Badge } from '@/components/ui/badge'
import { ArrowLeftRight, ArrowRight, ExternalLink } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
type StatusFilter = 'all' | 'settled' | 'pending' | 'failed'

export default function HistoryPage() {
  const { address }           = useAccount()
  const [txs,     setTxs]     = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [status,  setStatus]  = useState<StatusFilter>('all')

  useEffect(() => {
    if (!address) return
    setLoading(true)
    fetch(`${API}/transactions?wallet=${address}`)
      .then(r => r.json())
      .then(data => setTxs(Array.isArray(data) ? data : []))
      .catch(() => setTxs([]))
      .finally(() => setLoading(false))
  }, [address])

  const filtered: any[] = txs.filter(
    tx => status === 'all' || tx.status === status
  )

  // Group corridor steps together
  const corridorGroups = new Map<string, any[]>()
  const standalone: any[] = [];

  filtered.forEach(tx => {
    const cid = tx.corridor_id ?? tx.corridorId
    if (cid) {
      const group = corridorGroups.get(cid) ?? []
      group.push(tx)
      corridorGroups.set(cid, group)
    } else {
      standalone.push(tx)
    }
  })

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">History</h1>
          <p className="text-sm text-app-muted">All your Arc transactions</p>
        </div>
        <div className="flex items-center gap-1 rounded-lg border border-app-border bg-app-surface p-1">
          {(['all','settled','pending','failed'] as StatusFilter[]).map(s => (
            <button key={s} onClick={() => setStatus(s)}
              className={`rounded-md px-3 py-1 text-xs capitalize transition-colors
                ${status === s
                  ? 'bg-app-border text-app-text'
                  : 'text-app-muted hover:text-app-text'}`}>
              {s}
            </button>
          ))}
        </div>
      </div>

      {loading && <p className="text-sm text-app-muted">Loading…</p>}
      {!loading && filtered.length === 0 && (
        <p className="text-sm text-app-muted">No transactions found.</p>
      )}

      <div className="space-y-3">
        {/* Corridor groups */}
        {Array.from(corridorGroups.entries()).map(([cid, steps]) => {
          const step1 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 1)
          const step2 = steps.find((s: any) => Number(s.corridor_step ?? s.corridorStep) === 2)
          const fromCcy = step1?.from_currency ?? step1?.fromCurrency ?? ''
          const toCcy   = step2?.to_currency   ?? step2?.toCurrency   ?? ''
          return (
            <div key={cid} className="rounded-xl border border-app-accent/20 bg-app-surface">
              <div className="flex items-center gap-2 border-b border-app-border px-4 py-2.5">
                <Badge variant="arc">Corridor</Badge>
                {step1 && step2 && (
                  <span className="flex items-center gap-1 text-xs text-app-muted">
                    {fromCcy}
                    <ArrowRight className="h-3 w-3" />
                    USDC
                    <ArrowRight className="h-3 w-3" />
                    {toCcy}
                  </span>
                )}
                <span className="ml-auto font-mono text-[10px] text-app-accent-text">{cid}</span>
              </div>
              {steps
                .sort((a: any, b: any) =>
                  Number(a.corridor_step ?? a.corridorStep ?? 0) -
                  Number(b.corridor_step ?? b.corridorStep ?? 0)
                )
                .map((tx: any) => <TxRow key={tx.id} tx={tx} isCorridorStep />)
              }
            </div>
          )
        })}

        {/* Standalone */}
        {standalone.map((tx: any) => (
          <div key={tx.id} className="rounded-xl border border-app-border bg-app-surface">
            <TxRow tx={tx} />
          </div>
        ))}
      </div>
    </div>
  )
}

function TxRow({ tx, isCorridorStep = false }: { tx: any; isCorridorStep?: boolean }) {
  const fromCcy   = tx.from_currency ?? tx.fromCurrency  ?? ''
  const toCcy     = tx.to_currency   ?? tx.toCurrency    ?? ''
  const fromAmt   = Number(tx.from_amount  ?? tx.fromAmount  ?? 0)
  const toAmt     = Number(tx.to_amount    ?? tx.toAmount    ?? 0)
  const createdAt = Number(tx.created_at   ?? tx.createdAt   ?? 0)
  const step      = tx.corridor_step ?? tx.corridorStep
  const ref       = tx.reference     ?? tx.memo_id        ?? ''
  const hash      = tx.arc_tx_hash   ?? tx.arcTxHash      ?? ''
  const status    = tx.status        ?? 'pending'

  return (
    <div className={`flex items-center gap-3 px-4 py-3.5
      ${isCorridorStep ? 'border-b border-app-border last:border-0' : ''}`}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-accent/10">
        <ArrowLeftRight className="h-4 w-4 text-app-accent-text" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-app-text">
          {isCorridorStep && step && (
            <span className="mr-1.5 text-[10px] text-app-muted">Step {step}</span>
          )}
          {fromCcy} → {toCcy}
        </p>
        <div className="flex items-center gap-2 text-[10px] text-app-muted">
          <span>{new Date(createdAt * 1000).toLocaleString()}</span>
          {ref && <span className="font-mono text-app-accent-text">{ref}</span>}
        </div>
      </div>
      <div className="shrink-0 text-right">
        <p className="font-mono text-sm text-red-400">
          -{fromAmt.toLocaleString(undefined, { maximumFractionDigits: 4 })} {fromCcy}
        </p>
        <p className="font-mono text-sm text-emerald-400">
          +{toAmt.toFixed(4)} {toCcy}
        </p>
      </div>
      <div className="ml-2 flex shrink-0 flex-col items-end gap-1">
        <Badge variant={
          status === 'settled' ? 'success' :
          status === 'failed'  ? 'danger'  : 'warning'
        }>
          {status}
        </Badge>
        {hash && (
          <a href={`https://testnet.arcscan.app/tx/${hash}`}
            target="_blank" rel="noopener noreferrer">
            <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent-text" />
          </a>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/history/page.tsx"

mkdir -p "afrifx-web/app/(app)/invoices/[id]"
cat > "afrifx-web/app/(app)/invoices/[id]/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoice, useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  ArrowLeft, Copy, Check, ExternalLink,
  FileText, Send, Loader2, CheckCircle, X,
} from 'lucide-react'

export default function InvoiceDetailPage() {
  return <ClientOnly><InvoiceDetail /></ClientOnly>
}

function InvoiceDetail() {
  const { id }                      = useParams()
  const { address }                 = useAccount()
  const { data: invoice }           = useInvoice(id as string)
  const updateStatus                = useUpdateInvoiceStatus()
  const [copied, setCopied]         = useState(false)

  if (!invoice) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  const payLink   = `${typeof window !== 'undefined' ? window.location.origin : ''}/pay/${invoice.memo_ref}`
  const isCreator = invoice.creator_address.toLowerCase() === address?.toLowerCase()

  function copy() {
    navigator.clipboard.writeText(payLink)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  async function cancel() {
    if (!confirm('Cancel this invoice?')) return
    await updateStatus.mutateAsync({ id: invoice!.id, status: 'cancelled' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/invoices">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">Invoice</h1>
            <Badge variant={invoice.status === 'paid' ? 'success' : invoice.status === 'cancelled' ? 'danger' : 'arc'}>
              {invoice.status}
            </Badge>
          </div>
          <p className="font-mono text-xs text-app-accent-text">{invoice.memo_ref}</p>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {/* Details */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Invoice details</p>
          <div className="space-y-3">
            <div className="flex justify-between items-center rounded-lg bg-app-bg px-4 py-3">
              <span className="text-xs text-app-muted">Amount</span>
              <span className="font-mono text-lg font-bold text-app-text">
                {formatAmount(invoice.amount)} {invoice.currency}
              </span>
            </div>
            {[
              ['Description', invoice.description ?? '—'],
              ['Reference',   invoice.memo_ref],
              ['Created',     new Date(invoice.created_at * 1000).toLocaleString()],
              ['Due',         invoice.due_date ? new Date(invoice.due_date * 1000).toLocaleDateString() : 'No deadline'],
              ['Payer',       invoice.payer_address ? invoice.payer_address.slice(0,10)+'…' : 'Open (anyone)'],
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between text-xs">
                <span className="text-app-muted">{label}</span>
                <span className="font-mono text-app-text">{value}</span>
              </div>
            ))}
            {invoice.notes && (
              <div className="rounded-lg bg-app-bg p-3 text-xs">
                <p className="mb-1 text-app-muted">Notes</p>
                <p className="text-app-text whitespace-pre-wrap">{invoice.notes}</p>
              </div>
            )}
          </div>
        </div>

        {/* Share + status */}
        <div className="space-y-4">
          {invoice.status === 'paid' ? (
            <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-5 text-center">
              <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
              <p className="font-medium text-emerald-400">Invoice paid!</p>
              <p className="mt-1 text-xs text-emerald-600">
                Paid {invoice.paid_at ? new Date(invoice.paid_at * 1000).toLocaleString() : ''}
              </p>
              {invoice.payment_tx_hash && (
                <a href={`https://testnet.arcscan.app/tx/${invoice.payment_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="mt-3 inline-flex items-center gap-1.5 text-xs text-app-accent-text hover:underline">
                  <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
                </a>
              )}
            </div>
          ) : invoice.status !== 'cancelled' && isCreator && (
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-3 text-sm font-medium text-app-text">Payment link</p>
              <div className="mb-3 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2.5">
                <p className="flex-1 truncate font-mono text-xs text-app-accent-text">{payLink}</p>
                <button onClick={copy} className="shrink-0 text-app-muted hover:text-app-text">
                  {copied ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                </button>
              </div>
              <p className="text-xs text-app-muted">
                Share this link with your payer. They visit it, connect their wallet, and pay on-chain.
              </p>
              {invoice.status === 'draft' && (
                <Button className="mt-3 w-full" size="sm"
                  onClick={() => updateStatus.mutateAsync({ id: invoice.id, status: 'sent' })}>
                  <Send className="h-3.5 w-3.5" /> Mark as sent
                </Button>
              )}
            </div>
          )}

          {isCreator && !['paid','cancelled'].includes(invoice.status) && (
            <Button variant="danger" size="sm" className="w-full" onClick={cancel}>
              <X className="h-4 w-4" /> Cancel invoice
            </Button>
          )}

          {!isCreator && invoice.status === 'sent' && (
            <Link href={`/pay/${invoice.memo_ref}`}>
              <Button className="w-full">Pay this invoice</Button>
            </Link>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/invoices/[id]/page.tsx"

mkdir -p "afrifx-web/app/(app)/invoices/create"
cat > "afrifx-web/app/(app)/invoices/create/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import { useCreateInvoice } from '@/hooks/useInvoices'
import { useFXRates } from '@/hooks/useFXRate'
import { ArrowLeft, FileText, Loader2 } from 'lucide-react'

export default function CreateInvoicePage() {
  return <ClientOnly><CreateInvoiceContent /></ClientOnly>
}

function CreateInvoiceContent() {
  const router        = useRouter()
  const createInvoice = useCreateInvoice()
  const { data: rates = [] } = useFXRates()

  const [amount,       setAmount]       = useState('')
  const [currency,     setCurrency]     = useState('USDC')
  const [description,  setDescription]  = useState('')
  const [notes,        setNotes]        = useState('')
  const [payerAddress, setPayerAddress] = useState('')
  const [dueDate,      setDueDate]      = useState('')

  // USD equivalent preview for non-USDC invoices
  const rateEntry = rates.find(r => r.pair === `${currency}/USDC`)
  const usdEquiv = rateEntry && amount && currency !== 'USDC'
    ? parseFloat((parseFloat(amount) / rateEntry.rate).toFixed(2))
    : null

  async function handleCreate() {
    if (!amount) return
    const result = await createInvoice.mutateAsync({
      amount:       parseFloat(amount),
      currency,
      description:  description || undefined,
      notes:        notes       || undefined,
      payerAddress: payerAddress || undefined,
      dueDate:      dueDate ? Math.floor(new Date(dueDate).getTime() / 1000) : undefined,
    })
    if (result?.id) router.push(`/invoices/${result.id}`)
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/invoices">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create invoice</h1>
          <p className="text-sm text-app-muted">Generate a payment link with a unique Memo reference</p>
        </div>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Invoice details</p>
            <div className="space-y-3">
              {/* Amount + currency */}
              <div className="flex gap-3">
                <div className="flex-1">
                  <label className="mb-1 block text-xs text-app-muted">Amount *</label>
                  <Input type="number" placeholder="0.00" value={amount}
                    onChange={e => setAmount(e.target.value)} />
                </div>
                <div className="w-32">
                  <label className="mb-1 block text-xs text-app-muted">Currency</label>
                  <select value={currency} onChange={e => setCurrency(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {['USDC','NGN','GHS','KES','ZAR','EGP'].map(c => (
                      <option key={c} value={c}>{c}</option>
                    ))}
                  </select>
                </div>
              </div>

              {/* USD equivalent preview */}
              {usdEquiv && (
                <p className="text-xs text-emerald-400">
                  ≈ ${usdEquiv.toLocaleString()} USD at current rate
                </p>
              )}

              <div>
                <label className="mb-1 block text-xs text-app-muted">Description *</label>
                <Input placeholder="What is this invoice for?" value={description}
                  onChange={e => setDescription(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Notes (optional)</label>
                <textarea value={notes} onChange={e => setNotes(e.target.value)}
                  placeholder="Additional payment instructions, bank details, etc."
                  rows={3}
                  className="w-full resize-none rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted outline-none focus:ring-1 focus:ring-app-accent" />
              </div>
            </div>
          </div>

          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Payer details (optional)</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-app-muted">Payer wallet address</label>
                <Input placeholder="0x… (leave blank for open invoice)"
                  value={payerAddress} onChange={e => setPayerAddress(e.target.value)}
                  className="font-mono text-xs" />
                <p className="mt-1 text-[10px] text-app-muted">
                  If set, only this wallet can pay the invoice
                </p>
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Due date</label>
                <Input type="date" value={dueDate} onChange={e => setDueDate(e.target.value)} />
              </div>
            </div>
          </div>
        </div>

        {/* Preview */}
        <div className="space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-3 text-sm font-medium text-app-text">Preview</p>
            <div className="space-y-2 text-xs">
              <div className="flex justify-between">
                <span className="text-app-muted">Amount</span>
                <span className="font-mono text-app-text">
                  {amount ? `${parseFloat(amount).toLocaleString()} ${currency}` : '—'}
                </span>
              </div>
              {usdEquiv && (
                <div className="flex justify-between">
                  <span className="text-app-muted">USD value</span>
                  <span className="font-mono text-emerald-400">${usdEquiv.toLocaleString()}</span>
                </div>
              )}
              <div className="flex justify-between">
                <span className="text-app-muted">Description</span>
                <span className="text-app-text truncate max-w-28">{description || '—'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-app-muted">Due</span>
                <span className="text-app-text">{dueDate || 'No deadline'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-app-muted">Reference</span>
                <span className="font-mono text-app-accent-text">INV-YYYYMMDD-XXXX</span>
              </div>
            </div>

            <Button className="mt-4 w-full" onClick={handleCreate}
              disabled={!amount || !description || createInvoice.isPending}>
              {createInvoice.isPending
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</>
                : <><FileText className="h-4 w-4" /> Create invoice</>
              }
            </Button>
          </div>

          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs text-app-muted">
            <p className="mb-2 font-medium text-app-text">After creating</p>
            <ol className="space-y-1.5">
              {[
                'Invoice created with unique Memo ref',
                'Share payment link with payer',
                'Payer visits link and pays USDC on-chain',
                'Invoice updates to "paid" automatically',
                'Settlement visible on ArcScan',
              ].map((s, i) => (
                <li key={i} className="flex gap-2">
                  <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                  <span>{s}</span>
                </li>
              ))}
            </ol>
          </div>
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/invoices/create/page.tsx"

mkdir -p "afrifx-web/app/(app)/invoices"
cat > "afrifx-web/app/(app)/invoices/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoices } from '@/hooks/useInvoices'
import { useFXRates } from '@/hooks/useFXRate'
import { useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Copy, Check, ExternalLink,
  FileText, Send, ArrowRight, Loader2,
} from 'lucide-react'

const STATUS_BADGE: Record<string, any> = {
  draft:     'default',
  sent:      'arc',
  paid:      'success',
  overdue:   'danger',
  cancelled: 'danger',
}

export default function InvoicesPage() {
  return (
    <ClientOnly fallback={<div className="h-64 animate-pulse rounded-xl bg-app-surface" />}>
      <InvoicesContent />
    </ClientOnly>
  )
}

function InvoicesContent() {
  const { address }               = useAccount()
  const { data: invoices = [], isLoading } = useInvoices()
  const { data: rates = [] }      = useFXRates()
  const updateStatus              = useUpdateInvoiceStatus()
  const [copied, setCopied]       = useState<string|null>(null)
  const [filter, setFilter]       = useState('all')

  // Convert any invoice amount to USD using live rates
  function toUSD(amount: number, currency: string): number {
    if (!amount) return 0
    if (currency === 'USDC' || currency === 'USD') return amount
    if (currency === 'EURC') {
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    return rate && rate > 0 ? amount / rate : 0
  }

  const filtered = filter === 'all'
    ? invoices
    : invoices.filter(i => i.status === filter)

  const created  = invoices.filter(i => i.creator_address.toLowerCase() === address?.toLowerCase())
  const received = invoices.filter(i => i.payer_address?.toLowerCase() === address?.toLowerCase())

  function copyPayLink(memoRef: string) {
    const url = `${window.location.origin}/pay/${memoRef}`
    navigator.clipboard.writeText(url)
    setCopied(memoRef)
    setTimeout(() => setCopied(null), 2000)
  }

  async function markSent(id: string) {
    await updateStatus.mutateAsync({ id, status: 'sent' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Invoices</h1>
          <p className="text-sm text-app-muted">
            {created.length} created · {received.length} to pay
          </p>
        </div>
        <Link href="/invoices/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New invoice</Button>
        </Link>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          { label: 'Total invoiced', value: `$${formatAmount(created.reduce((s,i)=>s+toUSD(i.amount,i.currency),0))}`, color: 'text-app-accent-text' },
          { label: 'Paid',           value: String(created.filter(i=>i.status==='paid').length),      color: 'text-emerald-400' },
          { label: 'Pending',        value: String(created.filter(i=>i.status==='sent').length),      color: 'text-amber-400' },
          { label: 'To pay',         value: String(received.filter(i=>i.status==='sent').length),     color: 'text-red-400' },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4 text-center">
            <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
            <p className="mt-1 text-xs text-app-muted">{label}</p>
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {['all','draft','sent','paid','overdue','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
            {f}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="space-y-2">{[1,2,3].map(i=><div key={i} className="h-20 animate-pulse rounded-xl bg-app-surface"/>)}</div>
      ) : filtered.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <FileText className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No invoices yet</p>
          <Link href="/invoices/create">
            <Button variant="outline" size="sm" className="mt-3">Create your first invoice</Button>
          </Link>
        </div>
      ) : (
        <div className="space-y-2">
          {filtered.map(inv => {
            const isCreator = inv.creator_address.toLowerCase() === address?.toLowerCase()
            const isPayer   = inv.payer_address?.toLowerCase() === address?.toLowerCase()
            const isOverdue = inv.due_date && inv.due_date < Math.floor(Date.now()/1000) && inv.status === 'sent'
            return (
              <div key={inv.id} className="rounded-xl border border-app-border bg-app-surface p-4">
                <div className="flex items-center gap-4">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-bg">
                    <FileText className="h-4 w-4 text-app-accent-text" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-mono text-sm font-medium text-app-text">
                        {formatAmount(inv.amount)} {inv.currency}
                      </p>
                      <Badge variant={STATUS_BADGE[isOverdue ? 'overdue' : inv.status]}>
                        {isOverdue ? 'overdue' : inv.status}
                      </Badge>
                      <Badge variant={isCreator ? 'arc' : 'warning'}>
                        {isCreator ? 'Sent by you' : 'To pay'}
                      </Badge>
                    </div>
                    <p className="text-xs text-app-muted">
                      {inv.memo_ref} · {inv.description ?? 'No description'}
                      {inv.due_date && ` · Due ${new Date(inv.due_date*1000).toLocaleDateString()}`}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-2">
                    {isCreator && inv.status === 'draft' && (
                      <Button size="sm" variant="outline" onClick={() => markSent(inv.id)}>
                        <Send className="h-3.5 w-3.5" /> Send
                      </Button>
                    )}
                    {isCreator && inv.status !== 'paid' && inv.status !== 'cancelled' && (
                      <button onClick={() => copyPayLink(inv.memo_ref)}
                        className="flex items-center gap-1.5 rounded-lg border border-app-border px-2.5 py-1.5 text-xs text-app-muted hover:text-app-text transition-colors">
                        {copied === inv.memo_ref ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                        {copied === inv.memo_ref ? 'Copied!' : 'Copy link'}
                      </button>
                    )}
                    {isPayer && inv.status === 'sent' && (
                      <Link href={`/pay/${inv.memo_ref}`}>
                        <Button size="sm">Pay now <ArrowRight className="h-3.5 w-3.5" /></Button>
                      </Link>
                    )}
                    {inv.payment_tx_hash && (
                      <a href={`https://testnet.arcscan.app/tx/${inv.payment_tx_hash}`}
                        target="_blank" rel="noopener noreferrer"
                        className="text-app-muted hover:text-app-accent-text">
                        <ExternalLink className="h-4 w-4" />
                      </a>
                    )}
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/invoices/page.tsx"

mkdir -p "afrifx-web/app/(app)/marketplace/[id]"
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams, useSearchParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { TimerBanner } from '@/components/p2p/TimerBanner'
import { ChatWindow } from '@/components/chat/ChatWindow'
import { OfferParties } from '@/components/p2p/OfferParties'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'
import { useProfileByAddress } from '@/hooks/useProfile'
import { DisputeStatus } from '@/components/dispute/DisputeStatus'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

// Extend P2POffer with extra fields we use
interface OfferExtended extends P2POffer {
  taker_deadline?:      number | null
  maker_deadline?:      number | null
  dispute_raised?:      number
  dispute_id?:          string | null
  maker_timer_seconds?: number
  order_type?:          string
}

function normalizeOffer(row: unknown): OfferExtended | null {
  if (!row || (row as Record<string, unknown>).error) return null
  if (Array.isArray(row)) {
    return {
      id:              row[0],
      maker_address:   row[1],
      taker_address:   row[2],
      usdc_amount:     row[3],
      local_currency:  row[4],
      local_amount:    row[5],
      rate_offered:    row[6],
      status:          row[7],
      maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]),
      arc_tx_hash:     row[10],
      release_tx_hash: row[11],
      expires_at:      row[12],
      created_at:      row[13],
      updated_at:      row[14],
    } as OfferExtended
  }
  const r = row as Record<string, unknown>
  return {
    ...(r as unknown as P2POffer),
    maker_confirmed:     Number(r.maker_confirmed     ?? 0),
    taker_confirmed:     Number(r.taker_confirmed     ?? 0),
    taker_deadline:      r.taker_deadline  ? Number(r.taker_deadline)  : null,
    maker_deadline:      r.maker_deadline  ? Number(r.maker_deadline)  : null,
    dispute_raised:      Number(r.dispute_raised      ?? 0),
    maker_timer_seconds: Number(r.maker_timer_seconds ?? 1800),
    order_type:          (r.order_type as string) ?? 'market',
  } as OfferExtended
}

export default function OfferDetailPage() {
  const params       = useParams()
  const searchParams = useSearchParams()
  const { address }  = useAccount()

  const justAccepted = searchParams.get('accepted') === '1'

  const [offer,       setOffer]       = useState<OfferExtended | null>(null)
  const [loading,     setLoading]     = useState(true)
  const [notFound,    setNotFound]    = useState(false)
  const [disputing,   setDisputing]   = useState(false)
  const [disputeDone,    setDisputeDone]    = useState(false)
  const [disputeRecord,  setDisputeRecord]  = useState<{ id: string } | null>(null)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  // Profile hooks — MUST be before any conditional returns (React rules of hooks)
  const { data: makerProfile } = useProfileByAddress(offer?.maker_address ?? null)
  const { data: takerProfile } = useProfileByAddress(offer?.taker_address ?? null)

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) {
        if (!justAccepted) setNotFound(true)
        return
      }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) {
        setOffer(norm)
        setNotFound(false)
      } else if (!justAccepted) {
        setNotFound(true)
      }
    } catch {
      if (!justAccepted) setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [params.id, justAccepted])

  useEffect(() => { load() }, [load])

  // Fetch dispute record when dispute is raised
  useEffect(() => {
    if (!offer?.dispute_raised || disputeRecord) return
    fetch(`${API}/disputes/offer/${offer.id}`)
      .then(r => r.json())
      .then(data => { if (data?.id) setDisputeRecord(data) })
      .catch(() => {})
  }, [offer?.dispute_raised, offer?.id])

  useEffect(() => {
    const isStillSyncing = justAccepted && !offer?.taker_address
    const interval = setInterval(load, isStillSyncing ? 2000 : 5000)
    return () => clearInterval(interval)
  }, [load, justAccepted, offer?.taker_address])

  if (loading) return (
    <div className="space-y-4">
      <div className="h-24 animate-pulse rounded-xl bg-app-surface" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
      </div>
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-app-muted">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const offerStatus = offer.status as string

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = justAccepted
    ? !isMaker && !!address
    : address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = offer.maker_timer_seconds ?? 1800

  if (offerStatus === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-app-text">This trade is in progress.</p>
        <p className="text-xs text-app-muted">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace">
          <Button variant="outline" size="sm">← Back to marketplace</Button>
        </Link>
      </div>
    )
  }

  const statusBadgeMap: Record<string, string> = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }
  const statusBadge = (statusBadgeMap[offerStatus] ?? 'default') as
    'warning' | 'arc' | 'success' | 'danger' | 'default'

  const makerName = makerProfile?.display_name ?? makerProfile?.username ??
    (offer?.maker_address ? offer.maker_address.slice(0,8) + '…' : 'Seller')
  const takerName = takerProfile?.display_name ?? takerProfile?.username ??
    (offer?.taker_address ? offer.taker_address.slice(0,8) + '…' : 'Buyer')

  const steps = [
    { n:1, done: offerStatus !== 'open',     label: `${takerName} accepted offer`,               desc: 'USDC locked in vault' },
    { n:2, done: offerStatus !== 'open',     label: `${takerName} sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to ${makerName}`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: `${takerName} confirmed: "I sent the money"`, desc: 'Taker window' },
    { n:4, done: !!offer.maker_confirmed,     label: `${makerName} confirmed: "I received it"`,    desc: 'Maker window' },
    { n:5, done: offerStatus === 'released',  label: 'Platform releases USDC to taker',     desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offerStatus === 'accepted' && !offer.taker_confirmed && !!offer.taker_deadline
  const showMakerTimer = offerStatus === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!offer.maker_deadline

  const showChat = isInvolved && (
    offerStatus === 'accepted' ||
    offerStatus === 'released' ||
    justAccepted
  ) && !!offer.taker_address

  const isSyncing = justAccepted && !offer.taker_address

  async function handleDispute(
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address || !offer) return
    setDisputing(true)
    try {
      await raiseDispute(
        offer.id,
        disputeType === 'maker_silent'
          ? 'Maker did not confirm receipt — possible non-response'
          : 'Taker claims to have sent payment but maker did not receive it',
        disputeType,
        raisedByRole,
      )
      setDisputeDone(true)
      await load()
    } catch (_e) {}
    finally { setDisputing(false) }
  }

  const localAmountFormatted = Number(offer.local_amount).toLocaleString()
  const nowTs = Math.floor(Date.now() / 1000)

  return (
    <div>
      {/* Header */}
      <div className="mb-4 flex items-center gap-3">
        <Link href={isInvolved ? '/my-trades' : '/marketplace'}>
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            <Badge variant={offer.order_type === 'limit' ? 'warning' : 'arc'}>
              {offer.order_type ?? 'market'}
            </Badge>
            {!!offer.dispute_raised && <Badge variant="danger">Disputed</Badge>}
            {isTaker && <Badge variant="success">You are the buyer</Badge>}
          </div>
          <p className="font-mono text-xs text-app-muted">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {isSyncing && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3 text-sm text-app-accent-text">
          <Loader2 className="h-4 w-4 animate-spin shrink-0" />
          Trade accepted! Setting up your trade interface…
        </div>
      )}

      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.taker_deadline as number}
              totalSeconds={timerSecs}
              phase="taker"
              isMine={isTaker}
            />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.maker_deadline as number}
              totalSeconds={timerSecs}
              phase="maker"
              isMine={isMaker}
            />
          </div>
        )}
      </ClientOnly>

      <div className={`grid gap-4 ${showChat ? 'lg:grid-cols-3' : 'lg:grid-cols-2'}`}>

        {/* Summary */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-app-bg p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-app-muted">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-app-muted" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{localAmountFormatted}</p>
              <p className="text-xs text-app-muted">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <OfferParties
            makerAddress={offer.maker_address}
            takerAddress={offer.taker_address}
            isMaker={isMaker}
            isTaker={isTaker}
          />

          <div className="mt-2 flex justify-between text-xs">
            <span className="text-app-muted">Rate</span>
            <span className="font-mono text-app-text">
              1 USDC = {Number(offer.rate_offered) > 0
                ? (1 / Number(offer.rate_offered)).toFixed(2) : '—'} {offer.local_currency}
            </span>
          </div>

          {offer.arc_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Create tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-app-accent-text hover:underline">
                {offer.arc_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}
          {offer.release_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Release tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                {offer.release_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}

          {isMaker && offerStatus === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Progress + actions */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Progress</p>
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-app-border text-app-muted'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-app-text'}`}>{label}</p>
                  <p className="text-xs text-app-muted">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          <ClientOnly>
            <div className="space-y-3">
              {offerStatus === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {offerStatus === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!offer.dispute_raised && offerStatus === 'accepted' && (
                disputeRecord?.id ? (
                  <DisputeStatus
                    disputeId={disputeRecord.id}
                    offerId={offer.id}
                    userAddress={address ?? ''}
                    userRole={isMaker ? 'maker' : 'taker'}
                    username={undefined}
                  />
                ) : (
                  <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                    <p className="font-medium text-amber-400">⏳ Dispute raised — awaiting admin review</p>
                    <p className="mt-1 text-amber-600">An admin will accept and handle your dispute shortly.</p>
                  </div>
                )
              )}

              {offerStatus === 'open' && isMaker && (
                <div className="rounded-lg bg-app-bg p-3 text-center text-xs text-app-muted">
                  Waiting for a buyer to accept your offer…
                </div>
              )}

              {isSyncing && (
                <div className="flex items-center gap-2 rounded-lg border border-app-accent/30 bg-app-accent/10 px-3 py-3 text-xs text-app-accent-text">
                  <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                  <div>
                    <p className="font-medium">Offer accepted on Arc!</p>
                    <p className="mt-0.5 opacity-70">Syncing trade details…</p>
                  </div>
                </div>
              )}

              {offerStatus === 'accepted' && !isSyncing && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Your turn — send {offer.local_currency} to {makerName}</p>
                      <p className="mt-1 text-app-muted">
                        Send <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong> via bank or mobile money, then confirm below.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for {takerName} to send and confirm {localAmountFormatted} {offer.local_currency}…
                    </div>
                  )}

                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Check your account</p>
                      <p className="mt-1 text-app-muted">
                        {takerName} says they sent <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong>. Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={!!offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${localAmountFormatted} ${offer.local_currency} to ${makerName}`
                      }
                    </Button>
                  )}

                  {isMaker && !offer.dispute_raised && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={!!offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? `Waiting for ${takerName} to send first…`
                        : `✓ I received ${localAmountFormatted} ${offer.local_currency}`
                      }
                    </Button>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2 text-xs text-app-muted">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for {makerName} to confirm receipt…
                    </div>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ {makerName} has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_silent', 'taker')} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">✓ Dispute raised — admin will review and contact both parties.</p>
                      )}
                    </div>
                  )}

                  {/* MAKER dispute: deadline elapsed, no dispute yet */}
                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-red-900/40 bg-red-900/10 p-3 text-xs">
                        <p className="font-medium text-red-400">⚠️ {takerName} claims to have sent payment</p>
                        <p className="mt-1 text-red-600">
                          If you did not receive{' '}
                          <strong className="text-red-400">{localAmountFormatted} {offer.local_currency}</strong>,
                          raise a dispute for admin review.
                        </p>
                      </div>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_not_received', 'maker')}
                          disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : "I didn't receive payment — raise dispute"}
                        </Button>
                      ) : (
                        <div className="rounded-lg bg-amber-900/20 p-3 text-xs text-amber-400">
                          ✓ Dispute raised — admin will review.
                        </div>
                      )}
                    </div>
                  )}

                  {/* Both confirmed — waiting for release */}
                  {!!offer.maker_confirmed && !!offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      Both confirmed — releasing USDC within 15 seconds…
                    </div>
                  )}
                </>
              )}
            </div>
          </ClientOnly>

          {!!error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {!!txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-app-accent-text hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>

        {showChat && offer.taker_address && (
          <ClientOnly>
            <ChatWindow
              offerId={offer.id}
              makerAddress={offer.maker_address}
              takerAddress={offer.taker_address}
              currency={offer.local_currency}
              amount={Number(offer.local_amount)}
            />
          </ClientOnly>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/marketplace/[id]/page.tsx"

mkdir -p "afrifx-web/app/(app)/marketplace/create"
cat > "afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES      = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}
const TIMER_OPTIONS = [
  { label: '30 min',  value: 1800 },
  { label: '1 hour',  value: 3600 },
  { label: '2 hours', value: 7200 },
  { label: 'Custom',  value: 0    },
]

export function CreateOfferClient() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,     setOrderType]     = useState<OrderType>('market')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [limitOffset,   setLimitOffset]   = useState(0)
  const [timerOption,   setTimerOption]   = useState(1800)
  const [customTimer,   setCustomTimer]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch (_e) {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create P2P offer</h1>
          <p className="text-sm text-app-muted">Lock USDC in escrow — perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-app-border bg-app-surface p-1">
          <button onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Description */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-app-accent-text" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate.'}
          </div>
        </div>

        {/* USDC + currency */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-app-muted">
              Balance: <span className="text-app-text">{balance}</span>
            </span>
          </div>
          <div className="flex gap-2">
            <select value={localCurrency} onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none">
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input type="number" placeholder="0.00" value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className="flex-1 font-mono text-lg" />
          </div>
        </div>

        {/* Rate display + limit slider */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-app-muted">Live market rate</span>
              <span className="font-mono text-app-text">1 USDC = {marketRate.toLocaleString()} {localCurrency}</span>
            </div>
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-app-muted">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-app-text'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input type="range" min="-5" max="5" step="0.5" value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-app-accent" />
                <div className="mt-1 flex justify-between text-[10px] text-app-muted">
                  <span>-5%</span><span>Market</span><span>+5%</span>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated receive */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-app-muted">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-app-text">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-app-muted">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Timer */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Taker completion window
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            {TIMER_OPTIONS.map((opt) => (
              <button key={opt.value} onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-app-accent text-app-on-accent'
                    : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input type="number" placeholder="Minutes (min 5, max 1440)"
                value={customTimer} onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono" />
              <span className="text-xs text-app-muted">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-app-muted">
            If taker doesn't send {localCurrency} within this window, the offer automatically cancels and USDC returns to you.
          </p>
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs">
            <p className="mb-2 font-medium text-app-text">Order summary</p>
            <div className="space-y-1.5 text-app-muted">
              {[
                ['Order type', orderType],
                ['You lock',   `${usdcAmount} USDC`],
                ['You receive', `${localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${localCurrency}`],
                ['Taker window', timerSeconds >= 3600 ? `${timerSeconds/3600}h` : `${timerSeconds/60}min`],
                ['Duration',    'Perpetual until filled or cancelled'],
                ['Platform fee', `${(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span>{label}</span>
                  <span className="text-app-text">{val}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Trade flow reminder */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <p className="mb-1 font-medium text-app-text">Trade flow</p>
          <ol className="space-y-0.5">
            {[
              'You lock USDC in vault escrow',
              `Taker accepts + sends ${localCurrency} to you within the window`,
              'Taker confirms: "I sent the money"',
              'You confirm: "I received it"',
              'Platform releases USDC to taker',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button className="w-full" size="lg" onClick={handleCreate}
            disabled={
              isLoading || !usdcAmount || localAmount <= 0 || timerSeconds < 300 ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }>
            {isLoading
              ? 'Locking USDC in escrow…'
              : `Create ${orderType} order — ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx"

mkdir -p "afrifx-web/app/(app)/marketplace"
cat > "afrifx-web/app/(app)/marketplace/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { UserDisplay } from '@/components/profile/UserDisplay'
import { useP2P } from '@/hooks/useP2P'
import { arcTestnet } from '@/lib/arc-chain'
import { Plus, Clock, Zap, ShieldCheck, Loader2, ArrowRight, CheckCircle } from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8] ?? 0),
      taker_confirmed: Number(row[9] ?? 0),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: Number(row[12]), created_at: Number(row[13]),
      updated_at: Number(row[14]),
      order_type: row[15] ?? 'market',
      maker_timer_seconds: Number(row[17] ?? 1800),
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
}

function formatTimer(secs: number): string {
  if (secs >= 7200) return `${secs / 3600}h window`
  if (secs >= 3600) return '1h window'
  return `${Math.round(secs / 60)}min window`
}

// Accept states for clear UX
type AcceptState =
  | { phase: 'idle' }
  | { phase: 'signing';     offerId: string }
  | { phase: 'confirming';  offerId: string; txHash: string }
  | { phase: 'updating_db'; offerId: string }
  | { phase: 'done';        offerId: string }

export default function MarketplacePage() {
  const { address }                    = useAccount()
  const router                         = useRouter()
  const publicClient                   = usePublicClient({ chainId: arcTestnet.id })
  const [offers,   setOffers]          = useState<P2POffer[]>([])
  const [loading,  setLoading]         = useState(true)
  const [currency, setCurrency]        = useState('all')
  const [acceptState, setAcceptState]  = useState<AcceptState>({ phase: 'idle' })
  const { acceptOffer, error: p2pErr } = useP2P()

  async function load() {
    setLoading(true)
    try {
      const url = currency === 'all' ? `${API}/offers` : `${API}/offers?currency=${currency}`
      const res = await fetch(url)
      const data = await res.json()
      setOffers(Array.isArray(data) ? data.map(normalizeOffer) : [])
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address || acceptState.phase !== 'idle') return
    const timerSecs = (offer as any).maker_timer_seconds ?? 1800

    try {
      // Step 1: Sign + submit tx
      setAcceptState({ phase: 'signing', offerId: offer.id })
      const hash = await acceptOffer(offer.id as `0x${string}`, timerSecs)

      // Step 2: Wait for on-chain confirmation
      setAcceptState({ phase: 'confirming', offerId: offer.id, txHash: hash as string })
      if (publicClient) {
        await publicClient.waitForTransactionReceipt({
          hash: hash as `0x${string}`,
        })
      }

      // Step 3: Update DB immediately (don't rely on event listener timing)
      setAcceptState({ phase: 'updating_db', offerId: offer.id })
      await fetch(`${API}/offers/${offer.id}/accept`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          takerAddress:  address,
          timerSeconds:  timerSecs,
        }),
      }).catch(() => {}) // Non-fatal — watcher will catch it

      // Step 4: DB is updated — safe to redirect now
      setAcceptState({ phase: 'done', offerId: offer.id })

      // Small delay so user sees the success state
      await new Promise(r => setTimeout(r, 600))

      router.push(`/marketplace/${offer.id}?accepted=1`)
    } catch (err: any) {
      // User rejected or tx failed
      setAcceptState({ phase: 'idle' })
    }
  }

  const busyId = acceptState.phase !== 'idle' ? acceptState.offerId : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">P2P Marketplace</h1>
          <p className="text-sm text-app-muted">Buy USDC directly from verified traders.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> Create offer</Button>
        </Link>
      </div>

      {/* Global accepting banner */}
      {acceptState.phase !== 'idle' && (
        <div className="mb-4 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3">
          <div className="flex items-center gap-3">
            {acceptState.phase === 'done'
              ? <CheckCircle className="h-5 w-5 shrink-0 text-emerald-400" />
              : <Loader2 className="h-5 w-5 shrink-0 animate-spin text-app-accent-text" />
            }
            <div>
              <p className="text-sm font-medium text-app-text">
                {acceptState.phase === 'signing'     && 'Waiting for wallet signature…'}
                {acceptState.phase === 'confirming'  && 'Confirming on Arc blockchain…'}
                {acceptState.phase === 'updating_db' && 'Finalising trade setup…'}
                {acceptState.phase === 'done'        && 'Trade accepted! Redirecting…'}
              </p>
              <p className="text-xs text-app-muted">
                {acceptState.phase === 'signing'     && 'Please approve the transaction in your wallet'}
                {acceptState.phase === 'confirming'  && 'This usually takes a few seconds'}
                {acceptState.phase === 'updating_db' && 'Almost there…'}
                {acceptState.phase === 'done'        && 'Taking you to the settlement interface'}
              </p>
            </div>
          </div>
          {/* Step progress */}
          <div className="mt-3 flex items-center gap-2">
            {[
              { key: 'signing',     label: 'Sign' },
              { key: 'confirming',  label: 'Confirm' },
              { key: 'updating_db', label: 'Finalise' },
              { key: 'done',        label: 'Done' },
            ].map(({ key, label }, idx) => {
              const phases = ['signing','confirming','updating_db','done']
              const currentIdx = phases.indexOf(acceptState.phase)
              const stepIdx    = phases.indexOf(key)
              const isDone     = stepIdx < currentIdx || acceptState.phase === 'done'
              const isActive   = stepIdx === currentIdx && acceptState.phase !== 'done'
              return (
                <div key={key} className="flex items-center gap-2">
                  <div className={`flex h-6 w-6 items-center justify-center rounded-full text-[10px] font-bold transition-colors
                    ${isDone    ? 'bg-emerald-500 text-white'
                    : isActive  ? 'bg-app-accent text-app-on-accent'
                    :             'bg-app-border text-app-muted'}`}>
                    {isDone ? '✓' : idx + 1}
                  </div>
                  <span className={`text-xs ${isActive || isDone ? 'text-app-text' : 'text-app-muted'}`}>
                    {label}
                  </span>
                  {idx < 3 && <div className="h-px w-4 bg-app-border" />}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Trust badges */}
      <div className="mb-6 flex flex-wrap gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow'   },
          { icon: Zap,         label: 'Arc settlement'   },
          { icon: Clock,       label: 'Perpetual orders' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-muted">
            <Icon className="h-3.5 w-3.5 text-app-accent-text" />{label}
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all','NGN','GHS','KES','ZAR','EGP'].map(c => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-app-accent text-app-on-accent'
                : 'border border-app-border text-app-muted hover:text-app-text'}`}>
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c]} ${c}`}
          </button>
        ))}
        <button onClick={load}
          className="ml-auto rounded-full border border-app-border px-3 py-1 text-xs text-app-muted hover:text-app-text">
          ↻ Refresh
        </button>
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <p className="text-sm text-app-muted">No open offers right now.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create the first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const timer  = (offer as any).maker_timer_seconds ?? 1800
          const type   = (offer as any).order_type ?? 'market'
          const isBusy = busyId === offer.id

          return (
            <div key={offer.id}
              className={`rounded-xl border bg-app-surface p-4 transition-colors
                ${isBusy ? 'border-app-accent/40' : 'border-app-border'}`}>
              <div className="flex items-center gap-4">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-bg text-xl">
                  {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
                </div>

                <div className="flex-1 min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-app-text">
                      {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      <span className="mx-1.5 text-app-muted">→</span>
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                    </p>
                    {isOwn && <Badge variant="arc">Your offer</Badge>}
                    <Badge variant={type === 'limit' ? 'warning' : 'arc'}>{type}</Badge>
                  </div>
                  <div className="mt-1.5 flex flex-wrap items-center gap-3">
                    <ClientOnly fallback={<span className="text-xs text-app-muted">…</span>}>
                      <UserDisplay address={offer.maker_address} size="xs" suffix={isOwn ? '(you)' : undefined} />
                    </ClientOnly>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="text-xs text-app-muted">
                      1 USDC = {Number(offer.rate_offered) > 0
                        ? (1 / Number(offer.rate_offered)).toFixed(2)
                        : '—'} {offer.local_currency}
                    </span>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="flex items-center gap-1 text-xs text-app-muted">
                      <Clock className="h-3 w-3" />{formatTimer(timer)}
                    </span>
                  </div>
                </div>

                <div className="shrink-0">
                  {isOwn ? (
                    <Link href={`/marketplace/${offer.id}`}>
                      <Button variant="outline" size="sm">
                        Manage <ArrowRight className="h-3.5 w-3.5" />
                      </Button>
                    </Link>
                  ) : (
                    <ClientOnly>
                      <Button size="sm"
                        onClick={() => handleAccept(offer)}
                        disabled={!address || !!busyId}>
                        {isBusy ? (
                          <><Loader2 className="h-3.5 w-3.5 animate-spin" />
                          {acceptState.phase === 'signing'    ? 'Signing…'
                          : acceptState.phase === 'confirming' ? 'Confirming…'
                          : acceptState.phase === 'done'       ? 'Redirecting…'
                          : 'Processing…'}
                          </>
                        ) : 'Buy USDC'}
                      </Button>
                    </ClientOnly>
                  )}
                </div>
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/marketplace/page.tsx"

mkdir -p "afrifx-web/app/(app)/pay/[ref]"
cat > "afrifx-web/app/(app)/pay/[ref]/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits } from 'viem'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useCreatePayment } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs, MEMO_ADDRESS } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import {
  FileText, CheckCircle, AlertCircle,
  Loader2, ExternalLink, Wallet, XCircle,
  ArrowRight,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type PayStatus =
  | 'idle'
  | 'submitting'
  | 'confirming'
  | 'success'
  | 'failed'
  | 'error'

export default function PayPage() {
  return <ClientOnly><PayContent /></ClientOnly>
}

function PayContent() {
  const { ref }                          = useParams()
  const { address, isConnected }         = useAccount()
  const publicClient                     = usePublicClient({ chainId: arcTestnet.id })
  const { data: invoice, isLoading }     = useInvoiceByRef(ref as string)
  const { data: rates = [] }             = useFXRates()
  const createPayment                    = useCreatePayment()
  const { writeContractAsync }           = useWriteContract()

  const [status, setStatus] = useState<PayStatus>('idle')
  const [txHash, setTxHash] = useState<string | null>(null)
  const [errMsg, setErrMsg] = useState<string | null>(null)

  // ── Convert invoice amount to USDC ──────────────────────────
  // Invoice can be in any currency (NGN, GHS, KES, ZAR, EGP, EURC, USDC)
  // Transfer always happens in USDC on-chain
  function getUSDCAmount(amount: number, currency: string): number {
    if (currency === 'USDC') return amount

    if (currency === 'EURC') {
      // EURC/USDC rate = local units per USDC (inverted for EUR)
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }

    // Local currency: rate = local units per 1 USDC
    // So usdcAmount = localAmount / rate
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate || rate <= 0) return 0
    return amount / rate
  }

  if (isLoading) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!invoice) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <AlertCircle className="h-8 w-8 text-red-400" />
      <p className="text-sm text-app-muted">Invoice not found</p>
    </div>
  )

  // USDC amount the payer will actually send on-chain
  const usdcAmount     = getUSDCAmount(invoice.amount, invoice.currency)
  const isLocalCcy     = invoice.currency !== 'USDC' && invoice.currency !== 'EURC'
  const ratesLoaded    = rates.length > 0
  const rateAvailable  = !isLocalCcy || usdcAmount > 0

  const alreadyPaid  = invoice.status === 'paid'
  const isCancelled  = invoice.status === 'cancelled'
  const isCreator    = address?.toLowerCase() === invoice.creator_address.toLowerCase()
  const wrongPayer   = invoice.payer_address &&
    address?.toLowerCase() !== invoice.payer_address.toLowerCase()

  async function handlePay() {
    if (!address || !isConnected || !invoice || usdcAmount <= 0) return
    setStatus('submitting')
    setErrMsg(null)
    setTxHash(null)

    let hash: `0x${string}` | null = null

    try {
      // Always transfer in USDC regardless of invoice currency
      const usdcRaw = parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)
      const memoId  = buildMemoId(`invoice-${invoice.memo_ref}`)
      const target  = invoice.creator_address as `0x${string}`

      const code = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!code && code !== '0x'

      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, target, usdcAmount, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'p2p-create', ref: invoice.memo_ref },
        )
        hash = await writeContractAsync(args)
      } else {
        hash = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [target, usdcRaw],
        })
      }

      setTxHash(hash)
      setStatus('confirming')

      // Check on-chain status — NEVER skip this
      let receiptStatus: 'success' | 'reverted' = 'success'
      if (publicClient) {
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        receiptStatus = receipt.status
      }

      if (receiptStatus === 'reverted') {
        setStatus('failed')
        await createPayment.mutateAsync({
          recipientAddress: invoice.creator_address,
          amount:           usdcAmount,
          currency:         'USDC',
          description:      `FAILED: ${invoice.description ?? invoice.memo_ref}`,
          invoiceRef:       invoice.memo_ref,
          arcTxHash:        hash,
          status:           'failed',
        } as any).catch(() => {})
        return
      }

      // ── SUCCESS ────────────────────────────────────────────
      // Mark invoice paid
      await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ txHash: hash, payerAddress: address, usdcAmount }),
      })

      // Record payment in USDC (actual on-chain amount)
      await createPayment.mutateAsync({
        recipientAddress: invoice.creator_address,
        amount:           usdcAmount,
        currency:         'USDC',
        description:      invoice.description ?? invoice.memo_ref,
        invoiceRef:       invoice.memo_ref,
        arcTxHash:        hash,
      })

      setStatus('success')

    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setStatus('error')
      setErrMsg(msg)
      if (hash) {
        await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
          method:  'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ txHash: hash, status: 'failed' }),
        }).catch(() => {})
      }
    }
  }

  return (
    <div className="mx-auto max-w-lg">
      <div className="rounded-2xl border border-app-border bg-app-surface p-6">

        {/* Header */}
        <div className="mb-5 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-app-bg">
            <FileText className="h-6 w-6 text-app-accent-text" />
          </div>
          <div>
            <p className="text-sm font-medium text-app-text">Payment request</p>
            <p className="font-mono text-xs text-app-accent-text">{invoice.memo_ref}</p>
          </div>
          <Badge className="ml-auto" variant={
            alreadyPaid ? 'success' : isCancelled ? 'danger' : 'arc'
          }>
            {invoice.status}
          </Badge>
        </div>

        {/* Amount — show original + USDC equivalent */}
        <div className="mb-5 rounded-xl bg-app-bg p-5 text-center">
          <p className="text-xs text-app-muted">Amount due</p>
          <p className="mt-1 font-mono text-4xl font-bold text-app-text">
            {formatAmount(invoice.amount)}
          </p>
          <p className="text-sm text-app-accent-text">{invoice.currency}</p>

          {/* USDC conversion — shown when invoice is in local currency */}
          {isLocalCcy && (
            <div className="mt-3 flex items-center justify-center gap-2">
              <span className="text-xs text-app-muted">You will pay</span>
              <div className="flex items-center gap-1.5 rounded-full border border-app-accent/30 bg-app-accent/10 px-3 py-1">
                <ArrowRight className="h-3 w-3 text-app-accent-text" />
                {!ratesLoaded ? (
                  <span className="text-xs text-app-muted animate-pulse">Loading rate…</span>
                ) : usdcAmount > 0 ? (
                  <span className="font-mono text-sm font-semibold text-app-accent-text">
                    {formatAmount(usdcAmount, 6)} USDC
                  </span>
                ) : (
                  <span className="text-xs text-red-400">Rate unavailable</span>
                )}
              </div>
            </div>
          )}

          {/* Rate used */}
          {isLocalCcy && usdcAmount > 0 && (
            <p className="mt-1.5 text-[10px] text-app-muted">
              Rate: 1 USDC = {rates.find(r => r.pair === `${invoice.currency}/USDC`)?.rate.toLocaleString()} {invoice.currency}
            </p>
          )}
        </div>

        {/* Invoice details */}
        <div className="mb-5 space-y-2 text-xs">
          {[
            ['From',        invoice.creator_address.slice(0,12) + '…'],
            ['Description', invoice.description ?? '—'],
            ['Due',         invoice.due_date
              ? new Date(invoice.due_date * 1000).toLocaleDateString()
              : 'No deadline'],
          ].map(([l, v]) => (
            <div key={l} className="flex justify-between">
              <span className="text-app-muted">{l}</span>
              <span className="text-app-text">{v}</span>
            </div>
          ))}
          {invoice.notes && (
            <div className="rounded-lg bg-app-bg p-2.5 text-app-muted">{invoice.notes}</div>
          )}
        </div>

        {/* Payment status UI */}
        {status === 'success' ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
            <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
            <p className="font-medium text-emerald-400">Payment confirmed on-chain!</p>
            <p className="mt-1 text-xs text-emerald-600">
              {formatAmount(usdcAmount, 6)} USDC sent · Invoice marked as paid
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
              </a>
            )}
          </div>

        ) : status === 'failed' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-center">
            <XCircle className="mx-auto mb-2 h-8 w-8 text-red-400" />
            <p className="font-medium text-red-400">Transaction reverted on-chain</p>
            <p className="mt-1 text-xs text-red-600">
              The transaction failed on Arc. Your USDC was not deducted.
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-red-400 hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View failed tx
              </a>
            )}
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setTxHash(null); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'error' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4">
            <div className="flex items-start gap-2">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-400" />
              <div>
                <p className="text-sm font-medium text-red-400">Payment failed</p>
                <p className="mt-0.5 text-xs text-red-600">{errMsg}</p>
              </div>
            </div>
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'submitting' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div>
                <p className="text-sm font-medium text-app-text">Waiting for signature…</p>
                <p className="text-xs text-app-muted">Approve in your wallet</p>
              </div>
            </div>
          </div>

        ) : status === 'confirming' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div className="flex-1">
                <p className="text-sm font-medium text-app-text">Confirming on Arc…</p>
                <p className="text-xs text-app-muted">Waiting for on-chain confirmation</p>
              </div>
            </div>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> Track on ArcScan
              </a>
            )}
          </div>

        ) : alreadyPaid ? (
          <div className="rounded-xl bg-emerald-900/20 p-4 text-center text-sm text-emerald-400">
            ✓ This invoice has already been paid
          </div>

        ) : isCancelled ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-sm text-red-400">
            This invoice has been cancelled
          </div>

        ) : isCreator ? (
          <div className="rounded-xl bg-amber-900/20 p-4 text-center text-xs text-amber-400">
            You created this invoice — share this link with your payer
          </div>

        ) : wrongPayer ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            This invoice is addressed to a specific wallet — connected wallet doesn't match
          </div>

        ) : !isConnected ? (
          <div className="rounded-xl bg-app-bg p-4 text-center text-sm text-app-muted">
            <Wallet className="mx-auto mb-2 h-6 w-6" />
            Connect your wallet to pay this invoice
          </div>

        ) : !ratesLoaded && isLocalCcy ? (
          <div className="rounded-xl bg-app-bg p-4 text-center text-xs text-app-muted">
            <Loader2 className="mx-auto mb-2 h-5 w-5 animate-spin" />
            Loading exchange rates…
          </div>

        ) : !rateAvailable ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            Exchange rate for {invoice.currency} is currently unavailable.
            Please try again in a moment.
          </div>

        ) : (
          <>
            <Button className="w-full" size="lg" onClick={handlePay}>
              Pay {isLocalCcy
                ? `${formatAmount(usdcAmount, 4)} USDC (≈ ${formatAmount(invoice.amount)} ${invoice.currency})`
                : `${formatAmount(invoice.amount)} USDC`
              }
            </Button>
            <p className="mt-2 text-center text-[10px] text-app-muted">
              {isLocalCcy
                ? `${invoice.currency} converted to USDC at live rate · `
                : ''}
              Memo ref: {invoice.memo_ref}
            </p>
          </>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/pay/[ref]/page.tsx"

mkdir -p "afrifx-web/app/(app)/profile/[username]"
cat > "afrifx-web/app/(app)/profile/[username]/page.tsx" << 'AFX_EOF'
'use client'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useProfileByUsername } from '@/hooks/useProfile'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ArrowLeft, Twitter, AtSign, ExternalLink, ShieldCheck } from 'lucide-react'

export default function PublicProfilePage() {
  const { username }        = useParams()
  const { data: profile, isLoading } = useProfileByUsername(username as string)

  if (isLoading) return (
    <div className="space-y-4">
      <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
    </div>
  )

  if (!profile) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-app-text">Profile not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const totalTrades = (profile.maker_trades ?? 0) + (profile.taker_trades ?? 0)
  const reputation  = totalTrades >= 10 && profile.dispute_count === 0
    ? 'Elite' : totalTrades >= 5 ? 'Trusted' : totalTrades >= 1 ? 'Active' : 'New'
  const repColor = {
    Elite: 'text-amber-400', Trusted: 'text-emerald-400',
    Active: 'text-app-accent-text', New: 'text-app-muted',
  }[reputation]

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <h1 className="text-xl font-semibold text-app-text">Trader profile</h1>
      </div>

      <div className="max-w-lg space-y-4">
        <div className="rounded-xl border border-app-border bg-app-surface p-6">
          <div className="mb-4 flex items-center gap-4">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="lg"
              verified={profile.verified}
            />
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-lg font-semibold text-app-text">{profile.display_name}</h2>
                {profile.verified && (
                  <Badge variant="arc"><ShieldCheck className="h-3 w-3" /> Verified</Badge>
                )}
              </div>
              <p className="text-sm text-app-accent-text">@{profile.username}</p>
              {profile.bio && <p className="mt-1 text-xs text-app-muted">{profile.bio}</p>}
            </div>
          </div>

          {/* Stats */}
          <div className="mb-4 grid grid-cols-3 gap-2">
            {[
              { label: 'Reputation', value: reputation, color: repColor },
              { label: 'Trades',     value: String(totalTrades),          color: 'text-app-text' },
              { label: 'Disputes',   value: String(profile.dispute_count), color: profile.dispute_count > 0 ? 'text-red-400' : 'text-emerald-400' },
            ].map(({ label, value, color }) => (
              <div key={label} className="rounded-lg bg-app-bg p-3 text-center">
                <p className="text-[10px] text-app-muted">{label}</p>
                <p className={`mt-1 text-base font-bold ${color}`}>{value}</p>
              </div>
            ))}
          </div>

          {/* Socials */}
          {(profile.twitter_handle || profile.telegram_handle) && (
            <div className="space-y-1.5 border-t border-app-border pt-4 text-xs text-app-muted">
              {profile.twitter_handle && (
                <a href={`https://twitter.com/${profile.twitter_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
            </div>
          )}
        </div>

        <p className="text-center text-xs text-app-muted">
          Member since {new Date(profile.created_at * 1000).toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}
        </p>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/profile/[username]/page.tsx"

mkdir -p "afrifx-web/app/(app)/profile"
cat > "afrifx-web/app/(app)/profile/page.tsx" << 'AFX_EOF'
'use client'
import { EmailPreferences } from '@/components/notifications/EmailPreferences'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import {
  Twitter, AtSign, Edit2, CheckCircle,
  Loader2, ExternalLink, Star, ShieldCheck,
  TrendingUp, AlertTriangle, Copy, Check,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function ProfilePage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-32 animate-pulse rounded-xl bg-app-surface" />
      </div>
    }>
      <ProfileContent />
    </ClientOnly>
  )
}

function ProfileContent() {
  const { address }                    = useAccount()
  const { data: profile, refetch }     = useProfile()
  const queryClient                    = useQueryClient()

  const [editing,     setEditing]     = useState(false)
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [saving,      setSaving]      = useState(false)
  const [copied,      setCopied]      = useState(false)

  function startEdit() {
    if (!profile) return
    setDisplayName(profile.display_name)
    setBio(profile.bio ?? '')
    setTwitter(profile.twitter_handle ?? '')
    setTelegram(profile.telegram_handle ?? '')
    setShowSocials(profile.show_socials)
    setEditing(true)
  }

  async function saveEdit() {
    if (!address) return
    setSaving(true)
    try {
      await fetch(`${API}/profile/${address}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          displayName, bio,
          twitterHandle: twitter, telegramHandle: telegram, showSocials,
        }),
      })
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      await refetch()
      setEditing(false)
    } finally { setSaving(false) }
  }

  function copyAddress() {
    if (!address) return
    navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (!profile) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
      </div>
    )
  }

  // Use live counts from subquery (never 0 if trades exist)
  const makerTrades   = Number((profile as any).maker_trades   ?? 0)
  const takerTrades   = Number((profile as any).taker_trades   ?? 0)
  const totalTrades   = makerTrades + takerTrades
  const totalDisputes = Number((profile as any).total_disputes ?? profile.dispute_count ?? 0)

  // Reputation tiers
  const reputation =
    totalTrades >= 20 && totalDisputes === 0 ? 'Elite' :
    totalTrades >= 10 && totalDisputes === 0 ? 'Verified' :
    totalTrades >= 5  ? 'Trusted' :
    totalTrades >= 1  ? 'Active'  : 'New'

  const isVerified = totalTrades >= 10 && totalDisputes === 0

  const repColor = {
    Elite:    'text-amber-400',
    Verified: 'text-app-accent-text',
    Trusted:  'text-emerald-400',
    Active:   'text-emerald-400',
    New:      'text-app-muted',
  }[reputation]

  const repBg = {
    Elite:    'bg-amber-900/20 border-amber-900/40',
    Verified: 'bg-app-accent/10 border-app-accent/30',
    Trusted:  'bg-emerald-900/20 border-emerald-900/40',
    Active:   'bg-emerald-900/10 border-emerald-900/20',
    New:      'bg-app-border border-app-border',
  }[reputation]

  // Progress to next tier
  const nextTier = totalTrades < 1 ? { label: 'Active', need: 1, current: totalTrades }
    : totalTrades < 5  ? { label: 'Trusted',  need: 5,  current: totalTrades }
    : totalTrades < 10 ? { label: 'Verified', need: 10, current: totalTrades }
    : totalTrades < 20 ? { label: 'Elite',    need: 20, current: totalTrades }
    : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">My profile</h1>
        {!editing && (
          <Button variant="outline" size="sm" onClick={startEdit}>
            <Edit2 className="h-3.5 w-3.5" /> Edit
          </Button>
        )}
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-3">

        {/* Profile card */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex flex-col items-center gap-3 text-center">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="xl"
              verified={isVerified}
            />
            {editing ? (
              <Input value={displayName} onChange={e => setDisplayName(e.target.value)}
                className="text-center" />
            ) : (
              <div>
                <div className="flex items-center justify-center gap-2">
                  <h2 className="text-lg font-semibold text-app-text">
                    {profile.display_name}
                  </h2>
                  {isVerified && <Badge variant="arc">✓ Verified</Badge>}
                </div>
                <p className="text-sm text-app-accent-text">@{profile.username}</p>
              </div>
            )}
          </div>

          {/* Bio */}
          {editing ? (
            <textarea value={bio} onChange={e => setBio(e.target.value)}
              placeholder="Add a bio…" maxLength={160} rows={3}
              className="mb-3 w-full resize-none rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent" />
          ) : profile.bio ? (
            <p className="mb-4 text-center text-sm text-app-muted">{profile.bio}</p>
          ) : null}

          {/* Wallet address */}
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2">
            <div className="flex-1 min-w-0">
              <p className="text-[10px] text-app-muted">Wallet</p>
              <p className="truncate font-mono text-xs text-app-text">
                {address?.slice(0,10)}…{address?.slice(-6)}
              </p>
            </div>
            <button onClick={copyAddress} className="shrink-0 text-app-muted hover:text-app-text">
              {copied
                ? <Check className="h-3.5 w-3.5 text-emerald-400" />
                : <Copy className="h-3.5 w-3.5" />
              }
            </button>
            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-app-muted hover:text-app-accent-text">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>

          {/* Socials */}
          {editing ? (
            <div className="space-y-2">
              <div className="relative">
                <Twitter className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-app-muted" />
                <Input value={twitter} onChange={e => setTwitter(e.target.value.replace('@',''))}
                  placeholder="Twitter handle" className="pl-8 text-sm" />
              </div>
              <div className="relative">
                <AtSign className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-app-muted" />
                <Input value={telegram} onChange={e => setTelegram(e.target.value.replace('@',''))}
                  placeholder="Telegram handle" className="pl-8 text-sm" />
              </div>
              <div className="flex items-center justify-between text-xs">
                <span className="text-app-muted">Show socials publicly</span>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-5 w-9 rounded-full transition-colors ${showSocials ? 'bg-app-accent' : 'bg-app-border'}`}>
                  <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-4' : 'translate-x-0.5'}`} />
                </button>
              </div>
            </div>
          ) : (
            <div className="space-y-1.5 text-xs text-app-muted">
              {profile.twitter_handle && (
                <a href={`https://twitter.com/${profile.twitter_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-app-text">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {!profile.twitter_handle && !profile.telegram_handle && (
                <p className="text-center">No socials added yet</p>
              )}
            </div>
          )}

          {editing && (
            <div className="mt-4 flex gap-2">
              <Button variant="outline" className="flex-1" onClick={() => setEditing(false)}>Cancel</Button>
              <Button className="flex-1" onClick={saveEdit} disabled={saving}>
                {saving ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save'}
              </Button>
            </div>
          )}
        </div>

        {/* Reputation + Stats */}
        <div className="lg:col-span-2 space-y-4">

          {/* Reputation banner */}
          <div className={`rounded-xl border p-5 ${repBg}`}>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className={`flex h-12 w-12 items-center justify-center rounded-full border ${repBg}`}>
                  <Star className={`h-6 w-6 ${repColor}`} />
                </div>
                <div>
                  <p className={`text-lg font-bold ${repColor}`}>{reputation} Trader</p>
                  <p className="text-xs text-app-muted">
                    {totalTrades} completed trade{totalTrades !== 1 ? 's' : ''} ·{' '}
                    {totalDisputes === 0
                      ? 'Clean record'
                      : `${totalDisputes} dispute${totalDisputes !== 1 ? 's' : ''}`}
                  </p>
                </div>
              </div>
              {isVerified && (
                <div className="flex items-center gap-2 rounded-full bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent-text">
                  <ShieldCheck className="h-3.5 w-3.5" />
                  Verified
                </div>
              )}
            </div>

            {/* Progress to next tier */}
            {nextTier && (
              <div className="mt-4">
                <div className="mb-1 flex justify-between text-xs">
                  <span className="text-app-muted">Progress to {nextTier.label}</span>
                  <span className="text-app-text">
                    {nextTier.current}/{nextTier.need} trades
                    {totalDisputes > 0 ? ' · disputes blocking upgrade' : ''}
                  </span>
                </div>
                <div className="h-1.5 w-full overflow-hidden rounded-full bg-app-border">
                  <div
                    className={`h-full rounded-full transition-all ${repColor.replace('text-','bg-')}`}
                    style={{ width: `${Math.min(100, (nextTier.current / nextTier.need) * 100)}%` }}
                  />
                </div>
              </div>
            )}
          </div>

          {/* Stats grid */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {[
              {
                label: 'Total trades',
                value: String(totalTrades),
                icon:  TrendingUp,
                color: 'text-emerald-400',
                sub:   `${makerTrades} as maker · ${takerTrades} as taker`,
              },
              {
                label: 'Maker trades',
                value: String(makerTrades),
                icon:  TrendingUp,
                color: 'text-app-accent-text',
                sub:   'Offers you created',
              },
              {
                label: 'Taker trades',
                value: String(takerTrades),
                icon:  TrendingUp,
                color: 'text-app-accent-text',
                sub:   'Offers you accepted',
              },
              {
                label: 'Disputes',
                value: String(totalDisputes),
                icon:  totalDisputes > 0 ? AlertTriangle : CheckCircle,
                color: totalDisputes > 0 ? 'text-red-400' : 'text-emerald-400',
                sub:   totalDisputes === 0 ? 'Clean record ✓' : 'Raised against you',
              },
            ].map(({ label, value, icon: Icon, color, sub }) => (
              <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4 text-center">
                <Icon className={`mx-auto mb-1 h-4 w-4 ${color}`} />
                <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
                <p className="mt-0.5 text-xs font-medium text-app-text">{label}</p>
                <p className="mt-0.5 text-[10px] text-app-muted">{sub}</p>
              </div>
            ))}
          </div>

          {/* Shareable profile link */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-2 text-sm font-medium text-app-text">Public profile link</p>
            <div className="flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2">
              <p className="flex-1 truncate font-mono text-xs text-app-accent-text">
                {typeof window !== 'undefined' ? window.location.origin : ''}/profile/{profile.username}
              </p>
              <button
                onClick={() => navigator.clipboard.writeText(
                  `${window.location.origin}/profile/${profile.username}`
                )}
                className="shrink-0 text-xs text-app-muted hover:text-app-text">
                Copy
              </button>
            </div>
            <p className="mt-2 text-xs text-app-muted">
              Share this link so traders can verify your reputation before trading with you.
            </p>
          </div>

          {/* Email notification preferences */}
          <EmailPreferences />
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/profile/page.tsx"

mkdir -p "afrifx-web/app/(app)/send"
cat > "afrifx-web/app/(app)/send/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { Loader2, CheckCircle, Zap, AlertCircle } from 'lucide-react'

export default function SendPage() {
  const { isConnected }        = useAccount()
  const [to,     setTo]        = useState('')
  const [amount, setAmount]    = useState('')
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const { writeContractAsync, isPending } = useWriteContract()
  const [txHash, setTxHash]    = useState<`0x${string}` | undefined>()
  const { isSuccess }          = useWaitForTransactionReceipt({ hash: txHash })

  const amountNum     = parseFloat(amount) || 0
  const balanceNum    = parseFloat(balance) || 0
  const insufficientFunds = amountNum > 0 && amountNum > balanceNum
  const validAddress  = isAddress(to)
  const validAmount   = amountNum > 0 && !insufficientFunds
  const valid         = validAddress && validAmount

  // Max button — fill in full balance
  function setMax() {
    setAmount(balanceNum.toFixed(6))
  }

  async function handleSend() {
    if (!valid) return
    const hash = await writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    setTo('')
    setAmount('')
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">Send USDC to any Arc address instantly.</p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Balance */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="text-app-muted">Available balance</span>
          <span className="font-mono text-app-text">{balance} USDC</span>
        </div>

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient (Arc address)
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
            <button onClick={setMax}
              className="text-xs text-app-accent-text hover:underline">
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

          {/* Insufficient funds warning */}
          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance — you only have {balance} USDC
            </div>
          )}

          {/* Valid amount preview */}
          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(balanceNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Fee info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Chain</span>
            <span className="text-app-text">Arc Testnet · ID 5042002</span>
          </div>
        </div>

        {/* Send button — disabled when insufficient */}
        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !valid || isPending || insufficientFunds}>
          {isPending
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/send/page.tsx"

mkdir -p "afrifx-web/app/(app)/settlements"
cat > "afrifx-web/app/(app)/settlements/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useSettlementReport } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { formatAmount } from '@/lib/utils'
import { Download, Loader2, TrendingUp, TrendingDown, ExternalLink } from 'lucide-react'

export default function SettlementsPage() {
  return <ClientOnly><SettlementsContent /></ClientOnly>
}

function SettlementsContent() {
  const { address }          = useAccount()
  const { data: rates = [] } = useFXRates()
  const [range,    setRange] = useState('30')
  const [activeTab, setTab]  = useState<'sent'|'received'|'invoices'|'transactions'>('sent')

  const now    = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  const { data, isLoading } = useSettlementReport(fromTs, now)

  // Convert any amount to USD using live rates
  function toUSD(amount: number, currency: string): number {
    if (!amount) return 0
    if (currency === 'USDC' || currency === 'USD') return amount
    if (currency === 'EURC') {
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    return rate && rate > 0 ? amount / rate : 0
  }

  function downloadCSV() {
    if (!data) return
    const rows: string[] = []
    rows.push('Type,Reference,Amount,Currency,USD Equivalent,Counterparty,Date,Status,TxHash')

    data.payments.sent.forEach((p: any) => {
      rows.push([
        'Payment Sent', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.recipient_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.payments.received.forEach((p: any) => {
      rows.push([
        'Payment Received', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.sender_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.invoices.forEach((inv: any) => {
      rows.push([
        'Invoice', inv.memo_ref, inv.amount, inv.currency,
        toUSD(inv.amount, inv.currency).toFixed(2),
        inv.creator_address,
        new Date(inv.created_at * 1000).toISOString(),
        inv.status, inv.payment_tx_hash ?? '',
      ].join(','))
    })
    data.transactions.forEach((tx: any) => {
      const fromCcy = tx.from_currency ?? tx[2]
      const fromAmt = Number(tx.from_amount ?? tx[4] ?? 0)
      const toAmt   = Number(tx.to_amount ?? tx[5] ?? 0)
      const toCcy   = tx.to_currency ?? tx[3]
      const usdVal  = toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy)
      rows.push([
        'FX Conversion', tx.reference ?? tx.id, fromAmt, fromCcy,
        usdVal.toFixed(2),
        'AfriFX Vault',
        new Date((Number(tx.created_at) || 0) * 1000).toISOString(),
        tx.status, tx.arc_tx_hash ?? '',
      ].join(','))
    })

    const blob = new Blob([rows.join('\n')], { type: 'text/csv' })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href     = url
    a.download = `afrifx-settlements-${new Date().toISOString().slice(0,10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const tabData = {
    sent:         data?.payments.sent         ?? [],
    received:     data?.payments.received     ?? [],
    invoices:     data?.invoices              ?? [],
    transactions: data?.transactions          ?? [],
  }

  // Compute USD totals from the current tab data
  const totalSentUSD     = (data?.payments.sent     ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const totalReceivedUSD = (data?.payments.received ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const netFlow          = totalReceivedUSD - totalSentUSD

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Settlement reports</h1>
          <p className="text-sm text-app-muted">Full payment history with USD equivalents · exportable</p>
        </div>
        <div className="flex gap-2">
          <select value={range} onChange={e => setRange(e.target.value)}
            className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-text outline-none">
            <option value="7">Last 7 days</option>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last year</option>
          </select>
          <Button size="sm" onClick={downloadCSV} disabled={!data}>
            <Download className="h-4 w-4" /> Export CSV
          </Button>
        </div>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3">
        {[
          {
            label: 'Total sent (USD)',
            value: `$${formatAmount(totalSentUSD)}`,
            icon:  TrendingDown,
            color: 'text-red-400',
          },
          {
            label: 'Total received (USD)',
            value: `$${formatAmount(totalReceivedUSD)}`,
            icon:  TrendingUp,
            color: 'text-emerald-400',
          },
          {
            label: 'Net position',
            value: `${netFlow >= 0 ? '+' : ''}$${formatAmount(Math.abs(netFlow))}`,
            icon:  netFlow >= 0 ? TrendingUp : TrendingDown,
            color: netFlow >= 0 ? 'text-emerald-400' : 'text-red-400',
          },
        ].map(({ label, value, icon: Icon, color }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs text-app-muted">{label}</p>
              <Icon className={`h-4 w-4 ${color}`} />
            </div>
            <p className={`mt-1 font-mono text-xl font-bold ${color}`}>
              {isLoading ? <span className="inline-block h-6 w-24 animate-pulse rounded bg-app-border" /> : value}
            </p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {([
          ['sent',         'Sent'],
          ['received',     'Received'],
          ['invoices',     'Invoices'],
          ['transactions', 'FX conversions'],
        ] as const).map(([t, l]) => (
          <button key={t} onClick={() => setTab(t)}
            className={`rounded-md px-3 py-1.5 text-xs transition-colors
              ${activeTab === t ? 'bg-app-border text-app-text' : 'text-app-muted hover:text-app-text'}`}>
            {l} {data ? `(${tabData[t].length})` : ''}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : tabData[activeTab].length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-8 text-center text-sm text-app-muted">
          No {activeTab} in this period
        </div>
      ) : (
        <div className="rounded-xl border border-app-border bg-app-surface overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-app-border text-left text-xs text-app-muted">
                <th className="px-4 py-3 font-medium">Reference</th>
                <th className="px-4 py-3 font-medium">Amount</th>
                <th className="px-4 py-3 font-medium">USD value</th>
                <th className="px-4 py-3 font-medium">Counterparty</th>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {tabData[activeTab].map((item: any) => {
                const ref      = item.memo_ref ?? item.reference ?? (item.id ?? '').slice(0,12)
                const fromCcy  = item.from_currency ?? item[2]
                const toCcy    = item.to_currency   ?? item[3]
                const fromAmt  = Number(item.from_amount ?? item[4] ?? 0)
                const toAmt    = Number(item.to_amount   ?? item[5] ?? 0)
                const amount   = item.amount ?? fromAmt
                const currency = item.currency ?? fromCcy
                const usdVal   = activeTab === 'transactions'
                  ? (toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy))
                  : toUSD(Number(amount), currency)
                const counterparty = item.recipient_address ?? item.sender_address ?? item.creator_address ?? 'AfriFX Vault'
                const date     = new Date((Number(item.created_at) || 0) * 1000).toLocaleDateString()
                const status   = item.status ?? 'settled'
                const hash     = item.arc_tx_hash ?? item.payment_tx_hash

                return (
                  <tr key={item.id} className="border-b border-app-border/50 last:border-0 hover:bg-app-bg/50 transition-colors">
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-accent-text">{ref}</span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-text">
                        {formatAmount(Number(amount))} {currency}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-emerald-400">
                        ${formatAmount(usdVal)}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-app-muted">
                        {typeof counterparty === 'string' && counterparty.startsWith('0x')
                          ? `${counterparty.slice(0,8)}…`
                          : counterparty}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-xs text-app-muted whitespace-nowrap">{date}</td>
                    <td className="px-4 py-3">
                      <Badge variant={
                        status === 'settled' || status === 'paid' ? 'success' :
                        status === 'failed'  || status === 'cancelled' ? 'danger' : 'warning'
                      }>
                        {status}
                      </Badge>
                    </td>
                    <td className="px-4 py-3">
                      {hash && (
                        <a href={`https://testnet.arcscan.app/tx/${hash}`}
                          target="_blank" rel="noopener noreferrer"
                          className="text-app-muted hover:text-app-accent-text transition-colors">
                          <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/settlements/page.tsx"

mkdir -p "afrifx-web/app/(app)/treasury"
cat > "afrifx-web/app/(app)/treasury/TreasuryContent.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useWallet } from '@/hooks/useWallet'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { useTreasuryRules, useCreateRule, useToggleRule, useDeleteRule } from '@/hooks/useTreasury'
import { useFXRates } from '@/hooks/useFXRate'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Zap, Trash2, Pause, Play,
  AlertTriangle, ArrowRight, Users, Building2,
  ChevronDown, ChevronUp, ExternalLink,
} from 'lucide-react'

const CURRENCIES  = ['NGN','GHS','KES','ZAR','EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬'
}

export function TreasuryContent() {
  const { address }               = useAccount()
  const router                    = useRouter()
  const { data: wallet }          = useWallet()
  const { data: rules = [] }      = useTreasuryRules()
  const { data: batches = [] }    = usePayrollBatches()
  const { data: rates = [] }      = useFXRates()
  const createRule                = useCreateRule()
  const toggleRule                = useToggleRule()
  const deleteRule                = useDeleteRule()

  const [showRuleForm, setShowRuleForm] = useState(false)
  const [ruleName,     setRuleName]     = useState('')
  const [threshold,    setThreshold]    = useState('')
  const [actionType,   setActionType]   = useState<'percent'|'fixed'>('percent')
  const [actionVal,    setActionVal]    = useState('')
  const [targetCcy,    setTargetCcy]    = useState('NGN')

  const usdcBalance = wallet?.tokens.find(t => t.symbol === 'USDC')?.balance ?? 0
  const escrowLocked = wallet?.escrow.locked ?? 0
  const triggeredRules = rules.filter(r => r.status === 'triggered')

  async function handleCreateRule() {
    if (!ruleName || !threshold || !actionVal) return
    await createRule.mutateAsync({
      name:              ruleName,
      trigger_threshold: parseFloat(threshold),
      action_percent:    actionType === 'percent' ? parseFloat(actionVal) : null,
      action_amount:     actionType === 'fixed'   ? parseFloat(actionVal) : null,
      target_currency:   targetCcy,
    })
    setRuleName(''); setThreshold(''); setActionVal('')
    setShowRuleForm(false)
  }

  function getConversionAmount(rule: typeof rules[0]): number {
    if (rule.action_percent) return usdcBalance * (rule.action_percent / 100)
    return rule.action_amount ?? 0
  }

  function getLocalEquiv(usdcAmt: number, currency: string): string {
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate) return '—'
    return (usdcAmt / rate).toLocaleString(undefined, { maximumFractionDigits: 0 })
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Business Treasury</h1>
          <p className="text-sm text-app-muted">Automate conversions · manage payroll · track funds</p>
        </div>
        <Link href="/treasury/payroll">
          <Button size="sm">
            <Users className="h-4 w-4" /> New payroll
          </Button>
        </Link>
      </div>

      {/* Triggered rules alert */}
      {triggeredRules.length > 0 && (
        <div className="mb-4 rounded-xl border border-amber-900/50 bg-amber-900/20 p-4">
          <div className="flex items-start gap-3">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-400" />
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-400">
                {triggeredRules.length} auto-conversion rule{triggeredRules.length > 1 ? 's' : ''} triggered
              </p>
              {triggeredRules.map(r => {
                const amt = getConversionAmount(r)
                return (
                  <div key={r.id} className="mt-2 flex items-center justify-between text-xs">
                    <span className="text-amber-600">
                      "{r.name}" — convert {r.action_percent ? `${r.action_percent}%` : `${r.action_amount} USDC`} to {r.target_currency}
                      {amt > 0 && ` (≈ ${getLocalEquiv(amt, r.target_currency)} ${r.target_currency})`}
                    </span>
                    <div className="flex gap-2">
                      <Link href="/convert">
                        <Button size="sm" className="h-7 text-xs">
                          Convert now <ArrowRight className="h-3 w-3" />
                        </Button>
                      </Link>
                      <Button size="sm" variant="outline" className="h-7 text-xs"
                        onClick={() => toggleRule.mutate({ id: r.id, status: 'active' })}>
                        Dismiss
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* Stats row */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          { label: 'Available USDC',   value: `$${formatAmount(usdcBalance)}`,  sub: 'ready to use'        },
          { label: 'In escrow',        value: `$${formatAmount(escrowLocked)}`, sub: 'locked in P2P offers' },
          { label: 'Active rules',     value: String(rules.filter(r => r.status === 'active').length),
            sub: 'auto-conversion rules' },
          { label: 'Payrolls run',     value: String(batches.filter(b => b.status === 'completed').length),
            sub: `$${formatAmount(batches.filter(b => b.status === 'completed').reduce((s,b) => s + b.total_amount, 0))} total paid` },
        ].map(({ label, value, sub }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <p className="text-xs text-app-muted">{label}</p>
            <p className="mt-1 font-mono text-xl font-semibold text-app-text">{value}</p>
            <p className="mt-0.5 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* Auto-conversion rules */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Auto-conversion rules</p>
              <p className="text-xs text-app-muted">Trigger when USDC balance crosses a threshold</p>
            </div>
            <Button size="sm" variant="outline"
              onClick={() => setShowRuleForm(!showRuleForm)}>
              <Plus className="h-3.5 w-3.5" /> New rule
            </Button>
          </div>

          {/* Create rule form */}
          {showRuleForm && (
            <div className="mb-4 space-y-3 rounded-xl border border-app-border bg-app-bg p-4">
              <p className="text-xs font-medium text-app-text">New rule</p>
              <Input placeholder="Rule name (e.g. Convert excess NGN)"
                value={ruleName} onChange={e => setRuleName(e.target.value)} />
              <div className="flex gap-2">
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">When USDC balance exceeds</p>
                  <Input type="number" placeholder="1000" value={threshold}
                    onChange={e => setThreshold(e.target.value)} />
                </div>
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">Target currency</p>
                  <select value={targetCcy} onChange={e => setTargetCcy(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {CURRENCIES.map(c => (
                      <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
                    ))}
                  </select>
                </div>
              </div>
              <div>
                <p className="mb-1 text-[10px] text-app-muted">Convert</p>
                <div className="flex gap-2">
                  <div className="flex rounded-lg border border-app-border bg-app-surface">
                    {(['percent','fixed'] as const).map(t => (
                      <button key={t} onClick={() => setActionType(t)}
                        className={`px-3 py-1.5 text-xs transition-colors rounded-lg
                          ${actionType === t ? 'bg-app-accent text-app-on-accent' : 'text-app-muted'}`}>
                        {t === 'percent' ? '%' : 'Fixed'}
                      </button>
                    ))}
                  </div>
                  <Input type="number"
                    placeholder={actionType === 'percent' ? '30 (%)' : 'Amount (USDC)'}
                    value={actionVal} onChange={e => setActionVal(e.target.value)}
                    className="flex-1" />
                </div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" className="flex-1"
                  onClick={() => setShowRuleForm(false)}>Cancel</Button>
                <Button size="sm" className="flex-1" onClick={handleCreateRule}
                  disabled={createRule.isPending || !ruleName || !threshold || !actionVal}>
                  {createRule.isPending ? 'Saving…' : 'Save rule'}
                </Button>
              </div>
            </div>
          )}

          {/* Rules list */}
          {rules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Zap className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No rules yet</p>
              <p className="text-xs text-app-muted">
                Create a rule to be alerted when your balance crosses a threshold
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {rules.map(rule => {
                const amt = getConversionAmount(rule)
                return (
                  <div key={rule.id}
                    className="rounded-xl border border-app-border bg-app-bg p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-app-text truncate">{rule.name}</p>
                          <Badge variant={
                            rule.status === 'triggered' ? 'warning' :
                            rule.status === 'active'    ? 'success'  : 'default'
                          }>
                            {rule.status}
                          </Badge>
                        </div>
                        <p className="mt-0.5 text-xs text-app-muted">
                          When USDC &gt; {rule.trigger_threshold.toLocaleString()} →{' '}
                          convert {rule.action_percent ? `${rule.action_percent}%` : `${rule.action_amount} USDC`} to{' '}
                          {CURRENCY_FLAG[rule.target_currency]} {rule.target_currency}
                        </p>
                        {rule.last_triggered && (
                          <p className="mt-0.5 text-[10px] text-amber-500">
                            Last triggered: {new Date(rule.last_triggered * 1000).toLocaleDateString()}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          onClick={() => toggleRule.mutate({
                            id: rule.id,
                            status: rule.status === 'active' ? 'paused' : 'active',
                          })}
                          className="rounded p-1.5 text-app-muted hover:text-app-text transition-colors"
                          title={rule.status === 'active' ? 'Pause' : 'Activate'}
                        >
                          {rule.status === 'active'
                            ? <Pause className="h-3.5 w-3.5" />
                            : <Play  className="h-3.5 w-3.5" />
                          }
                        </button>
                        <button
                          onClick={() => deleteRule.mutate(rule.id)}
                          className="rounded p-1.5 text-app-muted hover:text-red-400 transition-colors"
                          title="Delete rule"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent payrolls */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Recent payrolls</p>
              <p className="text-xs text-app-muted">Batch USDC payments with Memo references</p>
            </div>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline">
                <Plus className="h-3.5 w-3.5" /> New batch
              </Button>
            </Link>
          </div>

          {batches.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Building2 className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No payrolls yet</p>
              <p className="text-xs text-app-muted">
                Send USDC to multiple wallets in one batch with unique Memo references
              </p>
              <Link href="/treasury/payroll">
                <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-2">
              {batches.slice(0, 6).map(batch => (
                <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                  <div className="flex items-center justify-between rounded-xl border border-app-border bg-app-bg p-3 hover:border-app-accent/40 transition-colors cursor-pointer">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <p className="text-sm font-medium text-app-text truncate">{batch.name}</p>
                        <Badge variant={
                          batch.status === 'completed'  ? 'success' :
                          batch.status === 'processing' ? 'arc'     :
                          batch.status === 'failed'     ? 'danger'  : 'warning'
                        }>
                          {batch.status}
                        </Badge>
                      </div>
                      <p className="text-xs text-app-muted">
                        {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                        · {new Date(batch.created_at * 1000).toLocaleDateString()}
                      </p>
                    </div>
                    <ArrowRight className="h-4 w-4 shrink-0 text-app-muted" />
                  </div>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/treasury/TreasuryContent.tsx"

mkdir -p "afrifx-web/app/(app)/treasury/payroll"
cat > "afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx" << 'AFX_EOF'
'use client'
import { useState, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useCreateBatch } from '@/hooks/usePayroll'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { formatAmount } from '@/lib/utils'
import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle } from 'lucide-react'
import Link from 'next/link'

interface Recipient {
  name:          string
  walletAddress: string
  amount:        string
  error?:        string
}

function isValidAddress(addr: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(addr)
}

export function PayrollCreateContent() {
  const router              = useRouter()
  const { formatted: balance } = useUSDCBalance()
  const createBatch         = useCreateBatch()

  const [batchName,    setBatchName]    = useState('')
  const [description,  setDescription]  = useState('')
  const [activeTab,    setActiveTab]    = useState<'manual'|'csv'>('manual')
  const [recipients,   setRecipients]   = useState<Recipient[]>([
    { name: '', walletAddress: '', amount: '' }
  ])
  const [csvError,     setCsvError]     = useState<string | null>(null)
  const [csvSuccess,   setCsvSuccess]   = useState<string | null>(null)
  const fileInputRef   = useRef<HTMLInputElement>(null)

  const totalAmount = recipients.reduce((s, r) => s + (parseFloat(r.amount) || 0), 0)
  const validCount  = recipients.filter(r =>
    isValidAddress(r.walletAddress) && parseFloat(r.amount) > 0
  ).length

  // ── Manual recipient management ───────────────────────────
  function addRecipient() {
    setRecipients(prev => [...prev, { name: '', walletAddress: '', amount: '' }])
  }

  function removeRecipient(i: number) {
    setRecipients(prev => prev.filter((_, idx) => idx !== i))
  }

  function updateRecipient(i: number, field: keyof Recipient, value: string) {
    setRecipients(prev => prev.map((r, idx) => {
      if (idx !== i) return r
      const validationError: string | undefined =
        field === 'walletAddress' && value && !isValidAddress(value)
          ? 'Invalid address'
          : undefined
      const updated: Recipient = { ...r, [field]: value, error: validationError }
      return updated
    }))
  }

  // ── CSV upload ─────────────────────────────────────────────
  function handleCSV(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setCsvError(null); setCsvSuccess(null)

    const reader = new FileReader()
    reader.onload = (ev) => {
      const text   = ev.target?.result as string
      const lines  = text.trim().split('\n')
      const header = lines[0].toLowerCase()

      // Detect column positions
      const cols   = header.split(',').map(c => c.trim().replace(/"/g,''))
      const nameI  = cols.indexOf('name')
      const addrI  = cols.findIndex(c => c.includes('wallet') || c.includes('address'))
      const amtI   = cols.findIndex(c => c.includes('amount'))

      if (addrI === -1 || amtI === -1) {
        setCsvError('CSV must have columns: name (optional), wallet_address, amount')
        return
      }

      const parsed: Recipient[] = []
      const errors: string[]    = []

      for (let i = 1; i < lines.length; i++) {
        const row  = lines[i].split(',').map(c => c.trim().replace(/"/g,''))
        const addr = row[addrI] ?? ''
        const amt  = row[amtI]  ?? ''
        const name = nameI >= 0 ? (row[nameI] ?? '') : ''

        if (!addr && !amt) continue // skip empty rows

        if (!isValidAddress(addr)) {
          errors.push(`Row ${i + 1}: invalid address "${addr}"`)
          continue
        }
        if (isNaN(parseFloat(amt)) || parseFloat(amt) <= 0) {
          errors.push(`Row ${i + 1}: invalid amount "${amt}"`)
          continue
        }
        parsed.push({ name, walletAddress: addr, amount: amt })
      }

      if (errors.length) {
        setCsvError(errors.slice(0, 3).join(' · ') + (errors.length > 3 ? ` +${errors.length - 3} more` : ''))
      }

      if (parsed.length) {
        setRecipients(parsed)
        setActiveTab('manual') // switch to manual to show/edit
        setCsvSuccess(`Imported ${parsed.length} recipient${parsed.length !== 1 ? 's' : ''} from CSV`)
      }
    }
    reader.readAsText(file)
    if (fileInputRef.current) fileInputRef.current.value = ''
  }

  // ── Create batch ──────────────────────────────────────────
  async function handleCreate() {
    const valid = recipients.filter(r =>
      isValidAddress(r.walletAddress) && parseFloat(r.amount) > 0
    )
    if (!batchName || !valid.length) return

    const result = await createBatch.mutateAsync({
      name:        batchName,
      description: description || undefined,
      recipients:  valid.map(r => ({
        name:          r.name || undefined,
        walletAddress: r.walletAddress,
        amount:        parseFloat(r.amount),
      })),
    })

    if (result?.id) {
      router.push(`/treasury/payroll/${result.id}`)
    }
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">New payroll batch</h1>
          <p className="text-sm text-app-muted">
            Send USDC to multiple wallets · each payment gets a unique Memo reference
          </p>
        </div>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">

          {/* Batch details */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-3 text-sm font-medium text-app-text">Batch details</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-app-muted">Batch name *</label>
                <Input placeholder="e.g. June 2026 Payroll" value={batchName}
                  onChange={e => setBatchName(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Description (optional)</label>
                <Input placeholder="e.g. Monthly contractor payments"
                  value={description} onChange={e => setDescription(e.target.value)} />
              </div>
            </div>
          </div>

          {/* Recipients — tabs */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <div className="mb-4 flex items-center justify-between">
              <p className="text-sm font-medium text-app-text">Recipients</p>
              <div className="flex rounded-lg border border-app-border bg-app-bg p-0.5">
                <button onClick={() => setActiveTab('manual')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'manual' ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
                  <Users className="h-3 w-3" /> Manual
                </button>
                <button onClick={() => setActiveTab('csv')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'csv' ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
                  <FileText className="h-3 w-3" /> CSV upload
                </button>
              </div>
            </div>

            {/* CSV tab */}
            {activeTab === 'csv' && (
              <div className="space-y-3">
                {/* Format guide */}
                <div className="rounded-lg bg-app-bg p-3 text-xs">
                  <p className="mb-1 font-medium text-app-text">Expected CSV format:</p>
                  <pre className="text-app-muted">{`name,wallet_address,amount
John Doe,0x1234...abcd,100
Jane Smith,0xabcd...1234,50`}</pre>
                  <p className="mt-1 text-app-muted">
                    • <code>name</code> is optional · <code>wallet_address</code> and <code>amount</code> required
                  </p>
                </div>

                <input ref={fileInputRef} type="file" accept=".csv,.txt"
                  onChange={handleCSV} className="hidden" />

                <button onClick={() => fileInputRef.current?.click()}
                  className="flex w-full flex-col items-center gap-3 rounded-xl border-2 border-dashed border-app-border bg-app-bg p-8 hover:border-app-accent/50 transition-colors">
                  <Upload className="h-8 w-8 text-app-muted" />
                  <div className="text-center">
                    <p className="text-sm font-medium text-app-text">Click to upload CSV</p>
                    <p className="text-xs text-app-muted">Supports .csv and .txt files</p>
                  </div>
                </button>

                {csvError && (
                  <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
                    <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{csvError}
                  </div>
                )}
                {csvSuccess && (
                  <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                    <CheckCircle className="h-3.5 w-3.5 shrink-0" />{csvSuccess}
                  </div>
                )}
              </div>
            )}

            {/* Manual tab */}
            {activeTab === 'manual' && (
              <div className="space-y-2">
                {/* Column headers */}
                <div className="hidden sm:grid grid-cols-12 gap-2 px-1 text-[10px] uppercase tracking-wider text-app-muted">
                  <div className="col-span-3">Name</div>
                  <div className="col-span-5">Wallet address</div>
                  <div className="col-span-3">Amount (USDC)</div>
                  <div className="col-span-1" />
                </div>

                {recipients.map((r, i) => (
                  <div key={i} className="grid grid-cols-12 items-start gap-2">
                    <div className="col-span-3">
                      <Input placeholder="Name" value={r.name}
                        onChange={e => updateRecipient(i, 'name', e.target.value)}
                        className="text-xs" />
                    </div>
                    <div className="col-span-5">
                      <Input
                        placeholder="0x..."
                        value={r.walletAddress}
                        onChange={e => updateRecipient(i, 'walletAddress', e.target.value)}
                        className={`font-mono text-xs ${r.error ? 'border-red-500' : ''}`}
                      />
                      {r.error && <p className="mt-0.5 text-[10px] text-red-400">{r.error}</p>}
                    </div>
                    <div className="col-span-3">
                      <Input type="number" placeholder="0.00" value={r.amount}
                        onChange={e => updateRecipient(i, 'amount', e.target.value)}
                        className="text-xs" />
                    </div>
                    <div className="col-span-1 flex justify-center pt-2">
                      {recipients.length > 1 && (
                        <button onClick={() => removeRecipient(i)}
                          className="text-app-muted hover:text-red-400 transition-colors">
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  </div>
                ))}

                <Button variant="outline" size="sm" onClick={addRecipient} className="w-full">
                  <Plus className="h-3.5 w-3.5" /> Add recipient
                </Button>
              </div>
            )}
          </div>
        </div>

        {/* Summary + action */}
        <div className="space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Batch summary</p>
            <div className="space-y-2.5 text-xs">
              {[
                ['Recipients',      `${validCount} valid`],
                ['Total payout',    `${formatAmount(totalAmount)} USDC`],
                ['Your balance',    `${balance} USDC`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span className="text-app-muted">{label}</span>
                  <span className="font-mono text-app-text">{val}</span>
                </div>
              ))}
              <div className="border-t border-app-border pt-2 flex justify-between">
                <span className="text-app-muted">Each payment</span>
                <span className="text-app-muted">Gets unique Memo ref</span>
              </div>
            </div>

            <Button className="mt-4 w-full" size="lg"
              onClick={handleCreate}
              disabled={!batchName || validCount === 0 || createBatch.isPending}>
              {createBatch.isPending ? 'Creating…' : `Review & send ${validCount} payment${validCount !== 1 ? 's' : ''}`}
            </Button>

            {createBatch.isError && (
              <p className="mt-2 text-xs text-red-400">Failed to create batch</p>
            )}
          </div>

          {/* How it works */}
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs text-app-muted">
            <p className="mb-2 font-medium text-app-text">How payroll works</p>
            <ol className="space-y-1.5">
              {[
                'Create batch with recipient list',
                'Review — confirm amounts are correct',
                'Execute — approve USDC, then send to each recipient',
                'Each payment gets a unique Memo reference (PAY-YYYYMMDD-XXXX)',
                'Track status live as payments confirm on Arc',
              ].map((s, i) => (
                <li key={i} className="flex gap-2">
                  <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                  <span>{s}</span>
                </li>
              ))}
            </ol>
          </div>
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx"

mkdir -p "afrifx-web/app/(app)/treasury/payroll/[id]"
cat > "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract } from 'wagmi'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch, useUpdateRecipient } from '@/hooks/usePayroll'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs } from '@/lib/memo'
import { MEMO_ADDRESS, MEMO_ABI } from '@/lib/memo'
import { formatAmount } from '@/lib/utils'
import { parseUnits } from 'viem'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle, Clock,
} from 'lucide-react'

export function PayrollExecuteContent() {
  const { id }           = useParams()
  const { address }      = useAccount()
  const { data: batch }  = usePayrollBatch(id as string)
  const updateRecipient  = useUpdateRecipient()
  const { writeContractAsync } = useWriteContract()

  const [executing,    setExecuting]    = useState(false)
  const [currentIdx,   setCurrentIdx]   = useState(0)
  const [errorMsg,     setErrorMsg]     = useState<string | null>(null)
  const [done,         setDone]         = useState(false)

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
    </div>
  )

  const recipients = batch!.recipients ?? []
  const sentCount  = recipients.filter(r => r.status === 'sent').length
  const pct        = recipients.length > 0 ? Math.round((sentCount / recipients.length) * 100) : 0

  async function executePayroll() {
    if (!address || executing) return
    setExecuting(true)
    setErrorMsg(null)

    const pending = recipients.filter(r => r.status === 'pending')

    for (let i = 0; i < pending.length; i++) {
      const recipient = pending[i]
      setCurrentIdx(i)
      try {
        const usdcRaw = parseUnits(recipient.amount.toFixed(6), USDC_DECIMALS)
        const memoId  = buildMemoId(`payroll-${batch!.id}-${recipient.id}`)

        // Check if Memo is available
        let hash: `0x${string}`
        try {
          const args = buildMemoTransferArgs(
            CONTRACTS.USDC,
            recipient.wallet_address as `0x${string}`,
            recipient.amount,
            USDC_DECIMALS,
            memoId,
            {
              app:  'afrifx',
              type: 'p2p-create', // reuse as generic transfer
              ref:  recipient.memo_ref ?? undefined,
            },
          )
          hash = await writeContractAsync(args)
        } catch {
          // Fallback to direct transfer
          hash = await writeContractAsync({
            address:      CONTRACTS.USDC,
            abi:          USDC_ABI,
            functionName: 'transfer',
            args:         [recipient.wallet_address as `0x${string}`, usdcRaw],
          })
        }

        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch!.id,
          status:  'sent',
          txHash:  hash,
        })
      } catch (err: any) {
        const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch!.id,
          status:  'failed',
        })
        setErrorMsg(`Payment to ${recipient.name ?? recipient.wallet_address.slice(0,10)} failed: ${msg}`)
        // Continue with next recipients
      }
    }

    setExecuting(false)
    setDone(true)
  }

  const statusBadge = {
    draft:      'warning',
    processing: 'arc',
    completed:  'success',
    failed:     'danger',
  }[batch!.status] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">{batch!.name}</h1>
            <Badge variant={statusBadge}>{batch!.status}</Badge>
          </div>
          <p className="text-xs text-app-muted">
            {batch.recipient_count} recipients · ${formatAmount(batch!.total_amount)} USDC
            · Created {new Date(batch!.created_at * 1000).toLocaleDateString()}
          </p>
        </div>
      </div>

      {/* Progress bar */}
      {(executing || batch!.status === 'completed') && (
        <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-2 flex items-center justify-between text-xs">
            <span className="text-app-muted">
              {executing ? `Sending payment ${currentIdx + 1} of ${recipients.filter(r => r.status === 'pending').length}…` : 'All payments sent'}
            </span>
            <span className={`font-medium ${pct === 100 ? 'text-emerald-400' : 'text-app-text'}`}>
              {sentCount}/{recipients.length} · {pct}%
            </span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-full bg-app-border">
            <div
              className="h-full rounded-full bg-emerald-500 transition-all duration-500"
              style={{ width: `${pct}%` }}
            />
          </div>
          {executing && (
            <p className="mt-1.5 text-center text-xs text-app-muted">
              Do not close this tab until all payments are sent.
            </p>
          )}
        </div>
      )}

      {done && sentCount === recipients.length && (
        <div className="mb-4 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">All payments sent successfully!</p>
          <p className="mt-1 text-xs text-emerald-600">
            ${formatAmount(batch!.total_amount)} USDC distributed to {sentCount} recipients
          </p>
        </div>
      )}

      {errorMsg && (
        <div className="mb-4 flex items-start gap-2 rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-medium">Payment failed</p>
            <p className="mt-0.5">{errorMsg}</p>
            <p className="mt-1 text-red-600">The remaining payments will continue. You can retry failed ones separately.</p>
          </div>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-3">

        {/* Recipients table */}
        <div className="lg:col-span-2 rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Recipients</p>
          <div className="space-y-2">
            {recipients.map((r, i) => (
              <div key={r.id}
                className={`flex items-center gap-3 rounded-xl p-3 transition-colors
                  ${executing && i === currentIdx && r.status === 'pending'
                    ? 'border border-app-accent/40 bg-app-accent/5'
                    : 'border border-app-border bg-app-bg'}`}>

                {/* Status icon */}
                <div className="shrink-0">
                  {r.status === 'sent'    ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                  : r.status === 'failed' ? <XCircle     className="h-4 w-4 text-red-400" />
                  : executing && i === currentIdx
                  ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
                  : <Clock   className="h-4 w-4 text-app-muted" />}
                </div>

                {/* Info */}
                <div className="flex-1 min-w-0">
                  {r.name && (
                    <p className="text-xs font-medium text-app-text">{r.name}</p>
                  )}
                  <p className="font-mono text-[11px] text-app-muted truncate">{r.wallet_address}</p>
                  {r.memo_ref && (
                    <p className="text-[10px] text-app-muted">{r.memo_ref}</p>
                  )}
                </div>

                {/* Amount */}
                <div className="shrink-0 text-right">
                  <p className="font-mono text-sm font-medium text-app-text">
                    {formatAmount(r.amount)} USDC
                  </p>
                  {r.tx_hash && (
                    <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                      target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-[10px] text-app-accent-text hover:underline">
                      View tx <ExternalLink className="h-2.5 w-2.5" />
                    </a>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Action panel */}
        <div className="space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Execute</p>
            <div className="space-y-2 text-xs">
              {[
                ['Recipients', String(batch.recipient_count)],
                ['Total',      `${formatAmount(batch!.total_amount)} USDC`],
                ['Sent',       `${sentCount} / ${batch.recipient_count}`],
              ].map(([l,v]) => (
                <div key={l} className="flex justify-between">
                  <span className="text-app-muted">{l}</span>
                  <span className="font-mono text-app-text">{v}</span>
                </div>
              ))}
            </div>

            {batch!.status !== 'completed' && (
              <Button className="mt-4 w-full" size="lg"
                onClick={executePayroll}
                disabled={executing || done || sentCount === recipients.length}>
                {executing
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
                  : sentCount > 0
                  ? `Resume (${recipients.length - sentCount} remaining)`
                  : <><Play className="h-4 w-4" /> Start payroll</>
                }
              </Button>
            )}

            {batch!.status === 'completed' && (
              <div className="mt-4 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                <CheckCircle className="h-3.5 w-3.5" />
                Payroll complete
              </div>
            )}

            <p className="mt-2 text-center text-[10px] text-app-muted">
              Each payment is sent individually on Arc with a unique Memo reference
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx"

mkdir -p "afrifx-web/app/(app)/wallet"
cat > "afrifx-web/app/(app)/wallet/WalletContent.tsx" << 'AFX_EOF'
'use client'
import { useWallet }   from '@/hooks/useWallet'
import { useAccount }  from 'wagmi'
import { useProfile }  from '@/hooks/useProfile'
import Link            from 'next/link'
import { Badge }       from '@/components/ui/badge'
import { Button }      from '@/components/ui/button'
import {
  PieChart, Pie, Cell, Tooltip,
  ResponsiveContainer,
} from 'recharts'
import {
  RefreshCw, ArrowLeftRight, Send,
  Store, ExternalLink, ShieldCheck,
  TrendingUp, Wallet, Copy, Check,
} from 'lucide-react'
import { useState } from 'react'
import { formatAmount } from '@/lib/utils'
import { useTokens } from '@/lib/tokens'

const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

export function WalletContent() {
  const t                         = useTokens()
  const { address }               = useAccount()
  const { data: profile }         = useProfile()
  const { data, isLoading, refetch } = useWallet()
  const [copied, setCopied]       = useState(false)

  function copyAddress() {
    if (!address) return
    navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const totalUSD   = (data?.tokens ?? []).reduce((s, t) => s + t.usdValue, 0)
  const escrowUSD  = data?.escrow.locked ?? 0
  const grandTotal = totalUSD + escrowUSD

  // Local currency colors
  const LOCAL_COLORS: Record<string, string> = {
    NGN: '#16A34A', GHS: '#DC2626',
    KES: '#9333EA', ZAR: '#0891B2', EGP: '#C2410C',
  }

  // Local currency slices — USD equivalent (localAmount / rate = usdcBalance)
  const localSlices = (data?.localEquiv ?? [])
    .map(({ currency, amount, rate }) => ({
      name:  currency,
      value: rate > 0 ? parseFloat((amount / rate).toFixed(2)) : 0,
      color: LOCAL_COLORS[currency] ?? '#6366F1',
    }))
    .filter(d => d.value > 0)

  // Full pie: tokens + escrow + local equivalents
  const pieData = [
    ...(data?.tokens ?? []).map(t => ({
      name: t.symbol, value: t.usdValue, color: t.color,
    })),
    ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : []),
    ...localSlices,
  ].filter(d => d.value > 0)

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Wallet</h1>
          <p className="text-sm text-app-muted">Your balances on Arc Testnet</p>
        </div>
        <button onClick={() => refetch()}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Top section: Portfolio overview */}
      <div className="mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3">

        {/* Total balance card */}
        <div className="lg:col-span-2 rounded-xl border border-app-border bg-app-surface p-6">
          <div className="mb-4 flex items-start justify-between">
            <div>
              <p className="text-sm text-app-muted">Total portfolio value</p>
              <p className="mt-1 font-mono text-4xl font-bold text-app-text">
                {isLoading
                  ? <span className="inline-block h-10 w-40 animate-pulse rounded bg-app-border" />
                  : `$${formatAmount(grandTotal)}`
                }
              </p>
              <p className="mt-1 text-xs text-app-muted">USD equivalent on Arc Testnet</p>
            </div>
            <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-accent/10">
              <Wallet className="h-6 w-6 text-app-accent-text" />
            </div>
          </div>

          {/* Wallet address */}
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2">
            <div>
              <p className="text-xs font-medium text-app-text">
                {profile?.display_name ?? 'Wallet'}
              </p>
              <p className="font-mono text-[10px] text-app-muted">
                {address ?? '—'}
              </p>
            </div>
            <button onClick={copyAddress} className="ml-auto shrink-0 text-app-muted hover:text-app-text">
              {copied
                ? <Check className="h-3.5 w-3.5 text-emerald-400" />
                : <Copy className="h-3.5 w-3.5" />
              }
            </button>
            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-app-muted hover:text-app-accent-text">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>

          {/* Quick actions */}
          <div className="flex gap-2">
            <Link href="/convert" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <ArrowLeftRight className="h-3.5 w-3.5" /> Convert
              </Button>
            </Link>
            <Link href="/send" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <Send className="h-3.5 w-3.5" /> Send
              </Button>
            </Link>
            <Link href="/marketplace/create" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <Store className="h-3.5 w-3.5" /> P2P
              </Button>
            </Link>
          </div>
        </div>

        {/* Donut chart */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-3 text-sm font-medium text-app-text">Allocation</p>
          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <RefreshCw className="h-5 w-5 animate-spin text-app-muted" />
            </div>
          ) : grandTotal === 0 ? (
            <div className="flex h-40 flex-col items-center justify-center gap-2">
              <p className="text-xs text-app-muted">No holdings yet</p>
            </div>
          ) : (
            <>
              <ResponsiveContainer width="100%" height={140}>
                <PieChart>
                  <Pie
                    data={pieData}
                    cx="50%" cy="50%"
                    innerRadius={42} outerRadius={62}
                    paddingAngle={3}
                    dataKey="value"
                  >
                    {pieData.map((entry, i) => (
                      <Cell key={i} fill={entry.color} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 11, color: t.text }}
                    labelStyle={{ color: t.text }}
                    itemStyle={{ color: t.text }}
                    formatter={(v: number, name: string) => [`$${formatAmount(v)} USD`, name]}
                  />
                </PieChart>
              </ResponsiveContainer>
              <div className="mt-2 max-h-44 overflow-y-auto space-y-1.5 pr-1">
                {pieData.map(d => (
                  <div key={d.name} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: d.color }} />
                      <span className="text-app-muted">{d.name}</span>
                    </div>
                    <span className="font-mono text-app-text">${formatAmount(d.value)}</span>
                  </div>
                ))}
              </div>
              <p className="mt-2 border-t border-app-border pt-2 text-[10px] text-app-muted">
                Local currencies show USD equivalent of your USDC holdings
              </p>
            </>
          )}
        </div>
      </div>

      {/* Token balances */}
      <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-5">
        <p className="mb-4 text-sm font-medium text-app-text">Token balances</p>
        <div className="grid gap-3 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">

          {/* USDC + EURC */}
          {(data?.tokens ?? [{ symbol: 'USDC', name: 'USD Coin', balance: 0, usdValue: 0, color: '#378ADD', address: '' }, { symbol: 'EURC', name: 'Euro Coin', balance: 0, usdValue: 0, color: '#10B981', address: '' }]).map(token => (
            <div key={token.symbol}
              className="flex items-center gap-3 rounded-xl border border-app-border bg-app-bg p-4">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-base font-bold text-white"
                style={{ background: token.color }}>
                {token.symbol[0]}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center justify-between">
                  <p className="text-sm font-medium text-app-text">{token.symbol}</p>
                  <p className="font-mono text-sm font-semibold text-app-text">
                    {isLoading
                      ? <span className="inline-block h-4 w-16 animate-pulse rounded bg-app-border" />
                      : formatAmount(token.balance)
                    }
                  </p>
                </div>
                <div className="flex items-center justify-between">
                  <p className="text-xs text-app-muted">{token.name}</p>
                  <p className="text-xs text-app-muted">≈ ${formatAmount(token.usdValue)}</p>
                </div>
              </div>
            </div>
          ))}

          {/* Escrow card */}
          <div className="flex items-center gap-3 rounded-xl border border-amber-900/40 bg-amber-900/10 p-4">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-amber-500/20">
              <ShieldCheck className="h-5 w-5 text-amber-400" />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center justify-between">
                <p className="text-sm font-medium text-app-text">Escrow</p>
                <p className="font-mono text-sm font-semibold text-amber-400">
                  {isLoading
                    ? <span className="inline-block h-4 w-16 animate-pulse rounded bg-app-border" />
                    : formatAmount(data?.escrow.locked ?? 0)
                  }
                </p>
              </div>
              <div className="flex items-center justify-between">
                <p className="text-xs text-amber-600">Locked in P2P offers</p>
                <p className="text-xs text-amber-600">
                  {data?.escrow.openOffers ?? 0} open · {data?.escrow.activeOffers ?? 0} active
                </p>
              </div>
            </div>
          </div>

          {/* Local currency equivalent cards */}
          {(data?.localEquiv ?? []).map(({ currency, flag, rate, amount }) => (
            <div key={currency}
              className="flex items-center gap-3 rounded-xl border border-app-border bg-app-bg p-4">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-border text-xl">
                {flag}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center justify-between">
                  <p className="text-sm font-medium text-app-text">{currency}</p>
                  <p className="font-mono text-sm font-semibold text-app-text">
                    {isLoading
                      ? <span className="inline-block h-4 w-20 animate-pulse rounded bg-app-border" />
                      : amount.toLocaleString(undefined, { maximumFractionDigits: 0 })
                    }
                  </p>
                </div>
                <div className="flex items-center justify-between">
                  <p className="text-xs text-app-muted">USDC equivalent</p>
                  <p className="text-xs text-app-muted">1 USDC = {rate.toLocaleString()}</p>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* P2P summary + Recent transactions */}
      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* P2P summary */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">P2P summary</p>
          <div className="space-y-3">
            {[
              { label: 'Completed trades', value: String(data?.p2p.completed ?? 0), icon: TrendingUp, color: 'text-emerald-400' },
              { label: 'P2P volume traded', value: `$${formatAmount(data?.p2p.totalVolume ?? 0)}`, icon: ArrowLeftRight, color: 'text-app-accent-text' },
              { label: 'Open offers',       value: String(data?.escrow.openOffers ?? 0),   icon: Store,       color: 'text-amber-400' },
              { label: 'Active trades',     value: String(data?.escrow.activeOffers ?? 0), icon: ShieldCheck, color: 'text-app-accent-text' },
            ].map(({ label, value, icon: Icon, color }) => (
              <div key={label} className="flex items-center justify-between rounded-lg bg-app-bg px-4 py-2.5">
                <div className="flex items-center gap-2 text-xs text-app-muted">
                  <Icon className={`h-3.5 w-3.5 ${color}`} />
                  {label}
                </div>
                <span className={`font-mono text-sm font-semibold ${color}`}>
                  {isLoading ? '—' : value}
                </span>
              </div>
            ))}
          </div>
          <Link href="/my-trades" className="mt-3 block">
            <Button variant="outline" size="sm" className="w-full">
              View all trades →
            </Button>
          </Link>
        </div>

        {/* Recent transactions */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Recent transactions</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => <div key={i} className="h-12 animate-pulse rounded bg-app-border" />)}
            </div>
          ) : data?.transactions.length ? (
            <div className="space-y-2 max-h-64 overflow-y-auto">
              {data.transactions.map(tx => (
                <div key={tx.id}
                  className="flex items-center gap-3 rounded-lg bg-app-bg px-3 py-2.5">
                  <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-app-accent/10">
                    <ArrowLeftRight className="h-3.5 w-3.5 text-app-accent-text" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium text-app-text">
                      {tx.fromCurrency} → {tx.toCurrency}
                    </p>
                    <p className="text-[10px] text-app-muted">
                      {new Date(tx.createdAt * 1000).toLocaleDateString()}
                      {tx.reference && <span className="ml-1 font-mono">· {tx.reference}</span>}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="font-mono text-xs text-emerald-400">
                      +{formatAmount(tx.toAmount)} {tx.toCurrency}
                    </p>
                    <Badge variant={
                      tx.status === 'settled'  ? 'success' :
                      tx.status === 'failed'   ? 'danger'  : 'warning'
                    }>
                      {tx.status}
                    </Badge>
                  </div>
                  {tx.arcTxHash && (
                    <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}
                      target="_blank" rel="noopener noreferrer" className="shrink-0">
                      <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent-text" />
                    </a>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <div className="flex h-32 flex-col items-center justify-center gap-2">
              <p className="text-xs text-app-muted">No transactions yet</p>
              <Link href="/convert">
                <Button variant="outline" size="sm">Make your first conversion</Button>
              </Link>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/wallet/WalletContent.tsx"

mkdir -p "afrifx-web/app/(auth)/connect"
cat > "afrifx-web/app/(auth)/connect/page.tsx" << 'AFX_EOF'
'use client'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useEffect } from 'react'
import { ArrowLeftRight, Zap, Shield, Globe } from 'lucide-react'
import { ConnectButton } from '@/components/wallet/ConnectButton'

const features = [
  { icon: Zap,           title: 'Sub-second settlement', desc: 'Arc finalises transactions in under 1 second.' },
  { icon: Shield,        title: 'USDC-native',           desc: 'Gas fees paid in USDC — no volatile ETH needed.' },
  { icon: Globe,         title: 'Pan-African corridors', desc: 'NGN, GHS, KES, ZAR and more coming soon.' },
]

export default function ConnectPage() {
  const { isConnected } = useAccount()
  const router = useRouter()

  useEffect(() => {
    if (isConnected) router.push('/convert')
  }, [isConnected, router])

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-app-accent/20">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-app-text">AfriFX</h1>
          <p className="text-xs text-app-muted">Stablecoin FX on Arc</p>
        </div>
      </div>

      <div className="mb-8 w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6">
        <h2 className="mb-1 text-base font-semibold text-app-text">Connect your wallet</h2>
        <p className="mb-5 text-xs text-app-muted">
          Connect to Arc Testnet (Chain ID 5042002) to start converting currencies instantly.
        </p>
        <ConnectButton />
      </div>

      <div className="grid w-full max-w-sm gap-3">
        {features.map(({ icon: Icon, title, desc }) => (
          <div key={title} className="flex gap-3 rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-app-accent/10">
              <Icon className="h-3.5 w-3.5 text-app-accent-text" />
            </div>
            <div>
              <p className="text-sm font-medium text-app-text">{title}</p>
              <p className="text-xs text-app-muted">{desc}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(auth)/connect/page.tsx"

mkdir -p "afrifx-web/app/(auth)/profile/setup"
cat > "afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { getAvatarColor } from '@/lib/avatar'
import { checkUsername } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeftRight, CheckCircle, XCircle,
  Loader2, Sparkles, Twitter, AtSign,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ProfileSetupClient() {
  const { address, isConnected } = useAccount()
  const router      = useRouter()
  const queryClient = useQueryClient()

  const [username,    setUsername]    = useState('')
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [step,        setStep]        = useState(1)

  const [usernameState, setUsernameState] = useState<'idle'|'checking'|'available'|'taken'|'invalid'>('idle')
  const [usernameError, setUsernameError] = useState('')
  const [submitting,    setSubmitting]    = useState(false)
  const [submitError,   setSubmitError]   = useState('')

  const avatarColor = username ? getAvatarColor(username) : '#D9A441'

  useEffect(() => {
    if (!username) { setUsernameState('idle'); return }
    if (username.length < 3)  { setUsernameState('invalid'); setUsernameError('Min 3 characters'); return }
    if (username.length > 20) { setUsernameState('invalid'); setUsernameError('Max 20 characters'); return }
    if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      setUsernameState('invalid'); setUsernameError('Letters, numbers, underscores only'); return
    }
    setUsernameState('checking')
    const t = setTimeout(async () => {
      const result = await checkUsername(username)
      if (result.error) { setUsernameState('invalid'); setUsernameError(result.error) }
      else if (result.available) { setUsernameState('available'); setUsernameError('') }
      else { setUsernameState('taken'); setUsernameError('This username is taken') }
    }, 500)
    return () => clearTimeout(t)
  }, [username])

  async function handleSubmit() {
    if (!address || usernameState !== 'available' || !displayName.trim()) return
    setSubmitting(true); setSubmitError('')
    try {
      const res = await fetch(`${API}/profile`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress:  address,
          username,
          displayName:    displayName.trim(),
          bio:            bio.trim() || null,
          twitterHandle:  twitter.trim() || null,
          telegramHandle: telegram.trim() || null,
          showSocials,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setSubmitError(data.error ?? 'Failed'); return }

      // ── KEY FIX: write profile directly into cache ──────────
      // This means ProfileGuard sees the profile IMMEDIATELY
      // when the router navigates — no refetch race condition.
      const now = Math.floor(Date.now() / 1000)
      queryClient.setQueryData(['profile', address], {
        wallet_address:  address.toLowerCase(),
        username:        username.toLowerCase(),
        display_name:    displayName.trim(),
        bio:             bio.trim() || null,
        twitter_handle:  twitter.trim() || null,
        telegram_handle: telegram.trim() || null,
        avatar_color:    data.avatarColor ?? avatarColor,
        trade_count:     0,
        dispute_count:   0,
        verified:        false,
        show_socials:    showSocials,
        created_at:      now,
        updated_at:      now,
        maker_trades:    0,
        taker_trades:    0,
      })
      // ─────────────────────────────────────────────────────────

      setStep(3)
    } catch (e: any) {
      setSubmitError(e.message)
    } finally {
      setSubmitting(false)
    }
  }

  if (!isConnected) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet first.</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <div className="mb-8 flex items-center gap-2">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/20">
          <ArrowLeftRight className="h-5 w-5 text-app-accent-text" />
        </div>
        <span className="text-xl font-semibold text-app-text">AfriFX</span>
      </div>

      {step === 3 && (
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex justify-center">
            <ProfileAvatar displayName={displayName} avatarColor={avatarColor} size="xl" />
          </div>
          <h1 className="mb-2 text-2xl font-semibold text-app-text">Welcome, {displayName}!</h1>
          <p className="mb-2 text-sm text-app-muted">
            Your profile <span className="text-app-accent-text">@{username}</span> is ready.
          </p>
          <p className="mb-8 text-xs text-app-muted">
            You can update your profile anytime from the sidebar.
          </p>
          <Button className="w-full" size="lg" onClick={() => router.push('/convert')}>
            <Sparkles className="h-4 w-4" /> Enter AfriFX
          </Button>
        </div>
      )}

      {step < 3 && (
        <div className="w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-2xl font-semibold text-app-text">Create your profile</h1>
            <p className="mt-1 text-sm text-app-muted">Your identity on AfriFX. Username is permanent.</p>
          </div>

          <div className="mb-8 flex items-center gap-2">
            {[1,2].map((s) => (
              <div key={s} className="flex items-center gap-2">
                <div className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold
                  ${step >= s ? 'bg-app-accent text-app-on-accent' : 'bg-app-border text-app-muted'}`}>
                  {step > s ? '✓' : s}
                </div>
                <span className={`text-xs ${step >= s ? 'text-app-text' : 'text-app-muted'}`}>
                  {s === 1 ? 'Identity' : 'Socials'}
                </span>
                {s < 2 && <div className="h-px w-8 bg-app-border" />}
              </div>
            ))}
          </div>

          {step === 1 && (
            <div className="space-y-4">
              <div className="flex items-center gap-4 rounded-xl border border-app-border bg-app-surface p-4">
                <ProfileAvatar displayName={displayName || username || 'A'} avatarColor={avatarColor} size="lg" />
                <div>
                  <p className="text-sm font-medium text-app-text">{displayName || 'Your name'}</p>
                  <p className="text-xs text-app-muted">{username ? `@${username}` : '@username'}</p>
                </div>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Username <span className="text-red-400">*</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={username}
                    onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g,''))}
                    placeholder="yourname" className="pl-7 font-mono" maxLength={20} />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2">
                    {usernameState === 'checking'  && <Loader2 className="h-4 w-4 animate-spin text-app-muted" />}
                    {usernameState === 'available' && <CheckCircle className="h-4 w-4 text-emerald-400" />}
                    {(usernameState === 'taken' || usernameState === 'invalid') && <XCircle className="h-4 w-4 text-red-400" />}
                  </span>
                </div>
                {usernameState === 'available' && <p className="mt-1 text-xs text-emerald-400">@{username} is available!</p>}
                {usernameError && <p className="mt-1 text-xs text-red-400">{usernameError}</p>}
                <p className="mt-1 text-[10px] text-app-muted">3–20 chars · letters, numbers, underscores · permanent</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Display name <span className="text-red-400">*</span>
                </label>
                <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="Your full name" maxLength={40} />
                <p className="mt-1 text-[10px] text-app-muted">Shown instead of your wallet address everywhere</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Bio <span className="font-normal normal-case text-app-muted">(optional)</span>
                </label>
                <textarea value={bio} onChange={(e) => setBio(e.target.value)}
                  placeholder="Tell others about yourself…" maxLength={160} rows={3}
                  className="w-full rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent resize-none" />
                <p className="mt-1 text-right text-[10px] text-app-muted">{bio.length}/160</p>
              </div>

              <Button className="w-full" size="lg" onClick={() => setStep(2)}
                disabled={usernameState !== 'available' || !displayName.trim()}>
                Next — Add socials
              </Button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <p className="text-xs text-app-muted">
                Connect your socials so traders can verify and trust you. All optional.
              </p>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <Twitter className="h-3.5 w-3.5" /> Twitter / X
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={twitter} onChange={(e) => setTwitter(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <AtSign className="h-3.5 w-3.5" /> Telegram
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={telegram} onChange={(e) => setTelegram(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div className="flex items-center justify-between rounded-lg border border-app-border bg-app-surface p-3">
                <div>
                  <p className="text-sm font-medium text-app-text">Show socials publicly</p>
                  <p className="text-xs text-app-muted">Others can see your Twitter and Telegram</p>
                </div>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-6 w-11 rounded-full transition-colors ${showSocials ? 'bg-app-accent' : 'bg-app-border'}`}>
                  <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-5' : 'translate-x-0.5'}`} />
                </button>
              </div>

              {submitError && <p className="text-xs text-red-400">{submitError}</p>}

              <div className="flex gap-2">
                <Button variant="outline" className="flex-1" onClick={() => setStep(1)}>Back</Button>
                <Button className="flex-1" size="lg" onClick={handleSubmit} disabled={submitting}>
                  {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</> : 'Create profile'}
                </Button>
              </div>
              <button onClick={handleSubmit} disabled={submitting}
                className="w-full text-xs text-app-muted hover:text-app-text transition-colors">
                Skip socials →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx"

mkdir -p "afrifx-web/app/admin/analytics"
cat > "afrifx-web/app/admin/analytics/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  BarChart, Bar, PieChart, Pie, Cell,
  XAxis, YAxis, Tooltip, ResponsiveContainer,
} from 'recharts'
import { Loader2 } from 'lucide-react'
import { useTokens } from '@/lib/tokens'

export default function AdminAnalytics() {
  const t = useTokens()
  const [data, setData]       = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/analytics')
      .then(r => r.json()).then(setData)
      .catch(() => {}).finally(() => setLoading(false))
  }, [])

  const splitData = data ? [
    { name: 'Direct', value: data.split.direct.volume, color: t.accent },
    { name: 'P2P',    value: data.split.p2p.volume,    color: '#10B981' },
  ] : []

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-app-text">Platform analytics</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="grid gap-4 lg:grid-cols-2">
          {/* Volume by corridor */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Volume by corridor</p>
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={data?.corridors ?? []} layout="vertical" barSize={16}>
                <XAxis type="number" tick={{ fill: t.muted, fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => `$${v}`} />
                <YAxis type="category" dataKey="pair" tick={{ fill: t.text, fontSize: 10 }} axisLine={false} tickLine={false} width={70} />
                <Tooltip
                  contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 12 }}
                  itemStyle={{ color: t.text }}
                  formatter={(v: number) => [`$${v.toLocaleString()}`, 'Volume']}
                />
                <Bar dataKey="volume" fill={t.accent} radius={[0,4,4,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>

          {/* P2P vs Direct */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">P2P vs Direct conversion</p>
            <ResponsiveContainer width="100%" height={200}>
              <PieChart>
                <Pie data={splitData} cx="50%" cy="50%" innerRadius={50} outerRadius={80} paddingAngle={4} dataKey="value">
                  {splitData.map((e, i) => <Cell key={i} fill={e.color} />)}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background:   t.surface,
                    border:       `1px solid ${t.border}`,
                    borderRadius: 8,
                    fontSize:     12,
                    color:        t.text,
                  }}
                  labelStyle={{ color: t.text }}
                  itemStyle={{ color: t.text }}
                  formatter={(v: number, name: string) => [`$${v.toLocaleString()}`, name]}
                />
              </PieChart>
            </ResponsiveContainer>
            <div className="mt-2 flex justify-center gap-4">
              {splitData.map(d => (
                <div key={d.name} className="flex items-center gap-1.5 text-xs">
                  <span className="h-2.5 w-2.5 rounded-full" style={{ background: d.color }} />
                  <span className="text-app-muted">{d.name}: ${d.value.toLocaleString()}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/analytics/page.tsx"

mkdir -p "afrifx-web/app/admin/audit"
cat > "afrifx-web/app/admin/audit/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Loader2, ScrollText } from 'lucide-react'

const ACTION_COLOR: Record<string, string> = {
  login:              'text-app-muted',
  logout:             'text-app-muted',
  create_sub_admin:   'text-emerald-400',
  update_sub_admin:   'text-app-accent-text',
  delete_sub_admin:   'text-red-400',
  force_release_offer:'text-amber-400',
  force_cancel_offer: 'text-red-400',
  resolve_dispute:    'text-emerald-400',
  suspend_user:       'text-red-400',
  unsuspend_user:     'text-emerald-400',
  update_credentials: 'text-app-accent-text',
}

export default function AdminAudit() {
  const [logs, setLogs]       = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/audit')
      .then(r => r.json())
      .then(d => setLogs(Array.isArray(d) ? d.map((r: any) => Array.isArray(r) ? {
        id: r[0], admin_id: r[1], admin_name: r[2], action: r[3],
        target_type: r[4], target_id: r[5], details: r[6],
        ip_address: r[7], created_at: r[8],
      } : r) : []))
      .catch(() => {}).finally(() => setLoading(false))
  }, [])

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-app-text">Audit log</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : logs.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <ScrollText className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No activity logged yet</p>
        </div>
      ) : (
        <div className="rounded-xl border border-app-border bg-app-surface overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-app-border text-left text-xs text-app-muted">
                <th className="px-4 py-3 font-medium">Admin</th>
                <th className="px-4 py-3 font-medium">Action</th>
                <th className="px-4 py-3 font-medium">Details</th>
                <th className="px-4 py-3 font-medium">When</th>
              </tr>
            </thead>
            <tbody>
              {logs.map(log => (
                <tr key={log.id} className="border-b border-app-border/50 last:border-0">
                  <td className="px-4 py-3">
                    <span className="font-medium text-app-text">{log.admin_name}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`font-mono text-xs ${ACTION_COLOR[log.action] ?? 'text-app-text'}`}>
                      {log.action}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-xs text-app-muted max-w-md truncate">
                    {log.details ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-xs text-app-muted whitespace-nowrap">
                    {new Date(Number(log.created_at) * 1000).toLocaleString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/audit/page.tsx"

mkdir -p "afrifx-web/app/admin/dashboard"
cat > "afrifx-web/app/admin/dashboard/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from 'recharts'
import {
  TrendingUp, DollarSign, Store, AlertTriangle,
  Users, UserPlus, Loader2,
} from 'lucide-react'
import { useTokens } from '@/lib/tokens'

export default function AdminDashboard() {
  const t = useTokens()
  const [data, setData]       = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/overview')
      .then(r => r.json())
      .then(setData)
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-app-text">Platform Overview</h1>

      {loading ? (
        <div className="flex h-64 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : (
        <>
          {/* Stat cards */}
          <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
            {[
              { label: 'Total volume',  value: `$${(data?.totalVolume ?? 0).toLocaleString()}`, icon: TrendingUp, color: 'text-app-accent-text' },
              { label: 'Fees collected',value: `$${(data?.totalFees ?? 0).toLocaleString()}`,   icon: DollarSign, color: 'text-emerald-400' },
              { label: 'Total users',   value: String(data?.totalUsers ?? 0),                   icon: Users,      color: 'text-app-accent-text' },
              { label: 'New this week', value: `+${data?.newUsersWeek ?? 0}`,                    icon: UserPlus,   color: 'text-emerald-400' },
            ].map(({ label, value, icon: Icon, color }) => (
              <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
                <div className="mb-2 flex items-center justify-between">
                  <p className="text-xs text-app-muted">{label}</p>
                  <Icon className={`h-4 w-4 ${color}`} />
                </div>
                <p className="font-mono text-2xl font-bold text-app-text">{value}</p>
              </div>
            ))}
          </div>

          {/* P2P + disputes row */}
          <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-5">
            {[
              { label: 'Open offers',    value: data?.p2p.open      ?? 0, color: 'text-amber-400'   },
              { label: 'Active trades',  value: data?.p2p.accepted  ?? 0, color: 'text-app-accent-text'   },
              { label: 'Completed',      value: data?.p2p.released  ?? 0, color: 'text-emerald-400' },
              { label: 'Cancelled',      value: data?.p2p.cancelled ?? 0, color: 'text-app-muted'   },
              { label: 'Open disputes',  value: data?.openDisputes  ?? 0, color: 'text-red-400'     },
            ].map(({ label, value, color }) => (
              <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4 text-center">
                <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
                <p className="mt-1 text-xs text-app-muted">{label}</p>
              </div>
            ))}
          </div>

          {/* Volume chart */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Platform volume (14 days)</p>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data?.chartData ?? []} barSize={20}>
                <XAxis dataKey="label" tick={{ fill: t.muted, fontSize: 10 }} axisLine={{ stroke: t.border }} tickLine={false} />
                <YAxis tick={{ fill: t.muted, fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => `$${v}`} />
                <Tooltip
                  contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: t.text }} itemStyle={{ color: t.text }}
                  cursor={{ fill: t.border }}
                  formatter={(v: number) => [`$${v.toLocaleString()}`, 'Volume']}
                />
                <Bar dataKey="volume" radius={[4,4,0,0]}>
                  {(data?.chartData ?? []).map((e: any, i: number) => (
                    <Cell key={i} fill={e.volume > 0 ? t.accent : t.border} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/dashboard/page.tsx"

mkdir -p "afrifx-web/app/admin/disputes"
cat > "afrifx-web/app/admin/disputes/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell }    from '@/components/admin/AdminShell'
import { Badge }         from '@/components/ui/badge'
import { Button }        from '@/components/ui/button'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { DisputeChat }   from '@/components/dispute/DisputeChat'
import { formatAmount }  from '@/lib/utils'
import {
  AlertTriangle, CheckCircle, ExternalLink,
  Loader2, Scale, RefreshCw, ChevronDown, ChevronUp,
  AlertCircle, X,
} from 'lucide-react'

export default function AdminDisputesPage() {
  const { admin }                     = useAdminAuth()
  const [disputes,   setDisputes]     = useState<any[]>([])
  const [loading,    setLoading]      = useState(true)
  const [filter,     setFilter]       = useState<'open'|'in_review'|'resolved'|'all'>('open')
  const [resolving,  setResolving]    = useState<string|null>(null)
  const [accepting,  setAccepting]    = useState<string|null>(null)
  const [expanded,   setExpanded]     = useState<string|null>(null)
  const [assignments, setAssignments] = useState<Record<string, any>>({})
  const [error,       setError]       = useState<string|null>(null)

  async function load() {
    setLoading(true)
    try {
      const res  = await adminFetch(`/disputes/admin/all${filter !== 'all' ? `?status=${filter}` : ''}`)
      const data = await res.json()
      const list = Array.isArray(data) ? data : []
      setDisputes(list)

      // Fetch assignments for all disputes
      const assignMap: Record<string, any> = {}
      await Promise.all(list.map(async (d: any) => {
        const id = d.id ?? d[0]
        try {
          const r = await adminFetch(`/disputes/${id}/assignment`)
          const a = await r.json()
          if (a) assignMap[id] = a
        } catch {}
      }))
      setAssignments(assignMap)
    } catch { setDisputes([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [filter])

  async function acceptDispute(disputeId: string) {
    if (!admin) return
    setAccepting(disputeId)
    try {
      const res = await adminFetch(`/disputes/${disputeId}/accept`, {
        method: 'POST',
        body:   JSON.stringify({ adminId: admin.id, adminName: admin.username }),
      })
      const data = await res.json()
      if (data.success) {
        setFilter('in_review') // switch to in_review tab
        await load()
        setExpanded(disputeId) // auto-expand to show chat
      } else {
        setError(data.error ?? 'Failed to accept dispute')
      }
    } catch (err: any) { setError(err.message ?? 'Failed to accept dispute') }
    finally { setAccepting(null) }
  }

  async function resolve(disputeId: string, resolution: string) {
    if (!confirm(`Resolve as "${resolution}"?`)) return
    setResolving(disputeId)
    try {
      await adminFetch(`/disputes/${disputeId}/resolve`, {
        method: 'PATCH',
        body:   JSON.stringify({
          resolution,
          resolvedBy: admin?.username ?? 'admin',
          notes:      `Admin resolved: ${resolution}`,
        }),
      })
      await load()
    } catch (err: any) { setError(err.message ?? 'Failed to resolve dispute') }
    finally { setResolving(null) }
  }

  const openCount     = disputes.filter(d => (d.status ?? d[4]) === 'open').length
  const inReviewCount = disputes.filter(d => (d.status ?? d[4]) === 'in_review').length
  const resolvedCount = disputes.filter(d => (d.status ?? d[4]) === 'resolved').length

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Disputes</h1>
          <p className="text-sm text-app-muted">
            {openCount} open · {inReviewCount} in review · {resolvedCount} resolved
          </p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {(['open','in_review','resolved','all'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
            {f.replace('_', ' ')}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <Scale className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No {filter} disputes</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map((d: any) => {
            const id           = d.id            ?? d[0]
            const offerId      = d.offer_id      ?? d[1]
            const raisedBy     = d.raised_by     ?? d[2]
            const reason       = d.reason        ?? d[3]
            const status       = d.status        ?? d[4]
            const disputeType  = d.dispute_type  ?? 'maker_not_received'
            const raisedByRole = d.raised_by_role ?? 'taker'
            const createdAt    = Number(d.created_at ?? d[8] ?? 0)
            const resolution   = d.resolution_type
            const usdcAmount   = Number(d.usdc_amount   ?? 0)
            const localCcy     = d.local_currency ?? ''
            const localAmt     = Number(d.local_amount  ?? 0)
            const makerAddr    = d.maker_address  ?? ''
            const takerAddr    = d.taker_address  ?? ''

            const isOpen      = status === 'open'
            const isInReview  = status === 'in_review'
            const assignment  = assignments[id]
            const isMyCase    = assignment?.admin_id === admin?.id
            const isExpanded  = expanded === id

            return (
              <div key={id}
                className={`rounded-xl border bg-app-surface overflow-hidden
                  ${isOpen ? 'border-amber-900/50' :
                    isInReview ? 'border-app-accent/40' : 'border-app-border'}`}>

                {/* Header */}
                <div className="p-5">
                  <div className="mb-3 flex flex-wrap items-start gap-3">
                    <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full
                      ${isOpen ? 'bg-amber-900/20' : isInReview ? 'bg-app-accent/10' : 'bg-emerald-900/20'}`}>
                      {isOpen ? <AlertTriangle className="h-5 w-5 text-amber-400" />
                       : isInReview ? <Scale className="h-5 w-5 text-app-accent-text" />
                       : <CheckCircle className="h-5 w-5 text-emerald-400" />}
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="flex flex-wrap items-center gap-2 mb-1">
                        <Badge variant={isOpen ? 'warning' : isInReview ? 'arc' : 'success'}>
                          {status.replace('_', ' ')}
                        </Badge>
                        <Badge variant={disputeType === 'maker_silent' ? 'arc' : 'danger'}>
                          {disputeType === 'maker_silent' ? '🔇 Maker silent' : '💸 Payment not received'}
                        </Badge>
                        <Badge variant={raisedByRole === 'maker' ? 'warning' : 'arc'}>
                          By {raisedByRole}
                        </Badge>
                        {assignment && (
                          <Badge variant="success">⚖️ {assignment.admin_name}</Badge>
                        )}
                      </div>
                      <p className="text-xs text-app-muted">
                        {new Date(createdAt * 1000).toLocaleString()} ·
                        <span className="font-mono text-app-accent-text ml-1">{offerId?.slice(0,16)}…</span>
                      </p>
                    </div>

                    {/* Expand toggle */}
                    <button onClick={() => setExpanded(isExpanded ? null : id)}
                      className="text-app-muted hover:text-app-text">
                      {isExpanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                    </button>
                  </div>

                  {/* Trade details */}
                  <div className="mb-3 grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">USDC</p>
                      <p className="font-mono font-semibold text-app-text">${formatAmount(usdcAmount)}</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Local</p>
                      <p className="font-mono font-semibold text-app-text">{localAmt.toLocaleString()} {localCcy}</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Maker</p>
                      <p className="font-mono text-app-text">{makerAddr.slice(0,10)}…</p>
                    </div>
                    <div className="rounded-lg bg-app-bg p-2">
                      <p className="text-app-muted">Taker</p>
                      <p className="font-mono text-app-text">{takerAddr.slice(0,10)}…</p>
                    </div>
                  </div>

                  {/* Reason */}
                  <div className="mb-3 rounded-lg bg-app-bg p-2.5 text-xs">
                    <p className="text-app-muted mb-1">Reason</p>
                    <p className="text-app-text">{reason || '—'}</p>
                  </div>

                  {/* Resolution */}
                  {resolution && (
                    <div className="mb-3 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                      Resolved: {resolution.replace(/_/g, ' ')}
                    </div>
                  )}

                  {/* Actions */}
                  <div className="flex flex-wrap gap-2">
                    {/* Accept button — for unassigned open disputes */}
                    {isOpen && !assignment && (
                      <Button size="sm" onClick={() => acceptDispute(id)}
                        disabled={accepting === id}>
                        {accepting === id
                          ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          : <Scale className="h-3.5 w-3.5" />
                        }
                        Accept dispute — become judge
                      </Button>
                    )}

                    {/* Already assigned to another admin */}
                    {(isOpen || isInReview) && assignment && !isMyCase && (
                      <p className="text-xs text-app-muted py-1">
                        Handled by Admin {assignment.admin_name}
                      </p>
                    )}

                    {/* Resolve buttons — only for assigned admin */}
                    {isInReview && isMyCase && (
                      <>
                        <Button size="sm"
                          onClick={() => resolve(id, 'release_to_taker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <CheckCircle className="h-3.5 w-3.5" />}
                          Release to taker
                        </Button>
                        <Button size="sm" variant="danger"
                          onClick={() => resolve(id, 'refund_maker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <AlertTriangle className="h-3.5 w-3.5" />}
                          Refund maker
                        </Button>
                      </>
                    )}

                    <a href={`https://testnet.arcscan.app`} target="_blank" rel="noopener noreferrer"
                      className="ml-auto text-app-muted hover:text-app-accent-text">
                      <ExternalLink className="h-4 w-4" />
                    </a>
                  </div>
                </div>

                {/* Chat — expanded section */}
                {isExpanded && admin && (isInReview || isOpen) && isMyCase && (
                  <div className="border-t border-app-border p-4">
                    <p className="mb-2 text-xs font-medium text-app-muted">
                      ⚖️ Messages go to both parties · Request statements privately below
                    </p>
                    {/* Request statement buttons */}
                    <div className="mb-3 flex gap-2">
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank account statement for the disputed period so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-app-accent/40 bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent-text hover:bg-app-accent/20 transition-colors">
                        📋 Request statement from maker
                      </button>
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank transfer receipt or proof of payment so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-app-accent/40 bg-app-accent/10 px-3 py-1.5 text-xs text-app-accent-text hover:bg-app-accent/20 transition-colors">
                        📋 Request statement from taker
                      </button>
                    </div>
                    <DisputeChat
                      disputeId={id}
                      senderId={admin.id}
                      senderType="admin"
                      senderName={admin.username}
                      viewerType="admin"
                      title="Three-way dispute chat"
                    />
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/disputes/page.tsx"

mkdir -p "afrifx-web/app/admin/invite/[token]"
cat > "afrifx-web/app/admin/invite/[token]/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, User, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function AcceptInvitePage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { acceptInvite } = useAdminAuth()

  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleAccept() {
    setError(null)
    if (!username || !password) { setError('Username and password are required'); return }
    if (password !== confirm)   { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await acceptInvite(params.token, username, password)
      if (result.success) {
        setDone(true)
        setTimeout(() => router.push('/admin/dashboard'), 1200)
      } else {
        setError((result as any).error ?? 'Could not accept invitation')
      }
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-app-accent/10">
            <Shield className="h-7 w-7 text-app-accent-text" />
          </div>
          <h1 className="text-2xl font-bold text-app-text">Accept invitation</h1>
          <p className="text-sm text-app-muted">Set up your AfriFX admin account</p>
        </div>

        <div className="rounded-2xl border border-app-border bg-app-surface p-6">
          {done ? (
            <div className="flex flex-col items-center gap-2 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-app-text">Account created — redirecting…</p>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" placeholder="Choose a username" autoComplete="off"
                  value={username} onChange={e => setUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleAccept()} />
              </div>
              <p className="text-[11px] text-app-muted leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleAccept} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Setting up…</> : <>Accept & create account</>}
              </Button>

              {error && (
                <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/invite/[token]/page.tsx"

mkdir -p "afrifx-web/app/admin/no-access"
cat > "afrifx-web/app/admin/no-access/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ShieldOff, LogOut } from 'lucide-react'
import { TOKEN_KEY, ADMIN_KEY } from '@/hooks/useAdminAuth'

// IMPORTANT: This page does NOT use AdminShell
// to avoid infinite redirect loops for sub-admins with no permissions

export default function NoAccessPage() {
  const router             = useRouter()
  const [username, setUsername] = useState('')
  const [checked,  setChecked]  = useState(false)

  useEffect(() => {
    // One-time check — do not loop
    const token    = sessionStorage.getItem(TOKEN_KEY)
    const adminRaw = sessionStorage.getItem(ADMIN_KEY)
    if (!token || !adminRaw) {
      router.replace('/admin')
      return
    }
    try {
      const admin = JSON.parse(adminRaw)
      setUsername(admin.username ?? '')
    } catch {}
    setChecked(true)
  }, []) // Empty deps — run once only, no loop

  function handleLogout() {
    sessionStorage.removeItem(TOKEN_KEY)
    sessionStorage.removeItem(ADMIN_KEY)
    router.replace('/admin')
  }

  if (!checked) return null

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-app-bg px-4">
      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-8 text-center">
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-amber-900/20 border border-amber-900/40">
          <ShieldOff className="h-8 w-8 text-amber-400" />
        </div>
        <h1 className="mb-2 text-lg font-semibold text-app-text">
          No permissions assigned
        </h1>
        {username && (
          <p className="mb-1 text-sm text-app-accent-text">@{username}</p>
        )}
        <p className="mb-6 text-sm text-app-muted">
          Your admin account has been created but no permissions have been
          assigned yet. Please contact the super admin to grant you access
          to the relevant sections.
        </p>
        <div className="mb-6 rounded-xl border border-app-border bg-app-bg p-4 text-left text-xs text-app-muted space-y-1.5">
          <p className="font-medium text-app-text">What the super admin needs to do:</p>
          <p>1. Go to Admin panel → Sub-admins</p>
          <p>2. Find your account and click Edit</p>
          <p>3. Assign the required permissions</p>
          <p>4. You can then log back in</p>
        </div>
        <button onClick={handleLogout}
          className="flex w-full items-center justify-center gap-2 rounded-xl border border-app-border px-4 py-2.5 text-sm text-app-muted hover:bg-app-bg hover:text-red-400 transition-colors">
          <LogOut className="h-4 w-4" />
          Sign out
        </button>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/no-access/page.tsx"

mkdir -p "afrifx-web/app/admin/offers"
cat > "afrifx-web/app/admin/offers/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, ExternalLink, RefreshCw, AlertCircle, X } from 'lucide-react'

const FLAGS: Record<string,string> = { NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬' }

function norm(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], maker_address: r[1], taker_address: r[2], usdc_amount: r[3],
    local_currency: r[4], local_amount: r[5], status: r[7],
    maker_confirmed: r[8], taker_confirmed: r[9], created_at: r[13],
  }
  return r
}

export default function AdminOffers() {
  const [offers,  setOffers]  = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [filter,  setFilter]  = useState('all')
  const [busy,    setBusy]    = useState<string|null>(null)
  const [error,   setError]   = useState<string|null>(null)

  async function load() {
    setLoading(true)
    const q = filter === 'all' ? '' : `?status=${filter}`
    const res = await adminFetch(`/admin/manage/offers${q}`)
    const data = await res.json()
    setOffers(Array.isArray(data) ? data.map(norm) : [])
    setLoading(false)
  }

  useEffect(() => { load() }, [filter])

  async function forceRelease(id: string) {
    if (!confirm('Force release USDC to the taker? This is irreversible.')) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/release`, { method: 'POST' })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to release offer')
    } finally { setBusy(null) }
  }

  async function forceCancel(id: string) {
    const reason = prompt('Reason for cancellation (refunds maker):')
    if (reason === null) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/cancel`, {
        method: 'POST', body: JSON.stringify({ reason }),
      })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to cancel offer')
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">Offers management</h1>
        <button onClick={load} className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      <div className="mb-4 flex gap-2">
        {['all','open','accepted','released','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-full px-3 py-1 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-accent text-app-on-accent' : 'border border-app-border text-app-muted'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="space-y-2">
          {offers.map(o => (
            <div key={o.id} className="rounded-xl border border-app-border bg-app-surface p-4">
              <div className="flex items-center gap-4">
                <div className="flex h-9 w-9 items-center justify-center rounded-full bg-app-bg text-lg">
                  {FLAGS[o.local_currency] ?? '🌍'}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-medium text-app-text">
                      {Number(o.usdc_amount).toFixed(2)} USDC ↔ {Number(o.local_amount).toLocaleString()} {o.local_currency}
                    </p>
                    <Badge variant={
                      o.status === 'released' ? 'success' :
                      o.status === 'accepted' ? 'arc' :
                      o.status === 'cancelled' ? 'danger' : 'warning'
                    }>{o.status}</Badge>
                  </div>
                  <p className="font-mono text-[10px] text-app-muted">
                    {o.id.slice(0,20)}… · maker {o.maker_address?.slice(0,8)}…
                    {o.taker_address && ` · taker ${o.taker_address.slice(0,8)}…`}
                  </p>
                </div>
                {o.status === 'accepted' && (
                  <div className="flex gap-2">
                    <Button size="sm" onClick={() => forceRelease(o.id)} disabled={busy === o.id}>
                      {busy === o.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Force release'}
                    </Button>
                    <Button size="sm" variant="danger" onClick={() => forceCancel(o.id)} disabled={busy === o.id}>
                      Cancel
                    </Button>
                  </div>
                )}
              </div>
            </div>
          ))}
          {offers.length === 0 && <p className="py-8 text-center text-sm text-app-muted">No offers found</p>}
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/offers/page.tsx"

mkdir -p "afrifx-web/app/admin"
cat > "afrifx-web/app/admin/page.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Shield, Lock, Mail, User, Loader2, AlertCircle,
  KeyRound, ArrowLeft,
} from 'lucide-react'

const PERMISSION_PAGES = [
  { perm: 'manage_offers',    path: '/admin/offers'     },
  { perm: 'resolve_disputes', path: '/admin/disputes'   },
  { perm: 'manage_users',     path: '/admin/users'      },
  { perm: 'view_analytics',   path: '/admin/analytics'  },
  { perm: 'manage_admins',    path: '/admin/sub-admins' },
  { perm: 'view_audit_log',   path: '/admin/audit'      },
]

function getRedirectPath(role: string, permissions: string[]): string {
  if (role === 'super_admin' || permissions.includes('view_dashboard') || permissions.includes('all')) {
    return '/admin/dashboard'
  }
  const first = PERMISSION_PAGES.find(p => permissions.includes(p.perm))
  return first ? first.path : '/admin/no-access'
}

type Mode = 'checking' | 'setup' | 'login'

export default function AdminLoginPage() {
  const router = useRouter()
  const { checkSetupStatus, setup, login, forgotPassword } = useAdminAuth()

  const [mode, setMode] = useState<Mode>('checking')

  // Setup fields
  const [setupUsername, setSetupUsername] = useState('')
  const [setupEmail,    setSetupEmail]    = useState('')
  const [setupPassword, setSetupPassword] = useState('')
  const [setupConfirm,  setSetupConfirm]  = useState('')

  // Login fields
  const [email,    setEmail]    = useState('')
  const [password, setPassword] = useState('')
  const [totpCode, setTotpCode] = useState('')
  const [needs2FA, setNeeds2FA] = useState(false)

  // Forgot password
  const [showForgot,   setShowForgot]   = useState(false)
  const [forgotEmail,  setForgotEmail]  = useState('')
  const [forgotSent,   setForgotSent]   = useState(false)

  const [error,   setError]   = useState<string | null>(null)
  const [busy,    setBusy]    = useState(false)

  useEffect(() => {
    checkSetupStatus()
      .then(needsSetup => setMode(needsSetup ? 'setup' : 'login'))
      .catch(() => setMode('login'))
  }, [])

  async function handleSetup() {
    setError(null)
    if (!setupUsername || !setupEmail || !setupPassword) {
      setError('All fields are required'); return
    }
    if (setupPassword !== setupConfirm) {
      setError('Passwords do not match'); return
    }
    setBusy(true)
    try {
      const result = await setup(setupEmail, setupPassword, setupUsername)
      if (result.success) {
        router.push('/admin/settings?onboarding=2fa')
      } else {
        setError((result as any).error ?? 'Setup failed')
      }
    } finally { setBusy(false) }
  }

  async function handleLogin() {
    setError(null)
    if (!email || !password) { setError('Email and password are required'); return }
    if (needs2FA && !totpCode) { setError('Enter your 6-digit authenticator code'); return }

    setBusy(true)
    try {
      const result = await login(email, password, needs2FA ? totpCode : undefined)
      if (result.success && result.admin) {
        router.push(getRedirectPath(result.admin.role, result.admin.permissions))
      } else if ((result as any).needs2FA) {
        setNeeds2FA(true)
      } else {
        setError((result as any).error ?? 'Login failed')
      }
    } finally { setBusy(false) }
  }

  async function handleForgot() {
    setError(null)
    if (!forgotEmail) { setError('Enter your email'); return }
    setBusy(true)
    try {
      const result = await forgotPassword(forgotEmail)
      if (result.success) setForgotSent(true)
      else setError((result as any).error ?? 'Request failed')
    } finally { setBusy(false) }
  }

  if (mode === 'checking') {
    return (
      <div className="flex min-h-screen items-center justify-center bg-app-bg">
        <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-app-accent/10">
            <Shield className="h-7 w-7 text-app-accent-text" />
          </div>
          <h1 className="text-2xl font-bold text-app-text">AfriFX Admin</h1>
          <p className="text-sm text-app-muted">
            {mode === 'setup' ? 'Create the super admin account' : 'Sign in to continue'}
          </p>
        </div>

        <div className="rounded-2xl border border-app-border bg-app-surface p-6">
          {mode === 'setup' && (
            <div className="space-y-3">
              <div className="text-center mb-2">
                <p className="text-sm font-medium text-app-text">First-time setup</p>
                <p className="text-xs text-app-muted">No admin account exists yet — create the super admin</p>
              </div>
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" placeholder="Username" autoComplete="off"
                  value={setupUsername} onChange={e => setSetupUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                  value={setupEmail} onChange={e => setSetupEmail(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={setupPassword} onChange={e => setSetupPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={setupConfirm} onChange={e => setSetupConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleSetup()} />
              </div>
              <p className="text-[11px] text-app-muted leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleSetup} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating account…</>
                      : <>Create super admin</>}
              </Button>
            </div>
          )}

          {mode === 'login' && !showForgot && (
            <div className="space-y-3">
              {!needs2FA ? (
                <>
                  <div className="text-center mb-2">
                    <Lock className="mx-auto mb-2 h-8 w-8 text-app-accent-text" />
                    <p className="text-sm font-medium text-app-text">Enter credentials</p>
                  </div>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                    <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                      value={email} onChange={e => setEmail(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <div className="relative">
                    <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                    <Input className="pl-9" type="password" placeholder="Password" autoComplete="current-password"
                      value={password} onChange={e => setPassword(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <Button className="w-full" onClick={handleLogin} disabled={!email || !password || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Signing in…</>
                          : <><Lock className="h-4 w-4" /> Sign in</>}
                  </Button>
                  <button onClick={() => { setShowForgot(true); setError(null) }}
                    className="w-full text-xs text-app-muted hover:text-app-text transition-colors">
                    Forgot password?
                  </button>
                </>
              ) : (
                <>
                  <div className="text-center mb-2">
                    <KeyRound className="mx-auto mb-2 h-8 w-8 text-app-accent-text" />
                    <p className="text-sm font-medium text-app-text">Two-factor authentication</p>
                    <p className="text-xs text-app-muted">Enter the 6-digit code from your authenticator app</p>
                  </div>
                  <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
                    maxLength={6} inputMode="numeric" autoFocus
                    value={totpCode} onChange={e => setTotpCode(e.target.value.replace(/\D/g, ''))}
                    onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  <Button className="w-full" onClick={handleLogin} disabled={totpCode.length !== 6 || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & sign in</>}
                  </Button>
                  <button onClick={() => { setNeeds2FA(false); setTotpCode(''); setError(null) }}
                    className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text transition-colors">
                    <ArrowLeft className="h-3 w-3" /> Back
                  </button>
                </>
              )}
            </div>
          )}

          {mode === 'login' && showForgot && (
            <div className="space-y-3">
              {!forgotSent ? (
                <>
                  <div className="text-center mb-2">
                    <Mail className="mx-auto mb-2 h-8 w-8 text-app-accent-text" />
                    <p className="text-sm font-medium text-app-text">Reset your password</p>
                    <p className="text-xs text-app-muted">We'll email you a reset link</p>
                  </div>
                  <Input type="email" placeholder="Your admin email" autoComplete="off"
                    value={forgotEmail} onChange={e => setForgotEmail(e.target.value)}
                    onKeyDown={e => e.key === 'Enter' && handleForgot()} />
                  <Button className="w-full" onClick={handleForgot} disabled={!forgotEmail || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : <>Send reset link</>}
                  </Button>
                </>
              ) : (
                <div className="rounded-lg bg-emerald-900/20 px-3 py-4 text-center text-sm text-emerald-400">
                  If that email is registered, a reset link is on its way. Check your inbox.
                </div>
              )}
              <button onClick={() => { setShowForgot(false); setForgotSent(false); setError(null) }}
                className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text transition-colors">
                <ArrowLeft className="h-3 w-3" /> Back to sign in
              </button>
            </div>
          )}

          {error && (
            <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
        </div>
        <p className="mt-4 text-center text-xs text-app-muted">🔒 Restricted area — all actions are logged</p>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/page.tsx"

mkdir -p "afrifx-web/app/admin/reset-password/[token]"
cat > "afrifx-web/app/admin/reset-password/[token]/page.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function ResetPasswordPage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { resetPassword } = useAdminAuth()

  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleReset() {
    setError(null)
    if (!password) { setError('Enter a new password'); return }
    if (password !== confirm) { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await resetPassword(params.token, password)
      if (result.success) setDone(true)
      else setError((result as any).error ?? 'Reset failed — the link may have expired')
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-app-accent/10">
            <Shield className="h-7 w-7 text-app-accent-text" />
          </div>
          <h1 className="text-2xl font-bold text-app-text">Reset password</h1>
          <p className="text-sm text-app-muted">Choose a new password for your admin account</p>
        </div>

        <div className="rounded-2xl border border-app-border bg-app-surface p-6">
          {done ? (
            <div className="flex flex-col items-center gap-3 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-app-text">Password updated</p>
              <Link href="/admin" className="w-full">
                <Button className="w-full">Go to sign in</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="New password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Confirm new password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleReset()} />
              </div>
              <p className="text-[11px] text-app-muted leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleReset} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
              </Button>

              {error && (
                <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/reset-password/[token]/page.tsx"

mkdir -p "afrifx-web/app/admin/settings"
cat > "afrifx-web/app/admin/settings/page.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import { AdminShell } from '@/components/admin/AdminShell'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import {
  Lock, ShieldCheck, ShieldOff, Loader2, AlertCircle,
  CheckCircle, KeyRound, Copy, Check,
} from 'lucide-react'

function ChangePasswordCard() {
  const { changePassword } = useAdminAuth()
  const [current,  setCurrent]  = useState('')
  const [next,     setNext]     = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [success,  setSuccess]  = useState(false)
  const [busy,     setBusy]     = useState(false)

  async function handleSubmit() {
    setError(null); setSuccess(false)
    if (!current || !next) { setError('All fields are required'); return }
    if (next !== confirm)  { setError('New passwords do not match'); return }

    setBusy(true)
    try {
      const result = await changePassword(current, next)
      if (result.success) {
        setSuccess(true)
        setCurrent(''); setNext(''); setConfirm('')
      } else {
        setError((result as any).error ?? 'Could not change password')
      }
    } finally { setBusy(false) }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Lock className="h-4 w-4 text-app-accent-text" /> Change password</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input type="password" placeholder="Current password" autoComplete="current-password"
          value={current} onChange={e => setCurrent(e.target.value)} />
        <Input type="password" placeholder="New password" autoComplete="new-password"
          value={next} onChange={e => setNext(e.target.value)} />
        <Input type="password" placeholder="Confirm new password" autoComplete="new-password"
          value={confirm} onChange={e => setConfirm(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && handleSubmit()} />
        <p className="text-[11px] text-app-muted">
          Min 12 characters, with uppercase, lowercase, a number, and a special character.
        </p>
        <Button onClick={handleSubmit} disabled={busy}>
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
        </Button>
        {success && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
            <CheckCircle className="h-3.5 w-3.5" /> Password updated
          </div>
        )}
        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function TwoFactorCard({ autoStart }: { autoStart: boolean }) {
  const { admin, setup2FA, verify2FA } = useAdminAuth()
  const [stage, setStage]   = useState<'idle' | 'qr' | 'recovery'>('idle')
  const [qrCode, setQrCode] = useState('')
  const [secret, setSecret] = useState('')
  const [code,   setCode]   = useState('')
  const [codes,  setCodes]  = useState<string[]>([])
  const [copied, setCopied] = useState(false)
  const [error,  setError]  = useState<string | null>(null)
  const [busy,   setBusy]   = useState(false)

  useEffect(() => {
    if (autoStart && admin && !admin.totpEnabled) handleStart()
  }, [autoStart, admin?.id])

  async function handleStart() {
    setError(null); setBusy(true)
    try {
      const result = await setup2FA()
      if (result.success) {
        setQrCode(result.qrCode!); setSecret(result.secret!); setStage('qr')
      } else {
        setError((result as any).error ?? 'Could not start 2FA setup')
      }
    } finally { setBusy(false) }
  }

  async function handleVerify() {
    setError(null)
    if (code.length !== 6) { setError('Enter the 6-digit code'); return }
    setBusy(true)
    try {
      const result = await verify2FA(code)
      if (result.success) {
        setCodes(result.recoveryCodes ?? [])
        setStage('recovery')
      } else {
        setError((result as any).error ?? 'Invalid code')
      }
    } finally { setBusy(false) }
  }

  function copyRecoveryCodes() {
    navigator.clipboard.writeText(codes.join('\n')).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  const enabled = admin?.totpEnabled && stage !== 'recovery'

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-app-accent-text" /> Two-factor authentication
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {enabled && stage === 'idle' && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
            <ShieldCheck className="h-4 w-4" /> 2FA is enabled on your account
          </div>
        )}

        {!enabled && stage === 'idle' && (
          <>
            <div className="flex items-center gap-2 rounded-lg bg-amber-900/20 px-3 py-2.5 text-xs text-amber-400">
              <ShieldOff className="h-4 w-4" /> 2FA is not enabled — we recommend turning it on
            </div>
            <Button onClick={handleStart} disabled={busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting…</> : <>Set up 2FA</>}
            </Button>
          </>
        )}

        {stage === 'qr' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              Scan this QR code with an authenticator app (Google Authenticator, 1Password, Authy).
            </p>
            {qrCode && (
              <div className="flex justify-center rounded-lg bg-white p-3">
                <img src={qrCode} alt="2FA QR code" className="h-40 w-40" />
              </div>
            )}
            <p className="break-all rounded-lg bg-app-bg p-2 text-center font-mono text-[10px] text-app-muted">
              {secret}
            </p>
            <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
              maxLength={6} inputMode="numeric"
              value={code} onChange={e => setCode(e.target.value.replace(/\D/g, ''))}
              onKeyDown={e => e.key === 'Enter' && handleVerify()} />
            <Button onClick={handleVerify} disabled={code.length !== 6 || busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & enable</>}
            </Button>
          </div>
        )}

        {stage === 'recovery' && (
          <div className="space-y-3">
            <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="h-4 w-4" /> 2FA enabled
            </div>
            <p className="text-xs text-app-muted">
              Save these recovery codes somewhere safe — each can be used once if you lose access to your authenticator.
            </p>
            <div className="grid grid-cols-2 gap-1.5 rounded-lg bg-app-bg p-3 font-mono text-xs text-app-text">
              {codes.map(c => <span key={c}>{c}</span>)}
            </div>
            <Button variant="outline" onClick={copyRecoveryCodes}>
              {copied ? <><Check className="h-4 w-4" /> Copied</> : <><Copy className="h-4 w-4" /> Copy codes</>}
            </Button>
          </div>
        )}

        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function SettingsBody() {
  const { admin } = useAdminAuth()
  const searchParams = useSearchParams()
  const autoStart2FA = searchParams.get('onboarding') === '2fa'

  return (
    <div className="mx-auto max-w-xl space-y-6">
      <div>
        <h1 className="text-lg font-semibold text-app-text">Account settings</h1>
        {admin && (
          <p className="text-sm text-app-muted">
            Signed in as <span className="text-app-accent-text">{admin.username}</span> · {admin.email}
          </p>
        )}
      </div>
      <ChangePasswordCard />
      <TwoFactorCard autoStart={autoStart2FA} />
    </div>
  )
}

export default function AdminSettingsPage() {
  return (
    <AdminShell>
      <Suspense fallback={
        <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-app-accent-text" /></div>
      }>
        <SettingsBody />
      </Suspense>
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/settings/page.tsx"

mkdir -p "afrifx-web/app/admin/sub-admins"
cat > "afrifx-web/app/admin/sub-admins/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Loader2, Plus, Shield, Trash2, Pause, Play,
  Key, Check, Mail, CheckCircle, AlertCircle, X,
} from 'lucide-react'

export default function AdminSubAdmins() {
  const { admin, invite } = useAdminAuth()
  const [admins,  setAdmins]  = useState<any[]>([])
  const [permMeta, setPermMeta] = useState<any>({})
  const [allPerms, setAllPerms] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [busy, setBusy] = useState<string|null>(null)

  // Invite form state
  const [inviteEmail, setInviteEmail] = useState('')
  const [selectedPerms, setSelectedPerms] = useState<string[]>([])
  const [inviteError,   setInviteError]   = useState<string|null>(null)
  const [inviteSuccess, setInviteSuccess] = useState<string|null>(null)

  // Editing
  const [editingId, setEditingId] = useState<string|null>(null)
  const [editPerms, setEditPerms] = useState<string[]>([])

  async function load() {
    setLoading(true)
    const [adminRes, permRes] = await Promise.all([
      adminFetch('/admin/manage/admins'),
      adminFetch('/admin/manage/permissions'),
    ])
    const adminData = await adminRes.json()
    const permData  = await permRes.json()
    setAdmins(Array.isArray(adminData) ? adminData : [])
    setPermMeta(permData.meta ?? {})
    setAllPerms(permData.all ?? [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function sendInvite() {
    if (!inviteEmail || selectedPerms.length === 0) return
    setInviteError(null); setInviteSuccess(null)
    setBusy('create')
    try {
      const result = await invite(inviteEmail, selectedPerms)
      if (result.success) {
        setInviteSuccess(result.message ?? `Invitation sent to ${inviteEmail}`)
        setInviteEmail(''); setSelectedPerms([])
      } else {
        setInviteError((result as any).error ?? 'Could not send invitation')
      }
    } finally { setBusy(null) }
  }

  async function toggleStatus(a: any) {
    setBusy(a.id)
    const newStatus = a.status === 'active' ? 'suspended' : 'active'
    let suspendedUntil = null
    if (newStatus === 'suspended') {
      const days = prompt('Suspend for how many days? (leave blank for indefinite)')
      if (days && !isNaN(Number(days))) {
        suspendedUntil = Math.floor(Date.now() / 1000) + Number(days) * 86400
      }
    }
    try {
      await adminFetch(`/admin/manage/admins/${a.id}`, {
        method: 'PATCH', body: JSON.stringify({ status: newStatus, suspendedUntil }),
      })
      await load()
    } finally { setBusy(null) }
  }

  async function deleteAdmin(id: string) {
    if (!confirm('Remove this sub-admin permanently?')) return
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, { method: 'DELETE' })
      await load()
    } finally { setBusy(null) }
  }

  async function savePerms(id: string) {
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, {
        method: 'PATCH', body: JSON.stringify({ permissions: editPerms }),
      })
      setEditingId(null)
      await load()
    } finally { setBusy(null) }
  }

  async function resetCredentials(a: any) {
    const newPassword = prompt(`Reset password for ${a.username}:\nEnter new password (min 12 chars):`)
    if (!newPassword) return
    setInviteError(null); setInviteSuccess(null)
    setBusy(a.id)
    try {
      const res = await adminFetch(`/admin/manage/admins/${a.id}/credentials`, {
        method: 'PATCH', body: JSON.stringify({ newPassword }),
      })
      if (res.ok) setInviteSuccess(`Password reset for ${a.username}`)
      else setInviteError((await res.json()).error ?? 'Failed to reset password')
    } finally { setBusy(null) }
  }

  function togglePerm(list: string[], setList: (l: string[]) => void, perm: string) {
    setList(list.includes(perm) ? list.filter(p => p !== perm) : [...list, perm])
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">Sub-admin management</h1>
        {admin?.role === 'super_admin' && (
          <Button size="sm" onClick={() => { setShowForm(!showForm); setInviteError(null); setInviteSuccess(null) }}>
            <Plus className="h-4 w-4" /> Invite sub-admin
          </Button>
        )}
      </div>

      {admin?.role !== 'super_admin' && (
        <div className="mb-6 flex items-center gap-2 rounded-lg bg-app-surface border border-app-border px-4 py-3 text-xs text-app-muted">
          Only the super admin can invite new sub-admins.
        </div>
      )}

      {/* Standalone feedback (e.g. after a password reset, when the invite form is closed) */}
      {!showForm && inviteSuccess && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
          <span className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
          </span>
          <button onClick={() => setInviteSuccess(null)} className="shrink-0 hover:text-emerald-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}
      {!showForm && inviteError && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
          </span>
          <button onClick={() => setInviteError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Invite form */}
      {showForm && (
        <div className="mb-6 rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-1 text-sm font-medium text-app-text">Invite a sub-admin</p>
          <p className="mb-4 text-xs text-app-muted">
            They'll get an email with a link to set their own password and, optionally, 2FA.
          </p>
          <div className="relative mb-4">
            <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
            <Input className="pl-9" placeholder="Email address" type="email" autoComplete="off"
              value={inviteEmail} onChange={e => setInviteEmail(e.target.value)} />
          </div>

          <p className="mb-2 text-xs font-medium text-app-text">Permissions</p>
          <div className="mb-4 grid grid-cols-2 gap-2 lg:grid-cols-3">
            {allPerms.map(perm => (
              <button key={perm} onClick={() => togglePerm(selectedPerms, setSelectedPerms, perm)}
                className={`flex items-start gap-2 rounded-lg border p-2.5 text-left transition-colors
                  ${selectedPerms.includes(perm)
                    ? 'border-app-accent bg-app-accent/10'
                    : 'border-app-border bg-app-bg'}`}>
                <div className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded
                  ${selectedPerms.includes(perm) ? 'bg-app-accent' : 'border border-app-border'}`}>
                  {selectedPerms.includes(perm) && <Check className="h-3 w-3 text-app-on-accent" />}
                </div>
                <div>
                  <p className="text-xs font-medium text-app-text">{permMeta[perm]?.label ?? perm}</p>
                  <p className="text-[10px] text-app-muted">{permMeta[perm]?.description}</p>
                </div>
              </button>
            ))}
          </div>

          <div className="flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setShowForm(false)}>Cancel</Button>
            <Button className="flex-1" onClick={sendInvite}
              disabled={!inviteEmail || selectedPerms.length === 0 || busy === 'create'}>
              {busy === 'create' ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Mail className="h-4 w-4" /> Send invite</>}
            </Button>
          </div>

          {inviteSuccess && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
            </div>
          )}
          {inviteError && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
            </div>
          )}
        </div>
      )}

      {/* Admins list */}
      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="space-y-3">
          {admins.map(a => (
            <div key={a.id} className="rounded-xl border border-app-border bg-app-surface p-5">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className={`flex h-10 w-10 items-center justify-center rounded-full
                    ${a.role === 'super_admin' ? 'bg-amber-500/20' : 'bg-app-accent/10'}`}>
                    <Shield className={`h-5 w-5 ${a.role === 'super_admin' ? 'text-amber-400' : 'text-app-accent-text'}`} />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-app-text">{a.username}</p>
                      <Badge variant={a.role === 'super_admin' ? 'warning' : 'arc'}>
                        {a.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
                      </Badge>
                      {a.status === 'suspended' && <Badge variant="danger">Suspended</Badge>}
                    </div>
                    <p className="text-xs text-app-muted">{a.email}</p>
                    {a.last_login && (
                      <p className="text-[10px] text-app-muted">
                        Last login: {new Date(Number(a.last_login) * 1000).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>

                {a.role !== 'super_admin' && (
                  <div className="flex gap-1">
                    <button onClick={() => resetCredentials(a)} disabled={busy === a.id}
                      title="Reset password"
                      className="rounded p-1.5 text-app-muted hover:text-app-accent-text">
                      <Key className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => toggleStatus(a)} disabled={busy === a.id}
                      title={a.status === 'active' ? 'Suspend' : 'Activate'}
                      className="rounded p-1.5 text-app-muted hover:text-amber-400">
                      {a.status === 'active' ? <Pause className="h-3.5 w-3.5" /> : <Play className="h-3.5 w-3.5" />}
                    </button>
                    <button onClick={() => deleteAdmin(a.id)} disabled={busy === a.id}
                      title="Remove"
                      className="rounded p-1.5 text-app-muted hover:text-red-400">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                )}
              </div>

              {/* Permissions */}
              {a.role !== 'super_admin' && (
                <div className="mt-3 border-t border-app-border pt-3">
                  {editingId === a.id ? (
                    <div>
                      <div className="mb-2 grid grid-cols-2 gap-2 lg:grid-cols-3">
                        {allPerms.map(perm => (
                          <button key={perm} onClick={() => togglePerm(editPerms, setEditPerms, perm)}
                            className={`flex items-center gap-1.5 rounded-lg border p-2 text-left text-xs transition-colors
                              ${editPerms.includes(perm) ? 'border-app-accent bg-app-accent/10 text-app-text' : 'border-app-border text-app-muted'}`}>
                            <div className={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded
                              ${editPerms.includes(perm) ? 'bg-app-accent' : 'border border-app-border'}`}>
                              {editPerms.includes(perm) && <Check className="h-2.5 w-2.5 text-app-on-accent" />}
                            </div>
                            {permMeta[perm]?.label ?? perm}
                          </button>
                        ))}
                      </div>
                      <div className="flex gap-2">
                        <Button size="sm" variant="outline" onClick={() => setEditingId(null)}>Cancel</Button>
                        <Button size="sm" onClick={() => savePerms(a.id)} disabled={busy === a.id}>
                          {busy === a.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Save permissions'}
                        </Button>
                      </div>
                    </div>
                  ) : (
                    <div className="flex items-center justify-between">
                      <div className="flex flex-wrap gap-1.5">
                        {(a.permissions ?? []).length === 0 ? (
                          <span className="text-xs text-app-muted">No permissions granted</span>
                        ) : (a.permissions ?? []).map((p: string) => (
                          <span key={p} className="rounded-full bg-app-border px-2 py-0.5 text-[10px] text-app-text">
                            {permMeta[p]?.label ?? p}
                          </span>
                        ))}
                      </div>
                      <button onClick={() => { setEditingId(a.id); setEditPerms(a.permissions ?? []) }}
                        className="shrink-0 text-xs text-app-accent-text hover:underline">
                        Edit permissions
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/sub-admins/page.tsx"

mkdir -p "afrifx-web/app/admin/users"
cat > "afrifx-web/app/admin/users/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Loader2, Search, Ban, CheckCircle } from 'lucide-react'

export default function AdminUsers() {
  const [users,   setUsers]   = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [search,  setSearch]  = useState('')
  const [busy,    setBusy]    = useState<string|null>(null)

  async function load(q = '') {
    setLoading(true)
    const res = await adminFetch(`/admin/manage/users${q ? `?search=${q}` : ''}`)
    const data = await res.json()
    setUsers(Array.isArray(data) ? data : [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function suspend(addr: string) {
    const reason = prompt('Reason for suspension:')
    if (reason === null) return
    setBusy(addr)
    try {
      await adminFetch(`/admin/manage/users/${addr}/suspend`, {
        method: 'POST', body: JSON.stringify({ reason }),
      })
      await load(search)
    } finally { setBusy(null) }
  }

  async function unsuspend(addr: string) {
    setBusy(addr)
    try {
      await adminFetch(`/admin/manage/users/${addr}/unsuspend`, { method: 'POST' })
      await load(search)
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-app-text">User management</h1>

      <div className="mb-4 flex gap-2">
        <div className="relative flex-1 max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
          <Input placeholder="Search by username, wallet or name…" value={search}
            onChange={e => setSearch(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && load(search)}
            className="pl-9" />
        </div>
        <Button size="sm" onClick={() => load(search)}>Search</Button>
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="space-y-2">
          {users.map(u => (
            <div key={u.wallet_address} className="flex items-center gap-4 rounded-xl border border-app-border bg-app-surface p-4">
              <div className="flex h-9 w-9 items-center justify-center rounded-full text-sm font-bold text-white"
                style={{ background: u.avatar_color ?? '#D9A441' }}>
                {(u.display_name ?? u.username ?? '?')[0].toUpperCase()}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="text-sm font-medium text-app-text">{u.display_name ?? u.username}</p>
                  <span className="text-xs text-app-accent-text">@{u.username}</span>
                  {u.verified ? <Badge variant="arc">Verified</Badge> : null}
                  {u.suspended ? <Badge variant="danger">Suspended</Badge> : null}
                </div>
                <p className="font-mono text-[10px] text-app-muted">{u.wallet_address}</p>
              </div>
              <div className="text-right text-xs">
                <p className="font-mono text-app-text">{u.trades} trades</p>
                <p className="text-app-muted">{new Date(Number(u.created_at) * 1000).toLocaleDateString()}</p>
              </div>
              {u.suspended ? (
                <Button size="sm" variant="outline" onClick={() => unsuspend(u.wallet_address)} disabled={busy === u.wallet_address}>
                  <CheckCircle className="h-3.5 w-3.5" /> Unsuspend
                </Button>
              ) : (
                <Button size="sm" variant="danger" onClick={() => suspend(u.wallet_address)} disabled={busy === u.wallet_address}>
                  <Ban className="h-3.5 w-3.5" /> Suspend
                </Button>
              )}
            </div>
          ))}
          {users.length === 0 && <p className="py-8 text-center text-sm text-app-muted">No users found</p>}
        </div>
      )}
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/users/page.tsx"

mkdir -p "afrifx-web/app"
cat > "afrifx-web/app/layout.tsx" << 'AFX_EOF'
import type { Metadata, Viewport } from 'next'
import { Providers } from './providers'
import '@/styles/globals.css'

export const metadata: Metadata = {
  title: 'AfriFX — Stablecoin FX on Arc',
  description: 'Instant stablecoin foreign exchange and cross-border payments for Africa, powered by Arc.',
  icons: {
    icon:     [{ url: '/favicon.svg', type: 'image/svg+xml' }],
    shortcut: '/favicon.svg',
    apple:    '/favicon.svg',
  },
  manifest: '/manifest.json',
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: dark)',  color: '#12100B' },
    { media: '(prefers-color-scheme: light)', color: '#F7F1E6' },
  ],
}

// Runs before first paint to set the theme class, preventing a flash of the
// wrong theme. Mirrors the logic in hooks/useTheme.tsx (manual pref wins,
// otherwise clock-based: light 06:00–17:59, dark otherwise).
const themeInitScript = `
(function() {
  try {
    var stored = localStorage.getItem('afrifx_theme');
    var theme;
    if (stored === 'light' || stored === 'dark') {
      theme = stored;
    } else {
      var h = new Date().getHours();
      theme = (h >= 6 && h < 18) ? 'light' : 'dark';
    }
    if (theme === 'light') document.documentElement.classList.add('light');
  } catch (e) {}
})();
`

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body
        className="min-h-screen bg-app-bg text-app-text"
        suppressHydrationWarning
      >
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
AFX_EOF
echo "  afrifx-web/app/layout.tsx"

mkdir -p "afrifx-web/app"
cat > "afrifx-web/app/providers.tsx" << 'AFX_EOF'
'use client'
import { WagmiProvider }       from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RainbowKitProvider, darkTheme, lightTheme } from '@rainbow-me/rainbowkit'
import { wagmiConfig }         from '@/lib/wagmi'
import { ThemeProvider, useTheme } from '@/hooks/useTheme'
import '@rainbow-me/rainbowkit/styles.css'

const queryClient = new QueryClient()

function RainbowKitThemed({ children }: { children: React.ReactNode }) {
  const { theme } = useTheme()
  const rkTheme = theme === 'light'
    ? lightTheme({
        accentColor:           '#8A5E13',
        accentColorForeground: 'white',
        borderRadius:          'large',
        fontStack:             'system',
        overlayBlur:           'small',
      })
    : darkTheme({
        accentColor:           '#D9A441',
        accentColorForeground: '#12100B',
        borderRadius:          'large',
        fontStack:             'system',
        overlayBlur:           'small',
      })
  return (
    <RainbowKitProvider theme={rkTheme} coolMode>
      {children}
    </RainbowKitProvider>
  )
}

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider>
          <RainbowKitThemed>
            {children}
          </RainbowKitThemed>
        </ThemeProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
AFX_EOF
echo "  afrifx-web/app/providers.tsx"

mkdir -p "afrifx-web/components/admin"
cat > "afrifx-web/components/admin/AdminShell.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { useTheme } from '@/hooks/useTheme'
import { ThemeToggle } from '@/components/layout/ThemeToggle'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2, Settings,
  Menu, X, Sun, Moon,
} from 'lucide-react'

// Full-width labeled theme toggle for the admin sidebar footer
function ThemeToggleRow() {
  const { theme, source, toggle } = useTheme()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  if (!mounted) {
    return <div className="h-9 rounded-lg border border-app-border" />
  }
  const isDark = theme === 'dark'
  return (
    <button onClick={toggle}
      className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
      {isDark ? <Moon className="h-3.5 w-3.5 shrink-0" /> : <Sun className="h-3.5 w-3.5 shrink-0" />}
      {isDark ? 'Dark mode' : 'Light mode'}
      {source === 'auto' && <span className="ml-auto text-[9px] text-app-accent-text">AUTO</span>}
    </button>
  )
}

const NAV = [
  { href: '/admshboard',  icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'   },
  { href: '/admin/offers',     icon: Store,           label: 'Offers',     perm: 'manage_offers'    },
  { href: '/admin/disputes',   icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes' },
  { href: '/admin/users',      icon: Users,           label: 'Users',      perm: 'manage_users'     },
  { href: '/admin/sub-admins', icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'    },
  { href: '/admin/analytics',  icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'   },
  { href: '/admin/audit',      icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'   },
]

function SidebarContent({
  admin, pathname, visibleNav, onLogout, onNavigate,
}: {
  admin:      { username: string; role: string }
  pathname:   string
  visibleNav: typeof NAV
  onLogout:   () => void
  onNavigate?: () => void
}) {
  return (
    <>
      <nav className="flex-1 overflow-y-auto py-3">
        {visibleNav.map(({ href, icon: Icon, label }) => {
          const active = pathname === href
          return (
            <Link key={href} href={href} onClick={onNavigate}
              className={`flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors
                ${active
                  ? 'bg-app-border font-medium text-app-text'
                  : 'text-app-muted hover:bg-app-bg hover:text-app-text'}`}>
              <Icon className="h-4 w-4 shrink-0" /> {label}
            </Link>
          )
        })}
      </nav>
      <div className="shrink-0 border-t border-app-border p-3 space-y-2">
        <div className="rounded-lg bg-app-bg px-3 py-2">
          <p className="text-xs font-medium text-app-text">{admin.username}</p>
          <p className="text-[10px] text-app-accent-text">
            {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
          </p>
        </div>
        <Link href="/admin/settings" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <Settings className="h-3.5 w-3.5 shrink-0" />
          Settings
        </Link>
        <Link href="/dashboard" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
          Main dashboard
        </Link>
        <button onClick={onLogout}
          className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-red-400 transition-colors">
          <LogOut className="h-3.5 w-3.5 shrink-0" />
          Logout
        </button>
        <ThemeToggleRow />
      </div>
    </>
  )
}

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router   = useRouter()
  const pathname = usePathname()
  const { admin, loading, logout, hasPermission } = useAdminAuth()
  const [drawerOpen, setDrawerOpen] = useState(false)

  useEffect(() => {
    if (!loading && !admin) router.push('/admin')
  }, [loading, admin, router])

  // Close the mobile drawer on route change
  useEffect(() => { setDrawerOpen(false) }, [pathname])

  // Lock body scroll while the mobile drawer is open
  useEffect(() => {
    document.body.style.overflow = drawerOpen ? 'hidden' : ''
    return () => { document.body.style.overflow = '' }
  }, [drawerOpen])

  if (loading) return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!admin) return null

  // Sub-admin landing on dashboard without permission
  // → redirect to their first permitted page
  if (
    typeof window !== 'undefined' &&
    admin.role !== 'super_admin' &&
    !admin.permissions.includes('view_dashboard') &&
    window.location.pathname === '/admin/dashboard'
  ) {
    const PAGES = [
      { perm: 'manage_offers',    path: '/admin/offers'     },
      { perm: 'resolve_disputes', path: '/admin/disputes'   },
      { perm: 'manage_users',     path: '/admin/users'      },
      { perm: 'view_analytics',   path: '/admin/analytics'  },
      { perm: 'manage_admins',    path: '/admin/sub-admins' },
      { perm: 'view_audit_log',   path: '/admin/audit'      },
    ]
    const first = PAGES.find(p => admin.permissions.includes(p.perm))
    if (first) { window.location.replace(first.path); return null }
  }

  const visibleNav = NAV.filter(item => hasPermission(item.perm))

  async function handleLogout() {
    setDrawerOpen(false)
    await logout()
    router.push('/admin')
  }

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg md:flex-row">
      {/* Mobile top bar — hidden md+ */}
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border bg-app-surface px-4 md:hidden">
        <div className="flex items-center gap-2">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <button onClick={() => setDrawerOpen(true)}
            className="rounded-lg p-1.5 text-app-muted hover:bg-app-bg hover:text-app-text"
            aria-label="Open admin menu">
            <Menu className="h-5 w-5" />
          </button>
        </div>
      </header>

      {/* Mobile drawer — hidden md+ */}
      {drawerOpen && (
        <div className="md:hidden">
          <div
            className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
            onClick={() => setDrawerOpen(false)}
          />
          <div className="fixed inset-y-0 left-0 z-50 flex w-72 flex-col bg-app-surface shadow-2xl">
            <div className="flex shrink-0 items-center justify-between border-b border-app-border px-4 py-4">
              <div className="flex items-center gap-2">
                <Shield className="h-5 w-5 text-app-accent-text" />
                <span className="font-semibold text-app-text">AfriFX Admin</span>
              </div>
              <button onClick={() => setDrawerOpen(false)}
                className="rounded-lg p-1.5 text-app-muted hover:text-app-text"
                aria-label="Close admin menu">
                <X className="h-5 w-5" />
              </button>
            </div>
            <SidebarContent
              admin={admin} pathname={pathname} visibleNav={visibleNav}
              onLogout={handleLogout} onNavigate={() => setDrawerOpen(false)}
            />
          </div>
        </div>
      )}

      {/* Desktop sidebar — hidden on mobile */}
      <aside className="hidden md:flex md:w-56 md:shrink-0 flex-col border-r border-app-border bg-app-surface">
        <div className="flex items-center gap-2 border-b border-app-border px-4 py-4">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <SidebarContent
          admin={admin} pathname={pathname} visibleNav={visibleNav}
          onLogout={handleLogout}
        />
      </aside>

      <main className="flex-1 overflow-y-auto p-4 md:p-6">{children}</main>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/admin/AdminShell.tsx"

mkdir -p "afrifx-web/components/chat"
cat > "afrifx-web/components/chat/ChatWindow.tsx" << 'AFX_EOF'
'use client'
import { useState, useRef, useEffect, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { MessageBubble }     from './MessageBubble'
import { QuickActions }      from './QuickActions'
import { MediaUploadButton } from './MediaUploadButton'
import { useChat }           from '@/hooks/useChat'
import { useProfileByAddress } from '@/hooks/useProfile'
import { ProfileAvatar }     from '@/components/profile/ProfileAvatar'
import { getAvatarColor }    from '@/lib/avatar'
import { shortenAddress }    from '@/lib/utils'
import type { CloudinaryUploadResult } from '@/lib/cloudinary'
import { Send, MessageSquare, ChevronDown, Shield, Lock } from 'lucide-react'

interface Props {
  offerId:      string
  makerAddress: string
  takerAddress: string
  currency:     string
  amount:       number
}

function UserChip({ address }: { address: string }) {
  const { data: profile } = useProfileByAddress(address)
  const color = profile?.avatar_color ?? getAvatarColor(address)
  const name  = profile?.display_name ?? shortenAddress(address)
  return (
    <div className="flex items-center gap-1.5">
      <ProfileAvatar displayName={name} avatarColor={color} size="xs" verified={profile?.verified} />
      <span className="text-xs text-app-text">
        {profile?.username ? `@${profile.username}` : name}
      </span>
    </div>
  )
}

export function ChatWindow({ offerId, makerAddress, takerAddress, currency, amount }: Props) {
  const { address } = useAccount()

  // Determine role client-side
  const isMaker = address?.toLowerCase() === makerAddress?.toLowerCase()
  const isTaker = address?.toLowerCase() === takerAddress?.toLowerCase()
  const isInvolved = isMaker || isTaker

  const otherAddress = isMaker ? takerAddress : makerAddress

  const { messages, role, typing, sendMessage, sendTyping } = useChat(
    isInvolved ? offerId : null
  )

  const { data: otherProfile } = useProfileByAddress(otherAddress)
  const { data: myProfile }    = useProfileByAddress(address ?? '')

  const [input,        setInput]        = useState('')
  const [sending,      setSending]      = useState(false)
  const [showActions,  setShowActions]  = useState(false)
  const [minimized,    setMinimized]    = useState(false)
  const [pendingMedia, setPendingMedia] = useState<CloudinaryUploadResult | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(null)

  const bottomRef = useRef<HTMLDivElement>(null)
  const inputRef  = useRef<HTMLTextAreaElement>(null)

  // Auto-scroll on new messages
  useEffect(() => {
    if (!minimized) {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
    }
  }, [messages, minimized])

  const otherName  = otherProfile?.display_name ?? shortenAddress(otherAddress)
  const otherColor = otherProfile?.avatar_color  ?? getAvatarColor(otherAddress)

  function getSenderName(sender: string | null | undefined): string {
    if (!sender || sender === 'system') return 'System'
    if (sender.toLowerCase() === address?.toLowerCase()) return 'You'
    return otherProfile?.display_name ?? shortenAddress(sender)
  }

  function isMe(sender: string | null | undefined): boolean {
    if (!sender || !address) return false
    return sender.toLowerCase() === address.toLowerCase()
  }

  async function handleSend() {
    if ((!input.trim() && !pendingMedia) || sending) return
    setSending(true)
    try {
      if (pendingMedia) {
        await sendMessage(
          input.trim() || pendingMedia.name,
     pendingMedia.url,
          pendingMedia.type,
          'media',
        )
        setPendingMedia(null)
        setImagePreview(null)
      } else {
        await sendMessage(input.trim())
      }
      setInput('')
    } finally { setSending(false) }
  }

  async function handleQuickAction(action: string, label: string) {
    setShowActions(false)
    setSending(true)
    try { await sendMessage(label, undefined, undefined, 'quick-action', action) }
    finally { setSending(false) }
  }

  function haleKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSend() }
    sendTyping()
  }

  function handleMediaUpload(result: CloudinaryUploadResult) {
    setPendingMedia(result)
    if (result.type === 'image') setImagePreview(result.url)
  }

  // ── Not involved: show a locked placeholder ───────────────
  if (!isInvolved) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 roundeorder border-app-border bg-app-bg">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
          <Lock className="h-5 w-5 text-app-muted" />
        </div>
        <p className="text-sm text-app-muted">Private trade chat</p>
      </div>
    )
  }

  // ── Wallet not yet connected / hydrating ──────────────────
  if (!address) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 rounded-2xl border border-app-border bg-app-bg">
        <div className="h-8 w-32 animate-pulse rounded-lg bg-app-border" />
      </div>
    )
  }

  return (
    <div className={`flex flex-col rounded-2xl border border-app-border bg-app-bg shadow-2xl transition-all duration-200 ${minimized ? 'h-14' : 'h-[520px]'}`}>

      {/* ── Header ── */}
      <div
        className="flex cursor-pointer items-center gap-3 rounded-t-2xl border-b border-app-border bg-app-surface px-4 py-3"
        onClick={() => setMinimized(!minimized)}
      >
        <div className="relative">
          <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="sm" verified={otherProfile?.verified} />
          <span className="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-emerald-400 ring-1 ring-app-surface" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <p className="truncate text-sm font-medium text-app-text">
              {otherProfile?.username ? `@${otherProfile.username}` : otherName}
            </p>
            <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium
              ${isMaker ? 'bg-app-accent/20 text-app-accent-text' : 'bg-emerald-900/40 text-emerald-400'}`}>
              {isMaker ? 'Taker' : 'Maker'}
            </span>
          </div>
          <p className="text-[10px] text-app-muted">
            {typing
              ? <span className="text-emerald-400 animate-pulse">typing…</span>
              : `${amount.toLocaleString()} ${currency} ↔ USDC`
            }
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1 rounded-full bg-emerald-900/30 px-2 py-0.5 text-[10px] text-emerald-400">
            <Shield className="h-3 w-3" /> Secured
          </div>
          <ChevronDown className={`h-4 w-4 shrink-0 text-app-muted transition-transform ${minimized ? 'rotate-180' : ''}`} />
        </div>
      </div>

      {!minimized && (
        <>
          {/* ── Parties banner ── */}
          <div className="flex items-center justify-between border-b border-app-border bg-[#0A1020] px-4 py-2">
            <UserChip address={makerAddress} />
            <span className="text-[10px] text-app-muted">⇄</span>
            <UserChip address={takerAddress} />
          </div>

          {/* ── Messages ── */}
          <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1">
            {messages.length === 0 && (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
                  <MessageSquare className="h-5 w-5 text-app-muted" />
                </div>
                <div>
                  <p className="text-sm font-medium text-app-text">Trade chat</p>
                  <p className="text-xs text-app-muted">
                    Messages are private between you and your trading partner.
                  </p>
                  <p className="mt-1 text-xs text-app-muted">
                    Use quick actions ⚡ to confirm payment status.
                  </p>
                </div>
              </div>
            )}

            {messages.map((msg) => (
              <MessageBubble
                key={msg.id}
                msg={msg}
                isMe={isMe(msg.sender)}
                senderName={getSenderName(msg.sender)}
              />
            ))}

            {/* Typing indicator */}
            {typing && (
              <div className="flex items-end gap-2">
                <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="xs" />
                <div className="rounded-2xl rounded-tl-sm bg-app-border px-3 py-2">
                  <div className="flex gap-1">
                    {[0,1,2].map(i => (
                      <span key={i}
                        className="h-1.5 w-1.5 animate-bounce rounded-full bg-app-muted"
                        style={{ animationDelay: `${i * 0.15}s` }}
                      />
                    ))}
                  </div>
                </div>
              </div>
            )}

            <div ref={bottomRef} />
          </div>

          {/* ── Image preview ── */}
          {imagePreview && (
            <div className="relative mx-4 mb-2">
              <img src={imagePreview} alt="Preview" className="h-20 rounded-lg object-cover" />
              <button
                onClick={() => { setImagePreview(null); setPendingMedia(null) }}
                className="absolute -right-1 -top-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-white text-xs font-bold"
              >
                ×
              </button>
            </div>
          )}

          {/* ── Quick actions ── */}
          {showActions && (
            <QuickActions onAction={handleQuickAction} disabled={sending} />
          )}

          {/* ── Input ── */}
          <div className="border-t border-app-border bg-app-surface p-3">
            <div className="flex items-end gap-2">
              <button
                onClick={() => setShowActions(!showActions)}
                title="Quick actions"
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full border text-sm transition-colors
                  ${showActions
                    ? 'border-app-accent bg-app-accent/10 text-app-accent-text'
                    : 'border-app-border bg-app-surface text-app-muted hover:text-app-text'}`}
              >
                ⚡
              </button>

              <MediaUploadButton
                offerId={offerId}
                onUpload={handleMediaUpload}
                disabled={sending}
              />

              <div className="flex flex-1 items-end rounded-xl border border-app-border bg-app-bg px-3 py-2">
                <textarea
                  ref={inputRef}
                  value={input}
                  onChange={(e) => { setInput(e.target.value); sendTyping() }}
                  onKeyDown={handleKeyDown}
                  placeholder="Message… (Enter to send, Shift+Enter for newline)"
                  rows={1}
                  style={{ maxHeight: '80px' }}
                  className="flex-1 resize-none bg-transparent text-sm text-app-text placeholder:text-app-muted outline-none leading-relaxed"
                />
              </div>

              <button
                onClick={handleSend}
                disabled={(!input.trim() && !pendingMedia) || sending}
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-accent text-app-on-accent transition-all hover:bg-app-accent-hover disabled:opacity-40 active:scale-95"
              >
                <Send className="h-4 w-4" />
              </button>
            </div>

            <p className="mt-1.5 text-center text-[10px] text-app-muted">
              🔒 Private · deleted automatically when trade completes
            </p>
          </div>
        </>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/chat/ChatWindow.tsx"

mkdir -p "afrifx-web/components/chat"
cat > "afrifx-web/components/chat/MediaUploadButton.tsx" << 'AFX_EOF'
'use client'
import { useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { Paperclip, Loader2 } from 'lucide-react'
import { uploadToCloudinary, type CloudinaryUploadResult } from '@/lib/cloudinary'

interface Props {
  offerId:   string
  onUpload:  (result: CloudinaryUploadResult) => void
  disabled?: boolean
}

export function MediaUploadButton({ offerId, onUpload, disabled }: Props) {
  const { address }               = useAccount()
  const inputRef                  = useRef<HTMLInputElement>(null)
  const [progress,  setProgress]  = useState(0)
  const [uploading, setUploading] = useState(false)
  const [errMsg,    setErrMsg]    = useState<string | null>(null)

  async function hdleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file || !address) return

    if (file.size > 10 * 1024 * 1024) {
      setErrMsg('File too large — max 10 MB')
      return
    }

    setUploading(true)
    setProgress(0)
    setErrMsg(null)

    try {
      const result = await uploadToCloudinary(file, offerId, address, setProgress)
      onUpload(result)
    } catch (err: any) {
      setErrMsg(err.message ?? 'Upload failed')
    } finally {
      setUploading(false)
      setProgress(0)
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="file"
        accept="image/*,application/pdf,.doc,.docx,video/mp4,video/webm"
        onChange={handleFile}
        className="hidden"
      />

      <button
        onClick={() => { setErrMsg(null); inputRef.current?.click() }}
        disabled={disabled || uploading}
        title="Attach image, PDF, or document (max 10 MB)"
        className="flex h-9 w-9 items-center justify-center rounded-full border border-app-border bg-app-surface text-app-muted transition-colors hover:border-app-accent hover:text-app-text disabled:opacity-40"
      >
        {uploading
          ? <Loader2 className="h-4 w-4 animate-spin" />
          : <Paperclip className="h-4 w-4" />
        }
      </button>

      {/* Progress bubble */}
      {uploading && (
        <div className="absolute -top-7 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-app-surface border border-app-border px-2 py-0.5 text-[10px] text-app-accent-text">
          {progress}%
        </div>
      )}

      {/* Error bubble */}
      {errMsg && (
        <div className="absolute -top-7 left-0 whitespace-nowrap rounded-full bg-red-900/80 px-2 py-0.5 text-[10px] text-red-300">
          {errMsg}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/chat/MediaUploadButton.tsx"

mkdir -p "afrifx-web/components/chat"
cat > "afrifx-web/components/chat/MessageBubble.tsx" << 'AFX_EOF'
'use client'
import { Download, FileText } from 'lucide-react'
import type { ChatMessage } from '@/hooks/useChat'

const QUICK_ACTION_LABELS: Record<string, { emoji: string; label: string; color: string }> = {
  payment_sent:     { emoji: '💸', label: 'Payment sent',         color: 'bg-blue-900/40 text-blue-300 border-blue-700/40'         },
  payment_received: { emoji: '✅', label: 'Payment received',     color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
  need_more_time:   { emoji: '⏰', label: 'Need a bit more time', color: 'bg-amber-900/40 text-amber-300 border-amber-700/40'       },
  dispute_warning:  { emoji: '⚠️', label: 'Dispute raised',       color: 'bg-red-900/40 text-red-300 border-red-700/40'            },
  trade_complete:   { emoji: '🎉', label: 'Trade complete!',       color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
}

interface Props {
  msg:        ChatMessage
  isMe:       boolean
  senderName: string
}

function formatTime(createdAt: number | string | null | undefined): string {
  if (!createdAt) return ''
  // Turso may return string — coerce to number
  const ts = typeof createdAt === 'string' ? parseInt(createdAt, 10) : Number(createdAt)
  if (isNaN(ts) || ts === 0) return ''
  // Unix seconds → milliseconds
  const ms   = ts < 1e12 ? ts * 1000 : ts
  const date = new Date(ms)
  if (isNaN(date.getTime())) return ''
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export function MessageBubble({ msg, isMe, senderName }: Props) {
  const time = formatTime(msg.created_at)

  // System message
  if (!msg.sender || msg.msg_type === 'system' || msg.sender === 'system') {
    return (
      <div className="flex justify-center py-1">
        <span className="rounded-full bg-app-border px-3 py-1 text-[11px] text-app-muted">
          {msg.content}
        </span>
      </div>
    )
  }

  // Quick action message
  if (msg.msg_type === 'quick-action' && .quick_action) {
    const qa = QUICK_ACTION_LABELS[msg.quick_action]
    return (
      <div className={`flex ${isMe ? 'justify-end' : 'justify-start'} py-0.5`}>
        <div className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-medium
          ${qa?.color ?? 'bg-app-border text-app-muted border-app-border'}`}>
          <span>{qa?.emoji}</span>
          <span>{qa?.label ?? msg.quick_action}</span>
          {time && <span className="opacity-60 text-[10px]">{time}</span>}
        </div>
      </div>
    )
  }

  return (
    <div className={`flex ${isMe ? 'justify-end' : 'justify-start'} group py-0.5`}>
      <div className={`max-w-[75%] flex flex-col gap-0.5 ${isMe ? 'items-end' : 'items-start'}`}>

        {/* Sender name — only for received messages */}
        {!isMe && (
          <span className="px-1 text-[10px] font-medium text-app-muted">{senderName}</span>
        )}

        <div className={`rounded-2xl px-3 py-2 ${
          isMe
            ? 'rounded-tr-s-app-accent text-app-on-accent'
            : 'rounded-tl-sm bg-app-border text-app-text'
        }`}>

          {/* Media */}
          {msg.media_url && (
            <div className="mb-2">
              {msg.media_type === 'image' ? (
                <a href={msg.media_url} target="_blank" rel="noopener noreferrer">
                  <img
                    src={msg.media_url}
                    alt="Shared image"
                    className="max-h-48 w-full rounded-lg object-cover cursor-pointer hover:opacity-90 transition-opacity"
                  />
                </a>
              ) : (
                <a
                  href={msg.media_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={`flex items-center gap-2 rounded-lg p-2 text-xs
                    ${isMe ? 'bg-app-on-accent/10 text-app-on-accent' : 'bg-app-surface text-app-text'}`}
                >
                  <FileText className="h-4 w-4 shrink-0" />
                  <span className="flex-1 truncate">{msg.content ?? 'Document'}</span>
                  <Download className="h-3.5 w-3.5 shrink-0 opacity-60" />
                </a>
              )}
            </div>
          )}

          {/* Text */}
          {msg.content && msg.media_type !== 'document' && (
            <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{msg.content}</p>
          )}

          {/* Timestamp + read receipt */}
          {time && (
            <p className={`mt-.5 text-right text-[10px] ${isMe ? 'text-app-on-accent/60' : 'text-app-muted'}`}>
              {time}
              {isMe && (
                <span className="ml-1">
                  {msg.read_maker && msg.read_taker ? '✓✓' : '✓'}
                </span>
              )}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/chat/MessageBubble.tsx"

mkdir -p "afrifx-web/components/corridor"
cat > "afrifx-web/components/corridor/CorridorCard.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import {
  ArrowRight, ArrowUpDown, CheckCircle,
  AlertCircle, Loader2, Hash, Coins
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { CurrencyInput } from '@/components/swap/CurrencyInput'
import { useRate } from '@/hooks/useFXRate'
import { useCorridorSwap } from '@/hooks/useCorridorSwap'
import {
  LOCAL_CURRENCIES, CURRENCY_FLAG, CURRENCY_LABELS,
  buildCorridorQuote, isCorridorSupported,
} from '@/lib/corridor'
import type { Currency } from '@/types'

export function CorridorCard() {
  const { isConnected } = useAccount()

  const [from,      setFrom]      = useState<Currency>('NGN')
  const [to,        setTo]        = useState<Currency>('KES')
  const [amount,    setAmount]    = useState('')
  const [quote,     setQuote]     = useState<ReturnType<typeof buildCorridorQuote> | null>(null)

  // Fetch both rates
  { rate: fromRate } = useRate(`${from}/USDC`)
  const { rate: toRate   } = useRate(`${to}/USDC`)

  const fromRateVal = fromRate?.rate ?? 0
  const toRateVal   = toRate?.rate   ?? 0
  const ratesReady  = fromRateVal > 0 && toRateVal > 0

  const {
    execute, reset,
    step, error,
    step1Hash, step2Hash, corridorId,
    isLoading, isComplete,
  } = useCorridorSwap()

  // Recalculate quote when inputs change
  useEffect(() => {
    const amt = parseFloat(amount)
    if (!amount || isNaN(amt) || amt <= 0 || !ratesReady) {
      setQuote(null); return
    }
    setQuote(buildCorridorQuote(from, to, amt, fromRateVal, toRateVal))
  }, [amount, from, to, fromRateVal, toRateVal])

  // Reset quote when user changes amount after completion
  function handleAmountChange(val: string) {
    if (val === '' || /^\d*\.?\d*$/.test(val)) {
      setAmount(val)
      if (isComplete) reset()
    }
  }

  function handleFromChange(c: Currency) {
    if (c === to) setTo(from) // auto-swap if same selected
    setFrom(c)
   setAmount('')
    setQuote(null)
    reset()
  }

  function handleToChange(c: Currency) {
    if (c === from) setFrom(to)
    setTo(c)
    setAmount('')
    setQuote(null)
    reset()
  }

  function flip() {
    setFrom(to)
    setTo(from)
    setAmount('')
    setQuote(null)
    reset()
  }

  async function handleExecute() {
    if (!quote) return
    await execute(quote)
  }

  const supported = isCorridorSupported(from, to)
  const canSwap   = isConnected && !!quote && supported && !isLoading

  // Step label helper
  const stepLabel: Record<string, string> = {
    'idle':          '',
    'step1-pending': 'Confirm Step 1 in MetaMask…',
    'step1-waiting': 'Step 1 settling on Arc…',
    'step1-done':    'Step 1 complete — preparing Step 2…',
    'step2-pending': 'Confirm Step 2 in MetaMask…',
    'step2-waiting': 'Step 2 settling on Arc…',
    'complete':      'Corridor swap complete!',
    'error':         'Something went wrong',
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5 shadow-xl">

      {/* Header */}
      <div className="mb-4 flex items-center gap-2">
        <Coins className="h-4 w-4 text-app-accent-text" />
        <span className="text-sm font-medium text-app-text">Cross-border corridor</span>
        <Badge variant="arc" className="ml-auto">2-step · via USDC</Badge>
      </div>

      {/* From currency */}
      <CurrencyInput
        label="You send"
        amount={amount}
        currency={from}
        onAmountChange={handleAmountChange}
        onCurrencyChange={handleFromChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== to)}
      />

      {/* Flip button */}
      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-app-border bg-app-surface p-2 text-app-muted transition-transform hover:rotate-180 hover:text-app-text"
        >
          <ArrowUpDown className="h-4 w-4" />
        </button>
      </div>

      {/* To currency */}
      <CurrencyInput
        label="Recipient receives (estimated)"
        amount={quote ? quote.step2.toAmount.toFixed(2) : ''}
        currency={to}
        onCurrencyChange={handleToChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== from)}
        readOnly
        className="mb-4"
      />

      {/* Route breakdown */}
      {quote && (
        <div className="mb-4 rounded-lg bg-app-bg p-3 text-xs">
          <p className="mb-2 font-medium text-app-text">Route</p>
          <div className="flex items-center gap-2 text-app-muted">
            <span>{CURRENCY_FLAG[from]} {from}</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>💵 USDC</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>{CURRENCY_FLAG[to]} {to}</span>
          </div>
          <div className="mt-2 space-y-1">
            <div className="flex justify-between">
              <span className="text-app-muted">Step 1 · {from} → USDC</span>
              <span className="font-mono text-app-text">~{quote.step1.toAmount.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Step 2 · USDC → {to}</span>
              <span className="font-mono text-app-text">{quote.step2.toAmount.toFixed(2)} {to}</span>
            </div>
            <div className="flex justify-between border-t border-app-border pt-1">
              <span className="text-app-muted">Total fees</span>
              <span className="font-mono text-app-text">${quote.totalFee.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Corridor ID</span>
              <span className="font-mono text-[10px] text-app-accent-text">{quote.corridorId}</span>
            </div>
          </div>
        </div>
      )}

      {/* Step progress indicator */}
      {step !== 'idle' && (
        <div className="mb-3 rounded-lg border border-app-border bg-app-bg p-3">
          <div className="mb-2 flex items-center gap-4">
            {/* Step 1 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${['step1-done','step2-pending','step2-waiting','complete'].includes(step)
                  ? 'bg-emerald-500 text-white'
                  : ['step1-pending','step1-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {['step1-done','step2-pending','step2-waiting','complete'].includes(step) ? '✓' : '1'}
              </div>
              <span className="text-xs text-app-muted">{from} → USDC</span>
            </div>
            <ArrowRight className="h-3 w-3 text-app-border" />
            {/* Step 2 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${step === 'complete'
                  ? 'bg-emerald-500 text-white'
                  : ['step2-pending','step2-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {step === 'complete' ? '✓' : '2'}
              </div>
              <span className="text-xs text-app-muted">USDC → {to}</span>
            </div>
          </div>
          <p className="flex items-center gap-1.5 text-xs text-app-muted">
            {isLoading && <Loader2 className="h-3 w-3 animate-spin text-app-accent-text" />}
            {step === 'complete' && <CheckCircle className="h-3 w-3 text-emerald-400" />}
            {step === 'error' && <AlertCircle className="h-3 w-3 text-red-400" />}
            {stepLabel[step]}
          </p>
        </div>
      )}

      {/* Main button */}
      {!isComplete && (
        <Button
          className="w-full"
          size="lg"
          onClick={handleExecute}
          disabled={!canSwap || isLoading}
        >
          {isLoading ? (
            <><Loader2 className="h-4 w-4 animate-spin" />
              {step === 'step1-pending' || step === 'step1-waiting'
                ? 'Step 1 of 2 · settling…'
                : 'Step 2 of 2 · settling…'}
            </>
          ) : !isConnected ? (
            'Connect wallet'
          ) : !amount ? (
            'Enter an amount'
          ) : !supported ? (
            'Corridor not supported'
          ) : !ratesReady ? (
            'Fetching rates…'
          ) : (
            `Send ${parseFloat(amount || '0').toLocaleString()} ${from} → ${to}`
          )}
        </Button>
      )}

      {/* Error */}
      {error && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-red-900/50 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
     <div>
            <p>{error}</p>
            <button onClick={reset} className="mt-1 underline hover:no-underline">Try again</button>
          </div>
        </div>
      )}

      {/* Success */}
      {isComplete && (
        <div className="mt-3 rounded-lg border border-emerald-900/50 bg-emerald-900/20 px-3 py-3">
          <div className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-400" />
            <div className="flex-1 text-xs">
        <p className="font-medium text-emerald-400">
                Corridor complete · {CURRENCY_FLAG[from]} {from} → {CURRENCY_FLAG[to]} {to}
              </p>
              <p className="mt-0.5 text-emerald-500">
                Sent {parseFloat(amount).toLocaleString()} {from} ·
                Received ~{quote?.step2.toAmount.toFixed(2)} {to}
              </p>
              <div className="mt-1.5 flex items-center gap-1">
                <Hash className="h-3 w-3 text-emerald-600" />
                <span className="font-mono text-[10px] text-emerald-600">
                  {corridorId}
                </span>
              </div>
              <div className="mt-1 space-y-0.5">
                {step1Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step1Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 1 · {step1Hash.slice(0, 18)}… ↗
                  </a>
                )}
                {step2Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step2Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 2 · {step2Hash.slice(0, 18)}… ↗
                  </a>
                )}
              </div>
              <button
                onClick={() => { reset(); setAmount(''); setQuote(null) }}
                className="mt-2 rounded-md bg-emerald-900/40 px-3 py-1 text-emerald-400 hover:bg-emerald-900/60"
              >
                New corridor swap
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/corridor/CorridorCard.tsx"

mkdir -p "afrifx-web/components/dispute"
cat > "afrifx-web/components/dispute/DisputeChat.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect, useRef } from 'react'
import { Send, FileText, Upload, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Message {
  id:          string
  sender_id:   string
  sender_type: 'maker' | 'taker' | 'admin'
  sender_name: string | null
  content:     string | null
  is_document: number
  doc_url:     string | null
  doc_name:    string | null
  admin_only:  number
  created_at:  number
}

interface Props {
  disputeId:   string
  senderId:    string
  senderType:  'maker' | 'taker' | 'admin'
  senderName:  string
  viewerType?: 'admin' | 'user'
  title?:      string
}

export function DisputeChat({
  disputeId, senderId, senderType, senderName,
  viewerType = 'user', title = 'Dispute communication',
}: Props) {
  const [messages,  setMessages]  = useState<Message[]>([])
  const [text,      setText]      = useState('')
  const [sending,   setSending]   = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploadError, setUploadError] = useState<string | null>(null)
  const bottomRef = useRef<HTMLDivElement>(null)
  const fileRef   = useRef<HTMLInputElement>(null)

  async function load() {
    try {
      const res  = await fetch(`${API}/disputes/${disputeId}/messages?viewerType=${viewerType}`)
      const data = await res.json()
      setMessages(Array.isArray(data) ? data : [])
    } catch {}
  }

  useEffect(() => {
    load()
    const interval = setInterval(load, 5000)
    return () => clearInterval(interval)
  }, [disputeId])

  async function sendMessage() {
    if (!text.trim() || sending) return
    setSending(true)
    try {
      await fetch(`${API}/disputes/${disputeId}/messages`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          senderId:   senderId,
          senderType: senderType,
          senderName: senderName,
          content:    text.trim(),
          adminOnly:  0,
        }),
      })
      setText('')
      await load()
    } catch {} finally { setSending(false) }
  }

  async function uploadDocument(file: File) {
    setUploading(true)
    setUploadError(null)
    try {
      // Send the actual file as multipart form-data; the backend streams
      // it to Cloudinary and records the returned URL.
      const formData = new FormData()
      formData.append('file',       file)
      formData.append('senderId',   senderId)
      formData.append('senderType', senderType)
      formData.append('senderName', senderName)

      const res = await fetch(`${API}/disputes/${disputeId}/messages/document`, {
        method: 'POST',
        body:   formData, // no Content-Type header — the browser sets the multipart boundary
      })
      if (res.ok) {
        await load()
      } else {
        const data = await res.json().catch(() => ({}))
        setUploadError(data.error ?? 'Upload failed. Please try again.')
      }
    } catch {
      setUploadError('Upload failed. Please check your connection and try again.')
    } finally { setUploading(false) }
  }

  function getBubbleStyle(msg: Message) {
    const isMe = msg.sender_id === senderId
    if (isMe) return 'ml-auto bg-app-accent/20 border-app-accent/30'
    if (msg.sender_type === 'admin') return 'bg-amber-900/20 border-amber-900/30'
    return 'bg-app-bg border-app-border'
  }

  function getSenderLabel(msg: Message) {
    if (msg.sender_id === senderId) return 'You'
    if (msg.sender_type === 'admin') return `⚖️ Admin${msg.sender_name ? ` (${msg.sender_name})` : ''}`
    if (msg.sender_type === 'maker') return msg.sender_name ?? `Seller${msg.sender_name ? ` (${msg.sender_name})` : ''}`
    return msg.sender_name ?? 'Buyer'
  }

  return (
    <div className="flex flex-col rounded-xl border border-app-border bg-app-surface overflow-hidden">
      {/* Header */}
      <div className="border-b border-app-border px-4 py-3">
        <p className="text-sm font-medium text-app-text">{title}</p>
        <p className="text-xs text-app-muted">
          {viewerType === 'admin'
            ? 'All parties — messages sent here are visible to maker and taker'
            : 'Communicate with the assigned admin · Upload bank statements below'}
        </p>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-3 min-h-[200px] max-h-[400px]">
        {messages.length === 0 ? (
          <p className="text-center text-xs text-app-muted py-4">
            No messages yet — start the conversation
          </p>
        ) : (
          messages.map(msg => (
            <div key={msg.id} className={`max-w-[80%] rounded-xl border p-3 text-xs ${getBubbleStyle(msg)}`}>
              <p className={`mb-1 font-medium ${msg.sender_type === 'admin' ? 'text-amber-400' : 'text-app-accent-text'}`}>
                {getSenderLabel(msg)}
                {msg.admin_only === 1 && (
                  <span className="ml-2 rounded bg-amber-900/30 px-1 py-0.5 text-[10px] text-amber-400">
                    Admin only
                  </span>
                )}
              </p>
              {msg.is_document === 1 ? (
                <div className="flex items-center gap-2">
                  <FileText className="h-4 w-4 text-app-accent-text" />
                  <span className="text-app-text">{msg.doc_name ?? 'Document'}</span>
                  {msg.doc_url && (
                    <a href={msg.doc_url} target="_blank" rel="noopener noreferrer"
                      className="text-app-accent-text hover:underline">View</a>
                  )}
                </div>
              ) : (
                <p className="text-app-text whitespace-pre-wrap">{msg.content}</p>
              )}
              <p className="mt-1 text-[10px] text-app-muted">
                {new Date(msg.created_at * 1000).toLocaleTimeString()}
              </p>
            </div>
          ))
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div className="border-t border-app-border p-3 space-y-2">
        <div className="flex gap-2">
          <input
            value={text}
            onChange={e => setText(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.shiftKey && sendMessage()}
            placeholder="Type your message…"
            className="flex-1 rounded-lg border border-app-border bg-app-bg px-3 py-2 text-xs text-app-text placeholder:text-app-muted outline-none focus:ring-1 focus:ring-app-accent"
          />
          <Button size="sm" onClick={sendMessage} disabled={!text.trim() || sending}>
            {sending ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Send className="h-3.5 w-3.5" />}
          </Button>
        </div>

        {/* Document upload — only for users (maker/taker), not admin */}
        {viewerType !== 'admin' && (
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <input ref={fileRef} type="file" className="hidden"
                accept=".pdf,.png,.jpg,.jpeg,.webp"
                onChange={e => e.target.files?.[0] && uploadDocument(e.target.files[0])} />
              <button onClick={() => fileRef.current?.click()} disabled={uploading}
                className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text transition-colors disabled:opacity-50">
                {uploading
                  ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  : <Upload className="h-3.5 w-3.5" />
                }
                Upload supporting document (PDF or image — admin will review)
              </button>
            </div>
            {uploadError && (
              <p className="text-xs text-red-400">{uploadError}</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/dispute/DisputeChat.tsx"

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/MobileDrawer.tsx" << 'AFX_EOF'
'use client'
import { useEffect } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield, FileText, BarChart3,
  CreditCard, X,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsAdmin } from '@/hooks/useIsAdmin'
import { ThemeToggle } from '@/components/layout/ThemeToggle'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',  icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor', icon: Globe,          label: 'Corridor' },
    { href: '/send',     icon: Send,           label: 'Send'     },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Payments', items: [
    { href: '/invoices',    icon: FileText,  label: 'Invoices'    },
    { href: '/settlements', icon: BarChart3, label: 'Settlements' },
  ]},
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2,  label: 'Treasury' },
    { href: '/treasury/payroll', icon: CreditCard, label: 'Payroll'  },
  ]},
  { label: 'Account', items: [
    { href: '/wallet',    icon: Wallet,          label: 'Wallet'    },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

interface Props {
  open:    boolean
  onClose: () => void
}

export function MobileDrawer({ open, onClose }: Props) {
  const pathname          = usePathname()
  const { data: isAdmin } = useIsAdmin()

  // Close on route change
  useEffect(() => { onClose() }, [pathname])

  // Prevent body scroll when open
  useEffect(() => {
    document.body.style.overflow = open ? 'hidden' : ''
    return () => { document.body.style.overflow = '' }
  }, [open])

  if (!open) return null

  return (
    <>
      {/* Backdrop */}
      <div
        className="md:hidden fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      {/* Drawer panel */}
      <div className="md:hidden fixed inset-y-0 left-0 z-50 w-72 overflow-y-auto bg-app-surface shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-app-border px-4 py-4">
          <span className="font-semibold text-app-text">AfriFX</span>
          <button onClick={onClose} className="rounded-lg p-1.5 text-app-muted hover:text-app-text">
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Nav items */}
        <div className="py-3">
          {nav.map((section) => (
            <div key={section.label} className="mb-2">
              <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
                {section.label}
              </p>
              {section.items.map(({ href, icon: Icon, label }) => {
                const active = pathname === href ||
                  (href !== '/' && pathname.startsWith(href + '/'))
                return (
                  <Link key={href} href={href}
                    className={cn(
                      'flex items-center gap-3 px-4 py-3 text-sm transition-colors',
                      active
                        ? 'bg-app-border font-medium text-app-text'
                        : 'text-app-muted hover:bg-app-bg hover:text-app-text'
                    )}>
                    <Icon className="h-4 w-4 shrink-0" />
                    {label}
                  </Link>
                )
              })}
            </div>
          ))}

          {isAdmin && (
            <div className="mb-2">
              <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
                Admin
              </p>
              <Link href="/admin"
                className={cn(
                  'flex items-center gap-3 px-4 py-3 text-sm transition-colors',
                  pathname.startsWith('/admin')
                    ? 'bg-amber-900/30 font-medium text-amber-400'
                    : 'text-amber-500/70 hover:bg-amber-900/20 hover:text-amber-400'
                )}>
                <Shield className="h-4 w-4 shrink-0" />
                Admin panel
              </Link>
            </div>
          )}

          {/* Appearance */}
          <div className="mt-2 border-t border-app-border pt-3">
            <p className="mb-2 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
              Appearance
            </p>
            <div className="flex items-center justify-between px-4">
              <span className="text-sm text-app-text">Theme</span>
              <ThemeToggle />
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/MobileDrawer.tsx"

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/MobileNav.tsx" << 'AFX_EOF'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Store, LayoutDashboard,
  User, Menu,
} from 'lucide-react'
import { useState } from 'react'
import { MobileDrawer } from './MobileDrawer'
import { cn } from '@/lib/utils'

const BOTTOM_NAV = [
  { href: '/convert',     icon: ArrowLeftRight, label: 'Convert'   },
  { href: '/marketplace', icon: Store,          label: 'Market'    },
  { href: '/dashboard',   icon: LayoutDashboard, label: 'Dashboard' },
  { href: '/profile',     icon: User,           label: 'Profile'   },
]

export function MobileNav() {
  const pathname          = usePathname()
  const [drawerOpen, setDrawerOpen] = useState(false)

  return (
    <>
      {/* Bottom tab bar — mobile only */}
      <nav className="md:hidden fixed bottom-0 left-0 right-0 z-40 border-t border-app-border bg-app-bg">
        <div className="flex items-center justify-around px-2 py-2">
          {BOTTOM_NAV.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex flex-col items-center gap-0.5 px-3 py-1.5 rounded-xl transition-colors',
                  active ? 'text-app-accent-text' : 'text-app-muted'
                )}>
                <Icon className={cn('h-5 w-5', active && 'text-app-accent-text')} />
                <span className="text-[10px] font-medium">{label}</span>
              </Link>
            )
          })}
          {/* More button opens full drawer */}
          <button
            onClick={() => setDrawerOpen(true)}
            className="flex flex-col items-center gap-0.5 px-3 py-1.5 rounded-xl text-app-muted transition-colors">
            <Menu className="h-5 w-5" />
            <span className="text-[10px] font-medium">More</span>
          </button>
        </div>
      </nav>

      {/* Full drawer */}
      <MobileDrawer open={drawerOpen} onClose={() => setDrawerOpen(false)} />
    </>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/MobileNav.tsx"

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/ThemeToggle.tsx" << 'AFX_EOF'
'use client'
import { Sun, Moon } from 'lucide-react'
import { useTheme } from '@/hooks/useTheme'
import { useEffect, useState } from 'react'

export function ThemeToggle({ className = '' }: { className?: string }) {
  const { theme, source, toggle } = useTheme()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  // Avoid hydration mismatch — render a neutral placeholder until mounted
  if (!mounted) {
    return <div className={`h-9 w-9 rounded-lg bg-app-border/50 ${className}`} />
  }

  const isDark = theme === 'dark'
  const label  = isDark ? 'Switch to light mode' : 'Switch to dark mode'

  return (
    <button
      onClick={toggle}
      title={source === 'auto' ? `${label} (currently auto, by time of day)` : label}
      aria-label={label}
      className={`relative flex h-9 w-9 items-center justify-center rounded-lg border border-app-border bg-app-surface text-app-muted transition-colors hover:bg-app-border hover:text-app-text ${className}`}
    >
      {isDark
        ? <Moon className="h-4 w-4" />
        : <Sun className="h-4 w-4" />}
      {source === 'auto' && (
        <span
          className="absolute -right-0.5 -top-0.5 h-2 w-2 rounded-full bg-app-accent"
          title="Auto (following time of day)"
        />
      )}
    </button>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/ThemeToggle.tsx"

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/TopNav.tsx" << 'AFX_EOF'
'use client'
import Link              from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { ConnectButton }  from '@rainbow-me/rainbowkit'
import { useAccount }     from 'wagmi'
import { useProfile }     from '@/hooks/useProfile'
import { ProfileAvatar }  from '@/components/profile/ProfileAvatar'
import { ClientOnly }     from '@/components/ui/client-only'
import { NotificationBell } from '@/components/notifications/NotificationBell'
import { ThemeToggle }     from '@/components/layout/ThemeToggle'

// Custom ConnectButton that shows our profile avatar when connected
function NavProfile() {
  const { isConnected }   = useAccount()
  const { data: profile } = useProfile()

  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        mounted,
      }) => {
        const ready = mounted
        if (!ready) return (
          <div className="h-8 w-24 animate-pulse rounded-full bg-app-border" />
        )

        if (!account) {
          return (
            <button onClick={openConnectModal}
              className="rounded-xl bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-opacity hover:opacity-90">
              Connect wallet
            </button>
          )
        }

        if (chain?.unsupported) {
          return (
            <button onClick={openChainModal}
              className="rounded-xl bg-red-500/20 px-4 py-2 text-sm font-medium text-red-400 transition-opacity hover:opacity-90">
              Wrong network
            </button>
          )
        }

        return (
          <div className="flex items-center gap-2">
            {/* Profile avatar → opens RainbowKit account modal (has copy address) */}
            <button onClick={openAccountModal}
              className="flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-2.5 py-1.5 transition-colors hover:bg-app-border">
              {profile ? (
                <>
                  <ProfileAvatar
                    displayName={profile.display_name}
                    avatarColor={profile.avatar_color}
                    size="xs"
                    verified={profile.verified}
                  />
                  <div className="hidden sm:block text-left">
                    <p className="text-xs font-medium text-app-text leading-none">
                      {profile.display_name}
                    </p>
                    <p className="text-[10px] text-app-accent-text leading-none mt-0.5">
                      @{profile.username}
                    </p>
                  </div>
                </>
              ) : (
                <>
                  {/* No profile yet — show shortened address */}
                  <div className="h-5 w-5 rounded-full bg-app-accent/30 flex items-center justify-center">
                    <span className="text-[8px] font-bold text-app-accent-text">
                      {account.address.slice(2,4).toUpperCase()}
                    </span>
                  </div>
                  <span className="hidden sm:block font-mono text-xs text-app-text">
                    {account.displayName}
                  </span>
                </>
              )}
              {/* Balance badge */}
              {account.displayBalance && (
                <span className="hidden md:block rounded-lg bg-app-border px-2 py-0.5 font-mono text-[10px] text-app-muted">
                  {account.displayBalance}
                </span>
              )}
            </button>
          </div>
        )
      }}
    </ConnectButton.Custom>
  )
}

export function TopNav() {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border px-4 md:px-6">
      <Link href="/convert"
        className="flex items-center gap-2 text-app-text font-semibold">
        <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-app-accent/20">
          <ArrowLeftRight className="h-4 w-4 text-app-accent-text" />
        </div>
        <span className="text-sm md:text-base">AfriFX</span>
        <span className="hidden sm:inline-flex items-center gap-1 rounded-full bg-app-accent/10 px-2 py-0.5 text-[10px] font-medium text-app-accent-text">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </Link>

      <ClientOnly fallback={
        <div className="h-8 w-28 animate-pulse rounded-xl bg-app-border" />
      }>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <NotificationBell />
          <NavProfile />
        </div>
      </ClientOnly>
    </header>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/TopNav.tsx"

mkdir -p "afrifx-web/components/notifications"
cat > "afrifx-web/components/notifications/EmailPreferences.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2, ChevronDown, ChevronUp } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,     setEmail]   = useState('')
  const [prefs, setPrefs]       = useState({
    notify_trades:            true,
    notify_disputes:          true,
    notify_invoices:          true,
    notify_trade_accepted:    true,
    notify_trade_completed:   true,
    notify_trade_cancelled:   true,
    notify_dispute_raised:    true,
    notify_dispute_accepted:  true,
    notify_invoice_paid:      true,
    notify_invoice_reminder:  true,
    notify_receipts:          true,
  })
  const [saving,    setSaving]  = useState(false)
  const [saved,     setSaved]   = useState(false)
  const [showAll,   setShowAll] = useState(false)

  useEffect(() => {
    if (profile) {
      const p = profile as any
      setEmail(p.email ?? '')
      setPrefs({
        notify_trades:           Number(p.notify_trades           ?? 1) === 1,
        notify_disputes:         Number(p.notify_disputes         ?? 1) === 1,
        notify_invoices:         Number(p.notify_invoices         ?? 1) === 1,
        notify_trade_accepted:   Number(p.notify_trade_accepted   ?? 1) === 1,
        notify_trade_completed:  Number(p.notify_trade_completed  ?? 1) === 1,
        notify_trade_cancelled:  Number(p.notify_trade_cancelled  ?? 1) === 1,
        notify_dispute_raised:   Number(p.notify_dispute_raised   ?? 1) === 1,
        notify_dispute_accepted: Number(p.notify_dispute_accepted ?? 1) === 1,
        notify_invoice_paid:     Number(p.notify_invoice_paid     ?? 1) === 1,
        notify_invoice_reminder: Number(p.notify_invoice_reminder ?? 1) === 1,
        notify_receipts:         Number(p.notify_receipts         ?? 1) === 1,
      })
    }
  }, [profile])

  async function save() {
    if (!address) return
    setSaving(true)
    setSaved(false)
    try {
      await fetch(`${API}/notifications/email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ wallet: address, email: email || null, ...prefs }),
      })
      await refetch()
      setSaved(true)
      setTimeout(() => setSaved(false), 3000)
    } catch {} finally { setSaving(false) }
  }

  const validEmail = !email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5 space-y-4">
      <div className="flex items-center gap-2">
        <Mail className="h-4 w-4 text-app-accent-text" />
        <h2 className="text-sm font-medium text-app-text">Email notifications</h2>
      </div>

      <p className="text-xs text-app-muted">
        Get notified about your trades, disputes, and invoice payments by email.
      </p>

      <div className="space-y-2">
        <label className="text-xs uppercase tracking-wider text-app-muted">
          Email address (optional)
        </label>
        <Input
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={e => setEmail(e.target.value)}
          className={!validEmail ? 'border-red-500/50' : ''}
        />
        {!validEmail && <p className="text-xs text-red-400">Invalid email format</p>}
      </div>

      <div className="space-y-3 border-t border-app-border pt-4">
        <p className="text-xs font-medium uppercase tracking-wider text-app-muted">
          Notification categories
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, completed, and cancelled" checked={prefs.notify_trades}    onChange={v => setPrefs(p => ({...p, notify_trades: v}))} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={prefs.notify_disputes}  onChange={v => setPrefs(p => ({...p, notify_disputes: v}))} />
        <Toggle label="Invoice and payments" description="Invoice paid and reminder alerts"  checked={prefs.notify_invoices}  onChange={v => setPrefs(p => ({...p, notify_invoices: v}))} />
        <Toggle label="Payment receipts"   description="Formal receipts for trades and invoices"  checked={prefs.notify_receipts}  onChange={v => setPrefs(p => ({...p, notify_receipts: v}))} />
      </div>

      {/* Granular toggles */}
      <button onClick={() => setShowAll(!showAll)}
        className="flex items-center gap-1 text-xs text-app-accent-text hover:underline">
        {showAll ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
        {showAll ? 'Hide' : 'Show'} individual event toggles
      </button>

      {showAll && (
        <div className="space-y-2 border-t border-app-border pt-3">
          <p className="text-[10px] uppercase tracking-wider text-app-muted">Trade events</p>
          <MiniToggle label="Trade accepted" checked={prefs.notify_trade_accepted}   onChange={v => setPrefs(p => ({...p, notify_trade_accepted: v}))} />
          <MiniToggle label="Trade completed" checked={prefs.notify_trade_completed}  onChange={v => setPrefs(p => ({...p, notify_trade_completed: v}))} />
          <MiniToggle label="Trade auto-cancelled" checked={prefs.notify_trade_cancelled}  onChange={v => setPrefs(p => ({...p, notify_trade_cancelled: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-app-muted pt-2">Dispute events</p>
          <MiniToggle label="Dispute raised against you" checked={prefs.notify_dispute_raised}   onChange={v => setPrefs(p => ({...p, notify_dispute_raised: v}))} />
          <MiniToggle label="Admin accepted your dispute" checked={prefs.notify_dispute_accepted}  onChange={v => setPrefs(p => ({...p, notify_dispute_accepted: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-app-muted pt-2">Invoice events</p>
          <MiniToggle label="Invoice paid" checked={prefs.notify_invoice_paid}     onChange={v => setPrefs(p => ({...p, notify_invoice_paid: v}))} />
          <MiniToggle label="Invoice unpaid reminder (48h)" checked={prefs.notify_invoice_reminder}  onChange={v => setPrefs(p => ({...p, notify_invoice_reminder: v}))} />
        </div>
      )}

      <Button onClick={save} disabled={!validEmail || saving} className="w-full">
        {saving
          ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</>
          : saved
          ? <><Check className="h-4 w-4 text-emerald-400" /> Saved</>
          : 'Save preferences'
        }
      </Button>
    </div>
  )
}

function Toggle({ label, description, checked, onChange }: {
  label: string, description: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-app-border bg-app-bg p-3 hover:bg-app-surface transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 cursor-pointer accent-app-accent" />
      <div>
        <p className="text-sm font-medium text-app-text">{label}</p>
        <p className="text-xs text-app-muted">{description}</p>
      </div>
    </label>
  )
}

function MiniToggle({ label, checked, onChange }: {
  label: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-center gap-2.5 rounded-lg bg-app-bg px-3 py-2 hover:bg-app-surface transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="h-3.5 w-3.5 shrink-0 cursor-pointer accent-app-accent" />
      <span className="text-xs text-app-text">{label}</span>
    </label>
  )
}
AFX_EOF
echo "  afrifx-web/components/notifications/EmailPreferences.tsx"

mkdir -p "afrifx-web/components/notifications"
cat > "afrifx-web/components/notifications/NotificationBell.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useRef } from 'react'
import { useAccount } from 'wagmi'
import { Bell, Check, X } from 'lucide-react'
import Link from 'next/link'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Notification {
  id:         string
  type:       string
  subject:    string
  payload:    string
  read_at:    number | null
  created_at: number
}

export function NotificationBell() {
  const { address }               = useAccount()
  const [open,         setOpen]   = useState(false)
  const [notifs,       setNotifs] = useState<Notification[]>([])
  const [unreadCount,  setCount]  = useState(0)
  const dropdownRef = useRef<MLDivElement>(null)

  async function loadUnreadCount() {
    if (!address) return
    try {
      const res = await fetch(`${API}/notifications/unread?wallet=${address}`)
      const data = await res.json()
      setCount(Number(data.count ?? 0))
    } catch {}
  }

  async function loadNotifs() {
    if (!address) return
    try {
      const res  = await fetch(`${API}/notifications?wallet=${address}`)
      const data = await res.json()
      setNotifs(Array.isArray(data) ? data : [])
    } catch {}
  }

  async function markRead(id: string) {
    try {
      await fetch(`${API}/notifications/${id}/read`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  async function markAllRead() {
    if (!address) return
    try {
      await fetch(`${API}/notifications/mark-all-read?wallet=${address}`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  useEffect(() => {
    if (!address) return
    loadUnreadCount()
    const interval = setInterval(loadUnreadCount, 30_000)
    return () => clearInterval(interval)
  }, [address])

  useEffect(() => {
    if (open) loadNotifs()
  }, [open])

  // Close on outside click
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    if (open) document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [open])

  if (!address) return null

  const getNotifLink = (n: Notification) => {
    try {
      const p = JSON.parse(n.payload)
      if (n.type.startsWith('trade')   && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type.startsWith('dispute') && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type === 'invoice_paid'    && p.invoiceId) return `/invoices/${p.invoiceId}`
    } catch {}
    return '#'
  }

  const getIcon = (type: string) => {
    if (type.startsWith('trade'))   return '🤝'
    if (type.startsWith('dispute')) return '⚠️'
    if (type === 'invoice_paid')    return '💰'
    return '🔔'
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button onClick={() => setOpen(!open)}
        className="relative flex h-9 w-9 items-center justify-center rounded-lg border border-app-border text-app-muted hover:bg-app-surface hover:text-app-text transition-colors">
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 mt-2 w-80 rounded-xl border border-app-border bg-app-surface shadow-2xl z-50">
          <div className="flex items-center justify-between border-b border-app-border px-4 py-3">
            <p className="text-nt-medium text-app-text">Notifications</p>
            <div className="flex items-center gap-2">
              {unreadCount > 0 && (
                <button onClick={markAllRead}
                  className="text-xs text-app-accent-text hover:underline">
                  Mark all read
                </button>
              )}
              <button onClick={() => setOpen(false)}
                className="text-app-muted hover:text-app-text">
                <X className="h-4 w-4" />
              </button>            </div>
          </div>
          <div className="max-h-96 overflow-y-auto">
            {notifs.length === 0 ? (
              <p className="px-4 py-8 text-center text-xs text-app-muted">No notifications yet</p>
            ) : (
              notifs.map(n => {
                const link   = getNotifLink(n)
                const isUnread = !n.read_at
                return (
                  <Link key={n.id} href={link}
                    onClick={() => { markRead(n.id); setOpen(false) }}
                  className={`flex items-start gap-3 border-b border-app-border px-4 py-3 last:border-0
                      ${isUnread ? 'bg-app-accent/5' : ''} hover:bg-app-bg transition-colors`}>
                    <span className="text-lg">{getIcon(n.type)}</span>
                    <div className="flex-1 min-w-0">
                      <p className={`text-xs ${isUnread ? 'font-medium text-app-text' : 'text-app-muted'}`}>
                        {n.subject}
                      </p>
                   <p className="mt-0.5 text-[10px] text-app-muted">
                        {new Date(n.created_at * 1000).toLocaleString()}
                      </p>
                    </div>
                    {isUnread && (
                      <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-app-accent" />
                    )}
                  </Link>
                )
              })
            )}
          </div>
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/notifications/NotificationBell.tsx"

mkdir -p "afrifx-web/components/p2p"
cat > "afrifx-web/components/p2p/TimerBanner.tsx" << 'AFX_EOF'
'use client'
import { useCountdown } from '@/hooks/useCountdown'
import { Clock, AlertTriangle, CheckCircle } from 'lucide-react'

interface TimerBannerProps {
  deadline:     number | null | undefined
  totalSeconds: number | null | undefined
  phase:        'taker' | 'maker'        // whose turn it is
  isMine:       boolean                  // is this timer for the current user?
}

export function TimerBanner({ deadline, totalSeconds, phase, isMine }: TimerBannerProps) {
  const { formatted, pctElapsed, isExpired, isWarning, isDanger } = useCountdown(deadline, totalSeconds)

  if (!deadline) return null

  // Dynamic color scheme based on % elapsed
  const scheme = isExpired
    ? { bg: 'bg-red-950/60',    border: 'border-red-500/50',   bar: 'bg-red-500',    text: 'text-red-300',    icon: 'text-red-400',    time: 'text-red-300'    }
    : isDanger
    ? { bg: 'bg-red-950/40',    bord'border-red-500/40',   bar: 'bg-red-500',    text: 'text-red-300',    icon: 'text-red-400',    time: 'text-red-200'    }
    : isWarning
    ? { bg: 'bg-amber-950/40',  border: 'border-amber-500/40', bar: 'bg-amber-400',  text: 'text-amber-300',  icon: 'text-amber-400',  time: 'text-amber-200'  }
    : { bg: 'bg-app-surface',     border: 'border-app-border',    bar: 'bg-app-accent',  text: 'text-app-muted',  icon: 'text-app-accent-text',  time: 'text-app-text'  }

  const phaseLabel = phase === 'taker'
    ? isMine ? 'Your window to send local currency' : "Waiting for taker to send"
    : isMine ? 'Your window to confirm receipt'      : 'Waiting for maker to confirm'

  const urgencyLabel = isExpired
    ? 'Time expired'
    : isDanger
    ? 'Urgent — act now'
    : isWarning
    ? 'Running low'
    : 'Time remaining'

  return (
    <div className={`w-full rounded-xl border px-5 py-4 ${scheme.bg} ${scheme.border}`}>
      {/* Top row — label + urgency */}
      <div className="mb-3 flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isExpired || isDanger
            ? <AlertTriangle className={`h-4 w-4 ${scheme.icon}`} />
            : <Clock className={`h-4 w-4 ${scheme.icon}`} />
          }
          <span className={`text-sm font-medium ${scheme.text}`}>{phaseLabel}</span>
        </div>
        <span className={`text-xs font-medium ${scheme.text}`}>{urgencyLabel}</span>
      </div>

      {/* Large countdown display */}
      <div className={`mb-3 text-center font-mono text-4xl font-bold tracking-wider ${scheme.time}`}
        style={{ fontVariantNumeric: 'tabular-nums' }}>
        {formatted}
      </div>

      {/* Progress bar — depletes left to right */}
      <div className="h-2 w-full overflow-hidden rounded-full bg-app-border">
        <div
          className={`h-full rounded-full transition-all duration-1000 ${scheme.bar}`}
          style={{ width: `${Math.max(0, 100 - pctElapsed)}%` }}
        />
      </div>

      {/* Bottom label */}
  <div className="mt-2 flex justify-between text-[10px] text-app-muted">
        <span>Start</span>
        <span className={`font-medium ${pctElapsed > 90 ? 'text-red-400' : pctElapsed > 70 ? 'text-amber-400' : 'text-app-muted'}`}>
          {Math.round(pctElapsed)}% elapsed
        </span>
        <span>Deadline</span>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/p2p/TimerBanner.tsx"

mkdir -p "afrifx-web/components/profile"
cat > "afrifx-web/components/profile/UserDisplay.tsx" << 'A_EOF'
'use client'
import Link from 'next/link'
import { ProfileAvatar } from './ProfileAvatar'
import { useProfileByAddress } from '@/hooks/useProfile'
import { getAvatarColor } from '@/lib/avatar'
import { shortenAddress } from '@/lib/utils'

interface UserDisplayProps {
  address:     string | null | undefined
  size?:       'xs' | 'sm' | 'md'
  showAvatar?: boolean
  clickable?:  boolean
  suffix?:     string
  fallback?:   string   // custom fallback text if no address
}

export function UserDisplay({
ress,
  size       = 'sm',
  showAvatar = true,
  clickable  = true,
  suffix,
  fallback,
}: UserDisplayProps) {
  const { data: profile, isLoading } = useProfileByAddress(address)

  if (!address) {
    return <span className="text-xs text-app-muted">{fallback ?? '—'}</span>
  }

  if (isLoading) {
    return (
      <span className="inline-flex items-center gap-1.5">
        {showAvatar && (
          <span className={`${size === 'xs' ? 'h-5 w-5' : 'h-6 w-6'} animate-pulse rounded-full bg-app-border`} >
        )}
        <span className="h-3 w-20 animate-pulse rounded bg-app-border" />
      </span>
    )
  }

  const displayName = profile?.display_name ?? shortenAddress(address)
  const username    = profile?.username
  const color       = profile?.avatar_color ?? getAvatarColor(address)
  const verified    = profile?.verified ?? false

  const label = username ? `@${username}` : displayName

  const inner = (
    <span className="inline-flex items-center gap-1.5">
      {showAvatar && (
        <Profivatar
          displayName={displayName}
          avatarColor={color}
          size={size === 'md' ? 'sm' : 'xs'}
          verified={verified}
        />
      )}
      <span className={`font-medium ${
        size === 'xs' ? 'text-[11px]' :
        size === 'sm' ? 'text-xs'     : 'text-sm'
      } text-app-text`}>
        {label}
        {suffix && <span className="ml-1 text-app-accent-text text-[10px]">{suffix}</span>}
      </span>
    </span>
  )

  if (clickable && username) {
    return (
      <Link href={`/profile/${username}`} className="hover:opacity-80 transition-opacity">
        {inner}
      </Link>
    )
  }

  return inner
}
AFX_EOF
echo "  afrifx-web/components/profile/UserDisplay.tsx"

mkdir -p "afrifx-web/components/ui"
cat > "afrifx-web/components/ui/badge.tsx" << 'AFX_EOF'
import * as React from 'react'
import { cn } from '@/lib/utils'

interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'arc'
}

export function Badge({ className, variant = 'default', ...props }: BadgeProps) {
  const styles = {
    default: 'bg-app-border text-app-text',
    success: 'bg-emerald-900/40 text-emerald-400',
    warning: 'bg-amber-900/40 text-amber-400',
    danger:  'bg-red-900/40 text-red-400',
    arc:     'bg-app-accent/20 text-app-accent-text',
  }
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium',
        styles[variant],
        className
      )}
      {...props}
    />
  )
}
AFX_EOF
echo "  afrifx-web/components/ui/badge.tsx"

mkdir -p "afrifx-web/components/ui"
cat > "afrifx-web/components/ui/button.tsx" << 'AFX_EOF'
import * as React from 'react'
import { Slot } from '@radix-ui/react-slot'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 rounded-md text-sm font-medium transition-all focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50',
  {
    variants: {
      variant: {
        default:  'bg-app-accent text-app-on-accent hover:bg-app-accent-hover active:scale-[0.98]',
        outline:  'border border-app-border bg-transparent hover:bg-app-surface text-app-text',
        ghost:    'bg-transparent hover:bg-app-surface text-app-text',
        danger:   'bg-[#EF4444] text-white hover:bg-[#dc2626]',
        success:  'bg-[#10B981] text-white hover:bg-[#059669]',
      },
      size: {
        default: 'h-10 px-4 py-2',
        sm:      'h-8 px-3 text-xs',
        lg:      'h-12 px-6 text-base',
        icon:    'h-9 w-9',
      },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  }
)

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    cont Comp = asChild ? Slot : 'button'
    return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
  }
)
Button.displayName = 'Button'

export { Button, buttonVariants }
AFX_EOF
echo "  afrifx-web/components/ui/button.tsx"

mkdir -p "afrifx-web/components/wallet"
cat > "afrifx-web/components/wallet/ConnectButton.tsx" << 'AFX_EOF'
'use client'
// Thin wrapper — kept for backwards compatibility
// TopNav now uses RainbowKit ConnectButton.Custom directly
import { useConnal } from '@rainbow-me/rainbowkit'

export function ConnectButton({ label = 'Connect wallet' }: { label?: string }) {
  const { openConnectModal } = useConnectModal()
  return (
    <button
      onClick={openConnectModal}
      className="rounded-xl bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-opacity hover:opacity-90">
      {label}
    </button>
  )
}
AFX_EOF
echo "  afrifx-web/components/wallet/ConnectButton.tsx"

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useTheme.<< 'AFX_EOF'
'use client'
import { createContext, useContext, useEffect, useState, useCallback } from 'react'

export type Theme = 'light' | 'dark'
type ThemeSource = 'auto' | 'manual'

interface ThemeCtx {
  theme:     Theme
  source:    ThemeSource   // 'auto' = following the clock; 'manual' = user overrode
  toggle:    () => void
  setTheme:  (t: Theme) => void
  useAuto:   () => void    // clear manual override, go back to clock-based
}

const Ctx = createContext<ThemeCtx | null>(null)

const STORAGE_KEY = 'afrifx_theme' // stores 'light' | 'dark' when manual; absent = auto

// Clock-based default: light during the day (06:00–17:59), dark in the evening/night.
export function themeForNow(date = new Date()): Theme {
  const h = date.getHours()
  return h >= 6 && h < 18 ? 'light' : 'dark'
}

function applyTheme(t: Theme) {
  const root = document.documentElement
  if (t === 'light') root.classList.add('light')
  else               root.classList.remove('light')
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  // Initial value is resolved by the inline script in layout.tsx before paint,
  // so we read the current DOM state here to stay in sync (no flash).
  const [theme, setThemeState]   = useState<Theme>('dark')
  const [source, setSource]      = useState<ThemeSource>('auto')

  useEffect(() => {
    const stored = (typeof window !== 'undefined'
      ? window.localStorage.getItem(STORAGE_KEY)
      : null) as Theme | null

    if (stored === 'light' || stored === 'dark') {
      setSource('manual')
      setThemeState(stored)
      applyTheme(stored)
    } else {
      const auto = themeForNow()
      setSource('auto')
      setThemeState(auto)
      applyTheme(auto)
    }
  }, [])

  // While in auto mode, re-check the clock periodically so the theme flips
  // on its own when the user crosses the day/night boundary mid-session.
  useEffect(() => {
    if (source !== 'auto') return
    const id = setInterval(() => {
      const auto = themeForNow()
      setThemeState(prev {
        if (prev !== auto) applyTheme(auto)
        return auto
      })
    }, 60_000)
    return () => clearInterval(id)
  }, [source])

  const setTheme = useCallback((t: Theme) => {
    setSource('manual')
    setThemeState(t)
    applyTheme(t)
    window.localStorage.setItem(STORAGE_KEY, t)
  }, [])

  const toggle = useCallback(() => {
    setTheme(theme === 'dark' ? 'light' : 'dark')
  }, [theme, setTheme])

  const useAuto = useCallback(() => {
    window.localStorage.removeItem(STORAGE_KEY)
    c auto = themeForNow()
    setSource('auto')
    setThemeState(auto)
    applyTheme(auto)
  }, [])

  return (
    <Ctx.Provider value={{ theme, source, toggle, setTheme, useAuto }}>
      {children}
    </Ctx.Provider>
  )
}

export function useTheme(): ThemeCtx {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider')
  return ctx
}
AFX_EOF
echo "  afrifx-web/hooks/useTheme.tsx"

mkdir -p "afrifx-web/styles"
cat > "afrifx-web/styles/globals.css" << 'AFX_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

/*
  Semantic color tokens as "R G B" channel triples so Tailwind can apply
  opacity modifiers, e.g. bg-app-accent/10.

  :root defines the DARK theme (warm espresso + gold). html.light overrides
  them with the LIGHT theme (warm ivory + deeper bronze). Every component
  reads these variables, so switching themes is purely a variable swap.

  Extra accent tokens keep text readable in BOTH themes:
    --app-accent        gold fill (buttons, bars, a states)
    --app-accent-hover  hover state for accent fills
    --app-accent-text   the accent used as READING text (links/labels);
                        deeper in light mode so it stays legible on ivory
    --app-on-accent     text/icons that sit ON a gold fill (dark in dark
                        mode, white in light mode) — replaces raw text-white
*/
:root {
  --app-bg:           18 16 11;    /* #12100B */
  --app-surface:      28 24 16;    /* #1C1810 */
  --app-border:       51 41 27;    /* #3329*/
  --app-accent:       217 164 65;  /* #D9A441 */
  --app-accent-hover: 196 143 46;  /* #C48F2E */
  --app-accent-text:  217 164 65;  /* #D9A441 — bright gold reads well on dark */
  --app-on-accent:    18 16 11;    /* #12100B — dark text on gold fill */
  --app-text:         242 233 216; /* #F2E9D8 */
  --app-muted:        156 138 110; /* #9C8A6E */

  /* Legacy aliases (kept for any direct var() consumers) */
  --bg:      #12100B;
  --card:    #1C1810;
  --border:  #33291B;
  --accent:  #D9A441;
  --success: #5BAE7B;
  --danger:  #D9694A;
  --muted:   #9C8A6E;
  --text:    #F2E9D8;
}

html.light {
  --app-bg:           247 241 230; /* #F7F1E6 — warm ivory */
  --app-surface:      255 253 248; /* #FFFDF8 — near-white warm surface */
  --app-border:       228 217 196; /* #E4D9C4 — soft sand */
  --app-accent:       138 94 19;   /* #8A5E13 — deep bronze, readable as fill+text on ivory */
  --app-accent-hover: 110 74 15;   /* #6E4A0F */
  --app-accent-text:  138 94 19;   /* #8A5E13 — pass AA (5.06:1) for link/label text */
  --app-on-accent:    255 255 255; /* #FFFFFF — white text on bronze fill */
  --app-text:         43 36 22;    /* #2B2416 — warm near-black */
  --app-muted:        107 95 73;   /* #6B5F49 — warm gray-brown, passes AA (5.56:1) */

  --bg:      #F7F1E6;
  --card:    #FFFDF8;
  --border:  #E4D9C4;
  --accent:  #8A5E13;
  --success: #2E7D53;
  --danger:  #C0492E;
  --muted:   #6B5F49;
  --text:    #2B2416;
}

* { box-sizing: border-box; }

/* Smooth the dark <-> light transition (kept subtle; excludes transforms) */
body, [class*="bg-app-"], [class*="border-app-"], [class*="text-app-"] {
  transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease;
}

body {
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

input[type='number']::-webkit-outer-spin-button,
input[type='number']::-webkit-inner-spin-button {
  -webkit-appearance: none;
  margin: 0;
}
AFX_EF
echo "  afrifx-web/styles/globals.css"

mkdir -p "afrifx-web"
cat > "afrifx-web/tailwind.config.ts" << 'AFX_EOF'
import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        // Semantic tokens — driven by CSS variables (see globals.css).
        // Support opacity modifiers via the <alpha-value> placeholder.
    app: {
          bg:            'rgb(var(--app-bg) / <alpha-value>)',
          surface:       'rgb(var(--app-surface) / <alpha-value>)',
          border:        'rgb(var(--app-border) / <alpha-value>)',
          accent:        'rgb(var(--app-accent) / <alpha-value>)',
          'accent-hover':'rgb(var(--app-accent-hover) / <alpha-value>)',
          'accent-text': 'rgb(var(--app-accent-text) / <alpha-value>)',
          'on-accent':   'rgb(var(--app-on-accent) / <alpha-value>)',
          text:          'rgb(var(--app-text) / <alpha-value>)',
          muted:         'rgb(var(--app-muted) / <alpha-value>)',
        },
        arc: {
          bg:      '#080D1B',
          card:    '#0F1729',
          border:  '#1B2B4B',
          accent:  '#378ADD',
          success: '#10B981',
          danger:  '#EF4444',
          muted:   '#64748B',
          text:    '#E2E8F0',
        },
      },
      keyframes: {
        ticker: {
          '0%':   { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(-50%)' },
        },
      },
      animation: {
        ticker: 'ticker 30s linear infinite',
      },
    },
  },
  plugins: [],
}
export default config
AFX_EOF
echo "  afrifx-web/tailwind.config.ts"

echo ""
echo "======================================================"
echo "Phase C complete -- dark/light toggle applied."
echo ""
echo "  NEXT:"
echo "    cd afrifx-web && npm run build"
echo "    git add -A && git commit -m 'Phase C: dark/light theme toggle'"
echo "    git push"
echo "======================================================"
