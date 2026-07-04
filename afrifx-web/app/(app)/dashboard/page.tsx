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
import { RecoveryNudge }     from '@/components/wallet/RecoveryNudge'
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
      <RecoveryNudge />
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
