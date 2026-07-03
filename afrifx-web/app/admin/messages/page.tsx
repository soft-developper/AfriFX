'use client'
import { useState, useEffect } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Card, CardContent } from '@/components/ui/card'
import {
  Loader2, Mail, MailOpen, Archive, AlertCircle,
  ChevronDown, ChevronUp, Reply,
} from 'lucide-react'

interface Message {
  id: string; name: string; email: string
  subject: string | null; message: string
  status: 'new' | 'read' | 'archived'; created_at: number
}

const FILTERS = ['all', 'new', 'read', 'archived'] as const
type Filter = typeof FILTERS[number]

export default function AdminMessagesPage() {
  const { hasPermission } = useAdminAuth()
  const canView = hasPermission('view_messages')

  const [messages, setMessages] = useState<Message[]>([])
  const [unread,   setUnread]   = useState(0)
  const [filter,   setFilter]   = useState<Filter>('all')
  const [loading,  setLoading]  = useState(true)
  const [expanded, setExpanded] = useState<string | null>(null)
  const [error,    setError]    = useState<string | null>(null)

  async function load(f: Filter = filter) {
    setLoading(true); setError(null)
    try {
      const res = await adminFetch(`/content/messages?status=${f}`)
      if (!res.ok) {
        const d = await res.json().catch(() => ({}))
        setError(d.error ?? 'Could not load messages')
        setMessages([])
      } else {
        const data = await res.json()
        setMessages(data.messages ?? [])
        setUnread(data.unread ?? 0)
      }
    } finally { setLoading(false) }
  }

  useEffect(() => { if (canView) load('all') }, [canView])

  async function setStatus(id: string, status: Message['status']) {
    await adminFetch(`/content/messages/${id}`, {
      method: 'PATCH', body: JSON.stringify({ status }),
    })
    // Update locally, then refresh unread count
    setMessages(prev => prev.map(m => m.id === id ? { ...m, status } : m))
    load(filter)
  }

  function toggle(m: Message) {
    if (expanded === m.id) { setExpanded(null); return }
    setExpanded(m.id)
    if (m.status === 'new') setStatus(m.id, 'read') // auto-mark read on open
  }

  function fmtDate(ts: number) {
    return new Date(ts * 1000).toLocaleString(undefined, {
      dateStyle: 'medium', timeStyle: 'short',
    })
  }

  if (!canView) {
    return (
      <AdminShell>
        <div className="mx-auto max-w-md rounded-xl border border-app-border bg-app-surface p-6 text-center">
          <AlertCircle className="mx-auto mb-2 h-6 w-6 text-app-muted" />
          <p className="text-sm text-app-text">You don't have permission to view messages.</p>
        </div>
      </AdminShell>
    )
  }

  return (
    <AdminShell>
      <div className="mx-auto max-w-3xl space-y-4">
        <div className="flex items-end justify-between">
          <div>
            <h1 className="text-lg font-semibold text-app-text">Contact messages</h1>
            <p className="text-sm text-app-muted">
              Submissions from the public Contact page.
              {unread > 0 && <span className="ml-1 text-app-accent-text">{unread} unread</span>}
            </p>
          </div>
        </div>

        {/* Filter tabs */}
        <div className="flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 text-sm">
          {FILTERS.map(f => (
            <button key={f} onClick={() => { setFilter(f); load(f) }}
              className={`flex-1 rounded-md px-3 py-1.5 capitalize transition-colors ${
                filter === f ? 'bg-app-accent text-app-on-accent font-medium' : 'text-app-muted hover:text-app-text'
              }`}>
              {f}
            </button>
          ))}
        </div>

        {loading ? (
          <div className="flex justify-center py-16"><Loader2 className="h-6 w-6 animate-spin text-app-accent" /></div>
        ) : error ? (
          <div className="flex items-center gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="h-3.5 w-3.5 shrink-0" />{error}
          </div>
        ) : messages.length === 0 ? (
          <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center text-sm text-app-muted">
            <Mail className="mx-auto mb-2 h-6 w-6 opacity-50" />
            No messages{filter !== 'all' ? ` marked "${filter}"` : ' yet'}.
          </div>
        ) : (
          <div className="space-y-2">
            {messages.map(m => {
              const isOpen = expanded === m.id
              return (
                <Card key={m.id} className={m.status === 'new' ? 'border-app-accent/40' : ''}>
                  <CardContent className="p-0">
                    <button onClick={() => toggle(m)}
                      className="flex w-full items-center gap-3 px-4 py-3 text-left">
                      <span className="shrink-0">
                        {m.status === 'new'
                          ? <Mail className="h-4 w-4 text-app-accent-text" />
                          : m.status === 'archived'
                          ? <Archive className="h-4 w-4 text-app-muted" />
                          : <MailOpen className="h-4 w-4 text-app-muted" />}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="flex items-center gap-2">
                          <span className={`truncate text-sm ${m.status === 'new' ? 'font-semibold text-app-text' : 'text-app-text'}`}>
                            {m.name}
                          </span>
                          <span className="truncate text-xs text-app-muted">{m.email}</span>
                        </span>
                        <span className="block truncate text-xs text-app-muted">
                          {m.subject || m.message.slice(0, 60)}
                        </span>
                      </span>
                      <span className="shrink-0 text-[11px] text-app-muted">{fmtDate(m.created_at)}</span>
                      {isOpen ? <ChevronUp className="h-4 w-4 shrink-0 text-app-muted" /> : <ChevronDown className="h-4 w-4 shrink-0 text-app-muted" />}
                    </button>

                    {isOpen && (
                      <div className="border-t border-app-border px-4 py-3">
                        {m.subject && <p className="mb-1 text-sm font-medium text-app-text">{m.subject}</p>}
                        <p className="whitespace-pre-wrap text-sm text-app-muted">{m.message}</p>
                        <div className="mt-3 flex flex-wrap gap-2">
                          <a href={`mailto:${m.email}?subject=Re: ${encodeURIComponent(m.subject || 'Your message to AfriFX')}`}
                            className="inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover">
                            <Reply className="h-3.5 w-3.5" /> Reply by email
                          </a>
                          {m.status !== 'archived' ? (
                            <button onClick={() => setStatus(m.id, 'archived')}
                              className="inline-flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
                              <Archive className="h-3.5 w-3.5" /> Archive
                            </button>
                          ) : (
                            <button onClick={() => setStatus(m.id, 'read')}
                              className="inline-flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
                              <MailOpen className="h-3.5 w-3.5" /> Unarchive
                            </button>
                          )}
                        </div>
                      </div>
                    )}
                  </CardContent>
                </Card>
              )
            })}
          </div>
        )}
      </div>
    </AdminShell>
  )
}
