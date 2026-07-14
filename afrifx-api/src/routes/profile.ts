import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

// ── Broadcast unsubscribe (PUBLIC reached from an email link, no login) ───
// Honours the opt-out we promise in every broadcast footer. Only affects
// ANNOUNCEMENTS; the user still receives essential alerts about their own
// trades, disputes and invoices.
router.post('/unsubscribe/:token', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT wallet_address, username FROM profiles
      WHERE unsubscribe_token = ${req.params.token} LIMIT 1`)
    const r = Array.isArray((rows as any).rows) ? (rows as any).rows : (Array.isArray(rows) ? rows : [])
    if (!r.length) return res.status(404).json({ error: 'This unsubscribe link is not valid.' })

    await db.run(sql`
      UPDATE profiles SET notify_broadcasts = 0
      WHERE unsubscribe_token = ${req.params.token}`)

    res.json({
      success: true,
      message: 'You have been unsubscribed from AfriFX announcements. You will still receive essential alerts about your own trades and disputes.',
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

const RESERVED = [
  'admin','afrifx','support','help','root','system','platform',
  'api','www','app','mail','dev','test','null','undefined',
]

const AVATAR_COLORS = [
  '#378ADD','#10B981','#8B5CF6','#F59E0B',
  '#EF4444','#EC4899','#14B8A6','#F97316',
  '#06B6D4','#84CC16','#A855F7','#FB923C',
]

function deriveColor(username: string): string {
  let hash = 0
  for (let i = 0; i < username.length; i++) {
    hash = username.charCodeAt(i) + ((hash << 5) - hash)
  }
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length]
}

function validateUsername(u: string): string | null {
  if (!u) return 'Username is required'
  if (u.length < 3)  return 'Username must be at least 3 characters'
  if (u.length > 20) return 'Username must be 20 characters or less'
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return 'Only letters, numbers and underscores allowed'
  if (RESERVED.includes(u.toLowerCase())) return 'This username is reserved'
  return null
}

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Normalise a profile row handles both array and object rows
// Includes live trade counts from subqueries
function normalizeProfile(row: any) {
  if (Array.isArray(row)) {
    return {
      wallet_address:  row[0],
      username:        row[1],
      display_name:    row[2],
      bio:             row[3],
      twitter_handle:  row[4],
      telegram_handle: row[5],
      avatar_color:    row[6],
      trade_count:     Number(row[7]  ?? 0),
      dispute_count:   Number(row[8]  ?? 0),
      verified:        !!row[9],
      show_socials:    !!row[10],
      created_at:      Number(row[11] ?? 0),
      updated_at:      Number(row[12] ?? 0),
      maker_trades:    Number(row[13] ?? 0),
      taker_trades:    Number(row[14] ?? 0),
      total_disputes:  Number(row[15] ?? 0),
    }
  }
  return {
    ...row,
    verified:       !!row.verified,
    show_socials:   !!row.show_socials,
    trade_count:    Number(row.trade_count    ?? 0),
    dispute_count:  Number(row.dispute_count  ?? 0),
    maker_trades:   Number(row.maker_trades   ?? 0),
    taker_trades:   Number(row.taker_trades   ?? 0),
    total_disputes: Number(row.total_disputes ?? 0),
  }
}

// Shared subquery for live trade + dispute counts
const PROFILE_QUERY = (whereClause: ReturnType<typeof sql>) => sql`
  SELECT p.*,
    (SELECT COUNT(*)
     FROM p2p_offers
     WHERE LOWER(maker_address) = LOWER(p.wallet_address)
       AND status = 'released') AS maker_trades,
    (SELECT COUNT(*)
     FROM p2p_offers
     WHERE LOWER(taker_address) = LOWER(p.wallet_address)
       AND status = 'released') AS taker_trades,
    (SELECT COUNT(*)
     FROM disputes
     WHERE LOWER(raised_by) != LOWER(p.wallet_address)
       AND offer_id IN (
         SELECT id FROM p2p_offers
         WHERE LOWER(maker_address) = LOWER(p.wallet_address)
       )) AS total_disputes
  FROM profiles p
  WHERE ${whereClause}
  LIMIT 1
`

// GET /profile/check/:username
router.get('/check/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  const err      = validateUsername(username)
  if (err) return res.json({ available: false, error: err })
  try {
    const rows = await db.run(
      sql`SELECT wallet_address FROM profiles WHERE LOWER(username) = ${username} LIMIT 1`
    )
    const r = parseRows(rows)
    res.json({ available: r.length === 0 })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/wallet/:address by wallet address (includes live trade counts)
router.get('/wallet/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const rows = await db.run(sql`
      SELECT p.*,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(maker_address) = ${addr}
           AND status = 'released') AS maker_trades,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(taker_address) = ${addr}
           AND status = 'released') AS taker_trades,
        (SELECT COUNT(*)
         FROM disputes d
         JOIN p2p_offers o ON o.id = d.offer_id
         WHERE LOWER(o.maker_address) = ${addr}
           AND LOWER(d.raised_by) != ${addr}) AS total_disputes
      FROM profiles p
      WHERE LOWER(p.wallet_address) = ${addr}
      LIMIT 1
    `)
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    res.json(normalizeProfile(r[0]))
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/:username by username (public)
router.get('/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  try {
    const rows = await db.run(sql`
      SELECT p.*,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(maker_address) = LOWER(p.wallet_address)
           AND status = 'released') AS maker_trades,
        (SELECT COUNT(*)
         FROM p2p_offers
         WHERE LOWER(taker_address) = LOWER(p.wallet_address)
           AND status = 'released') AS taker_trades,
        (SELECT COUNT(*)
         FROM disputes d
         JOIN p2p_offers o ON o.id = d.offer_id
         WHERE LOWER(o.maker_address) = LOWER(p.wallet_address)
           AND LOWER(d.raised_by) != LOWER(p.wallet_address)) AS total_disputes
      FROM profiles p
      WHERE LOWER(p.username) = ${username}
      LIMIT 1
    `)
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    const profile = normalizeProfile(r[0])
    if (!profile.show_socials) {
      profile.twitter_handle  = null
      profile.telegram_handle = null
    }
    res.json(profile)
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// POST /profile create
router.post('/', async (req, res) => {
  const {
    walletAddress, username, displayName,
    bio, twitterHandle, telegramHandle, showSocials,
  } = req.body

  const err = validateUsername(username)
  if (err) return res.status(400).json({ error: err })
  if (!displayName?.trim()) return res.status(400).json({ error: 'Display name is required' })
  if (!walletAddress)        return res.status(400).json({ error: 'Wallet address is required' })

  const now   = Math.floor(Date.now() / 1000)
  const color = deriveColor(username.toLowerCase())

  try {
    const existing = await db.run(
      sql`SELECT wallet_address FROM profiles
          WHERE LOWER(username) = ${username.toLowerCase()} LIMIT 1`
    )
    const r = parseRows(existing)
    if (r.length) return res.status(409).json({ error: 'Username already taken' })

    await db.run(
      sql`INSERT INTO profiles
          (wallet_address, username, display_name, bio,
           twitter_handle, telegram_handle, avatar_color,
           show_socials, created_at, updated_at)
          VALUES
          (${walletAddress.toLowerCase()}, ${username.toLowerCase()},
           ${displayName.trim()}, ${bio?.trim() || null},
           ${twitterHandle?.replace('@','').trim() || null},
           ${telegramHandle?.replace('@','').trim() || null},
           ${color}, ${showSocials !== false ? 1 : 0},
           ${now}, ${now})`
    )
    res.status(201).json({ username: username.toLowerCase(), avatarColor: color })
  } catch (e: any) {
    if (e.message?.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Username already taken' })
    }
    res.status(500).json({ error: e.message })
  }
})

// PATCH /profile/:address update
router.patch('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  const {
    displayName, bio, twitterHandle, telegramHandle, showSocials,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE profiles SET
            display_name    = COALESCE(${displayName?.trim()  ?? null}, display_name),
            bio             = COALESCE(${bio?.trim()          ?? null}, bio),
            twitter_handle  = COALESCE(${twitterHandle?.replace('@','').trim() ?? null}, twitter_handle),
            telegram_handle = COALESCE(${telegramHandle?.replace('@','').trim() ?? null}, telegram_handle),
            show_socials    = COALESCE(${showSocials !== undefined ? (showSocials ? 1 : 0) : null}, show_socials),
            updated_at      = ${now}
          WHERE LOWER(wallet_address) = ${addr}`
    )
    res.json({ success: true })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

export default router
