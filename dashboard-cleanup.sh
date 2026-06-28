#!/bin/bash
# Run from ~/AfriFX:  bash dashboard-cleanup.sh
set -e
echo "📊  Adding inflow/outflow + P2P stats + profile name to dashboard..."

# ============================================================
# 1 — Backend: add inflow/outflow + P2P stats to dashboard endpoint
# ============================================================
cat > afrifx-api/src/routes/user.ts << '__EOF__'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

// GET /user/:address
router.get('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const rows = await db.run(
      sql`SELECT * FROM users WHERE LOWER(wallet_address) = ${addr} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.json({ walletAddress: addr, volume30d: 0, txCount: 0, disputeWarnings: 0 })
    const u = r[0]
    res.json({
      walletAddress:    u.wallet_address  ?? u[0],
      volume30d:        Number(u.volume_30d       ?? u[1] ?? 0),
      txCount:          Number(u.tx_count          ?? u[2] ?? 0),
      disputeWarnings:  Number(u.dispute_warnings  ?? u[3] ?? 0),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /user/:address/stats — full dashboard stats
router.get('/:address/stats', async (req, res) => {
  const addr = req.params.address.toLowerCase()

  try {
    const now      = Math.floor(Date.now() / 1000)
    const day      = 86400
    const week     = day * 7
    const month    = day * 30

    // ── Conversion transactions ───────────────────────────
    const txRows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${addr}
          ORDER BY created_at DESC LIMIT 200`
    )
    const txs = parseRows(txRows).map((r: any) => Array.isArray(r) ? {
      id: r[0], wallet_address: r[1], from_currency: r[2], to_currency: r[3],
      from_amount: Number(r[4]), to_amount: Number(r[5]),
      spread_fee: Number(r[6]), network_fee: Number(r[7]),
      arc_tx_hash: r[8], memo_id: r[9], reference: r[10],
      corridor_id: r[11], corridor_step: r[12],
      status: r[13], settled_at: r[14], created_at: Number(r[15]),
    } : { ...r, from_amount: Number(r.from_amount), to_amount: Number(r.to_amount), created_at: Number(r.created_at) })

    // ── P2P offers ────────────────────────────────────────
    const offerRows = await db.run(
      sql`SELECT id, status, usdc_amount, maker_address, taker_address, created_at
          FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr}
             OR LOWER(taker_address) = ${addr}
          ORDER BY created_at DESC LIMIT 100`
    )
    const offers = parseRows(offerRows).map((r: any) => Array.isArray(r) ? {
      id: r[0], status: r[1], usdc_amount: Number(r[2]),
      maker_address: r[3], taker_address: r[4], created_at: Number(r[5]),
    } : { ...r, usdc_amount: Number(r.usdc_amount), created_at: Number(r.created_at) })

    // ── Dispute warnings ──────────────────────────────────
    const userRows = await db.run(
      sql`SELECT dispute_warnings FROM users WHERE LOWER(wallet_address) = ${addr} LIMIT 1`
    )
    const ur = parseRows(userRows)
    const disputeWarnings = Number(ur[0]?.dispute_warnings ?? ur[0]?.[0] ?? 0)

    // ── Volume calculations ───────────────────────────────
    const monthTxs  = txs.filter(t => t.created_at > now - month)
    const monthVol  = monthTxs.reduce((s, t) => s + t.from_amount, 0)
    const allVol    = txs.reduce((s, t) => s + t.from_amount, 0)
    const allTxCount = txs.length

    // P2P stats
    const completedTrades = offers.filter(o => o.status === 'released').length
    const activeTrades    = offers.filter(o => o.status === 'accepted').length
    const openOffers      = offers.filter(o =>
      o.status === 'open' && o.maker_address?.toLowerCase() === addr
    ).length

    // ── Weekly bar chart (last 7 days) ────────────────────
    const chartData = Array.from({ length: 7 }, (_, i) => {
      const dayStart = now - (6 - i) * day
      const dayEnd   = dayStart + day
      const label    = new Date(dayStart * 1000).toLocaleDateString([], { weekday: 'short' })
      const volume   = txs
        .filter(t => t.created_at >= dayStart && t.created_at < dayEnd)
        .reduce((s, t) => s + t.from_amount, 0)
      return { label, volume: parseFloat(volume.toFixed(2)) }
    })

    // ── Inflow / Outflow (last 30 days, daily) ────────────
    // Outflow = USDC sent (from_currency = USDC or conversions)
    // Inflow  = USDC received (to_currency = USDC or P2P releases)
    const flowData = Array.from({ length: 14 }, (_, i) => {
      const dayStart = now - (13 - i) * day
      const dayEnd   = dayStart + day
      const label    = new Date(dayStart * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })

      // Outflow: money sent out (conversions from any currency)
      const outflow = txs
        .filter(t => t.created_at >= dayStart && t.created_at < dayEnd)
        .reduce((s, t) => s + t.from_amount, 0)

      // Inflow: USDC received from P2P releases as taker
      const inflow = offers
        .filter(o =>
          o.status === 'released' &&
          o.taker_address?.toLowerCase() === addr &&
          o.created_at >= dayStart && o.created_at < dayEnd
        )
        .reduce((s, o) => s + o.usdc_amount, 0)

      return {
        label,
        inflow:  parseFloat(inflow.toFixed(2)),
        outflow: parseFloat(outflow.toFixed(2)),
      }
    })

    // ── Top pairs ─────────────────────────────────────────
    const pairMap: Record<string, { volume: number; txs: number }> = {}
    for (const t of txs) {
      const pair = `${t.from_currency}/${t.to_currency}`
      if (!pairMap[pair]) pairMap[pair] = { volume: 0, txs: 0 }
      pairMap[pair].volume += t.from_amount
      pairMap[pair].txs++
    }
    const pairBreakdown = Object.entries(pairMap)
      .map(([pair, d]) => ({ pair, volume: parseFloat(d.volume.toFixed(2)), txs: d.txs }))
      .sort((a, b) => b.volume - a.volume)
      .slice(0, 5)

    // ── Recent activity ───────────────────────────────────
    const recent = txs.slice(0, 8).map(t => ({
      id:           t.id,
      fromCurrency: t.from_currency,
      toCurrency:   t.to_currency,
      fromAmount:   t.from_amount,
      toAmount:     t.to_amount,
      status:       t.status,
      reference:    t.reference,
      arcTxHash:    t.arc_tx_hash,
      createdAt:    t.created_at,
    }))

    res.json({
      monthly:      { volume: parseFloat(monthVol.toFixed(2)), txCount: monthTxs.length },
      allTime:      { totalVolume: parseFloat(allVol.toFixed(2)), txCount: allTxCount },
      p2p:          { completedTrades, activeTrades, openOffers },
      disputeWarnings,
      chartData,
      flowData,
      pairBreakdown,
      recent,
    })
  } catch (err: any) {
    console.error('[Stats]', err.message)
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  routes/user.ts — flowData + P2P stats added"

# ============================================================
# 2 — Frontend: updated dashboard page
# ============================================================
cat > "afrifx-web/app/(app)/dashboard/page.tsx" << '__EOF__'
'use client'
import { useAccount } from 'wagmi'
import { useUSDCBalance }     from '@/hooks/useUSDCBalance'
import { useFXRates }         from '@/hooks/useFXRate'
import { useDashboardStats }  from '@/hooks/useDashboardStats'
import { useProfile }         from '@/hooks/useProfile'
import { formatAmount }       from '@/lib/utils'
import { ClientOnly }         from '@/components/ui/client-only'
import { ProfileAvatar }      from '@/components/profile/ProfileAvatar'
import { Badge }              from '@/components/ui/badge'
import {
  BarChart, Bar, AreaChart, Area,
  XAxis, YAxis, Tooltip, Legend,
  ResponsiveContainer, Cell,
} from 'recharts'
import {
  TrendingUp, TrendingDown, ArrowLeftRight,
  ExternalLink, RefreshCw, Wallet,
  Store, CheckCircle, AlertTriangle,
} from 'lucide-react'

export default function DashboardPage() {
  return (
    <ClientOnly fallback={<DashboardSkeleton />}>
      <DashboardContent />
    </ClientOnly>
  )
}

function DashboardContent() {
  const { address }            = useAccount()
  const { formatted: balance } = useUSDCBalance()
  const { data: rates }        = useFXRates()
  const { data: profile }      = useProfile()
  const { data: stats, isLoading, refetch } = useDashboardStats()

  const statCards = [
    {
      label: 'USDC balance',
      value: `${balance}`,
      sub:   'on Arc Testnet',
      icon:  Wallet,
      color: 'text-[#378ADD]',
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
      color: 'text-[#378ADD]',
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
      {/* Header — shows profile name + avatar */}
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
            <h1 className="text-xl font-semibold text-[#E2E8F0]">
              {profile ? profile.display_name : 'Dashboard'}
            </h1>
            <p className="text-xs text-[#378ADD]">
              {profile ? `@${profile.username}` : address?.slice(0,10).concat('…') ?? '—'}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          {/* Dispute warning */}
          {(stats?.disputeWarnings ?? 0) > 0 && (
            <div className="flex items-center gap-1.5 rounded-lg border border-amber-900/50 bg-amber-900/20 px-3 py-1.5 text-xs text-amber-400">
              <AlertTriangle className="h-3.5 w-3.5" />
              {stats!.disputeWarnings} dispute warning{stats!.disputeWarnings > 1 ? 's' : ''}
            </div>
          )}
          <button
            onClick={() => refetch()}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]"
          >
            <RefreshCw className={`h-3 w-3 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>
      </div>

      {/* Stat cards — 4 across */}
      <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
        {statCards.map(({ label, value, sub, icon: Icon, color }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="mb-2 flex items-center justify-between">
              <p className="text-xs text-[#64748B]">{label}</p>
              <Icon className={`h-3.5 w-3.5 ${color}`} />
            </div>
            <p className="font-mono text-xl font-semibold text-[#E2E8F0]">
              {isLoading && value === '—'
                ? <span className="inline-block h-6 w-20 animate-pulse rounded bg-[#1B2B4B]" />
                : value}
            </p>
            <p className="mt-1 text-xs text-[#64748B]">{sub}</p>
          </div>
        ))}
      </div>

      {/* Row 1: Weekly volume + Top pairs */}
      <div className="mb-4 grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Weekly volume (USDC)</p>
          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <RefreshCw className="h-5 w-5 animate-spin text-[#64748B]" />
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={160}>
              <BarChart data={stats?.chartData ?? []} barSize={24}>
                <XAxis dataKey="label" tick={{ fill: '#E2E8F0', fontSize: 11 }} axisLine={{ stroke: '#1B2B4B' }} tickLine={false} />
                <YAxis tick={{ fill: '#E2E8F0', fontSize: 11 }} axisLine={false} tickLine={false} tickFormatter={v => v > 0 ? `$${v}` : '0'} />
                <Tooltip
                  contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: '#E2E8F0' }}
                  itemStyle={{ color: '#E2E8F0' }}
                  cursor={{ fill: '#1B2B4B' }}
                  formatter={(v: number) => [`$${formatAmount(v)}`, 'Volume']}
                />
                <Bar dataKey="volume" radius={[4,4,0,0]}>
                  {(stats?.chartData ?? []).map((entry, i) => (
                    <Cell key={i} fill={entry.volume > 0 ? '#378ADD' : '#1B2B4B'} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          )}
        </div>

        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Top pairs</p>
          {isLoading ? (
            <div className="space-y-2">{[1,2,3].map(i => <div key={i} className="h-8 animate-pulse rounded bg-[#1B2B4B]" />)}</div>
          ) : stats?.pairBreakdown.length ? (
            <div className="space-y-2.5">
              {stats.pairBreakdown.map(p => (
                <div key={p.pair} className="flex items-center justify-between text-xs">
                  <span className="font-medium text-[#E2E8F0]">{p.pair}</span>
                  <div className="text-right">
                    <p className="font-mono text-[#E2E8F0]">${formatAmount(Number(p.volume))}</p>
                    <p className="text-[#64748B]">{p.txs} txs</p>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-xs text-[#64748B]">No transactions yet</p>
          )}
        </div>
      </div>

      {/* Row 2: Inflow / Outflow chart */}
      <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
        <div className="mb-4 flex items-center justify-between">
          <p className="text-sm font-medium text-[#E2E8F0]">Inflow vs Outflow (14 days)</p>
          <div className="flex items-center gap-4 text-xs text-[#64748B]">
            <span className="flex items-center gap-1.5">
              <span className="inline-block h-2.5 w-2.5 rounded-full bg-emerald-400" />
              Inflow (USDC received)
            </span>
            <span className="flex items-center gap-1.5">
              <span className="inline-block h-2.5 w-2.5 rounded-full bg-[#378ADD]" />
              Outflow (USDC sent)
            </span>
          </div>
        </div>
        {isLoading ? (
          <div className="flex h-40 items-center justify-center">
            <RefreshCw className="h-5 w-5 animate-spin text-[#64748B]" />
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
                  <stop offset="5%"  stopColor="#378ADD" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#378ADD" stopOpacity={0}   />
                </linearGradient>
              </defs>
              <XAxis dataKey="label" tick={{ fill: '#64748B', fontSize: 10 }} axisLine={false} tickLine={false} interval={1} />
              <YAxis tick={{ fill: '#64748B', fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={v => v > 0 ? `$${v}` : '0'} />
              <Tooltip
                contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 12 }}
                labelStyle={{ color: '#E2E8F0' }}
                itemStyle={{ color: '#E2E8F0' }}
                formatter={(v: number, name: string) => [`$${formatAmount(v)}`, name === 'inflow' ? 'Inflow' : 'Outflow']}
              />
              <Area type="monotone" dataKey="inflow"  stroke="#10B981" strokeWidth={2} fill="url(#inflowGrad)"  dot={false} />
              <Area type="monotone" dataKey="outflow" stroke="#378ADD" strokeWidth={2} fill="url(#outflowGrad)" dot={false} />
            </AreaChart>
          </ResponsiveContainer>
        )}
        {/* Net summary */}
        {stats?.flowData && (
          <div className="mt-3 flex items-center gap-6 border-t border-[#1B2B4B] pt-3">
            {(() => {
              const totalIn  = stats.flowData.reduce((s, d) => s + d.inflow,  0)
              const totalOut = stats.flowData.reduce((s, d) => s + d.outflow, 0)
              const net      = totalIn - totalOut
              return (
                <>
                  <div className="text-xs">
                    <p className="text-[#64748B]">Total inflow</p>
                    <p className="font-mono font-medium text-emerald-400">${formatAmount(totalIn)}</p>
                  </div>
                  <div className="text-xs">
                    <p className="text-[#64748B]">Total outflow</p>
                    <p className="font-mono font-medium text-[#378ADD]">${formatAmount(totalOut)}</p>
                  </div>
                  <div className="text-xs">
                    <p className="text-[#64748B]">Net position</p>
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
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Recent activity</p>
          {isLoading ? (
            <div className="space-y-2">{[1,2,3].map(i => <div key={i} className="h-12 animate-pulse rounded bg-[#1B2B4B]" />)}</div>
          ) : stats?.recent.length ? (
            <div className="space-y-2">
              {stats.recent.map(tx => (
                <div key={tx.id} className="flex items-center gap-3 rounded-lg bg-[#080D1B] px-3 py-2.5">
                  <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
                    <ArrowLeftRight className="h-3.5 w-3.5 text-[#378ADD]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium text-[#E2E8F0]">
                      {tx.fromCurrency} → {tx.toCurrency}
                    </p>
                    <p className="truncate font-mono text-[10px] text-[#64748B]">
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
                      <ExternalLink className="h-3 w-3 text-[#64748B] hover:text-[#378ADD]" />
                    </a>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <p className="text-xs text-[#64748B]">No transactions yet</p>
          )}
        </div>

        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Live rates</p>
          <div className="space-y-2.5">
            {(rates ?? []).map(r => {
              const up = r.change24h >= 0
              return (
                <div key={r.pair} className="flex items-center justify-between text-xs">
                  <span className="text-[#64748B]">{r.pair}</span>
                  <span className="font-mono text-[#E2E8F0]">{r.rate.toLocaleString()}</span>
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
        {[1,2,3,4].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />)}
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2 h-48 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
      <div className="h-56 animate-pulse rounded-xl bg-[#0F1729]" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    </div>
  )
}
__EOF__
echo "✅  dashboard/page.tsx — inflow/outflow + P2P stats + profile name"

# ============================================================
# 3 — Update useDashboardStats to include new fields
# ============================================================
cat > afrifx-web/hooks/useDashboardStats.ts << '__EOF__'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDashboardStats() {
  const { address } = useAccount()
  return useQuery({
    queryKey:  ['dashboard-stats', address],
    queryFn:   async () => {
      if (!address) return null
      const res  = await fetch(`${API}/user/${address}/stats`)
      if (!res.ok) throw new Error('Failed to fetch stats')
      return res.json()
    },
    enabled:        !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
__EOF__
echo "✅  hooks/useDashboardStats.ts"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Dashboard cleanup complete!"
echo ""
echo "  Added:"
echo "  • Profile avatar + @username in header"
echo "  • Dispute warning banner (amber) if warnings > 0"
echo "  • 4 stat cards (added Completed trades)"
echo "  • Inflow vs Outflow area chart (14 days)"
echo "    - Green area: USDC received (P2P as taker)"
echo "    - Blue area:  USDC sent (conversions)"
echo "    - Net position summary below chart"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
