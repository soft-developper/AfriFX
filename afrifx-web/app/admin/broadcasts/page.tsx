'use client'
import { useState, useEffect, useCallback } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import {
  Megaphone, Users, Shield, Filter, UserCheck, Loader2,
  Send, AlertCircle, CheckCircle2, Eye, History, Search,
} from 'lucide-react'

type Audience = 'sub_admins' | 'all_users' | 'selected' | 'filtered'

const AUDIENCES: { key: Audience; label: string; desc: string; icon: any }[] = [
  { key: 'sub_admins', label: 'Sub-admins',  desc: 'Internal message to all active sub-admins', icon: Shield },
  { key: 'all_users',  label: 'All users',   desc: 'Every registered user with an email',        icon: Users },
  { key: 'selected',   label: 'Selected',    desc: 'Pick specific users from a list',            icon: UserCheck },
  { key: 'filtered',   label: 'Filtered',    desc: 'A group, e.g. users with disputes',          icon: Filter },
]

const FILTERS = [
  { key: 'active_traders', label: 'Active traders',     desc: 'Users who have made or taken an offer' },
  { key: 'has_disputes',   label: 'Users with disputes', desc: 'Users involved in a disputed trade' },
]

interface Count { total: number; willSend: number; optedOut: number; internal: boolean }
interface UserRow { wallet: string; username: string; name: string; email: string; optedOut: boolean }

export default function AdminBroadcasts() {
  const { admin } = useAdminAuth()
  const [audience, setAudience] = useState<Audience>('all_users')
  const [filter,   setFilter]   = useState('active_traders')
  const [subject,  setSubject]  = useState('')
  const [body,     setBody]     = useState('')

  const [count,   setCount]   = useState<Count | null>(null)
  const [users,   setUsers]   = useState<UserRow[]>([])
  const [picked,  setPicked]  = useState<string[]>([])
  const [search,  setSearch]  = useState('')

  const [sending, setSending] = useState(false)
  const [result,  setResult]  = useState<string | null>(null)
  const [error,   setError]   = useState<string | null>(null)
  const [preview, setPreview] = useState(false)
  const [history, setHistory] = useState<any[]>([])
  const [tab, setTab] = useState<'compose' | 'history'>('compose')

  // Live recipient count for the chosen audience.
  const loadCount = useCallback(async () => {
    if (audience === 'selected') {
      setCount({ total: picked.length, willSend: picked.length, optedOut: 0, internal: false })
      return
    }
    setCount(null)
    try {
      const q = audience === 'filtered' ? `?filter=${filter}` : ''
      const r = await adminFetch(`/admin/broadcasts/audience/${audience}${q}`)
      setCount(await r.json())
    } catch { /* leave null */ }
  }, [audience, filter, picked.length])

  useEffect(() => { loadCount() }, [loadCount])

  // User list for the "selected" picker.
  useEffect(() => {
    if (audience !== 'selected' || users.length) return
    adminFetch('/admin/broadcasts/users')
      .then(r => r.json())
      .then(d => setUsers(Array.isArray(d) ? d : []))
      .catch(() => {})
  }, [audience, users.length])

  useEffect(() => {
    if (tab !== 'history') return
    adminFetch('/admin/broadcasts')
      .then(r => r.json())
      .then(d => setHistory(Array.isArray(d) ? d : []))
      .catch(() => {})
  }, [tab])

  async function send() {
    setError(null); setResult(null)
    if (!subject.trim() || !body.trim()) { setError('Subject and message are required'); return }
    if (audience === 'selected' && !picked.length) { setError('Pick at least one recipient'); return }

    const who = audience === 'sub_admins' ? 'all sub-admins'
      : audience === 'all_users' ? `all users (${count?.willSend ?? '?'} will receive it)`
      : audience === 'selected' ? `${picked.length} selected user(s)`
      : `the "${FILTERS.find(f => f.key === filter)?.label}" group (${count?.willSend ?? '?'} will receive it)`

    if (!confirm(`Send "${subject.trim()}" to ${who}?\n\nThis cannot be undone.`)) return

    setSending(true)
    try {
      const r = await adminFetch('/admin/broadcasts', {
        method: 'POST',
        body: JSON.stringify({
          audience, subject: subject.trim(), body: body.trim(),
          detail: audience === 'filtered' ? { filter }
                : audience === 'selected' ? { wallets: picked }
                : {},
        }),
      })
      const d = await r.json()
      if (!r.ok) { setError(d?.error ?? 'Could not send'); return }
      setResult(
        `Sending to ${d.sending} recipient${d.sending === 1 ? '' : 's'}` +
        (d.skippedOptOut ? ` · ${d.skippedOptOut} skipped (opted out)` : '') +
        '. Delivery continues in the background.')
      setSubject(''); setBody(''); setPicked([])
    } catch { setError('Could not send') }
    finally { setSending(false) }
  }

  const filtered = users.filter(u =>
    !search ||
    u.username?.toLowerCase().includes(search.toLowerCase()) ||
    u.email?.toLowerCase().includes(search.toLowerCase()))

  return (
    <AdminShell>
      <div className="mb-4 flex items-baseline justify-between">
        <h1 className="text-xl font-semibold text-app-text">Broadcasts</h1>
        <span className="text-xs text-app-muted">Delivered via Resend</span>
      </div>

      <div className="mb-6 flex gap-1 border-b border-app-border">
        {([['compose', 'Compose'], ['history', 'History']] as const).map(([k, l]) => (
          <button key={k} onClick={() => setTab(k)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
              tab === k ? 'border-app-accent text-app-text'
                        : 'border-transparent text-app-muted hover:text-app-text'}`}>
            {l}
          </button>
        ))}
      </div>

      {tab === 'history' ? (
        history.length === 0 ? (
          <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
            <History className="mx-auto mb-2 h-8 w-8 text-app-border" />
            <p className="text-sm text-app-muted">No broadcasts sent yet</p>
          </div>
        ) : (
          <div className="overflow-hidden rounded-xl border border-app-border bg-app-surface">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-app-border text-left text-xs text-app-muted">
                  <th className="px-4 py-3 font-medium">Subject</th>
                  <th className="px-4 py-3 font-medium">Audience</th>
                  <th className="px-4 py-3 font-medium">Sent by</th>
                  <th className="px-4 py-3 text-right font-medium">Delivered</th>
                  <th className="px-4 py-3 text-right font-medium">Failed</th>
                  <th className="px-4 py-3 text-right font-medium">Opted out</th>
                  <th className="px-4 py-3 font-medium">When</th>
                </tr>
              </thead>
              <tbody>
                {history.map((b: any) => (
                  <tr key={b.id} className="border-b border-app-border/50 last:border-0">
                    <td className="max-w-xs truncate px-4 py-3 text-app-text">{b.subject}</td>
                    <td className="px-4 py-3 text-xs text-app-muted">{b.audience}</td>
                    <td className="px-4 py-3 text-xs text-app-muted">{b.sent_by_name}</td>
                    <td className="px-4 py-3 text-right font-mono text-xs text-emerald-400">{b.delivered ?? 0}</td>
                    <td className="px-4 py-3 text-right font-mono text-xs text-red-400">{b.failed ?? 0}</td>
                    <td className="px-4 py-3 text-right font-mono text-xs text-app-muted">{b.skipped_optout ?? 0}</td>
                    <td className="whitespace-nowrap px-4 py-3 text-xs text-app-muted">
                      {new Date(Number(b.created_at) * 1000).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      ) : (
        <div className="grid gap-4 lg:grid-cols-3">
          {/* Compose */}
          <div className="space-y-4 lg:col-span-2">
            {/* Audience */}
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-3 text-sm font-medium text-app-text">Who receives this?</p>
              <div className="grid gap-2 sm:grid-cols-2">
                {AUDIENCES.map(a => {
                  const Icon = a.icon
                  const on = audience === a.key
                  return (
                    <button key={a.key} onClick={() => setAudience(a.key)}
                      className={`flex items-start gap-2.5 rounded-lg border p-3 text-left transition-colors ${
                        on ? 'border-app-accent bg-app-accent/[0.07]' : 'border-app-border hover:border-app-accent/50'}`}>
                      <Icon className={`mt-0.5 h-4 w-4 shrink-0 ${on ? 'text-app-accent-text' : 'text-app-muted'}`} />
                      <span>
                        <span className="block text-sm font-medium text-app-text">{a.label}</span>
                        <span className="block text-xs text-app-muted">{a.desc}</span>
                      </span>
                    </button>
                  )
                })}
              </div>

              {audience === 'filtered' && (
                <div className="mt-3 space-y-2 border-t border-app-border pt-3">
                  {FILTERS.map(f => (
                    <label key={f.key} className="flex cursor-pointer items-start gap-2.5">
                      <input type="radio" name="filter" checked={filter === f.key}
                        onChange={() => setFilter(f.key)} className="mt-1" />
                      <span>
                        <span className="block text-sm text-app-text">{f.label}</span>
                        <span className="block text-xs text-app-muted">{f.desc}</span>
                      </span>
                    </label>
                  ))}
                </div>
              )}

              {audience === 'selected' && (
                <div className="mt-3 border-t border-app-border pt-3">
                  <div className="mb-2 flex items-center gap-2">
                    <Search className="h-3.5 w-3.5 text-app-muted" />
                    <input value={search} onChange={e => setSearch(e.target.value)}
                      placeholder="Search users…"
                      className="flex-1 rounded-lg border border-app-border bg-app-bg px-2.5 py-1.5 text-xs text-app-text outline-none focus:ring-1 focus:ring-app-accent" />
                    <span className="text-xs text-app-muted">{picked.length} picked</span>
                  </div>
                  <div className="max-h-56 space-y-1 overflow-y-auto">
                    {filtered.map(u => (
                      <label key={u.wallet}
                        className="flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-app-bg/50">
                        <input type="checkbox" checked={picked.includes(u.wallet)}
                          onChange={e => setPicked(p =>
                            e.target.checked ? [...p, u.wallet] : p.filter(x => x !== u.wallet))} />
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-xs text-app-text">
                            {u.name || u.username || 'Unnamed'}
                            {u.optedOut && (
                              <span className="ml-1.5 text-[10px] text-amber-500">(opted out)</span>
                            )}
                          </span>
                          <span className="block truncate text-[10px] text-app-muted">{u.email}</span>
                        </span>
                      </label>
                    ))}
                    {!filtered.length && (
                      <p className="py-4 text-center text-xs text-app-muted">No users found</p>
                    )}
                  </div>
                </div>
              )}
            </div>

            {/* Message */}
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-3 text-sm font-medium text-app-text">Message</p>
              <input value={subject} onChange={e => setSubject(e.target.value)}
                placeholder="Subject"
                className="mb-2 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none focus:ring-1 focus:ring-app-accent" />
              <textarea value={body} onChange={e => setBody(e.target.value)}
                rows={9} placeholder="Write your message…&#10;&#10;Leave a blank line between paragraphs."
                className="w-full resize-y rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none focus:ring-1 focus:ring-app-accent" />
              <p className="mt-2 text-xs text-app-muted">
                Each recipient sees their own name in the greeting, and your name as the sender.
              </p>
            </div>

            {error && (
              <div className="flex items-start gap-2 rounded-xl border border-red-500/40 bg-red-500/[0.07] p-3">
                <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-400" />
                <p className="text-sm text-red-400">{error}</p>
              </div>
            )}
            {result && (
              <div className="flex items-start gap-2 rounded-xl border border-emerald-500/40 bg-emerald-500/[0.07] p-3">
                <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-400" />
                <p className="text-sm text-emerald-400">{result}</p>
              </div>
            )}
          </div>

          {/* Side: recipients + send */}
          <div className="space-y-4">
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-3 text-sm font-medium text-app-text">Recipients</p>
              {count == null ? (
                <div className="flex h-16 items-center justify-center">
                  <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
                </div>
              ) : (
                <>
                  <p className="font-mono text-3xl font-semibold text-app-text">{count.willSend}</p>
                  <p className="mt-0.5 text-xs text-app-muted">
                    will receive this email
                  </p>
                  {count.optedOut > 0 && (
                    <p className="mt-2 rounded-lg bg-amber-500/10 px-2.5 py-1.5 text-xs text-amber-500">
                      {count.optedOut} opted out of announcements and will be skipped.
                    </p>
                  )}
                  {count.internal && (
                    <p className="mt-2 text-xs text-app-muted">
                      Internal staff mail — no opt-out, no unsubscribe link.
                    </p>
                  )}
                </>
              )}
            </div>

            <button onClick={() => setPreview(p => !p)}
              className="flex w-full items-center justify-center gap-2 rounded-xl border border-app-border px-4 py-2.5 text-sm text-app-text hover:border-app-accent">
              <Eye className="h-4 w-4" /> {preview ? 'Hide preview' : 'Preview email'}
            </button>

            {preview && (
              <div className="rounded-xl border border-app-border bg-app-bg p-4 text-xs">
                <p className="mb-2 border-b border-app-border pb-2 text-[10px] uppercase tracking-wider text-app-muted">
                  Message from
                </p>
                <p className="font-semibold text-app-accent-text">{admin?.username ?? 'You'}</p>
                <p className="mb-3 text-[10px] text-app-muted">Administrator · AfriFX</p>
                <p className="mb-2 text-app-text">Hi <span className="text-app-muted">[their name]</span>,</p>
                <p className="whitespace-pre-wrap text-app-text">
                  {body || <span className="text-app-muted">Your message appears here…</span>}
                </p>
                <p className="mt-3 border-t border-app-border pt-2 text-app-muted">
                  — {admin?.username ?? 'You'}<br />
                  <span className="text-[10px]">Administrator, AfriFX</span>
                </p>
              </div>
            )}

            <button onClick={send}
              disabled={sending || !subject.trim() || !body.trim() || (count?.willSend ?? 0) === 0}
              className="flex w-full items-center justify-center gap-2 rounded-xl bg-app-accent px-4 py-3 text-sm font-semibold text-app-on-accent hover:bg-app-accent-hover disabled:opacity-50">
              {sending
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
                : <><Send className="h-4 w-4" /> Send broadcast</>}
            </button>
            <p className="text-center text-xs text-app-muted">
              This cannot be undone.
            </p>
          </div>
        </div>
      )}
    </AdminShell>
  )
}
