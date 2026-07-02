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
