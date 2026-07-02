#!/bin/bash
# ============================================================
# AfriFX -- Phase D: About & Contact pages (public) + admin editor
#
#   * NEW public pages  /about  and  /contact  (viewable logged-out),
#     themed with the app tokens (work in dark AND light mode)
#   * Contact page has editable details + a message form that saves the
#     message and emails your support inbox via Resend
#   * NEW admin editor at /admin/content -- flexible About sections
#     (add / remove / reorder heading+body) and Contact detail fields
#   * NEW 'manage_content' permission (super admin always allowed; can be
#     granted to a sub-admin later from the Sub-admins page)
#   * Backend: routes/content.ts (public GET, admin PATCH, contact POST),
#     mounted at /content; About/Contact links added to the app sidebar
#
# IMPORTANT -- run the DB schema ONCE before or after deploying the API:
#   turso db shell <your-db-name> < afrifx-api/phaseD-schema.sql
# It creates site_content + contact_messages and seeds default About/Contact
# text so the pages are never blank. Safe to re-run (IF NOT EXISTS / IGNORE).
#
# Run from ~/AfriFX:  bash phaseD-about-contact.sh
# ============================================================
set -e
echo ""
echo "Applying Phase D -- About & Contact..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/phaseD-schema.sql" << 'AFX_EOF'
-- ============================================================
-- AfriFX Phase D — site content tables
-- Run ONCE against your Turso DB:
--   turso db shell <your-db-name> < phaseD-schema.sql
-- (or paste the statements into: turso db shell <your-db-name>)
-- ============================================================

-- Single-row-per-key store for editable page content.
-- key = 'about'   -> value holds a JSON array of { heading, body } sections
-- key = 'contact' -> value holds a JSON object of contact fields
CREATE TABLE IF NOT EXISTS site_content (
  key         TEXT PRIMARY KEY,          -- 'about' | 'contact'
  value       TEXT NOT NULL,             -- JSON payload
  updated_by  TEXT,                      -- admin id who last edited
  updated_at  INTEGER NOT NULL           -- unix seconds
);

-- Messages submitted through the public Contact form.
-- Stored as a record AND emailed to the platform inbox via Resend.
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);

-- Seed sensible defaults so the public pages are never blank before
-- the admin edits them. INSERT OR IGNORE keeps existing rows untouched.
INSERT OR IGNORE INTO site_content (key, value, updated_at) VALUES
  ('about',
   '[{"heading":"About AfriFX","body":"AfriFX is a decentralized foreign-exchange and cross-border payments platform built on the Arc blockchain, making it fast and affordable to move value across Africa using stablecoins."},{"heading":"Our mission","body":"To give everyone access to instant, low-cost currency exchange and cross-border payments — without the delays and fees of traditional banking."},{"heading":"How it works","body":"Convert between USDC and local currencies directly, or trade peer-to-peer on our marketplace. Every transaction settles on Arc in under a second, with fees paid in USDC."}]',
   strftime('%s','now')),
  ('contact',
   '{"email":"support@afrifx.xyz","phone":"","address":"","supportHours":"Monday to Friday, 9am – 5pm WAT","twitter":"https://x.com/afrifx","telegram":"","discord":""}',
   strftime('%s','now'));
AFX_EOF
echo "  afrifx-api/phaseD-schema.sql"

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

export default router
AFX_EOF
echo "  afrifx-api/src/routes/content.ts"

mkdir -p "afrifx-api/src"
cat > "afrifx-api/src/index.ts" << 'AFX_EOF'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import walletRouter               from './routes/wallet'
import treasuryRouter             from './routes/treasury'
import payrollRouter              from './routes/payroll'
import notificationsRouter         from './routes/notifications'
import disputesRouter              from './routes/disputes'
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import { cleanExpiredSessions } from './services/auth/adminAuth'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import contentRouter              from './routes/content'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startAdminAuditSummary } from './jobs/adminAuditSummary'
import { startInvoiceReminders }  from './jobs/invoiceReminders'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)

app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',          ratesRouter)
app.use('/transactions',   transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         walletRouter)
app.use('/treasury',       treasuryRouter)
app.use('/payroll',        payrollRouter)
app.use('/notifications', notificationsRouter)
app.use('/disputes',       disputesRouter)
app.use('/invoices',       invoicesRouter)
app.use('/payments',       paymentsRouter)
app.use('/content',        contentRouter)
app.use('/admin-auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
startInvoiceReminders()
startAdminAuditSummary()

  // Clean expired admin sessions every hour
  setInterval(() => cleanExpiredSessions().catch(() => {}), 3600_000)
  startTreasuryChecker()
  startTxSettler()
})
AFX_EOF
echo "  afrifx-api/src/index.ts"

mkdir -p "afrifx-web/components/public"
cat > "afrifx-web/components/public/PublicChrome.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { ArrowLeftRight } from 'lucide-react'

export function PublicHeader({ active }: { active?: 'about' | 'contact' }) {
  return (
    <header className="border-b border-app-border bg-app-surface">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <Link href="/" className="flex items-center gap-2">
          <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-app-accent/20">
            <ArrowLeftRight className="h-4 w-4 text-app-accent-text" />
          </span>
          <span className="text-lg font-semibold text-app-text">AfriFX</span>
        </Link>
        <nav className="flex items-center gap-4 text-sm sm:gap-5">
          <Link href="/about"
            className={active === 'about' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            About
          </Link>
          <Link href="/contact"
            className={active === 'contact' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            Contact
          </Link>
          <Link href="/convert"
            className="rounded-lg bg-app-accent px-3 py-1.5 font-medium text-app-on-accent hover:bg-app-accent-hover">
            Launch app
          </Link>
        </nav>
      </div>
    </header>
  )
}

export function PublicFooter() {
  return (
    <footer className="border-t border-app-border">
      <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-3 px-4 py-6 text-xs text-app-muted sm:flex-row">
        <span>© {new Date().getFullYear()} AfriFX. Stablecoin FX on Arc.</span>
        <div className="flex gap-4">
          <Link href="/about" className="hover:text-app-text">About</Link>
          <Link href="/contact" className="hover:text-app-text">Contact</Link>
        </div>
      </div>
    </footer>
  )
}
AFX_EOF
echo "  afrifx-web/components/public/PublicChrome.tsx"

mkdir -p "afrifx-web/components/public"
cat > "afrifx-web/components/public/ContactForm.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { Send, Loader2, CheckCircle, AlertCircle } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ContactForm() {
  const [name,    setName]    = useState('')
  const [email,   setEmail]   = useState('')
  const [subject, setSubject] = useState('')
  const [message, setMessage] = useState('')
  const [busy,    setBusy]    = useState(false)
  const [sent,    setSent]    = useState(false)
  const [error,   setError]   = useState<string | null>(null)

  async function submit() {
    setError(null)
    if (!name || !email || !message) { setError('Name, email and message are required.'); return }
    setBusy(true)
    try {
      const res = await fetch(`${API}/content/contact/message`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, email, subject, message }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setSent(true)
        setName(''); setEmail(''); setSubject(''); setMessage('')
      } else {
        setError(data.error ?? 'Could not send your message. Please try again.')
      }
    } catch {
      setError('Could not send your message. Please check your connection.')
    } finally { setBusy(false) }
  }

  if (sent) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-2xl border border-app-border bg-app-surface p-8 text-center">
        <CheckCircle className="h-8 w-8 text-emerald-400" />
        <p className="font-medium text-app-text">Thanks for reaching out</p>
        <p className="text-sm text-app-muted">We've received your message and will get back to you soon.</p>
        <button onClick={() => setSent(false)}
          className="mt-2 text-sm font-medium text-app-accent-text hover:underline">
          Send another message
        </button>
      </div>
    )
  }

  const inputCls = 'w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent'

  return (
    <div className="rounded-2xl border border-app-border bg-app-surface p-6">
      <h2 className="mb-4 text-lg font-semibold text-app-text">Send us a message</h2>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <input className={inputCls} placeholder="Your name"
            value={name} onChange={e => setName(e.target.value)} />
          <input className={inputCls} type="email" placeholder="Your email"
            value={email} onChange={e => setEmail(e.target.value)} />
        </div>
        <input className={inputCls} placeholder="Subject (optional)"
          value={subject} onChange={e => setSubject(e.target.value)} />
        <textarea className={`${inputCls} min-h-[140px] resize-y`} placeholder="How can we help?"
          value={message} onChange={e => setMessage(e.target.value)} />

        <button onClick={submit} disabled={busy}
          className="inline-flex items-center gap-2 rounded-lg bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-colors hover:bg-app-accent-hover disabled:opacity-50">
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : <><Send className="h-4 w-4" /> Send message</>}
        </button>

        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/public/ContactForm.tsx"

mkdir -p "afrifx-web/app/about"
cat > "afrifx-web/app/about/page.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { PublicHeader, PublicFooter } from '@/components/public/PublicChrome'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Section { heading: string; body: string }

async function getSections(): Promise<Section[]> {
  try {
    const res = await fetch(`${API}/content/about`, { next: { revalidate: 60 } })
    if (!res.ok) return []
    const data = await res.json()
    return Array.isArray(data.sections) ? data.sections : []
  } catch { return [] }
}

export const metadata = {
  title: 'About — AfriFX',
  description: 'Learn about AfriFX, decentralized stablecoin FX and cross-border payments on Arc.',
}

export default async function AboutPage() {
  const sections = await getSections()

  return (
    <div className="flex min-h-screen flex-col bg-app-bg text-app-text">
      <PublicHeader active="about" />
      <main className="mx-auto w-full max-w-3xl flex-1 px-4 py-12 sm:py-16">
        <h1 className="mb-8 text-3xl font-bold sm:text-4xl">About</h1>
        {sections.length === 0 ? (
          <p className="text-app-muted">Content is being updated. Please check back soon.</p>
        ) : (
          <div className="space-y-10">
            {sections.map((s, i) => (
              <section key={i}>
                {s.heading && <h2 className="mb-3 text-xl font-semibold sm:text-2xl">{s.heading}</h2>}
                {s.body && (
                  <p className="whitespace-pre-wrap leading-relaxed text-app-muted">{s.body}</p>
                )}
              </section>
            ))}
          </div>
        )}
        <div className="mt-12 border-t border-app-border pt-6">
          <Link href="/contact" className="text-sm font-medium text-app-accent-text hover:underline">
            Have a question? Contact us →
          </Link>
        </div>
      </main>
      <PublicFooter />
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/about/page.tsx"

mkdir -p "afrifx-web/app/contact"
cat > "afrifx-web/app/contact/page.tsx" << 'AFX_EOF'
import { Mail, Phone, MapPin, Clock, Twitter, Send as TelegramIcon, MessageCircle } from 'lucide-react'
import { PublicHeader, PublicFooter } from '@/components/public/PublicChrome'
import { ContactForm } from '@/components/public/ContactForm'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Contact {
  email?: string; phone?: string; address?: string; supportHours?: string
  twitter?: string; telegram?: string; discord?: string
}

async function getContact(): Promise<Contact> {
  try {
    const res = await fetch(`${API}/content/contact`, { next: { revalidate: 60 } })
    if (!res.ok) return {}
    const data = await res.json()
    return data.contact ?? {}
  } catch { return {} }
}

export const metadata = {
  title: 'Contact — AfriFX',
  description: 'Get in touch with the AfriFX team.',
}

export default async function ContactPage() {
  const c = await getContact()

  const details = [
    c.email        && { icon: Mail,   label: 'Email',         value: c.email,        href: `mailto:${c.email}` },
    c.phone        && { icon: Phone,  label: 'Phone',         value: c.phone,        href: `tel:${c.phone}` },
    c.address      && { icon: MapPin, label: 'Address',       value: c.address,      href: undefined },
    c.supportHours && { icon: Clock,  label: 'Support hours', value: c.supportHours, href: undefined },
  ].filter(Boolean) as { icon: any; label: string; value: string; href?: string }[]

  const socials = [
    c.twitter  && { icon: Twitter,       label: 'Twitter / X', href: c.twitter },
    c.telegram && { icon: TelegramIcon,  label: 'Telegram',    href: c.telegram },
    c.discord  && { icon: MessageCircle, label: 'Discord',     href: c.discord },
  ].filter(Boolean) as { icon: any; label: string; href: string }[]

  return (
    <div className="flex min-h-screen flex-col bg-app-bg text-app-text">
      <PublicHeader active="contact" />
      <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-12 sm:py-16">
        <h1 className="mb-3 text-3xl font-bold sm:text-4xl">Contact us</h1>
        <p className="mb-10 max-w-2xl text-app-muted">
          Questions, feedback, or partnership enquiries — we'd love to hear from you.
        </p>

        <div className="grid gap-8 lg:grid-cols-2">
          {/* Details */}
          <div className="space-y-6">
            {details.length > 0 && (
              <div className="space-y-4">
                {details.map(({ icon: Icon, label, value, href }) => (
                  <div key={label} className="flex items-start gap-3">
                    <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-app-accent/10">
                      <Icon className="h-4 w-4 text-app-accent-text" />
                    </span>
                    <div>
                      <p className="text-xs text-app-muted">{label}</p>
                      {href
                        ? <a href={href} className="text-sm font-medium text-app-text hover:text-app-accent-text">{value}</a>
                        : <p className="whitespace-pre-wrap text-sm font-medium text-app-text">{value}</p>}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {socials.length > 0 && (
              <div>
                <p className="mb-3 text-xs uppercase tracking-wide text-app-muted">Follow us</p>
                <div className="flex flex-wrap gap-3">
                  {socials.map(({ icon: Icon, label, href }) => (
                    <a key={label} href={href} target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-2 rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text hover:border-app-accent hover:text-app-accent-text">
                      <Icon className="h-4 w-4" /> {label}
                    </a>
                  ))}
                </div>
              </div>
            )}

            {details.length === 0 && socials.length === 0 && (
              <p className="text-app-muted">Contact details are being updated. You can still send us a message.</p>
            )}
          </div>

          {/* Message form */}
          <ContactForm />
        </div>
      </main>
      <PublicFooter />
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/contact/page.tsx"

mkdir -p "afrifx-web/app/admin/content"
cat > "afrifx-web/app/admin/content/page.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import {
  Loader2, Plus, Trash2, ArrowUp, ArrowDown,
  CheckCircle, AlertCircle, FileText, Mail,
} from 'lucide-react'

interface Section { heading: string; body: string }
interface Contact {
  email: string; phone: string; address: string; supportHours: string
  twitter: string; telegram: string; discord: string
}

const EMPTY_CONTACT: Contact = {
  email: '', phone: '', address: '', supportHours: '',
  twitter: '', telegram: '', discord: '',
}

export default function AdminContentPage() {
  const { hasPermission } = useAdminAuth()
  const canEdit = hasPermission('manage_content')

  const [sections, setSections] = useState<Section[]>([])
  const [contact,  setContact]  = useState<Contact>(EMPTY_CONTACT)
  const [loading,  setLoading]  = useState(true)

  const [savingAbout,   setSavingAbout]   = useState(false)
  const [savingContact, setSavingContact] = useState(false)
  const [aboutMsg,   setAboutMsg]   = useState<{ ok: boolean; text: string } | null>(null)
  const [contactMsg, setContactMsg] = useState<{ ok: boolean; text: string } | null>(null)

  useEffect(() => {
    Promise.all([
      adminFetch('/content/about').then(r => r.json()).catch(() => ({ sections: [] })),
      adminFetch('/content/contact').then(r => r.json()).catch(() => ({ contact: EMPTY_CONTACT })),
    ]).then(([a, c]) => {
      setSections(Array.isArray(a.sections) ? a.sections : [])
      setContact({ ...EMPTY_CONTACT, ...(c.contact ?? {}) })
    }).finally(() => setLoading(false))
  }, [])

  // ── About section editing ────────────────────────────────
  function updateSection(i: number, field: keyof Section, val: string) {
    setSections(prev => prev.map((s, idx) => idx === i ? { ...s, [field]: val } : s))
  }
  function addSection() {
    setSections(prev => [...prev, { heading: '', body: '' }])
  }
  function removeSection(i: number) {
    setSections(prev => prev.filter((_, idx) => idx !== i))
  }
  function moveSection(i: number, dir: -1 | 1) {
    setSections(prev => {
      const next = [...prev]
      const j = i + dir
      if (j < 0 || j >= next.length) return prev
      ;[next[i], next[j]] = [next[j], next[i]]
      return next
    })
  }

  async function saveAbout() {
    setAboutMsg(null); setSavingAbout(true)
    try {
      const res = await adminFetch('/content/about', {
        method: 'PATCH', body: JSON.stringify({ sections }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setSections(data.sections ?? sections)
        setAboutMsg({ ok: true, text: 'About page saved' })
      } else {
        setAboutMsg({ ok: false, text: data.error ?? 'Could not save' })
      }
    } finally { setSavingAbout(false) }
  }

  async function saveContact() {
    setContactMsg(null); setSavingContact(true)
    try {
      const res = await adminFetch('/content/contact', {
        method: 'PATCH', body: JSON.stringify({ contact }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setContact({ ...EMPTY_CONTACT, ...(data.contact ?? contact) })
        setContactMsg({ ok: true, text: 'Contact details saved' })
      } else {
        setContactMsg({ ok: false, text: data.error ?? 'Could not save' })
      }
    } finally { setSavingContact(false) }
  }

  if (loading) {
    return (
      <AdminShell>
        <div className="flex justify-center py-16"><Loader2 className="h-6 w-6 animate-spin text-app-accent" /></div>
      </AdminShell>
    )
  }

  if (!canEdit) {
    return (
      <AdminShell>
        <div className="mx-auto max-w-md rounded-xl border border-app-border bg-app-surface p-6 text-center">
          <AlertCircle className="mx-auto mb-2 h-6 w-6 text-app-muted" />
          <p className="text-sm text-app-text">You don't have permission to edit site content.</p>
        </div>
      </AdminShell>
    )
  }

  const contactFields: { key: keyof Contact; label: string; placeholder: string }[] = [
    { key: 'email',        label: 'Support email', placeholder: 'support@afrifx.xyz' },
    { key: 'phone',        label: 'Phone',         placeholder: '+234 …' },
    { key: 'address',      label: 'Address',       placeholder: 'Office address' },
    { key: 'supportHours', label: 'Support hours', placeholder: 'Mon–Fri, 9am–5pm WAT' },
    { key: 'twitter',      label: 'Twitter / X',   placeholder: 'https://x.com/afrifx' },
    { key: 'telegram',     label: 'Telegram',      placeholder: 'https://t.me/…' },
    { key: 'discord',      label: 'Discord',       placeholder: 'https://discord.gg/…' },
  ]

  return (
    <AdminShell>
      <div className="mx-auto max-w-3xl space-y-6">
        <div>
          <h1 className="text-lg font-semibold text-app-text">Site content</h1>
          <p className="text-sm text-app-muted">Edit the public About and Contact pages.</p>
        </div>

        {/* About editor */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <FileText className="h-4 w-4 text-app-accent-text" /> About page
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            {sections.length === 0 && (
              <p className="text-sm text-app-muted">No sections yet — add one below.</p>
            )}
            {sections.map((s, i) => (
              <div key={i} className="rounded-lg border border-app-border bg-app-bg p-3">
                <div className="mb-2 flex items-center justify-between">
                  <span className="text-xs text-app-muted">Section {i + 1}</span>
                  <div className="flex items-center gap-1">
                    <button onClick={() => moveSection(i, -1)} disabled={i === 0}
                      className="rounded p-1 text-app-muted hover:text-app-text disabled:opacity-30" title="Move up">
                      <ArrowUp className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => moveSection(i, 1)} disabled={i === sections.length - 1}
                      className="rounded p-1 text-app-muted hover:text-app-text disabled:opacity-30" title="Move down">
                      <ArrowDown className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => removeSection(i)}
                      className="rounded p-1 text-app-muted hover:text-red-400" title="Remove">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
                <Input className="mb-2" placeholder="Heading"
                  value={s.heading} onChange={e => updateSection(i, 'heading', e.target.value)} />
                <textarea
                  className="min-h-[90px] w-full resize-y rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent"
                  placeholder="Body text"
                  value={s.body} onChange={e => updateSection(i, 'body', e.target.value)} />
              </div>
            ))}

            <div className="flex flex-wrap items-center gap-2">
              <Button variant="outline" size="sm" onClick={addSection}>
                <Plus className="h-4 w-4" /> Add section
              </Button>
              <Button size="sm" onClick={saveAbout} disabled={savingAbout}>
                {savingAbout ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save About page'}
              </Button>
            </div>
            {aboutMsg && (
              <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs ${aboutMsg.ok ? 'bg-emerald-900/20 text-emerald-400' : 'bg-red-900/20 text-red-400'}`}>
                {aboutMsg.ok ? <CheckCircle className="h-3.5 w-3.5" /> : <AlertCircle className="h-3.5 w-3.5" />}
                {aboutMsg.text}
              </div>
            )}
          </CardContent>
        </Card>

        {/* Contact editor */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Mail className="h-4 w-4 text-app-accent-text" /> Contact page
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {contactFields.map(({ key, label, placeholder }) => (
              <div key={key}>
                <label className="mb-1 block text-xs text-app-muted">{label}</label>
                <Input placeholder={placeholder}
                  value={contact[key]} onChange={e => setContact({ ...contact, [key]: e.target.value })} />
              </div>
            ))}
            <div className="pt-1">
              <Button size="sm" onClick={saveContact} disabled={savingContact}>
                {savingContact ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save Contact details'}
              </Button>
            </div>
            {contactMsg && (
              <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs ${contactMsg.ok ? 'bg-emerald-900/20 text-emerald-400' : 'bg-red-900/20 text-red-400'}`}>
                {contactMsg.ok ? <CheckCircle className="h-3.5 w-3.5" /> : <AlertCircle className="h-3.5 w-3.5" />}
                {contactMsg.text}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </AdminShell>
  )
}
AFX_EOF
echo "  afrifx-web/app/admin/content/page.tsx"

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
  Menu, X, Sun, Moon, FileText,
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

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/Sidebar.tsx" << 'AFX_EOF'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield, FileText, BarChart3,
  CreditCard,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsAdmin } from '@/hooks/useIsAdmin'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',  icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor', icon: Globe,          label: 'Corridor' },
    { href: '/send',     icon: Send,           label: 'Send'     },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Payments', items: [
    { href: '/invoices',    icon: FileText,  label: 'Invoices'    },
    { href: '/settlements', icon: BarChart3, label: 'Settlements' },
  ]},
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2,  label: 'Treasury' },
    { href: '/treasury/payroll', icon: CreditCard, label: 'Payroll'  },
  ]},
  { label: 'Account', items: [
    { href: '/wallet',    icon: Wallet,          label: 'Wallet'    },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname          = usePathname()
  const { data: isAdmin } = useIsAdmin()

  return (
    // Hidden on mobile (md:flex), visible on desktop
    <aside className="hidden md:flex md:w-52 md:shrink-0 flex-col overflow-y-auto border-r border-app-border py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-app-border font-medium text-app-text'
                    : 'text-app-muted hover:bg-app-surface hover:text-app-text'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}

      {isAdmin && (
        <div className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
            Admin
          </p>
          <Link href="/admin"
            className={cn(
              'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
              pathname.startsWith('/admin')
                ? 'bg-amber-900/30 font-medium text-amber-400'
                : 'text-amber-500/70 hover:bg-amber-900/20 hover:text-amber-400'
            )}>
            <Shield className="h-4 w-4 shrink-0" />
            Admin panel
          </Link>
        </div>
      )}

      <div className="mt-auto border-t border-app-border px-4 py-3">
        <div className="flex gap-4 text-xs text-app-muted">
          <Link href="/about" className="hover:text-app-text">About</Link>
          <Link href="/contact" className="hover:text-app-text">Contact</Link>
        </div>
      </div>
    </aside>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/Sidebar.tsx"

echo ""
echo "======================================================"
echo "Phase D files written."
echo ""
echo "  DB STEP (once):"
echo "    turso db shell <your-db-name> < afrifx-api/phaseD-schema.sql"
echo ""
echo "  THEN:"
echo "    cd afrifx-api && npm install && npx tsc --noEmit   # verify API"
echo "    cd ../afrifx-web && npm run build                  # verify web"
echo "    git add -A && git commit -m 'Phase D: About & Contact pages + admin content editor'"
echo "    git push"
echo ""
echo "  Deploy both, run the SQL, then check /about and /contact (logged"
echo "  out too), and edit them from Admin -> Site content. Submit a test"
echo "  message on /contact and confirm it lands in your support inbox."
echo "======================================================"
