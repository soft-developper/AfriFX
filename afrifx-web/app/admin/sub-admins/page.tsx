'use client'
import { useEffect, useState } from 'react'
import { DutyHoursPicker, type DutyValue } from '@/components/admin/DutyHoursPicker'
import { DutyOverview } from '@/components/admin/DutyOverview'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Loader2, Plus, Shield, Trash2, Pause, Play,
  Key, Check, Mail, CheckCircle, AlertCircle, X,
} from 'lucide-react'

export default function AdminSubAdmins() {
  const { admin, invite } = useAdminAuth()
  const [admins,  setAdmins]  = useState<any[]>([])
  const [permMeta, setPermMeta] = useState<any>({})
  const [allPerms, setAllPerms] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [busy, setBusy] = useState<string|null>(null)

  // Invite form state
  const [inviteEmail, setInviteEmail] = useState('')
  const [selectedPerms, setSelectedPerms] = useState<string[]>([])
  const [duty, setDuty] = useState<DutyValue | null>(null)
  const [inviteError,   setInviteError]   = useState<string|null>(null)
  const [inviteSuccess, setInviteSuccess] = useState<string|null>(null)

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

  async function sendInvite() {
    if (!inviteEmail || selectedPerms.length === 0) return
    setInviteError(null); setInviteSuccess(null)
    setBusy('create')
    try {
      const result = await invite(inviteEmail, selectedPerms, duty ?? undefined)
      if (result.success) {
        setInviteSuccess(result.message ?? `Invitation sent to ${inviteEmail}`)
        setInviteEmail(''); setSelectedPerms([]); setDuty(null)
      } else {
        setInviteError((result as any).error ?? 'Could not send invitation')
      }
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
    const newPassword = prompt(`Reset password for ${a.username}:\nEnter new password (min 12 chars):`)
    if (!newPassword) return
    setInviteError(null); setInviteSuccess(null)
    setBusy(a.id)
    try {
      const res = await adminFetch(`/admin/manage/admins/${a.id}/credentials`, {
        method: 'PATCH', body: JSON.stringify({ newPassword }),
      })
      if (res.ok) setInviteSuccess(`Password reset for ${a.username}`)
      else setInviteError((await res.json()).error ?? 'Failed to reset password')
    } finally { setBusy(null) }
  }

  function togglePerm(list: string[], setList: (l: string[]) => void, perm: string) {
    setList(list.includes(perm) ? list.filter(p => p !== perm) : [...list, perm])
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-app-text">Sub-admin management</h1>
        {admin?.role === 'super_admin' && (
          <Button size="sm" onClick={() => { setShowForm(!showForm); setInviteError(null); setInviteSuccess(null) }}>
            <Plus className="h-4 w-4" /> Invite sub-admin
          </Button>
        )}
      </div>

      {admin?.role !== 'super_admin' && (
        <div className="mb-6 flex items-center gap-2 rounded-lg bg-app-surface border border-app-border px-4 py-3 text-xs text-app-muted">
          Only the super admin can invite new sub-admins.
        </div>
      )}

      {/* Standalone feedback (e.g. after a password reset, when the invite form is closed) */}
      {!showForm && inviteSuccess && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
          <span className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
          </span>
          <button onClick={() => setInviteSuccess(null)} className="shrink-0 hover:text-emerald-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}
      {!showForm && inviteError && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
          </span>
          <button onClick={() => setInviteError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Invite form */}
      {showForm && (
        <div className="mb-6 rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-1 text-sm font-medium text-app-text">Invite a sub-admin</p>
          <p className="mb-4 text-xs text-app-muted">
            They'll get an email with a link to set their own password and, optionally, 2FA.
          </p>
          <div className="relative mb-4">
            <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
            <Input className="pl-9" placeholder="Email address" type="email" autoComplete="off"
              value={inviteEmail} onChange={e => setInviteEmail(e.target.value)} />
          </div>

          <p className="mb-2 text-xs font-medium text-app-text">Permissions</p>
          <div className="mb-4 grid grid-cols-2 gap-2 lg:grid-cols-3">
            {allPerms.map(perm => (
              <button key={perm} onClick={() => togglePerm(selectedPerms, setSelectedPerms, perm)}
                className={`flex items-start gap-2 rounded-lg border p-2.5 text-left transition-colors
                  ${selectedPerms.includes(perm)
                    ? 'border-app-accent bg-app-accent/10'
                    : 'border-app-border bg-app-bg'}`}>
                <div className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded
                  ${selectedPerms.includes(perm) ? 'bg-app-accent' : 'border border-app-border'}`}>
                  {selectedPerms.includes(perm) && <Check className="h-3 w-3 text-app-on-accent" />}
                </div>
                <div>
                  <p className="text-xs font-medium text-app-text">{permMeta[perm]?.label ?? perm}</p>
                  <p className="text-[10px] text-app-muted">{permMeta[perm]?.description}</p>
                  {permMeta[perm]?.note && (
                    <p className="mt-0.5 text-[10px] text-amber-500">{permMeta[perm].note}</p>
                  )}
                </div>
              </button>
            ))}
          </div>

          <div className="mb-4">
            <DutyHoursPicker value={duty} onChange={setDuty} />
          </div>

          <div className="flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setShowForm(false)}>Cancel</Button>
            <Button className="flex-1" onClick={sendInvite}
              disabled={!inviteEmail || selectedPerms.length === 0 || busy === 'create'}>
              {busy === 'create' ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Mail className="h-4 w-4" /> Send invite</>}
            </Button>
          </div>

          {inviteSuccess && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
            </div>
          )}
          {inviteError && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
            </div>
          )}
        </div>
      )}

      {/* Working-hour sessions — live status for every sub-admin */}
      <div className="mb-6">
        <div className="mb-3 flex items-baseline justify-between">
          <h2 className="text-sm font-medium text-app-text">Working-hour sessions</h2>
          <span className="text-xs text-app-muted">Times shown in UTC · updates live</span>
        </div>
        <DutyOverview />
      </div>

      {/* Admins list */}
      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : (
        <div className="space-y-3">
          {admins.map(a => (
            <div key={a.id} className="rounded-xl border border-app-border bg-app-surface p-5">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className={`flex h-10 w-10 items-center justify-center rounded-full
                    ${a.role === 'super_admin' ? 'bg-amber-500/20' : 'bg-app-accent/10'}`}>
                    <Shield className={`h-5 w-5 ${a.role === 'super_admin' ? 'text-amber-400' : 'text-app-accent-text'}`} />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-app-text">{a.username}</p>
                      <Badge variant={a.role === 'super_admin' ? 'warning' : 'arc'}>
                        {a.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
                      </Badge>
                      {a.status === 'suspended' && <Badge variant="danger">Suspended</Badge>}
                    </div>
                    <p className="text-xs text-app-muted">{a.email}</p>
                    {a.last_login && (
                      <p className="text-[10px] text-app-muted">
                        Last login: {new Date(Number(a.last_login) * 1000).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>

                {a.role !== 'super_admin' && (
                  <div className="flex gap-1">
                    <button onClick={() => resetCredentials(a)} disabled={busy === a.id}
                      title="Reset password"
                      className="rounded p-1.5 text-app-muted hover:text-app-accent-text">
                      <Key className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => toggleStatus(a)} disabled={busy === a.id}
                      title={a.status === 'active' ? 'Suspend' : 'Activate'}
                      className="rounded p-1.5 text-app-muted hover:text-amber-400">
                      {a.status === 'active' ? <Pause className="h-3.5 w-3.5" /> : <Play className="h-3.5 w-3.5" />}
                    </button>
                    <button onClick={() => deleteAdmin(a.id)} disabled={busy === a.id}
                      title="Remove"
                      className="rounded p-1.5 text-app-muted hover:text-red-400">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                )}
              </div>

              {/* Permissions */}
              {a.role !== 'super_admin' && (
                <div className="mt-3 border-t border-app-border pt-3">
                  {editingId === a.id ? (
                    <div>
                      <div className="mb-2 grid grid-cols-2 gap-2 lg:grid-cols-3">
                        {allPerms.map(perm => (
                          <button key={perm} onClick={() => togglePerm(editPerms, setEditPerms, perm)}
                            className={`flex items-center gap-1.5 rounded-lg border p-2 text-left text-xs transition-colors
                              ${editPerms.includes(perm) ? 'border-app-accent bg-app-accent/10 text-app-text' : 'border-app-border text-app-muted'}`}>
                            <div className={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded
                              ${editPerms.includes(perm) ? 'bg-app-accent' : 'border border-app-border'}`}>
                              {editPerms.includes(perm) && <Check className="h-2.5 w-2.5 text-app-on-accent" />}
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
                          <span className="text-xs text-app-muted">No permissions granted</span>
                        ) : (a.permissions ?? []).map((p: string) => (
                          <span key={p} className="rounded-full bg-app-border px-2 py-0.5 text-[10px] text-app-text">
                            {permMeta[p]?.label ?? p}
                          </span>
                        ))}
                      </div>
                      <button onClick={() => { setEditingId(a.id); setEditPerms(a.permissions ?? []) }}
                        className="shrink-0 text-xs text-app-accent-text hover:underline">
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
