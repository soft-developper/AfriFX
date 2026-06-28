import { Router }   from 'express'
import { db }       from '../db/client'
import { sql }      from 'drizzle-orm'
import { randomUUID } from 'crypto'
import multer       from 'multer'
import { uploadBuffer } from '../lib/cloudinary'

const router = Router()

// Multer — store in memory (we pipe to Cloudinary immediately)
const upload = multer({
  storage: multer.memoryStorage(),
  limits:  { fileSize: 10 * 1024 * 1024 }, // 10 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'image/jpeg','image/png','image/webp','image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'video/mp4','video/webm',
    ]
    cb(null, allowed.includes(file.mimetype))
  },
})

// ── Access control helper ─────────────────────────────────
async function verifyAccess(offerId: string, wallet: string): Promise<'maker'|'taker'|null> {
  try {
    const rows = await db.run(
      sql`SELECT maker_address, taker_address FROM p2p_offers WHERE id = ${offerId} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return null
    const o     = r[0]
    const maker = (o.maker_address ?? o[0] ?? '').toLowerCase()
    const taker = (o.taker_address ?? o[1] ?? '').toLowerCase()
    const w     = wallet.toLowerCase()
    if (w === maker) return 'maker'
    if (w === taker) return 'taker'
    return null
  } catch { return null }
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

function normalizeMsg(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], offer_id: row[1], sender: row[2],
      content: row[3], media_url: row[4], media_type: row[5],
      msg_type: row[6], quick_action: row[7],
      read_maker: Number(row[8]), read_taker: Number(row[9]),
      created_at: Number(row[10]),
    }
  }
  return { ...row, read_maker: Number(row.read_maker), read_taker: Number(row.read_taker) }
}

// In-memory typing store
const typingMap = new Map<string, number>()

// ── POST /chat/:offerId/upload ────────────────────────────
// Multer parses multipart, we upload to Cloudinary from backend
router.post('/:offerId/upload', upload.single('file'), async (req, res) => {
  const { offerId } = req.params
  const wallet      = req.body.wallet as string

  if (!wallet)   return res.status(400).json({ error: 'wallet required' })
  if (!req.file) return res.status(400).json({ error: 'No file provided' })

  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    return res.status(500).json({ error: 'Cloudinary not configured on server' })
  }

  try {
    const result = await uploadBuffer(
      req.file.buffer,
      req.file.originalname,
      req.file.mimetype,
      offerId,
    )
    res.json(result)
  } catch (err: any) {
    console.error('[Cloudinary] Upload failed:', err.message)
    res.status(500).json({ error: 'Upload failed: ' + err.message })
  }
})

// ── GET /chat/:offerId ────────────────────────────────────
router.get('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  const after  = Number(req.query.after ?? 0)

  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })

  try {
    const rows = await db.run(
      sql`SELECT * FROM messages
          WHERE offer_id   = ${offerId}
            AND created_at > ${after}
          ORDER BY created_at ASC LIMIT 100`
    )
    const msgs = parseRows(rows).map(normalizeMsg)

    // Mark messages from the other party as read
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    await db.run(
      sql`UPDATE messages SET ${sql.raw(field)} = 1
          WHERE offer_id = ${offerId} AND sender != ${wallet}`
    ).catch(() => {})

    res.json({ messages: msgs, role })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── GET /chat/:offerId/unread ─────────────────────────────
router.get('/:offerId/unread', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ count: 0 })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.json({ count: 0 })
  try {
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    const rows  = await db.run(
      sql`SELECT COUNT(*) as cnt FROM messages
          WHERE offer_id = ${offerId}
            AND sender   != ${wallet}
            AND ${sql.raw(field)} = 0`
    )
    const r = parseRows(rows)
    res.json({ count: Number(r[0]?.cnt ?? r[0]?.[0] ?? 0) })
  } catch { res.json({ count: 0 }) }
})

// ── POST /chat/:offerId ───────────────────────────────────
router.post('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const { wallet, content, mediaUrl, mediaType, msgType = 'text', quickAction } = req.body

  if (!wallet)                return res.status(400).json({ error: 'wallet required' })
  if (!content && !mediaUrl)  return res.status(400).json({ error: 'content or mediaUrl required' })

  const role = await verifyAccess(offerId, wallet.toLowerCase())
  if (!role) return res.status(403).json({ error: 'Access denied' })

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO messages
          (id, offer_id, sender, content, media_url, media_type,
           msg_type, quick_action, created_at)
          VALUES
          (${id}, ${offerId}, ${wallet.toLowerCase()},
           ${content ?? null}, ${mediaUrl ?? null}, ${mediaType ?? null},
           ${msgType}, ${quickAction ?? null}, ${now})`
    )
    res.status(201).json({
      id, offer_id: offerId, sender: wallet.toLowerCase(),
      content, media_url: mediaUrl, media_type: mediaType,
      msg_type: msgType, quick_action: quickAction,
      read_maker: 0, read_taker: 0, created_at: now,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── POST /chat/:offerId/system ────────────────────────────
router.post('/:offerId/system', async (req, res) => {
  const { offerId }  = req.params
  const { content }  = req.body
  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`INSERT INTO messages (id, offer_id, sender, content, msg_type, created_at)
          VALUES (${id}, ${offerId}, 'system', ${content}, 'system', ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── POST /chat/:offerId/typing ────────────────────────────
router.post('/:offerId/typing', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const role = await verifyAccess(req.params.offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })
  typingMap.set(`${req.params.offerId}-${role}`, Date.now())
  res.json({ ok: true })
})

// ── GET /chat/:offerId/typing ─────────────────────────────
router.get('/:offerId/typing', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ typing: false })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.json({ typing: false })
  const other     = role === 'maker' ? 'taker' : 'maker'
  const lastTyped = typingMap.get(`${offerId}-${other}`) ?? 0
  res.json({ typing: Date.now() - lastTyped < 3000 })
})

export default router
