import { Router } from 'express'
import { db }     from '../db/client'
import { notifyWelcome } from '../services/email/notifications'
import { sql }    from 'drizzle-orm'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /notifications?wallet=0x — recent notifications for in-app bell
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  try {
    const rows = await db.run(sql`
      SELECT id, type, subject, payload, read_at, created_at
      FROM notifications
      WHERE LOWER(user_wallet) = ${wallet}
      ORDER BY created_at DESC LIMIT 30
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /notifications/unread?wallet=0x — unread count for badge
router.get('/unread', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(sql`
      SELECT COUNT(*) as cnt FROM notifications
      WHERE LOWER(user_wallet) = ${wallet} AND read_at IS NULL
    `)
    const r = parseRows(rows)
    res.json({ count: Number(r[0]?.cnt ?? r[0]?.[0] ?? 0) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /notifications/:id/read — mark as read
router.patch('/:id/read', async (req, res) => {
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE notifications SET read_at = ${now} WHERE id = ${req.params.id}
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /notifications/mark-all-read?wallet=0x
router.patch('/mark-all-read', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE notifications SET read_at = ${now}
      WHERE LOWER(user_wallet) = ${wallet} AND read_at IS NULL
    `)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /notifications/email — update user email + preferences
router.post('/email', async (req, res) => {
  const { wallet, email, notify_trades, notify_disputes, notify_invoices } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'invalid email format' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    // Check if this is the first time adding an email
    const existingRows = await db.run(sql`SELECT email FROM profiles WHERE LOWER(wallet_address) = LOWER(${wallet}) LIMIT 1`)
    const existing = parseRows(existingRows)[0]
    const isFirstEmail = !existing?.email && email

    await db.run(sql`
      UPDATE profiles SET
        email = ${email ?? null},
        notify_trades   = ${notify_trades   ? 1 : 0},
        notify_disputes = ${notify_disputes ? 1 : 0},
        notify_invoices = ${notify_invoices ? 1 : 0},
        updated_at = ${now}
      WHERE LOWER(wallet_address) = LOWER(${wallet})
    `)

    // Send welcome email if this is their first email
    if (isFirstEmail) {
      notifyWelcome(wallet).catch(err => console.error('[Notify] welcome:', err.message))
    }

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /notifications/heartbeat — track user activity to suppress duplicate emails
router.post('/heartbeat', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      UPDATE profiles SET last_active_at = ${now}
      WHERE LOWER(wallet_address) = LOWER(${wallet})
    `)

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /notifications/test-email — send a test email to verify setup
router.post('/test-email', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  try {
    const rows = await db.run(sql`
      SELECT email, display_name, username FROM profiles
      WHERE LOWER(wallet_address) = LOWER(${wallet}) LIMIT 1
    `)
    const r = parseRows(rows)
    const profile = r[0]

    if (!profile?.email) {
      return res.status(400).json({ error: 'No email set for this wallet. Add one first.' })
    }

    const { sendEmail } = await import('../services/email/client')
    const name = profile.display_name ?? profile.username ?? 'there'

    const result = await sendEmail({
      to:      profile.email,
      subject: 'AfriFX email notifications are working',
      html:    '<html><body style="background:#080D1B;color:#E2E8F0;font-family:sans-serif;padding:40px;">'
        + '<div style="max-width:480px;margin:0 auto;background:#0F1729;border:1px solid #1B2B4B;border-radius:12px;padding:32px;">'
        + '<h1 style="color:#378ADD;margin:0 0 16px;font-size:20px;">AfriFX notifications</h1>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 16px;">Hi ' + name + ',</p>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 16px;">Your email notifications are set up and working correctly. You will now receive alerts for trades, disputes, and invoice payments.</p>'
        + '<p style="color:#64748B;font-size:12px;margin:24px 0 0;">AfriFX &middot; <a href="https://afrifx.xyz" style="color:#378ADD;">afrifx.xyz</a></p>'
        + '</div></body></html>',
    })

    if (result.success) {
      res.json({ success: true, message: 'Test email sent to ' + profile.email, emailId: result.id })
    } else {
      res.status(500).json({ error: result.error ?? 'Send failed' })
    }
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
