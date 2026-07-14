'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Loader2, ScrollText, ChevronDown, ChevronRight, Shield, User } from 'lucide-react'
import { DutySessionLogs } from '@/components/admin/DutySessionLogs'

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

interface Group {
  admin:  { id: string; name: string; email: string; role: string }
  logs:   any[]
  count:  number
  lastAt: number | null
}

export default function AdminAudit() {
  const [groups, setGroups]   = useState<Group[]>([])
  const [total, setTotal]     = useState(0)
  const [loading, setLoading] = useState(true)
  const [open, setOpen]       = useState<Record<string, boolean>>({})
  const [tab, setTab]         = useState<'actions' | 'sessions'>('actions')

  useEffect(() => {
    adminFetch('/admin/manage/audit/grouped')
      .then(r => r.json())
      .then(d => {
        const gs: Group[] = d?.groups ?? []
        setGroups(gs)
        setTotal(d?.totalActions ?? 0)
        // Open the super admin section by default; collapse the rest.
        const init: Record<string, boolean> = {}
        gs.forEach(g => { init[g.admin.id] = g.admin.role === 'super_admin' })
        setOpen(init)
      })
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  const toggle = (id: string) => setOpen(o => ({ ...o, [id]: !o[id] }))

  return (
    <AdminShell>
      <div className="mb-4 flex items-baseline justify-between">
        <h1 className="text-xl font-semibold text-app-text">Audit log</h1>
        {!loading && tab === 'actions' && (
          <span className="text-xs text-app-muted">
            {total} action{total === 1 ? '' : 's'} across {groups.length} account{groups.length === 1 ? '' : 's'}
          </span>
        )}
      </div>

      {/* Tabs: admin actions vs duty session logs */}
      <div className="mb-6 flex gap-1 border-b border-app-border">
        {([
          ['actions',  'Admin actions'],
          ['sessions', 'Duty sessions'],
        ] as const).map(([key, label]) => (
          <button key={key} onClick={() => setTab(key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
              tab === key
                ? 'border-app-accent text-app-text'
                : 'border-transparent text-app-muted hover:text-app-text'}`}>
            {label}
          </button>
        ))}
      </div>

      {tab === 'sessions' ? <DutySessionLogs /> : (
      <>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : groups.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <ScrollText className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No activity logged yet</p>
        </div>
      ) : (
        <div className="space-y-3">
          {groups.map(g => {
            const isSuper   = g.admin.role === 'super_admin'
            const isRemoved = g.admin.role === 'removed'
            const expanded  = !!open[g.admin.id]
            return (
              <div key={g.admin.id}
                className={`overflow-hidden rounded-xl border bg-app-surface ${
                  isSuper ? 'border-app-accent/40' : 'border-app-border'}`}>

                {/* Group header */}
                <button onClick={() => toggle(g.admin.id)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left hover:bg-app-bg/40">
                  <span className="flex items-center gap-3">
                    {expanded
                      ? <ChevronDown className="h-4 w-4 text-app-muted" />
                      : <ChevronRight className="h-4 w-4 text-app-muted" />}
                    <span className={`inline-flex h-7 w-7 items-center justify-center rounded-lg ${
                      isSuper ? 'bg-app-accent/20 text-app-accent-text' : 'bg-app-border/50 text-app-muted'}`}>
                      {isSuper ? <Shield className="h-3.5 w-3.5" /> : <User className="h-3.5 w-3.5" />}
                    </span>
                    <span>
                      <span className="block text-sm font-medium text-app-text">
                        {g.admin.name || 'Unnamed admin'}
                        {isSuper && (
                          <span className="ml-2 rounded-full bg-app-accent/15 px-2 py-0.5 text-[10px] font-medium text-app-accent-text">
                            Super admin
                          </span>
                        )}
                        {isRemoved && (
                          <span className="ml-2 rounded-full bg-app-border px-2 py-0.5 text-[10px] font-medium text-app-muted">
                            Removed
                          </span>
                        )}
                      </span>
                      {g.admin.email && (
                        <span className="block text-xs text-app-muted">{g.admin.email}</span>
                      )}
                    </span>
                  </span>

                  <span className="flex items-center gap-4 text-xs text-app-muted">
                    <span>{g.count} action{g.count === 1 ? '' : 's'}</span>
                    {g.lastAt && (
                      <span className="hidden sm:inline">
                        last {new Date(Number(g.lastAt) * 1000).toLocaleString()}
                      </span>
                    )}
                  </span>
                </button>

                {/* Group body */}
                {expanded && (
                  g.logs.length === 0 ? (
                    <p className="border-t border-app-border px-4 py-6 text-center text-xs text-app-muted">
                      No actions recorded for this account yet
                    </p>
                  ) : (
                    <div className="overflow-x-auto border-t border-app-border">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="border-b border-app-border text-left text-xs text-app-muted">
                            <th className="px-4 py-2.5 font-medium">Action</th>
                            <th className="px-4 py-2.5 font-medium">Details</th>
                            <th className="px-4 py-2.5 font-medium">When</th>
                          </tr>
                        </thead>
                        <tbody>
                          {g.logs.map(log => (
                            <tr key={log.id} className="border-b border-app-border/50 last:border-0">
                              <td className="px-4 py-2.5">
                                <span className={`font-mono text-xs ${ACTION_COLOR[log.action] ?? 'text-app-text'}`}>
                                  {log.action}
                                </span>
                              </td>
                              <td className="max-w-md truncate px-4 py-2.5 text-xs text-app-muted">
                                {log.details ?? '-'}
                              </td>
                              <td className="whitespace-nowrap px-4 py-2.5 text-xs text-app-muted">
                                {new Date(Number(log.created_at) * 1000).toLocaleString()}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )
                )}
              </div>
            )
          })}
        </div>
      )}
      </>
      )}
    </AdminShell>
  )
}
