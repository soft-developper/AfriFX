#!/bin/bash
# ============================================================
# AfriFX -- Phase B: Theme system (tokenize) + warm restyle
#
# B1 (tokenize): every hardcoded Tailwind colour class like bg-[#080D1B]
#   becomes a semantic class (bg-app-bg) driven by CSS variables. This is
#   mechanical and deterministic (1407 replacements across 72 files) and is
#   run in-script below so you can see exactly what it touches.
#
# B2 (restyle): the CSS variables are set to the warm, African-inspired
#   palette you approved (espresso base + gold accent + parchment text).
#   Because everything now reads from variables, this is the ONLY place the
#   colours are defined -- a future light mode just overrides them again.
#
# Chart colours (Recharts) and a few inline styles can't use classes, so
# those files are rewritten in full to read from lib/tokens.ts.
#
# Net visual effect: the whole app switches to the warm theme at once.
#
# Run from ~/AfriFX:  bash phaseB-theme.sh
# ============================================================
set -e
cd afrifx-web
echo ""
echo "Applying Phase B -- theme system + warm restyle..."
echo ""

# ------------------------------------------------------------
# B1: deterministic class tokenization (bg-[#HEX] -> bg-app-*)
# ------------------------------------------------------------
python3 - << 'TOKENIZE_EOF'
import os, re
CORE = {
  "080D1B": "app-bg", "0F1729": "app-surface", "1B2B4B": "app-border",
  "378ADD": "app-accent", "E2E8F0": "app-text", "64748B": "app-muted",
}
def pats():
    out=[]
    for h,n in CORE.items():
        rx=re.compile(r'-\[#'+''.join(f'[{c.lower()}{c.upper()}]' if c.isalpha() else c for c in h)+r'\]')
        out.append((rx,'-'+n))
    return out
P=pats(); files=subs=0
for root in ['app','components']:
    for dp,_,fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(('.tsx','.ts')): continue
            p=os.path.join(dp,fn); s=open(p).read(); o=s; n=0
            for rx,rp in P:
                s,c=rx.subn(rp,s); n+=c
            if s!=o: open(p,'w').write(s); files+=1; subs+=n
print(f"  tokenized {subs} colour classes across {files} files")
TOKENIZE_EOF

# ------------------------------------------------------------
# B2: theme config + JS token helper
# ------------------------------------------------------------
mkdir -p "styles"
cat > "styles/globals.css" << 'GLOBALS_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

/*
  Semantic color tokens as "R G B" channel triples so Tailwind can apply
  opacity modifiers, e.g. bg-app-accent/10. These defaults define the warm,
  African-inspired palette. A future light mode simply overrides these
  variables (no component changes needed).
*/
:root {
  --app-bg:      18 16 11;     /* #12100B — warm espresso */
  --app-surface: 28 24 16;     /* #1C1810 — warm dark brown */
  --app-border:  51 41 27;     /* #33291B — clay border */
  --app-accent:  217 164 65;   /* #D9A441 — rich gold */
  --app-text:    242 233 216;  /* #F2E9D8 — parchment */
  --app-muted:   156 138 110;  /* #9C8A6E — warm taupe */

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

* { box-sizing: border-box; }

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
GLOBALS_EOF
echo "  styles/globals.css (warm palette CSS variables)"

cat > "tailwind.config.ts" << 'TAILWIND_EOF'
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
          bg:      'rgb(var(--app-bg) / <alpha-value>)',
          surface: 'rgb(var(--app-surface) / <alpha-value>)',
          border:  'rgb(var(--app-border) / <alpha-value>)',
          accent:  'rgb(var(--app-accent) / <alpha-value>)',
          text:    'rgb(var(--app-text) / <alpha-value>)',
          muted:   'rgb(var(--app-muted) / <alpha-value>)',
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
TAILWIND_EOF
echo "  tailwind.config.ts (app.* semantic colours with alpha)"

mkdir -p "lib"
cat > "lib/tokens.ts" << 'TOKENS_EOF'
'use client'
import { useEffect, useState } from 'react'

/*
  Some UI needs colors as JavaScript strings rather than Tailwind classes —
  Recharts configs, inline style props, avatar fallbacks, etc. Those can't use
  utility classes, so they read the same semantic tokens from CSS variables
  here. This keeps charts and inline styles in sync with the active theme
  (including a future light mode) instead of hardcoding hex values.

  The DEFAULT_TOKENS below mirror the :root defaults in globals.css and act as
  the server-render / pre-hydration fallback. useTokens() resolves the live
  values on the client so a theme change is reflected everywhere.
*/

export interface Tokens {
  bg:      string
  surface: string
  border:  string
  accent:  string
  text:    string
  muted:   string
}

// Must match the :root defaults in styles/globals.css (warm palette)
export const DEFAULT_TOKENS: Tokens = {
  bg:      '#12100B',
  surface: '#1C1810',
  border:  '#33291B',
  accent:  '#D9A441',
  text:    '#F2E9D8',
  muted:   '#9C8A6E',
}

const VAR_MAP: Record<keyof Tokens, string> = {
  bg:      '--app-bg',
  surface: '--app-surface',
  border:  '--app-border',
  accent:  '--app-accent',
  text:    '--app-text',
  muted:   '--app-muted',
}

// Read a "R G B" CSS variable triple and return an rgb() color string
function readVar(name: string): string | null {
  if (typeof window === 'undefined') return null
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  if (!raw) return null
  const parts = raw.split(/\s+/).map(Number)
  if (parts.length === 3 && parts.every(n => !Number.isNaN(n))) {
    return `rgb(${parts[0]}, ${parts[1]}, ${parts[2]})`
  }
  return raw
}

export function resolveTokens(): Tokens {
  if (typeof window === 'undefined') return DEFAULT_TOKENS
  const out = { ...DEFAULT_TOKENS }
  ;(Object.keys(VAR_MAP) as (keyof Tokens)[]).forEach(k => {
    const v = readVar(VAR_MAP[k])
    if (v) out[k] = v
  })
  return out
}

// Hook: resolves live token values on mount (and re-runs on theme change)
export function useTokens(): Tokens {
  const [tokens, setTokens] = useState<Tokens>(DEFAULT_TOKENS)
  useEffect(() => {
    setTokens(resolveTokens())
    const observer = new MutationObserver(() => setTokens(resolveTokens()))
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'data-theme', 'style'],
    })
    return () => observer.disconnect()
  }, [])
  return tokens
}
TOKENS_EOF
echo "  lib/tokens.ts (JS token helper for charts/inline styles)"

# ------------------------------------------------------------
# B2: chart + accent-literal files (rewritten in full)
# ------------------------------------------------------------
mkdir -p "app/admin/dashboard"
cat > "app/admin/dashboard/page.tsx" << 'ADASH_EOF'
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
          <Loader2 className="h-6 w-6 animate-spin text-app-accent" />
        </div>
      ) : (
        <>
          {/* Stat cards */}
          <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
            {[
              { label: 'Total volume',  value: `$${(data?.totalVolume ?? 0).toLocaleString()}`, icon: TrendingUp, color: 'text-app-accent' },
              { label: 'Fees collected',value: `$${(data?.totalFees ?? 0).toLocaleString()}`,   icon: DollarSign, color: 'text-emerald-400' },
              { label: 'Total users',   value: String(data?.totalUsers ?? 0),                   icon: Users,      color: 'text-app-accent' },
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
              { label: 'Active trades',  value: data?.p2p.accepted  ?? 0, color: 'text-app-accent'   },
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
ADASH_EOF
echo "  admin dashboard charts -> tokens"

mkdir -p "app/admin/analytics"
cat > "app/admin/analytics/page.tsx" << 'AANALYTICS_EOF'
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
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent" /></div>
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
AANALYTICS_EOF
echo "  admin analytics charts -> tokens"

mkdir -p "app/(app)/dashboard"
cat > "app/(app)/dashboard/page.tsx" << 'UDASH_EOF'
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
      color: 'text-app-accent',
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
      color: 'text-app-accent',
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
            <p className="text-xs text-app-accent">
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
                    <p className="font-mono font-medium text-app-accent">${formatAmount(totalOut)}</p>
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
                    <ArrowLeftRight className="h-3.5 w-3.5 text-app-accent" />
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
                      <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent" />
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
UDASH_EOF
echo "  user dashboard charts -> tokens"

mkdir -p "app/(app)/wallet"
cat > "app/(app)/wallet/WalletContent.tsx" << 'WALLET_EOF'
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
              <Wallet className="h-6 w-6 text-app-accent" />
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
              className="shrink-0 text-app-muted hover:text-app-accent">
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
              { label: 'P2P volume traded', value: `$${formatAmount(data?.p2p.totalVolume ?? 0)}`, icon: ArrowLeftRight, color: 'text-app-accent' },
              { label: 'Open offers',       value: String(data?.escrow.openOffers ?? 0),   icon: Store,       color: 'text-amber-400' },
              { label: 'Active trades',     value: String(data?.escrow.activeOffers ?? 0), icon: ShieldCheck, color: 'text-app-accent' },
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
                    <ArrowLeftRight className="h-3.5 w-3.5 text-app-accent" />
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
                      <ExternalLink className="h-3 w-3 text-app-muted hover:text-app-accent" />
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
WALLET_EOF
echo "  wallet chart -> tokens"

mkdir -p "app"
cat > "app/providers.tsx" << 'PROVIDERS_EOF'
'use client'
import { WagmiProvider }       from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RainbowKitProvider, darkTheme }   from '@rainbow-me/rainbowkit'
import { wagmiConfig }         from '@/lib/wagmi'
import '@rainbow-me/rainbowkit/styles.css'

const queryClient = new QueryClient()

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={darkTheme({
            accentColor:          '#D9A441',
            accentColorForeground: 'white',
            borderRadius:         'large',
            fontStack:            'system',
            overlayBlur:          'small',
          })}
          coolMode
        >
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
PROVIDERS_EOF
echo "  RainbowKit accent -> gold"

mkdir -p "app"
cat > "app/layout.tsx" << 'LAYOUT_EOF'
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
  themeColor: '#12100B',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className="min-h-screen bg-app-bg text-app-text"
        suppressHydrationWarning
      >
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
LAYOUT_EOF
echo "  theme-color meta -> warm"

mkdir -p "app/admin/users"
cat > "app/admin/users/page.tsx" << 'USERS_EOF'
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
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent" /></div>
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
                  <span className="text-xs text-app-accent">@{u.username}</span>
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
USERS_EOF
echo "  avatar fallback -> gold"

mkdir -p "app/(auth)/profile/setup"
cat > "app/(auth)/profile/setup/ProfileSetupClient.tsx" << 'PROFSETUP_EOF'
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
          <ArrowLeftRight className="h-5 w-5 text-app-accent" />
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
            Your profile <span className="text-app-accent">@{username}</span> is ready.
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
                  ${step >= s ? 'bg-app-accent text-white' : 'bg-app-border text-app-muted'}`}>
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
PROFSETUP_EOF
echo "  avatar fallback -> gold"

echo ""
echo "======================================================"
echo "Phase B complete -- warm theme applied."
echo ""
echo "  NEXT:"
echo "    cd afrifx-web && npm run build"
echo "    git add -A && git commit -m 'Phase B: theme tokenization + warm African-inspired palette'"
echo "    git push   # verify on prod, then we do the dark/light toggle (Phase C)"
echo "======================================================"
