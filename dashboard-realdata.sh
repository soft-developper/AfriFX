#!/bin/bash
# ============================================================
# AfriFX — Real dashboard data from Turso
# Run from ~/AfriFX:  bash dashboard-realdata.sh
# ============================================================
set -e
echo ""
echo "📊  Wiring real dashboard data..."
echo ""

# ============================================================
# 1 — Backend: new /user/:address/stats endpoint
#     returns real volume, tx count, and recent activity
# ============================================================
cat > afrifx-api/src/routes/user.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { users, transactions } from '../db/schema'
import { eq, desc, gte, sum, count, sql } from 'drizzle-orm'

const router = Router()

// GET /user/:address/stats — full dashboard stats
router.get('/:address/stats', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  const now  = Math.floor(Date.now() / 1000)
  const day  = 86400
  const thirtyDaysAgo = now - 30 * day
  const sevenDaysAgo  = now - 7  * day

  try {
    // All-time stats
    const [allTime] = await db
      .select({
        txCount:    count(),
        totalVolume: sum(transactions.fromAmount),
      })
      .from(transactions)
      .where(eq(transactions.walletAddress, addr))

    // 30-day volume
    const [monthly] = await db
      .select({ volume: sum(transactions.fromAmount) })
      .from(transactions)
      .where(
        sql`${transactions.walletAddress} = ${addr}
          AND ${transactions.createdAt} >= ${thirtyDaysAgo}
          AND ${transactions.status} = 'settled'`
      )

    // 7-day daily volume breakdown (for bar chart)
    const weekly = await db
      .select({
        day:    sql<number>`CAST(${transactions.createdAt} / 86400 AS INTEGER)`,
        volume: sum(transactions.fromAmount),
        txs:    count(),
      })
      .from(transactions)
      .where(
        sql`${transactions.walletAddress} = ${addr}
          AND ${transactions.createdAt} >= ${sevenDaysAgo}`
      )
      .groupBy(sql`CAST(${transactions.createdAt} / 86400 AS INTEGER)`)
      .orderBy(sql`CAST(${transactions.createdAt} / 86400 AS INTEGER)`)

    // Recent 5 transactions
    const recent = await db
      .select()
      .from(transactions)
      .where(eq(transactions.walletAddress, addr))
      .orderBy(desc(transactions.createdAt))
      .limit(5)

    // Pair breakdown — most used corridors
    const pairBreakdown = await db
      .select({
        pair:   sql<string>`${transactions.fromCurrency} || '/' || ${transactions.toCurrency}`,
        txs:    count(),
        volume: sum(transactions.fromAmount),
      })
      .from(transactions)
      .where(eq(transactions.walletAddress, addr))
      .groupBy(sql`${transactions.fromCurrency} || '/' || ${transactions.toCurrency}`)
      .orderBy(desc(count()))
      .limit(5)

    // Build 7-day chart data with day labels
    const dayLabels = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
    const todayDay  = Math.floor(now / day)
    const chartData = Array.from({ length: 7 }, (_, i) => {
      const d       = todayDay - (6 - i)
      const match   = weekly.find(w => w.day === d)
      const date    = new Date(d * day * 1000)
      return {
        label:  dayLabels[date.getUTCDay()],
        volume: Number(match?.volume ?? 0),
        txs:    Number(match?.txs    ?? 0),
      }
    })

    res.json({
      allTime: {
        txCount:     Number(allTime?.txCount    ?? 0),
        totalVolume: Number(allTime?.totalVolume ?? 0),
      },
      monthly: {
        volume: Number(monthly?.volume ?? 0),
      },
      chartData,
      recent,
      pairBreakdown,
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /user/:address
router.get('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const existing = await db
      .select()
      .from(users)
      .where(eq(users.walletAddress, addr))
      .limit(1)

    if (!existing.length) {
      await db.insert(users).values({
        walletAddress: addr,
        createdAt: Math.floor(Date.now() / 1000),
      })
    }

    const [stats] = await db
      .select({ txCount: count(), volume: sum(transactions.toAmount) })
      .from(transactions)
      .where(eq(transactions.walletAddress, addr))

    res.json({
      walletAddress: addr,
      txCount:   Number(stats?.txCount ?? 0),
      volume30d: Number(stats?.volume  ?? 0),
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  routes/user.ts — /stats endpoint with real Turso data"

# ============================================================
# 2 — New frontend hook: useDashboardStats
# ============================================================
cat > afrifx-web/hooks/useDashboardStats.ts << '__EOF__'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface DashboardStats {
  allTime: {
    txCount:     number
    totalVolume: number
  }
  monthly: {
    volume: number
  }
  chartData: {
    label:  string
    volume: number
    txs:    number
  }[]
  recent: {
    id:           string
    fromCurrency: string
    toCurrency:   string
    fromAmount:   number
    toAmount:     number
    status:       string
    createdAt:    number
    reference:    string | null
    arcTxHash:    string | null
  }[]
  pairBreakdown: {
    pair:   string
    txs:    number
    volume: number
  }[]
}

export function useDashboardStats() {
  const { address } = useAccount()

  return useQuery<DashboardStats>({
    queryKey: ['dashboard-stats', address],
    queryFn: async () => {
      const res = await fetch(`${API}/user/${address}/stats`)
      if (!res.ok) throw new Error('Failed to fetch stats')
      return res.json()
    },
    enabled:         !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
__EOF__
echo "✅  hooks/useDashboardStats.ts"

# ============================================================
# 3 — Rebuild Dashboard page with real data
# ============================================================
cat > "afrifx-web/app/(app)/dashboard/page.tsx" << '__EOF__'
'use client'
import { useAccount } from 'wagmi'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useFXRates } from '@/hooks/useFXRate'
import { useDashboardStats } from '@/hooks/useDashboardStats'
import { shortenAddress, formatAmount } from '@/lib/utils'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import {
  BarChart, Bar, XAxis, YAxis,
  Tooltip, ResponsiveContainer, Cell,
} from 'recharts'
import {
  TrendingUp, TrendingDown, ArrowLeftRight,
  ExternalLink, RefreshCw, Wallet,
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
  const { data: stats, isLoading, refetch } = useDashboardStats()

  const statCards = [
    {
      label: 'USDC balance',
      value: `${balance}`,
      sub:   'on Arc Testnet',
      icon:  Wallet,
      trend: null,
    },
    {
      label: 'Volume (30d)',
      value: stats ? `$${formatAmount(stats.monthly.volume)}` : '—',
      sub:   `${stats?.allTime.txCount ?? 0} total transactions`,
      icon:  TrendingUp,
      trend: null,
    },
    {
      label: 'All-time volume',
      value: stats ? `$${formatAmount(stats.allTime.totalVolume)}` : '—',
      sub:   'across all corridors',
      icon:  TrendingUp,
      trend: null,
    },
  ]

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Dashboard</h1>
          <p className="font-mono text-xs text-[#64748B]">
            {address ? shortenAddress(address, 6) : '—'}
          </p>
        </div>
        <button
          onClick={() => refetch()}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]"
        >
          <RefreshCw className={`h-3 w-3 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Stat cards */}
      <div className="mb-6 grid grid-cols-3 gap-4">
        {statCards.map(({ label, value, sub, icon: Icon }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="mb-2 flex items-center justify-between">
              <p className="text-xs text-[#64748B]">{label}</p>
              <Icon className="h-3.5 w-3.5 text-[#378ADD]" />
            </div>
            <p className="font-mono text-2xl font-medium text-[#E2E8F0]">
              {isLoading && value === '—' ? (
                <span className="inline-block h-7 w-24 animate-pulse rounded bg-[#1B2B4B]" />
              ) : value}
            </p>
            <p className="mt-1 text-xs text-[#64748B]">{sub}</p>
          </div>
        ))}
      </div>

      <div className="mb-6 grid grid-cols-3 gap-4">
        {/* Weekly volume chart */}
        <div className="col-span-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">
            Weekly volume (USDC)
          </p>
          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <RefreshCw className="h-5 w-5 animate-spin text-[#64748B]" />
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={160}>
              <BarChart data={stats?.chartData ?? []} barSize={24}>
                <XAxis
                  dataKey="label"
                  tick={{ fill: '#64748B', fontSize: 11 }}
                  axisLine={false}
                  tickLine={false}
                />
                <YAxis
                  tick={{ fill: '#64748B', fontSize: 11 }}
                  axisLine={false}
                  tickLine={false}
                  tickFormatter={(v) => v > 0 ? `$${v}` : '0'}
                />
                <Tooltip
                  contentStyle={{
                    background: '#0F1729',
                    border: '1px solid #1B2B4B',
                    borderRadius: 8,
                    fontSize: 12,
                  }}
                  labelStyle={{ color: '#E2E8F0' }}
                  formatter={(v: number) => [`$${formatAmount(v)}`, 'Volume']}
                />
                <Bar dataKey="volume" radius={[4, 4, 0, 0]}>
                  {(stats?.chartData ?? []).map((entry, i) => (
                    <Cell
                      key={i}
                      fill={entry.volume > 0 ? '#378ADD' : '#1B2B4B'}
                    />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          )}
        </div>

        {/* Top pairs */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Top pairs</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => (
                <div key={i} className="h-8 animate-pulse rounded bg-[#1B2B4B]" />
              ))}
            </div>
          ) : stats?.pairBreakdown.length ? (
            <div className="space-y-2.5">
              {stats.pairBreakdown.map((p) => (
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

      <div className="grid grid-cols-2 gap-4">
        {/* Recent transactions */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Recent activity</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => (
                <div key={i} className="h-12 animate-pulse rounded bg-[#1B2B4B]" />
              ))}
            </div>
          ) : stats?.recent.length ? (
            <div className="space-y-2">
              {stats.recent.map((tx) => (
                <div key={tx.id} className="flex items-center gap-3 rounded-lg bg-[#080D1B] px-3 py-2.5">
                  <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
                    <ArrowLeftRight className="h-3.5 w-3.5 text-[#378ADD]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium text-[#E2E8F0]">
                      {tx.fromCurrency} → {tx.toCurrency}
                    </p>
                    <p className="truncate font-mono text-[10px] text-[#64748B]">
                      {tx.reference ?? tx.id.slice(0, 16) + '…'}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="font-mono text-xs text-emerald-400">
                      +{Number(tx.toAmount).toFixed(2)} {tx.toCurrency}
                    </p>
                    <Badge variant={
                      tx.status === 'settled' ? 'success' :
                      tx.status === 'failed'  ? 'danger'  : 'warning'
                    }>
                      {tx.status}
                    </Badge>
                  </div>
                  {tx.arcTxHash && (
                    <a
                      href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="shrink-0"
                    >
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

        {/* Live rates snapshot */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Live rates</p>
          <div className="space-y-2.5">
            {(rates ?? []).map((r) => {
              const up = r.change24h >= 0
              return (
                <div key={r.pair} className="flex items-center justify-between text-xs">
                  <span className="text-[#64748B]">{r.pair}</span>
                  <span className="font-mono text-[#E2E8F0]">
                    {r.rate.toLocaleString()}
                  </span>
                  <span className={`flex items-center gap-0.5 ${up ? 'text-emerald-400' : 'text-red-400'}`}>
                    {up
                      ? <TrendingUp className="h-3 w-3" />
                      : <TrendingDown className="h-3 w-3" />
                    }
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
      <div className="grid grid-cols-3 gap-4">
        {[1,2,3].map(i => (
          <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
        ))}
      </div>
      <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
      <div className="grid grid-cols-2 gap-4">
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    </div>
  )
}
__EOF__
echo "✅  dashboard/page.tsx — real data from Turso"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Dashboard real data wiring complete!"
echo ""
echo "  New endpoint:  GET /user/:address/stats"
echo "  Returns:"
echo "    allTime   — total tx count + total volume"
echo "    monthly   — 30-day settled volume"
echo "    chartData — 7-day daily breakdown for bar chart"
echo "    recent    — last 5 transactions"
echo "    pairs     — top corridors by tx count"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
