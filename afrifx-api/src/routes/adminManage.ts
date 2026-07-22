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
// PERMISSIONS META for building UI
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

    // Live rates for USD conversion
    const { getCachedRates } = await import('../services/rateOracle')
    const rateList = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of rateList) rates[r.pair] = r.rate

    // Convert any amount to USD using live rates
    function toUSD(amount: number, currency: string): number {
      if (!amount || amount <= 0) return 0
      if (currency === 'USDC' || currency === 'USD') return amount
      if (currency === 'EURC') return amount * (rates['EURC/USDC'] ? 1 / rates['EURC/USDC'] : 1.09)
      const rate = rates[`${currency}/USDC`]
      return rate && rate > 0 ? amount / rate : 0
    }

    // USD value of a transaction always use the USDC side if present
    function txUSD(fromCcy: string, toCcy: string, fromAmt: number, toAmt: number): number {
      if (toCcy   === 'USDC') return toAmt
      if (fromCcy === 'USDC') return fromAmt
      return toUSD(fromAmt, fromCcy)
    }

    // All transactions with USD volume
    const txRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount, spread_fee, created_at
          FROM transactions`
    )
    const txs = parseRows(txRows).map((r: any) => {
      const fromCcy = r.from_currency ?? r[0]
      const toCcy   = r.to_currency   ?? r[1]
      const fromAmt = Number(r.from_amount ?? r[2] ?? 0)
      const toAmt   = Number(r.to_amount   ?? r[3] ?? 0)
      const fee     = Number(r.spread_fee  ?? r[4] ?? 0)
      const ts      = Number(r.created_at  ?? r[5] ?? 0)
      return {
        usdVol:    txUSD(fromCcy, toCcy, fromAmt, toAmt),
        usdFee:    toUSD(fee, fromCcy),
        createdAt: ts,
      }
    })

    // P2P released volume (USDC = USD)
    const p2pVolRows = await db.run(
      sql`SELECT SUM(usdc_amount) as vol FROM p2p_offers WHERE status = 'released'`
    )
    const pvr = parseRows(p2pVolRows)
    const p2pVol = Number(pvr[0]?.vol ?? pvr[0]?.[0] ?? 0)

    const totalVolume = txs.reduce((s, t) => s + t.usdVol, 0) + p2pVol
    const totalTxs    = txs.length
    const totalFees   = txs.reduce((s, t) => s + t.usdFee, 0)

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

    // Volume chart (last 14 days) correct day alignment, USD values
    const recentTxRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount, created_at
          FROM transactions WHERE created_at > ${now - day * 14}`
    )
    const recentTxs = parseRows(recentTxRows).map((r: any) => ({
      usdVol:    txUSD(r.from_currency??r[0], r.to_currency??r[1], Number(r.from_amount??r[2]), Number(r.to_amount??r[3])),
      createdAt: Number(r.created_at ?? r[4]),
    }))

    const recentP2PRows = await db.run(
      sql`SELECT usdc_amount, created_at FROM p2p_offers
          WHERE status = 'released' AND created_at > ${now - day * 14}`
    )
    const recentP2P = parseRows(recentP2PRows).map((r: any) => ({
      usdVol:    Number(r.usdc_amount ?? r[0]),
      createdAt: Number(r.created_at  ?? r[1]),
    }))

    const chartData = Array.from({ length: 14 }, (_, i) => {
      const daysAgo  = 13 - i
      const dayEnd   = now - daysAgo * day
      const dayStart = dayEnd - day
      const label    = daysAgo === 0
        ? 'Today'
        : new Date(dayStart * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })

      const txVol  = recentTxs.filter(t => t.createdAt >= dayStart && t.createdAt < dayEnd).reduce((s,t)=>s+t.usdVol,0)
      const p2pV   = recentP2P.filter(t => t.createdAt >= dayStart && t.createdAt < dayEnd).reduce((s,t)=>s+t.usdVol,0)
      return { label, volume: parseFloat((txVol + p2pV).toFixed(2)) }
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

// GET /admin/manage/admins list all admins
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

// POST /admin/manage/admins create sub-admin
router.post('/admins', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const admin = (req as any).admin
  const {
    username, email, password, walletAddress, permissions,
    dutyStartMin, dutyEndMin, dutyDays, dutyDates,
  } = req.body

  if (!username || !email || !password) {
    return res.status(400).json({ error: 'username, email, password and wallet address required' })
  }
  if (password.length < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters' })
  }

  // Working hours (the sub-admin's dispute duty session). Optional at invite
  // if any duty field is supplied, the whole window must be valid (max 6h).
  const wantsDuty = dutyStartMin != null || dutyEndMin != null ||
                    (dutyDays?.length) || (dutyDates?.length)
  if (wantsDuty) {
    const { validateWindow } = await import('../lib/duty')
    const err = validateWindow({
      startMin: dutyStartMin, endMin: dutyEndMin,
      days: dutyDays ?? [], dates: dutyDates ?? [],
    })
    if (err) return res.status(400).json({ error: err })
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
           role, permissions, status, created_by, created_at, updated_at,
           duty_start_min, duty_end_min, duty_days, duty_dates)
          VALUES
          (${id}, ${username.toLowerCase()}, ${email.toLowerCase()},
           ${hash}, ${walletAddress?.toLowerCase() ?? null},
           'sub_admin', ${JSON.stringify(validPerms)},
           'active', ${admin.id}, ${now}, ${now},
           ${wantsDuty ? dutyStartMin : null}, ${wantsDuty ? dutyEndMin : null},
           ${wantsDuty ? (dutyDays ?? []).join(',') : null},
           ${wantsDuty ? (dutyDates ?? []).join(',') : null})`
    )

    await logAction(admin.id, admin.username, 'create_sub_admin', 'admin', id,
      `Created sub-admin '${username}' with ${validPerms.length} permissions` +
      (wantsDuty ? ` and a duty window` : ''), req.ip)

    res.status(201).json({ id, username, permissions: validPerms })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /admin/manage/admins/:id update permissions / status
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

// DELETE /admin/manage/admins/:id remove sub-admin
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

// PATCH /admin/manage/admins/:id/credentials change username/email/password
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

// GET /admin/manage/offers all offers with filters
router.get('/offers', requirePermission(PERMISSIONS.MANAGE_OFFERS), async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = status
      ? await db.run(sql`SELECT * FROM p2p_offers WHERE status = ${status} ORDER BY created_at DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM p2p_offers ORDER BY created_at DESC LIMIT 100`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/release force release to taker
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
      `Force released offer, tx ${hash.slice(0,14)}`, req.ip)
    res.json({ success: true, txHash: hash })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin/manage/offers/:id/cancel force cancel, refund maker
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
      `Force cancelled offer: ${reason ?? 'no reason'}, tx ${hash.slice(0,14)}`, req.ip)
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

// POST /admin/manage/disputes/:id/resolve release to taker OR refund maker
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
      hash = await cancelPlatform(offerId as `0x${string}`, reason ?? 'Dispute resolved, refund')
      await db.run(sql`UPDATE p2p_offers SET status = 'cancelled', updated_at = ${now} WHERE id = ${offerId}`)
    }

    await db.run(
      sql`UPDATE disputes SET status = ${`resolved_${resolution}`}, settled_at = ${now}, resolved_by = ${admin.username} WHERE id = ${req.params.id}`
    ).catch(() => {})
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`).catch(() => {})

    await logAction(admin.id, admin.username, 'resolve_dispute', 'dispute', req.params.id,
      `Resolved dispute via ${resolution}, tx ${hash.slice(0,14)}. Reason: ${reason ?? 'none'}`, req.ip)

    res.json({ success: true, txHash: hash, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// USER MANAGEMENT
// ══════════════════════════════════════════════════════════

// GET /admin/manage/users search/list users
router.get('/users', requirePermission(PERMISSIONS.MANAGE_USERS), async (req, res) => {
  const search = (req.query.search as string)?.toLowerCase()
  // Sortable columns. Whitelisted — never interpolate user input into SQL.
  const sortKey = String(req.query.sort ?? 'volume')
  const dir     = String(req.query.dir ?? 'desc').toLowerCase() === 'asc' ? 'ASC' : 'DESC'

  const SORTABLE: Record<string, string> = {
    volume:    'volume',
    trades:    'trades',
    disputes:  'disputes',
    avg:       'avg_trade',
    active:    'last_active',
    joined:    'created_at',
    name:      'username',
  }
  const orderCol = SORTABLE[sortKey] ?? 'volume'

  try {
    /*
      ONE query instead of the old N+1 (it ran a separate COUNT per user — 50
      users meant 51 round trips). We LEFT JOIN an aggregate of each wallet's
      released trades so volume, counts, average size and last activity all come
      back in a single pass.

      A user appears as maker OR taker, so the aggregate unions both sides.
    */
    const rows = await db.run(sql`
      WITH trade_stats AS (
        SELECT wallet, COUNT(*) AS trades, SUM(usdc_amount) AS volume,
               MAX(updated_at) AS last_active
        FROM (
          SELECT LOWER(maker_address) AS wallet, usdc_amount, updated_at
            FROM p2p_offers WHERE status = 'released' AND maker_address IS NOT NULL
          UNION ALL
          SELECT LOWER(taker_address) AS wallet, usdc_amount, updated_at
            FROM p2p_offers WHERE status = 'released' AND taker_address IS NOT NULL
        )
        GROUP BY wallet
      ),
      maker_stats AS (
        SELECT LOWER(maker_address) AS wallet, COUNT(*) AS maker_trades
        FROM p2p_offers WHERE status = 'released' AND maker_address IS NOT NULL
        GROUP BY wallet
      ),
      taker_stats AS (
        SELECT LOWER(taker_address) AS wallet, COUNT(*) AS taker_trades
        FROM p2p_offers WHERE status = 'released' AND taker_address IS NOT NULL
        GROUP BY wallet
      ),
      dispute_stats AS (
        SELECT wallet, COUNT(*) AS disputes FROM (
          SELECT LOWER(o.maker_address) AS wallet FROM disputes d
            JOIN p2p_offers o ON o.id = d.offer_id WHERE o.maker_address IS NOT NULL
          UNION ALL
          SELECT LOWER(o.taker_address) AS wallet FROM disputes d
            JOIN p2p_offers o ON o.id = d.offer_id WHERE o.taker_address IS NOT NULL
        )
        GROUP BY wallet
      )
      SELECT p.*,
             COALESCE(t.trades, 0)        AS trades,
             COALESCE(t.volume, 0)        AS volume,
             t.last_active                AS last_active,
             COALESCE(mk.maker_trades, 0) AS maker_trades_live,
             COALESCE(tk.taker_trades, 0) AS taker_trades_live,
             COALESCE(d.disputes, 0)      AS disputes,
             CASE WHEN COALESCE(t.trades,0) > 0
                  THEN COALESCE(t.volume,0) / t.trades ELSE 0 END AS avg_trade
      FROM profiles p
      LEFT JOIN trade_stats   t  ON t.wallet  = LOWER(p.wallet_address)
      LEFT JOIN maker_stats   mk ON mk.wallet = LOWER(p.wallet_address)
      LEFT JOIN taker_stats   tk ON tk.wallet = LOWER(p.wallet_address)
      LEFT JOIN dispute_stats d  ON d.wallet  = LOWER(p.wallet_address)
      ${search
        ? sql`WHERE LOWER(p.username) LIKE ${'%'+search+'%'}
                 OR LOWER(p.wallet_address) LIKE ${'%'+search+'%'}
                 OR LOWER(p.display_name) LIKE ${'%'+search+'%'}`
        : sql``}
      ORDER BY ${sql.raw(orderCol)} ${sql.raw(dir)}
      LIMIT 100`)

    const users = parseRows(rows).map((r: any) => {
      const o = Array.isArray(r) ? {} : r
      const trades   = Number(o.trades   ?? 0)
      const disputes = Number(o.disputes ?? 0)
      return {
        ...o,
        trades,
        disputes,
        volume:        Number(o.volume    ?? 0),
        avg_trade:     Number(o.avg_trade ?? 0),
        last_active:   o.last_active ? Number(o.last_active) : null,
        maker_trades:  Number(o.maker_trades_live ?? 0),
        taker_trades:  Number(o.taker_trades_live ?? 0),
        // Dispute rate is the number an admin actually cares about: 3 disputes
        // on 3 trades is very different from 3 on 300.
        dispute_rate:  trades > 0 ? +((disputes / trades) * 100).toFixed(1) : 0,
        verified:      !!o.verified,
        suspended:     !!o.suspended,
      }
    })
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
      // Column might not exist yet add it
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
// DISPUTE DUTY SESSIONS
// ══════════════════════════════════════════════════════════

// GET /duty/status the calling admin's current duty state (for their dashboard)
router.get('/duty/status', async (req: any, res) => {
  try {
    const { dutyStatus, getAdminWindow } = await import('../lib/duty')
    const admin = req.admin
    if (!admin) return res.status(401).json({ error: 'Not authenticated' })
    const st = await dutyStatus(admin.id)
    // Include the schedule itself so the UI can show "Mon–Fri · 09:00–15:00 UTC".
    const w  = await getAdminWindow(admin.id)
    res.json({
      ...st,
      role: admin.role,
      startMin: w?.startMin ?? null,
      endMin:   w?.endMin   ?? null,
      days:     w?.days     ?? [],
      dates:    w?.dates    ?? [],
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /duty/resume sub-admin clicks "resume duty" to go on duty
router.post('/duty/resume', async (req: any, res) => {
  try {
    const { resumeDuty } = await import('../lib/duty')
    const admin = req.admin
    if (!admin) return res.status(401).json({ error: 'Not authenticated' })
    const r = await resumeDuty(admin.id, admin.username)
    if (!r.ok) return res.status(400).json({ error: r.error })
    await logAction(admin.id, admin.username, 'resume_duty', 'duty', admin.id,
      'Resumed duty for scheduled session')
    res.json({ success: true, windowEnd: r.windowEnd })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /duty/sessions session logs for the general admin to review.
// Most recent first; optionally filter by ?admin=<id>.
router.get('/duty/sessions', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (req, res) => {
  const adminFilter = req.query.admin as string | undefined
  try {
    const rows = adminFilter
      ? await db.run(sql`SELECT * FROM admin_duty_sessions WHERE admin_id = ${adminFilter}
                         ORDER BY window_start DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM admin_duty_sessions
                         ORDER BY window_start DESC LIMIT 100`)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /duty/overview every sub-admin's schedule + LIVE status, for the
// general admin's sub-admins page. Returns enough for the UI to render a
// ticking countdown without re-deriving the schedule itself.
router.get('/duty/overview', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (_req, res) => {
  try {
    const { getAdminWindow, windowAt, nextWindowStart } = await import('../lib/duty')
    const now = Math.floor(Date.now() / 1000)

    const rows = await db.run(sql`
      SELECT id, username, email, status
      FROM admins WHERE role = 'sub_admin' ORDER BY username ASC`)

    const out = []
    for (const r of parseRows(rows)) {
      const id       = Array.isArray(r) ? r[0] : r.id
      const username = Array.isArray(r) ? r[1] : r.username
      const email    = Array.isArray(r) ? r[2] : r.email
      const acct     = Array.isArray(r) ? r[3] : r.status

      const w = await getAdminWindow(id)
      if (!w) {
        out.push({ id, username, email, accountStatus: acct, hasWindow: false })
        continue
      }

      const win = windowAt(w, now)
      let onDuty = false
      if (win) {
        const s = parseRows(await db.run(sql`
          SELECT status FROM admin_duty_sessions
          WHERE admin_id = ${id} AND window_start = ${win.start} LIMIT 1`))
        const st = s.length ? (Array.isArray(s[0]) ? s[0][0] : s[0].status) : null
        onDuty = st === 'on_duty'
      }

      out.push({
        id, username, email, accountStatus: acct,
        hasWindow: true,
        startMin: w.startMin, endMin: w.endMin,
        days: w.days, dates: w.dates,
        inWindow:    !!win,
        onDuty,
        windowStart: win?.start ?? null,
        windowEnd:   win?.end   ?? null,
        nextStart:   win ? null : (nextWindowStart(w, now) ?? null),
      })
    }
    res.json(out)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /admins/:id/duty set, change, or CLEAR a sub-admin's working hours.
// Send { clear: true } to remove their hours (they can then no longer accept
// disputes). Otherwise send the window; it's validated (max 6h) as at invite.
// The sub-admin is emailed whenever their hours change.
router.patch('/admins/:id/duty', requirePermission(PERMISSIONS.MANAGE_ADMINS), async (req, res) => {
  const actor = (req as any).admin
  const { clear, dutyStartMin, dutyEndMin, dutyDays, dutyDates } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    const rows = parseRows(await db.run(sql`
      SELECT id, username, email, role FROM admins WHERE id = ${req.params.id} LIMIT 1`))
    const t = rows[0]
    if (!t) return res.status(404).json({ error: 'Admin not found' })

    const target = {
      id:       Array.isArray(t) ? t[0] : t.id,
      username: Array.isArray(t) ? t[1] : t.username,
      email:    Array.isArray(t) ? t[2] : t.email,
      role:     Array.isArray(t) ? t[3] : t.role,
    }
    if (target.role === 'super_admin') {
      return res.status(400).json({ error: 'Super admins are not on the duty rota' })
    }

    const { sendEmail } = await import('../services/email/client')

    // ── Clear hours ────────────────────────────────────────
    if (clear) {
      await db.run(sql`
        UPDATE admins
        SET duty_start_min = NULL, duty_end_min = NULL,
            duty_days = NULL, duty_dates = NULL, updated_at = ${now}
        WHERE id = ${target.id}`)

      await logAction(actor.id, actor.username, 'update_duty_hours', 'admin', target.id,
        `Cleared working hours for '${target.username}'`, req.ip)

      sendEmail({
        to: target.email,
        subject: 'Your AfriFX duty hours have been removed',
        html: `<p>Hi ${target.username},</p>
               <p>Your dispute duty hours have been removed by an administrator.
                  You will not be able to accept new disputes until hours are
                  assigned again.</p>
               <p>AfriFX</p>`,
      }).catch((e: any) => console.error('[Duty] email failed:', e?.message))

      return res.json({ success: true, cleared: true })
    }

    // ── Set / change hours ─────────────────────────────────
    const { validateWindow, formatWindowText } = await import('../lib/duty')
    const err = validateWindow({
      startMin: dutyStartMin, endMin: dutyEndMin,
      days: dutyDays ?? [], dates: dutyDates ?? [],
    })
    if (err) return res.status(400).json({ error: err })

    await db.run(sql`
      UPDATE admins
      SET duty_start_min = ${dutyStartMin}, duty_end_min = ${dutyEndMin},
          duty_days  = ${(dutyDays ?? []).join(',')},
          duty_dates = ${(dutyDates ?? []).join(',')},
          updated_at = ${now}
      WHERE id = ${target.id}`)

    const text = formatWindowText(dutyStartMin, dutyEndMin, dutyDays ?? [], dutyDates ?? [])

    await logAction(actor.id, actor.username, 'update_duty_hours', 'admin', target.id,
      `Set working hours for '${target.username}': ${text}`, req.ip)

    sendEmail({
      to: target.email,
      subject: 'Your AfriFX duty hours have been updated',
      html: `<p>Hi ${target.username},</p>
             <p>Your dispute duty hours have been updated by an administrator.</p>
             <p><strong>New schedule:</strong> ${text}</p>
             <p>You'll get a reminder shortly before each session begins. Remember to
                click <strong>Resume duty</strong> on your dashboard to start accepting
                disputes.</p>
             <p>AfriFX</p>`,
    }).catch((e: any) => console.error('[Duty] email failed:', e?.message))

    res.json({ success: true, schedule: text })
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

// GET /audit/grouped audit trail grouped by admin account.
// Super admin(s) first, then sub-admins. Each group carries that admin's
// own actions, so the log reads per-person instead of one interleaved list.
router.get('/audit/grouped', requirePermission(PERMISSIONS.VIEW_AUDIT_LOG), async (_req, res) => {
  try {
    // All known admins (so an admin with zero actions still shows, empty).
    const adminRows = await db.run(
      sql`SELECT id, name, email, role FROM admins ORDER BY created_at ASC`)
    const admins = parseRows(adminRows).map((r: any) => Array.isArray(r)
      ? { id: r[0], name: r[1], email: r[2], role: r[3] }
      : { id: r.id, name: r.name, email: r.email, role: r.role })

    // Recent audit entries (cap generous; grouping happens below).
    const logRows = await db.run(
      sql`SELECT * FROM admin_audit_log ORDER BY created_at DESC LIMIT 1000`)
    const logs = parseRows(logRows).map((r: any) => Array.isArray(r)
      ? { id: r[0], admin_id: r[1], admin_name: r[2], action: r[3],
          target_type: r[4], target_id: r[5], details: r[6],
          ip_address: r[7], created_at: r[8] }
      : r)

    // Bucket by admin_id.
    const byAdmin = new Map<string, any[]>()
    for (const l of logs) {
      const key = l.admin_id ?? 'unknown'
      if (!byAdmin.has(key)) byAdmin.set(key, [])
      byAdmin.get(key)!.push(l)
    }

    const groups = admins.map((a: any) => ({
      admin:   a,
      logs:    byAdmin.get(a.id) ?? [],
      count:   (byAdmin.get(a.id) ?? []).length,
      lastAt:  (byAdmin.get(a.id) ?? [])[0]?.created_at ?? null,
    }))

    // Any logs whose admin no longer exists (deleted sub-admin) keep them
    // visible rather than silently dropping history.
    const knownIds = new Set(admins.map((a: any) => a.id))
    const orphanLogs = logs.filter((l: any) => !knownIds.has(l.admin_id))
    if (orphanLogs.length) {
      const byName = new Map<string, any[]>()
      for (const l of orphanLogs) {
        const key = l.admin_name ?? 'Removed admin'
        if (!byName.has(key)) byName.set(key, [])
        byName.get(key)!.push(l)
      }
      for (const [name, ls] of byName) {
        groups.push({
          admin:  { id: ls[0].admin_id, name, email: '', role: 'removed' },
          logs:   ls, count: ls.length, lastAt: ls[0]?.created_at ?? null,
        })
      }
    }

    // Super admin(s) first, then the rest by most-recent activity.
    groups.sort((a: any, b: any) => {
      const aSuper = a.admin.role === 'super_admin' ? 0 : 1
      const bSuper = b.admin.role === 'super_admin' ? 0 : 1
      if (aSuper !== bSuper) return aSuper - bSuper
      return (b.lastAt ?? 0) - (a.lastAt ?? 0)
    })

    res.json({ groups, totalActions: logs.length })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ══════════════════════════════════════════════════════════
// ANALYTICS
// ══════════════════════════════════════════════════════════
router.get('/analytics', requirePermission(PERMISSIONS.VIEW_ANALYTICS), async (_req, res) => {
  try {
    // Live rates for USD conversion
    const { getCachedRates } = await import('../services/rateOracle')
    const rateList = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of rateList) rates[r.pair] = r.rate

    function txUSD(fromCcy: string, toCcy: string, fromAmt: number, toAmt: number): number {
      if (toCcy   === 'USDC') return toAmt
      if (fromCcy === 'USDC') return fromAmt
      if (fromCcy === 'EURC') return fromAmt * (rates['EURC/USDC'] ? 1 / rates['EURC/USDC'] : 1.09)
      const rate = rates[`${fromCcy}/USDC`]
      return rate && rate > 0 ? fromAmt / rate : 0
    }

    // Volume by corridor all rows then group in JS for USD conversion
    const corridorRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount
          FROM transactions`
    )

    const corridorMap: Record<string, { volume: number; count: number }> = {}
    for (const r of parseRows(corridorRows)) {
      const fromCcy = r.from_currency ?? r[0]
      const toCcy   = r.to_currency   ?? r[1]
      const fromAmt = Number(r.from_amount ?? r[2] ?? 0)
      const toAmt   = Number(r.to_amount   ?? r[3] ?? 0)
      const pair    = `${fromCcy}/${toCcy}`
      const usd     = txUSD(fromCcy, toCcy, fromAmt, toAmt)
      if (!corridorMap[pair]) corridorMap[pair] = { volume: 0, count: 0 }
      corridorMap[pair].volume += usd
      corridorMap[pair].count++
    }

    const corridors = Object.entries(corridorMap)
      .map(([pair, d]) => ({
        pair,
        volume: parseFloat(d.volume.toFixed(2)),
        count:  d.count,
      }))
      .sort((a, b) => b.volume - a.volume)
      .slice(0, 10)

    // P2P vs direct split both in USD
    const directRows = await db.run(
      sql`SELECT from_currency, to_currency, from_amount, to_amount FROM transactions`
    )
    let directVol = 0
    let directCnt = 0
    for (const r of parseRows(directRows)) {
      directVol += txUSD(r.from_currency??r[0], r.to_currency??r[1], Number(r.from_amount??r[2]), Number(r.to_amount??r[3]))
      directCnt++
    }

    const p2pRows = await db.run(
      sql`SELECT COUNT(*) as cnt, SUM(usdc_amount) as vol FROM p2p_offers WHERE status = 'released'`
    )
    const pr = parseRows(p2pRows)

    res.json({
      corridors,
      split: {
        direct: { count: directCnt, volume: parseFloat(directVol.toFixed(2)) },
        p2p:    {
          count:  Number(pr[0]?.cnt ?? pr[0]?.[0] ?? 0),
          volume: parseFloat(Number(pr[0]?.vol ?? pr[0]?.[1] ?? 0).toFixed(2)),
        },
      },
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
