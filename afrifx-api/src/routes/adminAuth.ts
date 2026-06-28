import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import {
  verifyPassword, signToken, normalizeAdmin,
  requireAdmin, logAction,
} from '../lib/adminAuth'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /admin/auth/is-admin?wallet=0x — sidebar visibility check
router.get('/is-admin', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ isAdmin: false })
  const adminWallet = process.env.ADMIN_WALLET?.toLowerCase()
  if (adminWallet && wallet === adminWallet) return res.json({ isAdmin: true })
  try {
    const rows = await db.run(
      sql`SELECT id FROM admins
          WHERE LOWER(wallet_address) = ${wallet}
            AND status = 'active' LIMIT 1`
    )
    res.json({ isAdmin: parseRows(rows).length > 0 })
  } catch { res.json({ isAdmin: false }) }
})

// POST /admin/auth/verify-wallet — step 1
router.post('/verify-wallet', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const adminWallet = process.env.ADMIN_WALLET?.toLowerCase()
  const w           = wallet.toLowerCase()
  if (adminWallet && w === adminWallet) return res.json({ valid: true, role: 'super_admin' })
  try {
    const rows = await db.run(
      sql`SELECT id, role FROM admins
          WHERE LOWER(wallet_address) = ${w}
            AND status = 'active' LIMIT 1`
    )
    const r = parseRows(rows)
    if (r.length) return res.json({ valid: true, role: r[0].role ?? r[0][1] })
    res.json({ valid: false, error: 'This wallet is not authorised for admin access' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/auth/login — step 2
router.post('/login', async (req, res) => {
  const { identifier, password, wallet } = req.body
  if (!identifier || !password) {
    return res.status(400).json({ error: 'identifier and password required' })
  }
  try {
    const rows = await db.run(
      sql`SELECT * FROM admins
          WHERE (LOWER(username) = ${identifier.toLowerCase()}
              OR LOWER(email)    = ${identifier.toLowerCase()})
          LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(401).json({ error: 'Invalid credentials' })
    const admin = normalizeAdmin(r[0])
    const valid = await verifyPassword(password, admin.password_hash)
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' })
    const now = Math.floor(Date.now() / 1000)
    if (admin.status === 'suspended') {
      if (!admin.suspended_until || admin.suspended_until > now) {
        return res.status(403).json({ error: 'Account suspended', until: admin.suspended_until })
      }
    }
    if (wallet && admin.wallet_address &&
        wallet.toLowerCase() !== admin.wallet_address.toLowerCase() &&
        admin.role !== 'super_admin') {
      return res.status(403).json({ error: 'Wallet does not match this admin account' })
    }
    const token = signToken({
      id: admin.id, username: admin.username,
      role: admin.role, permissions: admin.permissions,
    })
    await db.run(sql`UPDATE admins SET last_login = ${now} WHERE id = ${admin.id}`)
    await logAction(admin.id, admin.username, 'login', undefined, undefined, 'Admin logged in', req.ip)
    res.json({
      token,
      admin: {
        id: admin.id, username: admin.username,
        email: admin.email, role: admin.role,
        permissions: admin.permissions,
      },
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /admin/auth/me
router.get('/me', requireAdmin, async (req, res) => {
  res.json({ admin: (req as any).admin })
})

// POST /admin/auth/logout
router.post('/logout', requireAdmin, async (req, res) => {
  const admin = (req as any).admin
  await logAction(admin.id, admin.username, 'logout', undefined, undefined, 'Admin logged out', req.ip)
  res.json({ success: true })
})

export default router
