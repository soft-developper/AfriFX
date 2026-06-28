'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  BarChart, Bar, PieChart, Pie, Cell,
  XAxis, YAxis, Tooltip, ResponsiveContainer,
} from 'recharts'
import { Loader2 } from 'lucide-react'

export default function AdminAnalytics() {
  const [data, setData]       = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/analytics')
      .then(r => r.json()).then(setData)
      .catch(() => {}).finally(() => setLoading(false))
  }, [])

  const splitData = data ? [
    { name: 'Direct', value: data.split.direct.volume, color: '#378ADD' },
    { name: 'P2P',    value: data.split.p2p.volume,    color: '#10B981' },
  ] : []

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">Platform analytics</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="grid gap-4 lg:grid-cols-2">
          {/* Volume by corridor */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Volume by corridor</p>
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={data?.corridors ?? []} layout="vertical" barSize={16}>
                <XAxis type="number" tick={{ fill: '#64748B', fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => `$${v}`} />
                <YAxis type="category" dataKey="pair" tick={{ fill: '#E2E8F0', fontSize: 10 }} axisLine={false} tickLine={false} width={70} />
                <Tooltip
                  contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 12 }}
                  itemStyle={{ color: '#E2E8F0' }}
                  formatter={(v: number) => [`$${v.toLocaleString()}`, 'Volume']}
                />
                <Bar dataKey="volume" fill="#378ADD" radius={[0,4,4,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>

          {/* P2P vs Direct */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">P2P vs Direct conversion</p>
            <ResponsiveContainer width="100%" height={200}>
              <PieChart>
                <Pie data={splitData} cx="50%" cy="50%" innerRadius={50} outerRadius={80} paddingAngle={4} dataKey="value">
                  {splitData.map((e, i) => <Cell key={i} fill={e.color} />)}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background:   '#0F1729',
                    border:       '1px solid #1B2B4B',
                    borderRadius: 8,
                    fontSize:     12,
                    color:        '#E2E8F0',
                  }}
                  labelStyle={{ color: '#E2E8F0' }}
                  itemStyle={{ color: '#E2E8F0' }}
                  formatter={(v: number, name: string) => [`$${v.toLocaleString()}`, name]}
                />
              </PieChart>
            </ResponsiveContainer>
            <div className="mt-2 flex justify-center gap-4">
              {splitData.map(d => (
                <div key={d.name} className="flex items-center gap-1.5 text-xs">
                  <span className="h-2.5 w-2.5 rounded-full" style={{ background: d.color }} />
                  <span className="text-[#64748B]">{d.name}: ${d.value.toLocaleString()}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </AdminShell>
  )
}
