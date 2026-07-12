import { Router }     from 'express'
import { notifyDisputeRaised, notifyAdminsOfNewDispute, notifyDisputeAccepted, notifyAdminMessage } from '../services/email/notifications'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import multer         from 'multer'
import { uploadBuffer } from '../lib/cloudinary'

const router = Router()

// Multer — hold the file in memory, then stream it to Cloudinary
const upload = multer({
  storage: multer.memoryStorage(),
  limits:  { fileSize: 10 * 1024 * 1024 }, // 10 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'image/jpeg', 'image/png', 'image/webp', 'image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ]
    cb(null, allowed.includes(file.mimetype))
  },
})

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /disputes?wallet=0x — disputes involving a wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(sql`
      SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE LOWER(o.maker_address) = ${wallet}
         OR LOWER(o.taker_address) = ${wallet}
      ORDER BY d.created_at DESC LIMIT 50
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/offer/:offerId — dispute for a specific offer
router.get('/offer/:offerId', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM disputes WHERE offer_id = ${req.params.offerId} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes — raise a dispute
// dispute_type: 'maker_not_received' | 'maker_silent'
// raised_by_role: 'maker' | 'taker'
router.post('/', async (req, res) => {
  const {
    offerId, raisedBy, reason,
    disputeType = 'maker_not_received',
    raisedByRole = 'taker',
  } = req.body

  if (!offerId || !raisedBy) {
    return res.status(400).json({ error: 'offerId and raisedBy required' })
  }

  const now = Math.floor(Date.now() / 1000)
  // Auto-release 24h from now if dispute is maker_silent
  const autoReleaseAt = null // No auto-release when dispute raised — admin must resolve

  try {
    // Check offer exists and is in accepted state
    const offerRows = await db.run(sql`
      SELECT id, status, taker_confirmed, maker_confirmed,
             maker_address, taker_address
      FROM p2p_offers WHERE id = ${offerId} LIMIT 1
    `)
    const offers = parseRows(offerRows)
    if (!offers.length) return res.status(404).json({ error: 'Offer not found' })

    const offer = offers[0]
    const offerStatus    = offer.status         ?? offer[1]
    const takerConfirmed = Number(offer.taker_confirmed ?? offer[3])
    const makerAddress   = (offer.maker_address ?? offer[5])?.toLowerCase()
    const takerAddress   = (offer.taker_address ?? offer[6])?.toLowerCase()
    const raisedByLower  = raisedBy.toLowerCase()

    // Validate: offer must be accepted
    if (offerStatus !== 'accepted') {
      return res.status(400).json({ error: 'Can only dispute accepted offers' })
    }

    // Validate: taker must have confirmed sending before any dispute
    if (!takerConfirmed) {
      return res.status(400).json({ error: 'Taker must confirm sending before raising a dispute' })
    }

    // Validate: wallet must be involved
    if (raisedByLower !== makerAddress && raisedByLower !== takerAddress) {
      return res.status(403).json({ error: 'Not involved in this offer' })
    }

    // Check no existing open dispute
    const existRows = await db.run(sql`
      SELECT id FROM disputes
      WHERE offer_id = ${offerId} AND status = 'open' LIMIT 1
    `)
    if (parseRows(existRows).length) {
      return res.status(400).json({ error: 'Dispute already open for this offer' })
    }

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO disputes
        (id, offer_id, raised_by, reason, status,
         dispute_type, raised_by_role, auto_release_at,
         auto_settle_at, created_at)
      VALUES
        (${id}, ${offerId}, ${raisedByLower}, ${reason ?? ''},
         'open', ${disputeType}, ${raisedByRole},
         ${autoReleaseAt},
         ${now + 86400}, ${now})
    `)

    // Mark offer as disputed
    await db.run(sql`
      UPDATE p2p_offers SET dispute_raised = 1, updated_at = ${now}
      WHERE id = ${offerId}
    `)

    // Determine other party
    const otherPartyWallet = raisedByLower === makerAddress ? takerAddress : makerAddress

    // Fire notification (non-blocking)
    // Alert all admins with resolve_disputes permission
    notifyAdminsOfNewDispute({
      raisedByWallet: raisedByLower,
      raisedByRole:   raisedByRole as 'maker' | 'taker',
      disputeType:    disputeType as 'maker_silent' | 'maker_not_received',
      usdcAmount:     Number(offer.usdc_amount ?? 0),
      localAmount:    Number(offer.local_amount ?? 0),
      localCcy:       offer.local_currency ?? '',
      disputeId:      id,
    }).catch((err: any) => console.error('[Notify] admin_alert:', err.message))

    notifyDisputeRaised({
      raisedByWallet:   raisedByLower,
      otherPartyWallet: otherPartyWallet ?? '',
      raisedByRole:     raisedByRole as 'maker' | 'taker',
      disputeType:      disputeType as 'maker_silent' | 'maker_not_received',
      offerId,
      disputeId:        id,
    }).catch(err => console.error('[Notify] dispute_raised failed:', err.message))

    res.status(201).json({ id, autoReleaseAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/admin/all — admin: all disputes with offer details
router.get('/admin/all', async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = await db.run(sql`
      SELECT d.*,
             o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status,
             o.taker_confirmed, o.maker_confirmed
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      ${status ? sql`WHERE d.status = ${status}` : sql``}
      ORDER BY d.created_at DESC LIMIT 100
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /disputes/:id/resolve — admin resolves dispute
// resolution: 'release_to_taker' | 'refund_maker' | 'escalate'
router.patch('/:id/resolve', async (req, res) => {
  const { resolution, resolvedBy, notes } = req.body
  if (!resolution || !resolvedBy) {
    return res.status(400).json({ error: 'resolution and resolvedBy required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // Get dispute + offer
    const dRows = await db.run(sql`
      SELECT d.*, o.id as oid FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE d.id = ${req.params.id} LIMIT 1
    `)
    const dr = parseRows(dRows)
    if (!dr.length) return res.status(404).json({ error: 'Dispute not found' })
    const dispute  = dr[0]
    const offerId  = dispute.offer_id ?? dispute[1]

    // Update dispute
    await db.run(sql`
      UPDATE disputes SET
        status      = 'resolved',
        resolution_type = ${resolution},
        admin_resolved_by = ${resolvedBy},
        admin_notes = ${notes ?? null},
        admin_resolved_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Count this resolution against the resolver's active duty session (for the
    // session log the general admin reviews). No-op if they aren't on duty
    // (e.g. super admin, or a sub-admin finishing a dispute after their window).
    await db.run(sql`
      UPDATE admin_duty_sessions
      SET disputes_resolved = COALESCE(disputes_resolved, 0) + 1, updated_at = ${now}
      WHERE admin_name = ${resolvedBy} AND status = 'on_duty'`)

    // Update offer based on resolution
    if (resolution === 'release_to_taker') {
      // Mark maker_confirmed so p2pReleaseWatcher picks it up
      await db.run(sql`
        UPDATE p2p_offers SET
          maker_confirmed = 1,
          updated_at      = ${now}
        WHERE id = ${offerId}
      `)
    } else if (resolution === 'refund_maker') {
      // Cancel offer → p2pReleaseWatcher Job1 handles refund
      await db.run(sql`
        UPDATE p2p_offers SET
          status     = 'cancelled',
          updated_at = ${now}
        WHERE id = ${offerId}
      `)
    }

    res.json({ success: true, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router

// ── Dispute Assignment ─────────────────────────────────────

// POST /disputes/:id/accept — admin accepts to handle dispute
// GATED: only a sub-admin who is ON DUTY (inside their scheduled working hours
// AND has clicked "resume duty") may accept. Super admins bypass the gate.
router.post('/:id/accept', async (req, res) => {
  const { adminId, adminName } = req.body
  if (!adminId || !adminName) {
    return res.status(400).json({ error: 'adminId and adminName required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // ── Duty gate ──────────────────────────────────────────
    const roleRows = await db.run(
      sql`SELECT role FROM admins WHERE id = ${adminId} LIMIT 1`)
    const rr   = parseRows(roleRows)[0]
    const role = rr ? (Array.isArray(rr) ? rr[0] : rr.role) : null

    if (role !== 'super_admin') {
      const { isOnDuty } = await import('../lib/duty')
      const duty = await isOnDuty(adminId)
      if (!duty.onDuty) {
        return res.status(403).json({
          error: duty.reason ?? 'You must be on duty to accept a dispute',
          code:  'not_on_duty',
        })
      }
    }

    // Check not already assigned
    const existing = await db.run(sql`
      SELECT id FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    if (parseRows(existing).length) {
      return res.status(400).json({ error: 'Dispute already accepted by another admin' })
    }

    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_assignments (id, dispute_id, admin_id, admin_name, accepted_at)
      VALUES (${id}, ${req.params.id}, ${adminId}, ${adminName}, ${now})
    `)

    // Count this acceptance against the admin's current duty session (for the log).
    await db.run(sql`
      UPDATE admin_duty_sessions
      SET disputes_accepted = COALESCE(disputes_accepted, 0) + 1, updated_at = ${now}
      WHERE admin_id = ${adminId} AND status = 'on_duty'`)

    // Update dispute status to 'in_review'
    await db.run(sql`
      UPDATE disputes SET status = 'in_review', updated_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Fetch offer_id from dispute
    const dRows = await db.run(sql`SELECT offer_id FROM disputes WHERE id = ${req.params.id} LIMIT 1`)
    const dr = parseRows(dRows)[0]

    if (dr) {
      notifyDisputeAccepted({
        disputeId: req.params.id,
        offerId:   dr.offer_id ?? dr[0],
        adminName,
      }).catch((err: any) => console.error('[Notify] dispute_accepted:', err.message))
    }

    res.json({ success: true, adminName })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/:id/assignment — get assigned admin for a dispute
router.get('/:id/assignment', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Dispute Messages ───────────────────────────────────────

// GET /disputes/:id/messages?viewerType=admin|maker|taker
router.get('/:id/messages', async (req, res) => {
  const viewerType = req.query.viewerType as string ?? 'user'
  const isAdmin    = viewerType === 'admin'
  try {
    // Admins see all messages; users only see non-admin-only messages
    const rows = await db.run(
      isAdmin
        ? sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`
        : sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} AND admin_only = 0 ORDER BY created_at ASC`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages — send a message
router.post('/:id/messages', async (req, res) => {
  const { senderId, senderType, senderName, content, adminOnly = 0 } = req.body
  if (!senderId || !senderType || !content) {
    return res.status(400).json({ error: 'senderId, senderType, content required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType},
         ${senderName ?? null}, ${content}, ${adminOnly ? 1 : 0}, ${now})
    `)

    // If admin sent a message, notify both parties (rate-limited)
    if (senderType === 'admin' && !adminOnly) {
      const dRows = await db.run(sql`
        SELECT o.id as offer_id, o.maker_address, o.taker_address
        FROM disputes d
        JOIN p2p_offers o ON o.id = d.offer_id
        WHERE d.id = ${req.params.id} LIMIT 1
      `)
      const d = parseRows(dRows)[0]
      if (d) {
        const offerId = d.offer_id ?? d[0]
        const parties = [d.maker_address ?? d[1], d.taker_address ?? d[2]].filter(Boolean)
        for (const wallet of parties) {
          notifyAdminMessage({
            recipientWallet: wallet,
            adminName:       senderName ?? 'Admin',
            offerId,
            disputeId:       req.params.id,
          }).catch((err: any) => console.error('[Notify] admin_message:', err.message))
        }
      }
    }

    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages/document — upload a supporting document
// Accepts multipart form-data (field name "file"), stores it on Cloudinary,
// and records the resulting URL as an admin-only dispute message.
router.post('/:id/messages/document', upload.single('file'), async (req, res) => {
  const { senderId, senderType, senderName } = req.body
  if (!senderId) return res.status(400).json({ error: 'senderId required' })
  if (!req.file) return res.status(400).json({ error: 'No file provided' })

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    return res.status(500).json({ error: 'File storage is not configured on the server' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    const uploaded = await uploadBuffer(
      req.file.buffer,
      req.file.originalname,
      req.file.mimetype,
      `dispute-${req.params.id}`,
    )

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, is_document, doc_url, doc_name, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType ?? 'user'},
         ${senderName ?? null},
         'Supporting document submitted',
         1, ${uploaded.url}, ${uploaded.name}, 1, ${now})
    `)
    res.status(201).json({ id, docUrl: uploaded.url, docName: uploaded.name })
  } catch (err: any) {
    console.error('[Disputes] Document upload failed:', err.message)
    res.status(500).json({ error: 'Upload failed: ' + err.message })
  }
})

// GET /disputes/:id/archive — full archived dispute for super-admin audit
router.get('/:id/archive', async (req, res) => {
  try {
    const [disputeRows, msgRows, assignRows] = await Promise.all([
      db.run(sql`SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount, o.maker_address, o.taker_address FROM disputes d JOIN p2p_offers o ON o.id = d.offer_id WHERE d.id = ${req.params.id} LIMIT 1`),
      db.run(sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`),
      db.run(sql`SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1`),
    ])
    res.json({
      dispute:    parseRows(disputeRows)[0] ?? null,
      messages:   parseRows(msgRows),
      assignment: parseRows(assignRows)[0] ?? null,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})
