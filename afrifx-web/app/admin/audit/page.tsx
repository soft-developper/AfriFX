'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Loader2, ScrollText } from 'lucide-react'

const ACTION_COLOR: Record<string, string> = {
  login:              'text-[#64748B]',
  logout:             'text-[#64748B]',
  create_sub_admin:   'text-emerald-400',
  update_sub_admin:   'text-[#378ADD]',
  delete_sub_admin:   'text-red-400',
  force_release_offer:'text-amber-400',
  force_cancel_offer: 'text-red-400',
  resolve_dispute:    'text-emerald-400',
  suspend_user:       'text-red-400',
  unsuspend_user:     'text-emerald-400',
  update_credentials: 'text-[#378ADD]',
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
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">Audit log</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : logs.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <ScrollText className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No activity logged yet</p>
        </div>
      ) : (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-[#1B2B4B] text-left text-xs text-[#64748B]">
                <th className="px-4 py-3 font-medium">Admin</th>
                <th className="px-4 py-3 font-medium">Action</th>
                <th className="px-4 py-3 font-medium">Details</th>
                <th className="px-4 py-3 font-medium">When</th>
              </tr>
            </thead>
            <tbody>
              {logs.map(log => (
                <tr key={log.id} className="border-b border-[#1B2B4B]/50 last:border-0">
                  <td className="px-4 py-3">
                    <span className="font-medium text-[#E2E8F0]">{log.admin_name}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`font-mono text-xs ${ACTION_COLOR[log.action] ?? 'text-[#E2E8F0]'}`}>
                      {log.action}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-xs text-[#64748B] max-w-md truncate">
                    {log.details ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-xs text-[#64748B] whitespace-nowrap">
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
