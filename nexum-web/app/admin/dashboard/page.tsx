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
