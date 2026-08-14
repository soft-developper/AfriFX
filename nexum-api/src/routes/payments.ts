import { notifyInvoicePaid } from '../services/email/notifications'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { getCachedRates } from '../services/rateOracle'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normPayment(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], sender_address: r[1], recipient_address: r[2],
    amount: Number(r[3]), currency: r[4],
    local_currency: r[5], local_amount: r[6] ? Number(r[6]) : null,
    description: r[7], invoice_ref: r[8], memo_ref: r[9],
    status: r[10], arc_tx_hash: r[11],
    created_at: Number(r[12]), settled_at: r[13] ? Number(r[13]) : null,
  }
  return {
    ...r,
    amount: Number(r.amount),
    local_amount: r.local_amount ? Number(r.local_amount) : null,
  }
}

function genRef(): string {
  const date = new Date().toISOString().slice(0,10).replace(/-/g,'')
  const rand = Math.random().toString(36).slice(2,6).toUpperCase()
  return `PAY-${date}-${rand}`
}

// GET /payments?wallet=0x sent + received
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  const type   = req.query.type as string // 'sent' | 'received' | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = type === 'sent'
      ? await db.run(sql`SELECT * FROM payments WHERE LOWER(sender_address) = ${wallet} ORDER BY created_at DESC LIMIT 100`)
      : type === 'received'
      ? await db.run(sql`SELECT * FROM payments WHERE LOWER(recipient_address) = ${wallet} ORDER BY created_at DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM payments
          WHERE LOWER(sender_address) = ${wallet} OR LOWER(recipient_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 100`)
    res.json(parseRows(rows).map(normPayment))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /payments record a payment
router.post('/', async (req, res) => {
  const {
    senderAddress, recipientAddress, amount,
    currency = 'USDC', localCurrency, description,
    invoiceRef, arcTxHash,
  } = req.body

  if (!senderAddress || !recipientAddress || !amount) {
    return res.status(400).json({ error: 'senderAddress, recipientAddress, amount required' })
  }

  const id      = randomUUID()
  const memoRef = genRef()
  const now     = Math.floor(Date.now() / 1000)

  // Calculate local currency equivalent
  let localAmount: number | null = null
  if (localCurrency) {
    const rates = getCachedRates()
    const rate  = rates.find(r => r.pair === `${localCurrency}/USDC`)?.rate
    if (rate) localAmount = parseFloat((amount * rate).toFixed(2))
  }

  try {
    // Allow explicit status override (e.g. 'failed' for reverted txs)
    const paymentStatus = req.body.status === 'failed' ? 'failed'
      : arcTxHash ? 'settled' : 'pending'

    await db.run(
      sql`INSERT INTO payments
          (id, sender_address, recipient_address, amount, currency,
           local_currency, local_amount, description, invoice_ref,
           invoice_id, memo_ref, status, arc_tx_hash, created_at)
          VALUES
          (${id}, ${senderAddress.toLowerCase()}, ${recipientAddress.toLowerCase()},
           ${Number(amount)}, ${currency},
           ${localCurrency ?? null}, ${localAmount},
           ${description ?? null}, ${invoiceRef ?? null},
           ${req.body.invoiceId ?? null},
           ${memoRef}, ${paymentStatus},
           ${arcTxHash ?? null}, ${now})`
    )
    res.status(201).json({ id, memoRef })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /payments/:id/settle
router.patch('/:id/settle', async (req, res) => {
  const { arcTxHash } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE payments SET
            status      = 'settled',
            arc_tx_hash = COALESCE(${arcTxHash ?? null}, arc_tx_hash),
            settled_at  = ${now}
          WHERE id = ${req.params.id}`
    )

    // Fetch payment + invoice for email notification
    try {
      const pRows = await db.run(sql`
        SELECT p.*, i.creator_address, i.memo_ref as reference,
               i.local_currency, i.local_amount, i.id as invoice_id
        FROM payments p
        LEFT JOIN invoices i ON i.id = p.invoice_id OR i.memo_ref = p.invoice_ref
        WHERE p.id = ${req.params.id} LIMIT 1
      `)
      const _pr = parseRows(pRows)
      const _p  = _pr[0]
      if (_p && (_p.creator_address || _p[0])) {
        notifyInvoicePaid({
          creatorWallet: _p.creator_address ?? '',
          payerAddress:  _p.payer_address   ?? _p.sender_address ?? '',
          invoiceRef:    _p.reference        ?? _p.memo_ref ?? '',
          usdcAmount:    Number(_p.usdc_amount ?? _p.amount ?? 0),
          localAmount:   _p.local_amount ? Number(_p.local_amount) : undefined,
          localCcy:      _p.local_currency ?? undefined,
          invoiceId:     _p.invoice_id ?? _p.id ?? '',
          txHash:        arcTxHash ?? '',
        }).catch((err: any) => console.error('[Notify] invoice_paid:', err.message))
      }
    } catch {}

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /payments/report?wallet=0x&from=ts&to=ts settlement report data
router.get('/report', async (req, res) => {
  const wallet  = (req.query.wallet as string)?.toLowerCase()
  const fromTs  = Number(req.query.from ?? 0)
  const toTs    = Number(req.query.to   ?? Math.floor(Date.now() / 1000))
  if (!wallet)  return res.status(400).json({ error: 'wallet required' })

  try {
    // Payments sent
    const sentRows = await db.run(
      sql`SELECT * FROM payments
          WHERE LOWER(sender_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Payments received
    const recvRows = await db.run(
      sql`SELECT * FROM payments
          WHERE LOWER(recipient_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Invoices paid
    const invRows = await db.run(
      sql`SELECT * FROM invoices
          WHERE (LOWER(creator_address) = ${wallet} OR LOWER(payer_address) = ${wallet})
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Transactions (FX conversions)
    const txRows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )

    const sent     = parseRows(sentRows).map(normPayment)
    const received = parseRows(recvRows).map(normPayment)

    const totalSent     = sent.reduce((s, p) => s + p.amount, 0)
    const totalReceived = received.reduce((s, p) => s + p.amount, 0)

    res.json({
      summary: {
        totalSent:     parseFloat(totalSent.toFixed(2)),
        totalReceived: parseFloat(totalReceived.toFixed(2)),
        netFlow:       parseFloat((totalReceived - totalSent).toFixed(2)),
        sentCount:     sent.length,
        receivedCount: received.length,
      },
      payments: {
        sent,
        received,
      },
      invoices: parseRows(invRows),
      transactions: parseRows(txRows),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
