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
