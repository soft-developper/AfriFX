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
            <Input placeholder="Username" autoComplete="off" value={username} onChange={e => setUsername(e.target.value)} />
            <Input placeholder="Email" type="email" autoComplete="off" value={email} onChange={e => setEmail(e.target.value)} />
            <Input placeholder="Password (min 8 chars)" type="password" autoComplete="new-password" value={password} onChange={e => setPassword(e.target.value)} />
            <Input placeholder="Wallet address (required)" autoComplete="off" value={wallet} onChange={e => setWallet(e.target.value)} className="font-mono text-xs" />
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
              disabled={!username || !email || !password || !wallet || selectedPerms.length === 0 || busy === 'create'}>
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
