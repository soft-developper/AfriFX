#!/bin/bash
# ============================================================
# AfriFX -- In-dashboard reader for Contact-form messages
#
# Adds an admin screen to read the messages people submit through the
# public /contact page, so you're not dependent on email forwarding.
#
#   * NEW permission 'view_messages' -- super admin always has it; you can
#     grant it to a sub-admin from Admin -> Sub-admins.
#   * Backend: GET /content/messages (list + unread count) and
#     PATCH /content/messages/:id (mark read/archived), both gated by
#     view_messages (super admin bypasses, as with other permissions).
#   * Frontend: /admin/messages -- filter by all/new/read/archived, expand
#     to read, auto-marks 'read' on open, Reply-by-email + Archive actions.
#     Nav link 'Messages' appears for anyone with the permission.
#
# The messages are stored in the contact_messages table (created in Phase D).
# messages-schema.sql re-creates it IF NOT EXISTS, in case that wasn't run.
#
# Run from ~/AfriFX:  bash admin-messages-reader.sh
# ============================================================
set -e
echo ""
echo "Adding the in-dashboard messages reader..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/messages-schema.sql" << 'AFX_EOF'
-- Ensures the contact_messages table exists (safe if Phase D already made it).
-- Run once if you're unsure whether Phase D's schema was applied:
--   turso db shell <your-db-name> < afrifx-api/messages-schema.sql
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);
AFX_EOF
echo "  afrifx-api/messages-schema.sql"

mkdir -p "afrifx-api/src/lib"
cat > "afrifx-api/src/lib/permissions.ts" << 'AFX_EOF'
// All available admin permissions
export const PERMISSIONS = {
  VIEW_DASHBOARD:    'view_dashboard',
  MANAGE_OFFERS:     'manage_offers',     // force release / cancel offers
  RESOLVE_DISPUTES:  'resolve_disputes',  // settle disputes
  MANAGE_USERS:      'manage_users',      // edit user profiles, warnings
  SUSPEND_USERS:     'suspend_users',     // suspend user accounts
  VIEW_ANALYTICS:    'view_analytics',    // platform analytics
  MANAGE_TREASURY:   'manage_treasury',   // platform treasury / fees
  MANAGE_ADMINS:     'manage_admins',     // add/remove/edit sub-admins
  MANAGE_CONTENT:    'manage_content',    // edit About / Contact page content
  VIEW_MESSAGES:     'view_messages',      // read contact-form submissions
  VIEW_AUDIT_LOG:    'view_audit_log',    // see audit trail
} as const

export type Permission = typeof PERMISSIONS[keyof typeof PERMISSIONS]

export const ALL_PERMISSIONS = Object.values(PERMISSIONS)

// Human-readable labels + descriptions for the UI
export const PERMISSION_META: Record<string, { label: string; description: string }> = {
  view_dashboard:   { label: 'View Dashboard',    description: 'Access the admin overview and stats' },
  manage_offers:    { label: 'Manage Offers',     description: 'Force release or cancel P2P offers' },
  resolve_disputes: { label: 'Resolve Disputes',  description: 'Settle disputes — release or refund USDC' },
  manage_users:     { label: 'Manage Users',      description: 'Edit profiles, issue warnings' },
  suspend_users:    { label: 'Suspend Users',     description: 'Suspend or ban user accounts' },
  view_analytics:   { label: 'View Analytics',    description: 'See platform-wide analytics and charts' },
  manage_treasury:  { label: 'Manage Treasury',   description: 'View and manage platform fees' },
  manage_admins:    { label: 'Manage Admins',     description: 'Add, edit, suspend sub-admins' },
  manage_content:   { label: 'Manage Content',    description: 'Edit the About and Contact pages' },
  view_messages:    { label: 'View Messages',     description: 'Read contact-form submissions' },
  view_audit_log:   { label: 'View Audit Log',    description: 'Review all admin activity' },
}
AFX_EOF
echo "  afrifx-api/src/lib/permissions.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/content.ts" << 'AFX_EOF'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { requireAdmin, requirePermission, logAction } from '../lib/adminAuth'
import { PERMISSIONS } from '../lib/permissions'
import { sendEmail }  from '../services/email/client'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Fallback content if the row is missing (e.g. schema not seeded yet)
const DEFAULTS: Record<string, any> = {
  about: [
    { heading: 'About AfriFX', body: 'AfriFX is a decentralized foreign-exchange and cross-border payments platform built on the Arc blockchain.' },
  ],
  contact: {
    email: 'support@afrifx.xyz', phone: '', address: '',
    supportHours: '', twitter: '', telegram: '', discord: '',
  },
}

async function readContent(key: 'about' | 'contact') {
  const rows = parseRows(await db.run(sql`SELECT value FROM site_content WHERE key = ${key} LIMIT 1`))
  if (!rows.length) return DEFAULTS[key]
  const raw = Array.isArray(rows[0]) ? rows[0][0] : rows[0].value
  try { return JSON.parse(raw) } catch { return DEFAULTS[key] }
}

// ── Public reads ─────────────────────────────────────────────
// GET /content/about   → JSON array of { heading, body }
// GET /content/contact → JSON object of contact fields
router.get('/about', async (_req, res) => {
  try { res.json({ sections: await readContent('about') }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.get('/contact', async (_req, res) => {
  try { res.json({ contact: await readContent('contact') }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Admin writes (super admin, or sub-admin with manage_content) ──
// PATCH /content/about   body: { sections: [{ heading, body }] }
router.patch('/about', requireAdmin, requirePermission(PERMISSIONS.MANAGE_CONTENT), async (req, res) => {
  const admin = (req as any).admin
  const { sections } = req.body
  if (!Array.isArray(sections)) {
    return res.status(400).json({ error: 'sections must be an array' })
  }
  // Sanitize: keep only heading/body strings, drop empties
  const clean = sections
    .map((s: any) => ({
      heading: String(s?.heading ?? '').slice(0, 200),
      body:    String(s?.body ?? '').slice(0, 5000),
    }))
    .filter((s: any) => s.heading || s.body)

  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      INSERT INTO site_content (key, value, updated_by, updated_at)
      VALUES ('about', ${JSON.stringify(clean)}, ${admin.id}, ${now})
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at
    `)
    await logAction(admin.id, admin.username, 'update_content', 'content', 'about',
      `${clean.length} section(s)`, req.ip)
    res.json({ success: true, sections: clean })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /content/contact  body: { contact: {...fields} }
router.patch('/contact', requireAdmin, requirePermission(PERMISSIONS.MANAGE_CONTENT), async (req, res) => {
  const admin = (req as any).admin
  const c = req.body?.contact
  if (!c || typeof c !== 'object') {
    return res.status(400).json({ error: 'contact object required' })
  }
  const fields = ['email', 'phone', 'address', 'supportHours', 'twitter', 'telegram', 'discord']
  const clean: Record<string, string> = {}
  for (const f of fields) clean[f] = String(c[f] ?? '').slice(0, 500)

  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      INSERT INTO site_content (key, value, updated_by, updated_at)
      VALUES ('contact', ${JSON.stringify(clean)}, ${admin.id}, ${now})
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at
    `)
    await logAction(admin.id, admin.username, 'update_content', 'content', 'contact', undefined, req.ip)
    res.json({ success: true, contact: clean })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Public contact form submission ───────────────────────────
// POST /content/contact/message  body: { name, email, subject?, message }
// Saves the message and emails the platform inbox via Resend.
router.post('/contact/message', async (req, res) => {
  const { name, email, subject, message } = req.body
  if (!name || !email || !message) {
    return res.status(400).json({ error: 'name, email and message are required' })
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Please enter a valid email address' })
  }

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  const cleanSubject = String(subject ?? '').slice(0, 200)
  const cleanMessage = String(message).slice(0, 5000)

  try {
    await db.run(sql`
      INSERT INTO contact_messages (id, name, email, subject, message, status, created_at)
      VALUES (${id}, ${String(name).slice(0,120)}, ${email}, ${cleanSubject},
              ${cleanMessage}, 'new', ${now})
    `)

    // Notify the platform inbox. The recipient is the support address the
    // admin set on the Contact page (falls back to a sensible default).
    const contact = await readContent('contact')
    const inbox   = (contact && contact.email) ? contact.email : 'support@afrifx.xyz'

    await sendEmail({
      to:      inbox,
      subject: `New contact message${cleanSubject ? `: ${cleanSubject}` : ''}`,
      html: `
        <div style="font-family:sans-serif;line-height:1.5">
          <h2 style="margin:0 0 12px">New message from the AfriFX contact form</h2>
          <p><strong>Name:</strong> ${escapeHtml(String(name))}</p>
          <p><strong>Email:</strong> ${escapeHtml(email)}</p>
          ${cleanSubject ? `<p><strong>Subject:</strong> ${escapeHtml(cleanSubject)}</p>` : ''}
          <p><strong>Message:</strong></p>
          <p style="white-space:pre-wrap;padding:12px;background:#f4f4f5;border-radius:8px">${escapeHtml(cleanMessage)}</p>
        </div>
      `,
    }).catch(() => {}) // don't fail the request if email is down; message is already saved

    res.status(201).json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, ch => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] as string
  ))
}

// ── Admin: read contact-form submissions ─────────────────────
// GET /content/messages?status=new|read|archived  (super admin, or
// sub-admin with view_messages)
router.get('/messages', requireAdmin, requirePermission(PERMISSIONS.VIEW_MESSAGES), async (req, res) => {
  const filter = String(req.query.status ?? 'all')
  try {
    const rows = parseRows(await db.run(
      filter === 'all'
        ? sql`SELECT * FROM contact_messages ORDER BY created_at DESC LIMIT 500`
        : sql`SELECT * FROM contact_messages WHERE status = ${filter} ORDER BY created_at DESC LIMIT 500`
    ))
    const messages = rows.map((r: any) => Array.isArray(r) ? {
      id: r[0], name: r[1], email: r[2], subject: r[3],
      message: r[4], status: r[5], created_at: r[6],
    } : r)
    // Unread count for the badge
    const countRows = parseRows(await db.run(
      sql`SELECT COUNT(*) AS c FROM contact_messages WHERE status = 'new'`
    ))
    const unread = Number(Array.isArray(countRows[0]) ? countRows[0][0] : countRows[0]?.c ?? 0)
    res.json({ messages, unread })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /content/messages/:id  body: { status: 'new'|'read'|'archived' }
router.patch('/messages/:id', requireAdmin, requirePermission(PERMISSIONS.VIEW_MESSAGES), async (req, res) => {
  const { status } = req.body
  if (!['new', 'read', 'archived'].includes(status)) {
    return res.status(400).json({ error: 'Invalid status' })
  }
  try {
    await db.run(sql`UPDATE contact_messages SET status = ${status} WHERE id = ${req.params.id}`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/content.ts"

mkdir -p "afrifx-web/app/admin/messages"
cat > "afrifx-web/app/admin/messages/page.tsx" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-web/app/admin/messages/page.tsx"

mkdir -p "afrifx-web/components/admin"
cat > "afrifx-web/components/admin/AdminShell.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { useTheme } from '@/hooks/useTheme'
import { ThemeToggle } from '@/components/layout/ThemeToggle'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2, Settings,
  Menu, X, Sun, Moon, FileText, Mail,
} from 'lucide-react'

// Full-width labeled theme toggle for the admin sidebar footer
function ThemeToggleRow() {
  const { theme, source, toggle } = useTheme()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  if (!mounted) {
    return <div className="h-9 rounded-lg border border-app-border" />
  }
  const isDark = theme === 'dark'
  return (
    <button onClick={toggle}
      className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
      {isDark ? <Moon className="h-3.5 w-3.5 shrink-0" /> : <Sun className="h-3.5 w-3.5 shrink-0" />}
      {isDark ? 'Dark mode' : 'Light mode'}
      {source === 'auto' && <span className="ml-auto text-[9px] text-app-accent-text">AUTO</span>}
    </button>
  )
}

const NAV = [
  { href: '/admin/dashboard',  icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'   },
  { href: '/admin/offers',     icon: Store,           label: 'Offers',     perm: 'manage_offers'    },
  { href: '/admin/disputes',   icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes' },
  { href: '/admin/users',      icon: Users,           label: 'Users',      perm: 'manage_users'     },
  { href: '/admin/sub-admins', icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'    },
  { href: '/admin/content',    icon: FileText,        label: 'Site content', perm: 'manage_content' },
  { href: '/admin/messages',   icon: Mail,            label: 'Messages',   perm: 'view_messages'    },
  { href: '/admin/analytics',  icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'   },
  { href: '/admin/audit',      icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'   },
]

function SidebarContent({
  admin, pathname, visibleNav, onLogout, onNavigate,
}: {
  admin:      { username: string; role: string }
  pathname:   string
  visibleNav: typeof NAV
  onLogout:   () => void
  onNavigate?: () => void
}) {
  return (
    <>
      <nav className="flex-1 overflow-y-auto py-3">
        {visibleNav.map(({ href, icon: Icon, label }) => {
          const active = pathname === href
          return (
            <Link key={href} href={href} onClick={onNavigate}
              className={`flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors
                ${active
                  ? 'bg-app-border font-medium text-app-text'
                  : 'text-app-muted hover:bg-app-bg hover:text-app-text'}`}>
              <Icon className="h-4 w-4 shrink-0" /> {label}
            </Link>
          )
        })}
      </nav>
      <div className="shrink-0 border-t border-app-border p-3 space-y-2">
        <div className="rounded-lg bg-app-bg px-3 py-2">
          <p className="text-xs font-medium text-app-text">{admin.username}</p>
          <p className="text-[10px] text-app-accent-text">
            {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
          </p>
        </div>
        <Link href="/admin/settings" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <Settings className="h-3.5 w-3.5 shrink-0" />
          Settings
        </Link>
        <Link href="/dashboard" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
          Main dashboard
        </Link>
        <button onClick={onLogout}
          className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-red-400 transition-colors">
          <LogOut className="h-3.5 w-3.5 shrink-0" />
          Logout
        </button>
        <ThemeToggleRow />
      </div>
    </>
  )
}

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router   = useRouter()
  const pathname = usePathname()
  const { admin, loading, logout, hasPermission } = useAdminAuth()
  const [drawerOpen, setDrawerOpen] = useState(false)

  useEffect(() => {
    if (!loading && !admin) router.push('/admin')
  }, [loading, admin, router])

  // Close the mobile drawer on route change
  useEffect(() => { setDrawerOpen(false) }, [pathname])

  // Lock body scroll while the mobile drawer is open
  useEffect(() => {
    document.body.style.overflow = drawerOpen ? 'hidden' : ''
    return () => { document.body.style.overflow = '' }
  }, [drawerOpen])

  if (loading) return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!admin) return null

  // Sub-admin landing on dashboard without permission
  // → redirect to their first permitted page
  if (
    typeof window !== 'undefined' &&
    admin.role !== 'super_admin' &&
    !admin.permissions.includes('view_dashboard') &&
    window.location.pathname === '/admin/dashboard'
  ) {
    const PAGES = [
      { perm: 'manage_offers',    path: '/admin/offers'     },
      { perm: 'resolve_disputes', path: '/admin/disputes'   },
      { perm: 'manage_users',     path: '/admin/users'      },
      { perm: 'view_analytics',   path: '/admin/analytics'  },
      { perm: 'manage_admins',    path: '/admin/sub-admins' },
      { perm: 'view_audit_log',   path: '/admin/audit'      },
    ]
    const first = PAGES.find(p => admin.permissions.includes(p.perm))
    if (first) { window.location.replace(first.path); return null }
  }

  const visibleNav = NAV.filter(item => hasPermission(item.perm))

  async function handleLogout() {
    setDrawerOpen(false)
    await logout()
    router.push('/admin')
  }

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg md:flex-row">
      {/* Mobile top bar — hidden md+ */}
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border bg-app-surface px-4 md:hidden">
        <div className="flex items-center gap-2">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <button onClick={() => setDrawerOpen(true)}
            className="rounded-lg p-1.5 text-app-muted hover:bg-app-bg hover:text-app-text"
            aria-label="Open admin menu">
            <Menu className="h-5 w-5" />
          </button>
        </div>
      </header>

      {/* Mobile drawer — hidden md+ */}
      {drawerOpen && (
        <div className="md:hidden">
          <div
            className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
            onClick={() => setDrawerOpen(false)}
          />
          <div className="fixed inset-y-0 left-0 z-50 flex w-72 flex-col bg-app-surface shadow-2xl">
            <div className="flex shrink-0 items-center justify-between border-b border-app-border px-4 py-4">
              <div className="flex items-center gap-2">
                <Shield className="h-5 w-5 text-app-accent-text" />
                <span className="font-semibold text-app-text">AfriFX Admin</span>
              </div>
              <button onClick={() => setDrawerOpen(false)}
                className="rounded-lg p-1.5 text-app-muted hover:text-app-text"
                aria-label="Close admin menu">
                <X className="h-5 w-5" />
              </button>
            </div>
            <SidebarContent
              admin={admin} pathname={pathname} visibleNav={visibleNav}
              onLogout={handleLogout} onNavigate={() => setDrawerOpen(false)}
            />
          </div>
        </div>
      )}

      {/* Desktop sidebar — hidden on mobile */}
      <aside className="hidden md:flex md:w-56 md:shrink-0 flex-col border-r border-app-border bg-app-surface">
        <div className="flex items-center gap-2 border-b border-app-border px-4 py-4">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <SidebarContent
          admin={admin} pathname={pathname} visibleNav={visibleNav}
          onLogout={handleLogout}
        />
      </aside>

      <main className="flex-1 overflow-y-auto p-4 md:p-6">{children}</main>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/admin/AdminShell.tsx"

echo ""
echo "Done. Now:"
echo "  # (only if unsure the contact_messages table exists):"
echo "  turso db shell <your-db-name> < afrifx-api/messages-schema.sql"
echo ""
echo "  cd afrifx-api && npx tsc --noEmit    # verify backend"
echo "  cd ../afrifx-web && npm run build    # verify web"
echo "  git add -A && git commit -m 'Admin: in-dashboard contact-message reader (view_messages permission)'"
echo "  git push"
echo ""
echo "  Redeploy both. Then: submit a test message on /contact, and read it"
echo "  under Admin -> Messages. To let a sub-admin see it, grant them the"
echo "  'View Messages' permission from Admin -> Sub-admins."
