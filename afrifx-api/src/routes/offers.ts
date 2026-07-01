import { notifyTradeAccepted, notifyTradeCompleted } from '../services/email/notifications'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// GET /offers — only OPEN offers visible to everyone
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const type     = req.query.type     as string | undefined
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status = 'open'
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          ${type     ? sql`AND order_type = ${type}`         : sql``}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/my?wallet=0x… — maker + taker see ALL their offers
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id — returns offer but frontend enforces access control
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })
    res.json(offers[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers — create new offer
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount, localCurrency, localAmount,
    rateOffered, orderType, limitRate, makerTimerSeconds, arcTxHash,
  } = req.body
  const now      = Math.floor(Date.now() / 1000)
  const PERPETUAL = 9999999999
  try {
    await db.run(
      sql`INSERT OR IGNORE INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, order_type, limit_rate, maker_timer_seconds,
           arc_tx_hash, expires_at, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${orderType ?? 'market'}, ${limitRate ?? null},
           ${makerTimerSeconds ?? 1800}, ${arcTxHash ?? null},
           ${PERPETUAL}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) {
    console.error('[Offers] Insert error:', err.message)
    res.status(500).json({ error: err.message })
  }
})

// PATCH /offers/:id
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress, makerConfirmed, takerConfirmed,
    releaseTxHash, takerDeadline, makerDeadline,
    disputeRaised, disputeId,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status         ?? null}, status),
            taker_address   = COALESCE(${takerAddress   ? takerAddress.toLowerCase() : null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash  ?? null}, release_tx_hash),
            taker_deadline  = COALESCE(${takerDeadline  ?? null}, taker_deadline),
            maker_deadline  = COALESCE(${makerDeadline  ?? null}, maker_deadline),
            dispute_raised  = COALESCE(${disputeRaised  ?? null}, dispute_raised),
            dispute_id      = COALESCE(${disputeId      ?? null}, dispute_id),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    // Fetch offer data for email notification
    const _offerRows = await db.run(sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`)
    const _offerData = Array.isArray((_offerRows as any).rows) ? (_offerRows as any).rows[0] : (_offerRows as any)[0]
    // Fire email + in-app notification (non-blocking)
    if (_offerData) {
      notifyTradeAccepted({
        makerWallet: _offerData.maker_address ?? _offerData[1] ?? '',
        takerWallet: (req.body.takerAddress ?? '').toLowerCase(),
        usdcAmount:  Number(_offerData.usdc_amount  ?? _offerData[3]  ?? 0),
        localAmount: Number(_offerData.local_amount ?? _offerData[5]  ?? 0),
        localCcy:    _offerData.local_currency ?? _offerData[4] ?? '',
        offerId:     req.params.id,
      }).catch((err: any) => console.error('[Notify] trade_accepted:', err.message))
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers/:id/dispute
router.post('/:id/dispute', async (req, res) => {
  const { raisedBy, reason } = req.body
  const offerId      = req.params.id
  const now          = Math.floor(Date.now() / 1000)
  const disputeId    = randomUUID()
  const autoSettleAt = now + 86400
  try {
    await db.run(
      sql`INSERT INTO disputes (id, offer_id, raised_by, reason, auto_settle_at, created_at)
          VALUES (${disputeId}, ${offerId}, ${raisedBy.toLowerCase()},
                  ${reason ?? null}, ${autoSettleAt}, ${now})`
    )
    await db.run(
      sql`UPDATE p2p_offers
          SET dispute_raised = 1, dispute_id = ${disputeId}, updated_at = ${now}
          WHERE id = ${offerId}`
    )
    const offerRows = await db.run(sql`SELECT maker_address FROM p2p_offers WHERE id = ${offerId}`)
    const rows = Array.isArray((offerRows as any).rows) ? (offerRows as any).rows : []
    if (rows.length) {
      const maker = rows[0].maker_address ?? rows[0][0]
      await db.run(
        sql`UPDATE users SET dispute_warnings = dispute_warnings + 1
            WHERE LOWER(wallet_address) = ${maker.toLowerCase()}`
      ).catch(() => {})
    }
    res.status(201).json({ disputeId, autoSettleAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id/dispute
router.get('/:id/dispute', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM disputes WHERE offer_id = ${req.params.id}
          ORDER BY created_at DESC LIMIT 1`
    )
    const disputes = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!disputes.length) return res.status(404).json({ error: 'No dispute' })
    res.json(disputes[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})


// PATCH /offers/:id/accept — called by taker after tx confirms
// Forces DB update so detail page loads correctly
router.patch('/:id/accept', async (req, res) => {
  const { takerAddress, timerSeconds = 1800 } = req.body
  if (!takerAddress) return res.status(400).json({ error: 'takerAddress required' })

  const now          = Math.floor(Date.now() / 1000)
  const takerDeadline = now + Number(timerSeconds)

  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status         = 'accepted',
            taker_address  = ${takerAddress.toLowerCase()},
            taker_deadline = ${takerDeadline},
            updated_at     = ${now}
          WHERE id = ${req.params.id}
            AND status = 'open'`
    )
    res.json({ success: true, takerDeadline })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
