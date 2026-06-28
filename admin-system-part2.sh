#!/bin/bash
# ============================================================
# AfriFX — Admin System Part 2: Management Routes
# Run from ~/AfriFX:  bash admin-system-part2.sh
# (Run admin-system-part1.sh FIRST)
# ============================================================
set -e
echo ""
echo "🔐  Building Admin System — Part 2 (Management Routes)..."
echo ""

# ============================================================
# 1 — Admin management routes (sub-admins, users, offers, etc.)
# ============================================================
cat > afrifx-api/src/routes/adminManage.ts << '__EOF__'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import {
  requireAdmin, requirePermission,
  hashPassword, normalizeAdmin, logAction,
} from '../lib/adminAuth'
import { PERMISSIONS, ALL_PERMISSIONS, PERMISSION_META } from '../lib/permissions'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// All routes require admin auth
router.use(requireAdmin)

// ══════════════════════════════════════════════════════════
// PERMISSIONS META — for building UI
// ══════════════════════════════════════════════════════════
router.get('/permissions', (_req, res) => {
  res.json({
    all:  ALL_PERMISSIONS,
    meta: PERMISSION_META,
  })
})

// ══════════════════════════════════════════════════════════
// DASHBOARD OVERVIEW
// ══════════════════════════════════════════════════════════
router.get('/overview', requirePermission(PERMISSIONS.VIEW_DASHBOARD), async (_req, res) => {
  try {
    const now   = Math.floor(Date.now() / 1000)
    const day   = 86400
    const week  = day * 7

    // Total platform volume (all transactions)
    const volRows = await db.run(sql`SELECT SUM(from_amount) as vol, COUNT(*) as cnt FROM transactions`)
    const vr = parseRows(volRows)
    const totalVolume = Number(vr[0]?.vol ?? vr[0]?.[0] ?? 0)
    const totalTxs    = Number(vr[0]?.cnt ?? vr[0]?.[1] ?? 0)

    // Total fees collected
    const feeRows = await db.run(sql`SELECT SUM(spread_fee) as fees FROM transactions`)
    const fr = parseRows(feeRows)
    const totalFees = Number(fr[0]?.fees ?? fr[0]?.[0] ?? 0)

    // P2P stats
    const p2pRows = await db.run(sql`SELECT status, COUNT(*) as cnt FROM p2p_offers GROUP BY status`)
    const p2pStats: Record<string, number> = {}
    for (const r of parseRows(p2pRows)) {
      p2pStats[r.status ?? r[0]] = Number(r.cnt ?? r[1] ?? 0)
    }

    // Open disputes
    const dispRows = await db.run(sql`SELECT COUNT(*) as cnt FROM disputes WHERE status = 'open'`)
    const dr = parseRows(dispRows)
    const openDisputes = Number(dr[0]?.cnt ?? dr[0]?.[0] ?? 0)

    // Total users
    const userRows = await db.run(sql`SELECT COUNT(*) as cnt FROM profiles`)
    const usr = parseRows(userRows)
    const totalUsers = Number(usr[0]?.cnt ?? usr[0]?.[0] ?? 0)

    // New users this week
    const newUserRows = await db.run(
      sql`SELECT COUNT(*) as cnt FROM profiles WHERE created_at > ${now - week}`
    )
    const nur = parseRows(newUserRows)
    const newUsersWeek = Number(nur[0]?.cnt ?? nur[0]?.[0] ?? 0)

    // Volume chart (last 14 days)
    const txRows = await db.run(
      sql`SELECT from_amount, created_at FROM transactions
          WHERE created_at > ${now - day * 14}`
    )
    const txs = parseRows(txRows).map((r: any) => ({
      amount:    Number(r.from_amount ?? r[0]),
      createdAt: Number(r.created_at  ?? r[1]),
    }))
    const chartData = Array.from({ length: 14 }, (_, i) => {
      const dayStart = now - (13 - i) * day
      const dayEnd   = dayStart + day
      const label    = new Date(dayStart * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })
      const volume   = txs
        .filter(t => t.createdAt >= dayStart && t.createdAt < dayEnd)
        .reduce((s, t) => s + t.amount, 0)
      return { label, volume: parseFloat(volume.toFixed(2)) }
    })

    res.json({
      totalVolume:  parseFloat(totalVolume.toFixed(2)),
      totalTxs,
      totalFees:    parseFloat(totalFees.toFixed(2)),
      p2p: {
        open:      p2pStats.open      ?? 0,
        accepted:  p2pStats.accepted  ?? 0,
        released:  p2pStats.released  ?? 0,
        cancelled: p2pStats.cancelled ?? 0,
      },
      openDisputes,
      totalUsers,
      newUsersWeek,
      chartData,
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// ══════════════════════════════════════════════════════════
// SUB-ADMIN MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/admins — list all admins
router.get('/admins', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (_req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT id, username, email, wallet_address, role, permissions,
                 status, suspended_until, created_by, last_login, created_at
          FROM admins ORDER BY created_at DESC`
    )
    const admins = parseRows(rows).map(r => {
      const a = normalizeAdmin(Array.isArray(r) ? [
        r[0], r[1], r[2], '', r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], 0
      ] : { ...r, password_hash: '' })
      delete (a as any).password_hash
      return a
    })
    res.json(admins)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/admins — create sub-admin
router.post('/admins', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const { username, email, password, walletAddress, permissions } = req.body

  if (!username || !email || !password) {
    return res.status(400).json({ error: 'username, email, password required' })
  }
  if (password.length < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters' })
  }

  try {
    // Check uniqueness
    const existing = await db.run(
      sql`SELECT id FROM admins
          WHERE LOWER(username) = ${username.toLowerCase()}
             OR LOWER(email) = ${email.toLowerCase()} LIMIT 1`
    )
    if (parseRows(existing).length) {
      return res.status(409).json({ error: 'Username or email already exists' })
    }

    // Validate permissions are real
    const validPerms = (permissions ?? []).filter((p: string) => ALL_PERMISSIONS.includes(p as any))

    const id   = randomUUID()
    const now  = Math.floor(Date.now() / 1000)
    const hash = await hashPassword(password)

    await db.run(
      sql`INSERT INTO admins
          (id, username, email, password_hash, wallet_address,
           role, permissions, status, created_by, created_at, updated_at)
          VALUES
          (${id}, ${username.toLowerCase()}, ${email.toLowerCase()},
           ${hash}, ${walletAddress?.toLowerCase() ?? null},
           'sub_admin', ${JSON.stringify(validPerms)},
           'active', ${admin.id}, ${now}, ${now})`
    )

    await logAction(admin.id, admin.username, 'create_sub_admin', 'admin', id,
      `Created sub-admin '${username}' with ${validPerms.length} permissions`, req.ip)

    res.status(201).json({ id, username, permissions: validPerms })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /admin/manage/admins/:id — update permissions / status
router.patch('/admins/:id', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const { permissions, status, suspendedUntil, walletAddress } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    // Prevent editing super admins
    const targetRows = await db.run(sql`SELECT role, username FROM admins WHERE id = ${req.params.id} LIMIT 1`)
    const tr = parseRows(targetRows)
    if (!tr.length) return res.status(404).json({ error: 'Admin not found' })
    const targetRole = tr[0].role ?? tr[0][0]
    const targetName = tr[0].username ?? tr[0][1]
    if (targetRole === 'super_admin') {
      return res.status(403).json({ error: 'Cannot modify a super admin' })
    }

    const validPerms = permissions
      ? (permissions as string[]).filter(p => ALL_PERMISSIONS.includes(p as any))
      : null

    await db.run(
      sql`UPDATE admins SET
            permissions     = COALESCE(${validPerms ? JSON.stringify(validPerms) : null}, permissions),
            status          = COALESCE(${status ?? null}, status),
            suspended_until = ${suspendedUntil ?? null},
            wallet_address  = COALESCE(${walletAddress?.toLowerCase() ?? null}, wallet_address),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )

    const actionDesc = status === 'suspended'
      ? `Suspended sub-admin '${targetName}'${suspendedUntil ? ` until ${new Date(suspendedUntil * 1000).toLocaleDateString()}` : ''}`
      : status === 'active'
      ? `Reactivated sub-admin '${targetName}'`
      : `Updated permissions for sub-admin '${targetName}'`

    await logAction(admin.id, admin.username, 'update_sub_admin', 'admin', req.params.id,
      actionDesc, req.ip)

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /admin/manage/admins/:id — remove sub-admin
router.delete('/admins/:id', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  try {
    const targetRows = await db.run(sql`SELECT role, username FROM admins WHERE id = ${req.params.id} LIMIT 1`)
    const tr = parseRows(targetRows)
    if (!tr.length) return res.status(404).json({ error: 'Admin not found' })
    if ((tr[0].role ?? tr[0][0]) === 'super_admin') {
      return res.status(403).json({ error: 'Cannot delete a super admin' })
    }
    const targetName = tr[0].username ?? tr[0][1]

    await db.run(sql`DELETE FROM admins WHERE id = ${req.params.id}`)
    await logAction(admin.id, admin.username, 'delete_sub_admin', 'admin', req.params.id,
      `Removed sub-admin '${targetName}'`, req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// USER LOGIN DATA MANAGEMENT (admins can reset passwords etc.)
// ══════════════════════════════════════════════════════════

// PATCH /admin/manage/admins/:id/credentials — change username/email/password
router.patch('/admins/:id/credentials', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const { username, email, newPassword } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    const updates: any = { updated_at: now }
    const changes: string[] = []

    if (username) {
      const dup = await db.run(
        sql`SELECT id FROM admins WHERE LOWER(username) = ${username.toLowerCase()} AND id != ${req.params.id} LIMIT 1`
      )
      if (parseRows(dup).length) return res.status(409).json({ error: 'Username taken' })
      await db.run(sql`UPDATE admins SET username = ${username.toLowerCase()}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('username')
    }
    if (email) {
      const dup = await db.run(
        sql`SELECT id FROM admins WHERE LOWER(email) = ${email.toLowerCase()} AND id != ${req.params.id} LIMIT 1`
      )
      if (parseRows(dup).length) return res.status(409).json({ error: 'Email taken' })
      await db.run(sql`UPDATE admins SET email = ${email.toLowerCase()}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('email')
    }
    if (newPassword) {
      if (newPassword.length < 8) return res.status(400).json({ error: 'Password must be at least 8 characters' })
      const hash = await hashPassword(newPassword)
      await db.run(sql`UPDATE admins SET password_hash = ${hash}, updated_at = ${now} WHERE id = ${req.params.id}`)
      changes.push('password')
    }

    await logAction(admin.id, admin.username, 'update_credentials', 'admin', req.params.id,
      `Changed ${changes.join(', ')}`, req.ip)

    res.json({ success: true, changed: changes })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// OFFERS MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/offers — all offers with filters
router.get('/offers', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = status
      ? await db.run(sql`SELECT * FROM p2p_offers WHERE status = ${status} ORDER BY created_at DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM p2p_offers ORDER BY created_at DESC LIMIT 100`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/release — force release to taker
router.post('/offers/:id/release', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const admin = (req as any).admin
  const offerId = req.params.id as `0x${string}`
  try {
    const hash = await releasePlatform(offerId)
    const now  = Math.floor(Date.now() / 1000)
    await db.run(
      sql`UPDATE p2p_offers SET status = 'released', release_tx_hash = ${hash}, updated_at = ${now} WHERE id = ${offerId}`
    )
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})
    await logAction(admin.id, admin.username, 'force_release_offer', 'offer', offerId,
      `Force released offer — tx ${hash.slice(0,14)}`, req.ip)
    res.json({ success: true, txHash: hash })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/cancel — force cancel, refund maker
router.post('/offers/:id/cancel', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const admin = (req as any).admin
  const offerId = req.params.id as `0x${string}`
  const { reason } = req.body
  try {
    const hash = await cancelPlatform(offerId, reason ?? 'Admin cancelled')
    const now  = Math.floor(Date.now() / 1000)
    await db.run(
      sql`UPDATE p2p_offers SET status = 'cancelled', updated_at = ${now} WHERE id = ${offerId}`
    )
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})
    await logAction(admin.id, admin.username, 'force_cancel_offer', 'offer', offerId,
      `Force cancelled offer: ${reason ?? 'no reason'} — tx ${hash.slice(0,14)}`, req.ip)
    res.json({ success: true, txHash: hash })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// DISPUTE RESOLUTION
// ══════════════════════════════════════════════════════════

// GET /admin/manage/disputes
router.get('/disputes', requirePermission(PERMISSIONS.RESOLVE_DISPUTES), async (req, res) => {
  const status = (req.query.status as string) ?? 'open'
  try {
    const rows = await db.run(
      sql`SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount,
                 o.maker_address, o.taker_address, o.status as offer_status
          FROM disputes d
          LEFT JOIN p2p_offers o ON o.id = d.offer_id
          WHERE d.status = ${status}
          ORDER BY d.created_at DESC LIMIT 100`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/disputes/:id/resolve — release to taker OR refund maker
router.post('/disputes/:id/resolve', requirePermission(PERMISSIONS.RESOLVE_DISPUTES), async (req, res) => {
  const admin = (req as any).admin
  const { resolution, offerId, reason } = req.body // resolution: 'release' | 'refund'

  if (!['release','refund'].includes(resolution)) {
    return res.status(400).json({ error: 'resolution must be release or refund' })
  }

  try {
    const now = Math.floor(Date.now() / 1000)
    let hash: string

    if (resolution === 'release') {
      hash = await releasePlatform(offerId as `0x${string}`)
      await db.run(sql`UPDATE p2p_offers SET status = 'released', release_tx_hash = ${hash}, updated_at = ${now} WHERE id = ${offerId}`)
    } else {
      hash = await cancelPlatform(offerId as `0x${string}`, reason ?? 'Dispute resolved — refund')
      await db.run(sql`UPDATE p2p_offers SET status = 'cancelled', updated_at = ${now} WHERE id = ${offerId}`)
    }

    await db.run(
      sql`UPDATE disputes SET status = ${`resolved_${resolution}`}, settled_at = ${now}, resolved_by = ${admin.username} WHERE id = ${req.params.id}`
    ).catch(() => {})
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})

    await logAction(admin.id, admin.username, 'resolve_dispute', 'dispute', req.params.id,
      `Resolved dispute via ${resolution} — tx ${hash.slice(0,14)}. Reason: ${reason ?? 'none'}`, req.ip)

    res.json({ success: true, txHash: hash, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// USER MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/users — search/list users
router.get('/users', requirePermission(PERMISSIONS.MANAGE_USERS), async (req, res) => {
  const search = (req.query.search as string)?.toLowerCase()
  try {
    const rows = search
      ? await db.run(sql`SELECT * FROM profiles
          WHERE LOWER(username) LIKE ${'%'+search+'%'}
             OR LOWER(wallet_address) LIKE ${'%'+search+'%'}
             OR LOWER(display_name) LIKE ${'%'+search+'%'}
          ORDER BY created_at DESC LIMIT 50`)
      : await db.run(sql`SELECT * FROM profiles ORDER BY created_at DESC LIMIT 50`)

    // Enrich with trade counts
    const users = []
    for (const r of parseRows(rows)) {
      const u = Array.isArray(r) ? {
        wallet_address: r[0], username: r[1], display_name: r[2],
        verified: r[9], created_at: r[11],
      } : r
      const tradeRows = await db.run(
        sql`SELECT COUNT(*) as cnt FROM p2p_offers
            WHERE (LOWER(maker_address) = ${u.wallet_address.toLowerCase()}
               OR LOWER(taker_address) = ${u.wallet_address.toLowerCase()})
              AND status = 'released'`
      )
      const tc = parseRows(tradeRows)
      users.push({ ...u, trades: Number(tc[0]?.cnt ?? tc[0]?.[0] ?? 0) })
    }
    res.json(users)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/users/:address/suspend
router.post('/users/:address/suspend', requirePermission(PERMISSIONS.SUSPEND_USERS), async (req, res) => {
  const admin = (req as any).admin
  const { reason, until } = req.body
  const addr = req.params.address.toLowerCase()
  try {
    // Add suspended flag to profiles (create column on the fly if missing handled by migration)
    await db.run(
      sql`UPDATE profiles SET suspended = 1, suspended_until = ${until ?? null}, suspend_reason = ${reason ?? null} WHERE LOWER(wallet_address) = ${addr}`
    ).catch(async () => {
      // Column might not exist yet — add it
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspended INTEGER DEFAULT 0`).catch(() => {})
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspended_until INTEGER`).catch(() => {})
      await db.run(sql`ALTER TABLE profiles ADD COLUMN suspend_reason TEXT`).catch(() => {})
      await db.run(sql`UPDATE profiles SET suspended = 1, suspended_until = ${until ?? null}, suspend_reason = ${reason ?? null} WHERE LOWER(wallet_address) = ${addr}`)
    })
    await logAction(admin.id, admin.username, 'suspend_user', 'user', addr,
      `Suspended user: ${reason ?? 'no reason'}`, req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/users/:address/unsuspend
router.post('/users/:address/unsuspend', requirePermission(PERMISSIONS.SUSPEND_USERS), async (req, res) => {
  const admin = (req as any).admin
  const addr = req.params.address.toLowerCase()
  try {
    await db.run(
      sql`UPDATE profiles SET suspended = 0, suspended_until = NULL, suspend_reason = NULL WHERE LOWER(wallet_address) = ${addr}`
    ).catch(() => {})
    await logAction(admin.id, admin.username, 'unsuspend_user', 'user', addr,
      'Unsuspended user', req.ip)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// AUDIT LOG VIEWER
// ══════════════════════════════════════════════════════════
router.get('/audit', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (req, res) => {
  const adminFilter = req.query.admin as string
  try {
    const rows = adminFilter
      ? await db.run(sql`SELECT * FROM admin_audit_log WHERE admin_id = ${adminFilter} ORDER BY created_at DESC LIMIT 200`)
      : await db.run(sql`SELECT * FROM admin_audit_log ORDER BY created_at DESC LIMIT 200`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// ANALYTICS
// ══════════════════════════════════════════════════════════
router.get('/analytics', requirePermission(PERMISSIONS.VIEW_ANALYTICS), async (_req, res) => {
  try {
    // Volume by corridor
    const corridorRows = await db.run(
      sql`SELECT from_currency, to_currency, SUM(from_amount) as vol, COUNT(*) as cnt
          FROM transactions
          GROUP BY from_currency, to_currency
          ORDER BY vol DESC LIMIT 10`
    )
    const corridors = parseRows(corridorRows).map((r: any) => ({
      pair:   `${r.from_currency ?? r[0]}/${r.to_currency ?? r[1]}`,
      volume: Number(r.vol ?? r[2]),
      count:  Number(r.cnt ?? r[3]),
    }))

    // P2P vs direct split
    const directRows = await db.run(sql`SELECT COUNT(*) as cnt, SUM(from_amount) as vol FROM transactions`)
    const p2pRows    = await db.run(sql`SELECT COUNT(*) as cnt, SUM(usdc_amount) as vol FROM p2p_offers WHERE status = 'released'`)
    const dr = parseRows(directRows)
    const pr = parseRows(p2pRows)

    res.json({
      corridors,
      split: {
        direct: { count: Number(dr[0]?.cnt ?? dr[0]?.[0] ?? 0), volume: Number(dr[0]?.vol ?? dr[0]?.[1] ?? 0) },
        p2p:    { count: Number(pr[0]?.cnt ?? pr[0]?.[0] ?? 0), volume: Number(pr[0]?.vol ?? pr[0]?.[1] ?? 0) },
      },
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/adminManage.ts"

# ============================================================
# 2 — Register routes + seed in index.ts
# ============================================================
cat > afrifx-api/src/index.ts << '__EOF__'
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
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
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
app.use('/admin/auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
  startTreasuryChecker()
  startTxSettler()
})
__EOF__
echo "✅  index.ts — admin routes registered + seedSuperAdmin on boot"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Admin System Part 2 (Management Routes) complete!"
echo ""
echo "  Endpoints added (all require admin token):"
echo "  /admin/manage/overview      — platform stats"
echo "  /admin/manage/admins        — CRUD sub-admins"
echo "  /admin/manage/admins/:id/credentials — reset login data"
echo "  /admin/manage/offers        — view + force release/cancel"
echo "  /admin/manage/disputes      — view + resolve"
echo "  /admin/manage/users         — search + suspend"
echo "  /admin/manage/audit         — audit log viewer"
echo "  /admin/manage/analytics     — corridor + split analytics"
echo "  /admin/manage/permissions   — permission metadata for UI"
echo ""
echo "  Every action is permission-gated + audit logged."
echo ""
echo "  Next: run admin-system-part3.sh for the frontend UI"
echo "══════════════════════════════════════════════════════"
