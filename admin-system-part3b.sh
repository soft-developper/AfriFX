#!/bin/bash
# ============================================================
# AfriFX — Admin System Part 3b: Remaining admin pages
# Run from ~/AfriFX:  bash admin-system-part3b.sh
# ============================================================
set -e
echo ""
echo "🔐  Building Admin pages — offers, disputes, users, sub-admins, analytics, audit..."
echo ""

mkdir -p afrifx-web/app/admin/{offers,disputes,users,sub-admins,analytics,audit}

# ============================================================
# 1 — Offers management page
# ============================================================
cat > afrifx-web/app/admin/offers/page.tsx << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, ExternalLink, RefreshCw } from 'lucide-react'

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
      else alert((await res.json()).error)
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
      else alert((await res.json()).error)
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Offers management</h1>
        <button onClick={load} className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      <div className="mb-4 flex gap-2">
        {['all','open','accepted','released','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-full px-3 py-1 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#378ADD] text-white' : 'border border-[#1B2B4B] text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-2">
          {offers.map(o => (
            <div key={o.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex items-center gap-4">
                <div className="flex h-9 w-9 items-center justify-center rounded-full bg-[#080D1B] text-lg">
                  {FLAGS[o.local_currency] ?? '🌍'}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-medium text-[#E2E8F0]">
                      {Number(o.usdc_amount).toFixed(2)} USDC ↔ {Number(o.local_amount).toLocaleString()} {o.local_currency}
                    </p>
                    <Badge variant={
                      o.status === 'released' ? 'success' :
                      o.status === 'accepted' ? 'arc' :
                      o.status === 'cancelled' ? 'danger' : 'warning'
                    }>{o.status}</Badge>
                  </div>
                  <p className="font-mono text-[10px] text-[#64748B]">
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
          {offers.length === 0 && <p className="py-8 text-center text-sm text-[#64748B]">No offers found</p>}
        </div>
      )}
    </AdminShell>
  )
}
__EOF__
echo "✅  admin/offers/page.tsx"

# ============================================================
# 2 — Disputes page
# ============================================================
cat > afrifx-web/app/admin/disputes/page.tsx << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, AlertTriangle, ArrowRight } from 'lucide-react'

export default function AdminDisputes() {
  const [disputes, setDisputes] = useState<any[]>([])
  const [loading,  setLoading]  = useState(true)
  const [busy,     setBusy]     = useState<string|null>(null)

  async function load() {
    setLoading(true)
    const res = await adminFetch('/admin/manage/disputes?status=open')
    const data = await res.json()
    setDisputes(Array.isArray(data) ? data : [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function resolve(d: any, resolution: 'release'|'refund') {
    const label = resolution === 'release' ? 'release USDC to the TAKER' : 'refund USDC to the MAKER'
    const reason = prompt(`Resolve dispute — this will ${label}.\nEnter a reason:`)
    if (reason === null) return
    setBusy(d.id)
    try {
      const res = await adminFetch(`/admin/manage/disputes/${d.id}/resolve`, {
        method: 'POST',
        body: JSON.stringify({ resolution, offerId: d.offer_id, reason }),
      })
      if (res.ok) await load()
      else alert((await res.json()).error)
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">Dispute resolution</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <AlertTriangle className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No open disputes 🎉</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map(d => (
            <div key={d.id} className="rounded-xl border border-amber-900/40 bg-amber-900/10 p-5">
              <div className="mb-3 flex items-center justify-between">
                <Badge variant="danger">Dispute open</Badge>
                <span className="text-xs text-[#64748B]">
                  {d.created_at ? new Date(Number(d.created_at) * 1000).toLocaleString() : ''}
                </span>
              </div>

              <div className="mb-3 grid grid-cols-2 gap-3 text-xs">
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Trade</p>
                  <p className="font-mono text-[#E2E8F0]">
                    {Number(d.usdc_amount ?? 0).toFixed(2)} USDC ↔ {Number(d.local_amount ?? 0).toLocaleString()} {d.local_currency}
                  </p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Reason</p>
                  <p className="text-[#E2E8F0]">{d.reason ?? 'Maker did not confirm'}</p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Maker</p>
                  <p className="font-mono text-[#E2E8F0]">{d.maker_address?.slice(0,16)}…</p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Taker</p>
                  <p className="font-mono text-[#E2E8F0]">{d.taker_address?.slice(0,16)}…</p>
                </div>
              </div>

              <div className="flex gap-2">
                <Button size="sm" className="flex-1" onClick={() => resolve(d, 'release')} disabled={busy === d.id}>
                  {busy === d.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <>Release to taker <ArrowRight className="h-3.5 w-3.5" /></>}
                </Button>
                <Button size="sm" variant="danger" className="flex-1" onClick={() => resolve(d, 'refund')} disabled={busy === d.id}>
                  Refund maker
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </AdminShell>
  )
}
__EOF__
echo "✅  admin/disputes/page.tsx"

# ============================================================
# 3 — Users page
# ============================================================
cat > afrifx-web/app/admin/users/page.tsx << '__EOF__'
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
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">User management</h1>

      <div className="mb-4 flex gap-2">
        <div className="relative flex-1 max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
          <Input placeholder="Search by username, wallet or name…" value={search}
            onChange={e => setSearch(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && load(search)}
            className="pl-9" />
        </div>
        <Button size="sm" onClick={() => load(search)}>Search</Button>
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-2">
          {users.map(u => (
            <div key={u.wallet_address} className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex h-9 w-9 items-center justify-center rounded-full text-sm font-bold text-white"
                style={{ background: u.avatar_color ?? '#378ADD' }}>
                {(u.display_name ?? u.username ?? '?')[0].toUpperCase()}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="text-sm font-medium text-[#E2E8F0]">{u.display_name ?? u.username}</p>
                  <span className="text-xs text-[#378ADD]">@{u.username}</span>
                  {u.verified ? <Badge variant="arc">Verified</Badge> : null}
                  {u.suspended ? <Badge variant="danger">Suspended</Badge> : null}
                </div>
                <p className="font-mono text-[10px] text-[#64748B]">{u.wallet_address}</p>
              </div>
              <div className="text-right text-xs">
                <p className="font-mono text-[#E2E8F0]">{u.trades} trades</p>
                <p className="text-[#64748B]">{new Date(Number(u.created_at) * 1000).toLocaleDateString()}</p>
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
          {users.length === 0 && <p className="py-8 text-center text-sm text-[#64748B]">No users found</p>}
        </div>
      )}
    </AdminShell>
  )
}
__EOF__
echo "✅  admin/users/page.tsx"

# ============================================================
# 4 — Sub-admins management page
# ============================================================
cat > afrifx-web/app/admin/sub-admins/page.tsx << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Loader2, Plus, Shield, Trash2, Pause, Play,
  Key, X, Check,
} from 'lucide-react'

export default function AdminSubAdmins() {
  const [admins,  setAdmins]  = useState<any[]>([])
  const [permMeta, setPermMeta] = useState<any>({})
  const [allPerms, setAllPerms] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [busy, setBusy] = useState<string|null>(null)

  // Form state
  const [username, setUsername] = useState('')
  const [email,    setEmail]    = useState('')
  const [password, setPassword] = useState('')
  const [wallet,   setWallet]   = useState('')
  const [selectedPerms, setSelectedPerms] = useState<string[]>([])

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

  async function createAdmin() {
    if (!username || !email || !password) return
    setBusy('create')
    try {
      const res = await adminFetch('/admin/manage/admins', {
        method: 'POST',
        body: JSON.stringify({ username, email, password, walletAddress: wallet, permissions: selectedPerms }),
      })
      if (res.ok) {
        setShowForm(false)
        setUsername(''); setEmail(''); setPassword(''); setWallet(''); setSelectedPerms([])
        await load()
      } else alert((await res.json()).error)
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
    const newPassword = prompt(`Reset password for ${a.username}:\nEnter new password (min 8 chars):`)
    if (!newPassword) return
    setBusy(a.id)
    try {
      const res = await adminFetch(`/admin/manage/admins/${a.id}/credentials`, {
        method: 'PATCH', body: JSON.stringify({ newPassword }),
      })
      if (res.ok) alert('Password reset successfully')
      else alert((await res.json()).error)
    } finally { setBusy(null) }
  }

  function togglePerm(list: string[], setList: (l: string[]) => void, perm: string) {
    setList(list.includes(perm) ? list.filter(p => p !== perm) : [...list, perm])
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Sub-admin management</h1>
        <Button size="sm" onClick={() => setShowForm(!showForm)}>
          <Plus className="h-4 w-4" /> Add sub-admin
        </Button>
      </div>

      {/* Create form */}
      {showForm && (
        <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">New sub-admin</p>
          <div className="mb-4 grid grid-cols-2 gap-3">
            <Input placeholder="Username" value={username} onChange={e => setUsername(e.target.value)} />
            <Input placeholder="Email" type="email" value={email} onChange={e => setEmail(e.target.value)} />
            <Input placeholder="Password (min 8 chars)" type="password" value={password} onChange={e => setPassword(e.target.value)} />
            <Input placeholder="Wallet address (optional)" value={wallet} onChange={e => setWallet(e.target.value)} className="font-mono text-xs" />
          </div>

          <p className="mb-2 text-xs font-medium text-[#E2E8F0]">Permissions</p>
          <div className="mb-4 grid grid-cols-2 gap-2 lg:grid-cols-3">
            {allPerms.map(perm => (
              <button key={perm} onClick={() => togglePerm(selectedPerms, setSelectedPerms, perm)}
                className={`flex items-start gap-2 rounded-lg border p-2.5 text-left transition-colors
                  ${selectedPerms.includes(perm)
                    ? 'border-[#378ADD] bg-[#378ADD]/10'
                    : 'border-[#1B2B4B] bg-[#080D1B]'}`}>
                <div className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded
                  ${selectedPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                  {selectedPerms.includes(perm) && <Check className="h-3 w-3 text-white" />}
                </div>
                <div>
                  <p className="text-xs font-medium text-[#E2E8F0]">{permMeta[perm]?.label ?? perm}</p>
                  <p className="text-[10px] text-[#64748B]">{permMeta[perm]?.description}</p>
                </div>
              </button>
            ))}
          </div>

          <div className="flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setShowForm(false)}>Cancel</Button>
            <Button className="flex-1" onClick={createAdmin}
              disabled={!username || !email || !password || busy === 'create'}>
              {busy === 'create' ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Create sub-admin'}
            </Button>
          </div>
        </div>
      )}

      {/* Admins list */}
      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-3">
          {admins.map(a => (
            <div key={a.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className={`flex h-10 w-10 items-center justify-center rounded-full
                    ${a.role === 'super_admin' ? 'bg-amber-500/20' : 'bg-[#378ADD]/10'}`}>
                    <Shield className={`h-5 w-5 ${a.role === 'super_admin' ? 'text-amber-400' : 'text-[#378ADD]'}`} />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-[#E2E8F0]">{a.username}</p>
                      <Badge variant={a.role === 'super_admin' ? 'warning' : 'arc'}>
                        {a.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
                      </Badge>
                      {a.status === 'suspended' && <Badge variant="danger">Suspended</Badge>}
                    </div>
                    <p className="text-xs text-[#64748B]">{a.email}</p>
                    {a.last_login && (
                      <p className="text-[10px] text-[#64748B]">
                        Last login: {new Date(Number(a.last_login) * 1000).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>

                {a.role !== 'super_admin' && (
                  <div className="flex gap-1">
                    <button onClick={() => resetCredentials(a)} disabled={busy === a.id}
                      title="Reset password"
                      className="rounded p-1.5 text-[#64748B] hover:text-[#378ADD]">
                      <Key className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => toggleStatus(a)} disabled={busy === a.id}
                      title={a.status === 'active' ? 'Suspend' : 'Activate'}
                      className="rounded p-1.5 text-[#64748B] hover:text-amber-400">
                      {a.status === 'active' ? <Pause className="h-3.5 w-3.5" /> : <Play className="h-3.5 w-3.5" />}
                    </button>
                    <button onClick={() => deleteAdmin(a.id)} disabled={busy === a.id}
                      title="Remove"
                      className="rounded p-1.5 text-[#64748B] hover:text-red-400">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                )}
              </div>

              {/* Permissions */}
              {a.role !== 'super_admin' && (
                <div className="mt-3 border-t border-[#1B2B4B] pt-3">
                  {editingId === a.id ? (
                    <div>
                      <div className="mb-2 grid grid-cols-2 gap-2 lg:grid-cols-3">
                        {allPerms.map(perm => (
                          <button key={perm} onClick={() => togglePerm(editPerms, setEditPerms, perm)}
                            className={`flex items-center gap-1.5 rounded-lg border p-2 text-left text-xs transition-colors
                              ${editPerms.includes(perm) ? 'border-[#378ADD] bg-[#378ADD]/10 text-[#E2E8F0]' : 'border-[#1B2B4B] text-[#64748B]'}`}>
                            <div className={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded
                              ${editPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                              {editPerms.includes(perm) && <Check className="h-2.5 w-2.5 text-white" />}
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
                          <span className="text-xs text-[#64748B]">No permissions granted</span>
                        ) : (a.permissions ?? []).map((p: string) => (
                          <span key={p} className="rounded-full bg-[#1B2B4B] px-2 py-0.5 text-[10px] text-[#E2E8F0]">
                            {permMeta[p]?.label ?? p}
                          </span>
                        ))}
                      </div>
                      <button onClick={() => { setEditingId(a.id); setEditPerms(a.permissions ?? []) }}
                        className="shrink-0 text-xs text-[#378ADD] hover:underline">
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
__EOF__
echo "✅  admin/sub-admins/page.tsx"

# ============================================================
# 5 — Analytics page
# ============================================================
cat > afrifx-web/app/admin/analytics/page.tsx << '__EOF__'
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
                <XAxis type="number" tick={{ fill: '#64748B', fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={v => `$${v}`} />
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
                  contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 12 }}
                  formatter={(v: number) => `$${v.toLocaleString()}`}
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
__EOF__
echo "✅  admin/analytics/page.tsx"

# ============================================================
# 6 — Audit log page
# ============================================================
cat > afrifx-web/app/admin/audit/page.tsx << '__EOF__'
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
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden">
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
__EOF__
echo "✅  admin/audit/page.tsx"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Admin System COMPLETE!"
echo ""
echo "  All admin pages built:"
echo "  /admin             — two-step login (wallet → credentials)"
echo "  /admin/dashboard   — platform overview + volume chart"
echo "  /admin/offers      — view + force release/cancel"
echo "  /admin/disputes    — resolve (release/refund)"
echo "  /admin/users       — search + suspend/unsuspend"
echo "  /admin/sub-admins  — full CRUD + permissions + reset passwords"
echo "  /admin/analytics   — corridor volume + P2P/direct split"
echo "  /admin/audit       — full activity log"
echo ""
echo "  Nav is permission-gated — sub-admins only see what"
echo "  they have access to."
echo ""
echo "  ⚠️  IMPORTANT — set these in afrifx-api/.env:"
echo "  ADMIN_WALLET=0xYourWallet"
echo "  ADMIN_USERNAME=superadmin"
echo "  ADMIN_EMAIL=admin@afrifx.com"
echo "  ADMIN_PASSWORD=YourStrongPassword"
echo "  ADMIN_JWT_SECRET=long-random-32char-string"
echo ""
echo "  Restart both servers, then visit /admin"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
