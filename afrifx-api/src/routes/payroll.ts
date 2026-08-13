import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID, createHash } from 'crypto'  // PHASE_7F: createHash for deterministic idempotency UUID

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normBatch(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], wallet_address: row[1], name: row[2],
      description: row[3], total_amount: Number(row[4]),
      currency: row[5], recipient_count: Number(row[6]),
      status: row[7], executed_at: row[8] ? Number(row[8]) : null,
      created_at: Number(row[9]),
      // dest_chain was added later via ALTER TABLE, so it lands at the end.
      // Older rows created before the migration have no value: default 'arc'.
      dest_chain: row[10] ?? 'arc',
    }
  }
  return {
    ...row,
    total_amount: Number(row.total_amount),
    recipient_count: Number(row.recipient_count),
    dest_chain: row.dest_chain ?? 'arc',
  }
}

function normRecipient(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], batch_id: row[1], name: row[2],
      wallet_address: row[3], amount: Number(row[4]),
      currency: row[5], status: row[6],
      tx_hash: row[7], memo_ref: row[8], created_at: Number(row[9]),
    }
  }
  return { ...row, amount: Number(row.amount) }
}

// GET /payroll/batches?wallet=0x
router.get('/batches', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM payroll_batches
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 20`
    )
    res.json(parseRows(rows).map(normBatch))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /payroll/batches create batch
router.post('/batches', async (req, res) => {
  const { walletAddress, name, description, recipients, currency = 'USDC', destChain = 'arc' } = req.body
  if (!walletAddress || !name || !recipients?.length) {
    return res.status(400).json({ error: 'walletAddress, name and recipients required' })
  }

  // Only the chains AfriFX settles on are valid payout targets. Anything
  // else is rejected rather than stored and failing silently at execute time.
  const ALLOWED_CHAINS = ['arc']  // PHASE_7H: Arc-only until a real cross-chain payout path exists
  const chain = String(destChain).toLowerCase()
  if (!ALLOWED_CHAINS.includes(chain)) {
    return res.status(400).json({ error: `Unsupported payout chain: ${destChain}` })
  }

  const batchId     = randomUUID()
  const now         = Math.floor(Date.now() / 1000)
  const totalAmount = recipients.reduce((s: number, r: any) => s + Number(r.amount), 0)

  try {
    await db.run(
      sql`INSERT INTO payroll_batches
          (id, wallet_address, name, description, total_amount,
           currency, recipient_count, created_at, dest_chain)
          VALUES
          (${batchId}, ${walletAddress.toLowerCase()}, ${name},
           ${description ?? null}, ${totalAmount}, ${currency},
           ${recipients.length}, ${now}, ${chain})`
    )

    for (const r of recipients) {
      const ref = `PAY-${new Date().toISOString().slice(0,10).replace(/-/g,'')}-${Math.random().toString(36).slice(2,6).toUpperCase()}`
      await db.run(
        sql`INSERT INTO payroll_recipients
            (id, batch_id, name, wallet_address, amount, currency, memo_ref, created_at)
            VALUES
            (${randomUUID()}, ${batchId}, ${r.name ?? null},
             ${r.walletAddress.toLowerCase()}, ${Number(r.amount)},
             ${currency}, ${ref}, ${now})`
      )
    }

    res.status(201).json({ id: batchId, totalAmount, recipientCount: recipients.length })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /payroll/batches/:id batch + recipients
router.get('/batches/:id', async (req, res) => {
  try {
    const batchRows = await db.run(
      sql`SELECT * FROM payroll_batches WHERE id = ${req.params.id} LIMIT 1`
    )
    const batches = parseRows(batchRows)
    if (!batches.length) return res.status(404).json({ error: 'Not found' })

    const recipientRows = await db.run(
      sql`SELECT * FROM payroll_recipients
          WHERE batch_id = ${req.params.id}
          ORDER BY created_at ASC`
    )

    res.json({
      ...normBatch(batches[0]),
      recipients: parseRows(recipientRows).map(normRecipient),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /payroll/recipients/:id update recipient status + tx_hash
router.patch('/recipients/:id', async (req, res) => {
  const { status, txHash } = req.body
  try {
    await db.run(
      sql`UPDATE payroll_recipients SET
            status  = COALESCE(${status ?? null}, status),
            tx_hash = COALESCE(${txHash ?? null}, tx_hash)
          WHERE id = ${req.params.id}`
    )
    // If all recipients sent, mark batch complete
    const rid = req.params.id
    const recRows = await db.run(sql`SELECT batch_id FROM payroll_recipients WHERE id = ${rid} LIMIT 1`)
    const rr = parseRows(recRows)
    if (rr.length) {
      const batchId = rr[0].batch_id ?? rr[0][1]
      const pendingRows = await db.run(
        sql`SELECT COUNT(*) as cnt FROM payroll_recipients
            WHERE batch_id = ${batchId} AND status = 'pending'`
      )
      const pr = parseRows(pendingRows)
      const pending = Number(pr[0]?.cnt ?? pr[0]?.[0] ?? 0)
      if (pending === 0) {
        await db.run(
          sql`UPDATE payroll_batches SET
                status      = 'completed',
                executed_at = ${Math.floor(Date.now() / 1000)}
              WHERE id = ${batchId}`
        )
      }
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /payroll/batches/:id delete draft
router.delete('/batches/:id', async (req, res) => {
  try {
    await db.run(sql`DELETE FROM payroll_recipients WHERE batch_id = ${req.params.id}`)
    await db.run(sql`DELETE FROM payroll_batches WHERE id = ${req.params.id} AND status = 'draft'`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── PAYOUT ENGINE (hybrid custody, Phase 7c) ────────────────
//
// Pay a batch's recipients from the platform float, backend-signed (no user
// present). Kicked off by /execute, which returns immediately; the client
// polls GET /payroll/batches/:id to watch per-recipient progress.
//
// THREE RULES THAT KEEP MONEY SAFE
//   1. BALANCE GATE: refuse to start a batch the float can't cover, BEFORE
//      paying anyone - so a batch never half-pays and runs dry.
//   2. IDEMPOTENT PER RECIPIENT: the key is `${batchId}:${recipientId}`, so a
//      retry or double-execute can't pay anyone twice (Circle dedupes it).
//   3. RESUMABLE: only 'pending' recipients are paid; 'paid' ones are skipped.
//      If the process restarts mid-run, re-executing finishes the rest.

// Guard so the same batch isn't worked by two overlapping runs in one process.
const runningBatches = new Set<string>()

// PHASE_7F: deterministic UUID from an arbitrary string. Circle's SDK requires
// idempotencyKey to be a valid UUID; a composite like `${batchId}:${recipientId}`
// is rejected client-side ("API parameter invalid"). We hash the composite key
// (SHA-1) and format it as a UUIDv5-style value: SAME input => SAME UUID, so a
// retry of the same payout still dedupes exactly-once, and the SDK accepts it.
function stableUuid(input: string): string {
  const h = createHash('sha1').update(input).digest('hex')  // 40 hex chars
  // Format 32 of them as 8-4-4-4-12, with version (5) and variant bits set.
  const b = h.slice(0, 32).split('')
  b[12] = '5'                                   // version 5
  const variant = (parseInt(b[16], 16) & 0x3 | 0x8).toString(16)
  b[16] = variant                               // variant 10xx
  const u = b.join('')
  return `${u.slice(0,8)}-${u.slice(8,12)}-${u.slice(12,16)}-${u.slice(16,20)}-${u.slice(20,32)}`
}

// PHASE_7G active
async function runBatchPayout(batchId: string): Promise<void> {
  if (runningBatches.has(batchId)) return
  runningBatches.add(batchId)
  try {
    const { sendUsdc, getPayoutStatus } = await import('../services/platformDisbursement')  // PHASE_7G

    const pending = parseRows(await db.run(sql`
      SELECT id, wallet_address, amount, memo_ref
      FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status = 'pending'`))

    for (const r of pending) {
      const recipientId = r.id ?? r[0]
      const toAddress   = r.wallet_address ?? r[1]
      const amount      = Number(r.amount ?? r[2])
      const memoRef     = r.memo_ref ?? r[3] ?? undefined

      try {
        await db.run(sql`
          UPDATE payroll_recipients SET status = 'processing'
          WHERE id = ${recipientId} AND status = 'pending'`)

        const result = await sendUsdc({
          walletId:           process.env.PAYROLL_DISBURSEMENT_WALLET_ID as string,
          destinationAddress: String(toAddress),
          amount,
          // Stable key => exactly-once even if this runs twice.
          idempotencyKey:     stableUuid(`${batchId}:${recipientId}`),  // PHASE_7F: valid, stable UUID
          refId:              memoRef ? String(memoRef) : undefined,
        })

        await db.run(sql`
          UPDATE payroll_recipients
          SET status = 'paid', tx_hash = ${result.txHash ?? result.id}
          WHERE id = ${recipientId}`)
      } catch (err: any) {
        // One recipient failing must not abort the batch; mark it and go on.
        // Capture Circle's ACTUAL message so failures are diagnosable: log it
        // (Render logs) and stash a short form in tx_hash (no error column yet)
        // prefixed with "ERR:" so the UI/DB can show why.
        const reason = String(err?.response?.data?.message ?? err?.message ?? 'unknown error').slice(0, 180)
        console.error(`[payout] batch=${batchId} recipient=${recipientId} FAILED:`, reason)
        await db.run(sql`
          UPDATE payroll_recipients SET status = 'failed', tx_hash = ${'ERR: ' + reason}
          WHERE id = ${recipientId}`).catch(() => {})
      }
    }

    // PHASE_7G: backfill real on-chain hashes. The send loop above recorded
    // the Circle tx id (0x… hash isn't known at send time). Now poll each paid
    // recipient briefly and replace tx_hash with the real hash once Circle has
    // it. Bounded so a slow confirmation can't hang the batch; anything not
    // ready keeps its id and a later re-execute backfills it.
    const paidRows = parseRows(await db.run(sql`
      SELECT id, tx_hash FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status = 'paid'`))
    for (const pr of paidRows) {
      const rid    = pr.id ?? pr[0]
      const stored = String(pr.tx_hash ?? pr[1] ?? '')
      if (stored.startsWith('0x')) continue
      if (stored.startsWith('ERR:')) continue
      const circleTxId = stored
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const st = await getPayoutStatus(circleTxId)
          if (st.txHash) {
            await db.run(sql`
              UPDATE payroll_recipients SET tx_hash = ${st.txHash}
              WHERE id = ${rid}`).catch(() => {})
            break
          }
          if (['FAILED', 'DENIED', 'CANCELLED'].includes(st.state)) break
        } catch { /* transient - retry */ }
        await new Promise(r => setTimeout(r, 3000))
      }
    }

    // Settle the batch status from the actual recipient outcomes.
    const counts = parseRows(await db.run(sql`
      SELECT status, COUNT(*) AS c FROM payroll_recipients
      WHERE batch_id = ${batchId} GROUP BY status`))
    const by: Record<string, number> = {}
    for (const row of counts) by[String(row.status ?? row[0])] = Number(row.c ?? row[1])

    const stillPending = (by['pending'] ?? 0) + (by['processing'] ?? 0)
    const failed       = by['failed'] ?? 0
    const finalStatus  =
      stillPending > 0 ? 'processing'
      : failed > 0     ? 'partial'
      :                  'completed'

    await db.run(sql`
      UPDATE payroll_batches
      SET status = ${finalStatus},
          executed_at = ${Math.floor(Date.now() / 1000)}
      WHERE id = ${batchId}`)
  } finally {
    runningBatches.delete(batchId)
  }
}

// POST /payroll/batches/:id/execute
//
// Start (or resume) paying a batch from the float. Validates + balance-gates,
// flips the batch to 'processing', kicks off the payout in the background, and
// returns immediately. Poll GET /payroll/batches/:id for progress.
router.post('/batches/:id/execute', async (req, res) => {
  const batchId  = req.params.id
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })

  try {
    const batchRows = parseRows(await db.run(sql`
      SELECT id, status FROM payroll_batches WHERE id = ${batchId} LIMIT 1`))
    if (!batchRows.length) return res.status(404).json({ error: 'Batch not found' })
    const status = String(batchRows[0].status ?? batchRows[0][1])
    if (status === 'completed') return res.status(400).json({ error: 'Batch already completed' })

    // Sum only what's still owed (pending), so a resume gates on the remainder.
    const owedRows = parseRows(await db.run(sql`
      SELECT COALESCE(SUM(amount), 0) AS owed FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status IN ('pending', 'processing')`))
    const owed = Number(owedRows[0]?.owed ?? owedRows[0]?.[0] ?? 0)
    if (owed <= 0) return res.status(400).json({ error: 'Nothing left to pay in this batch' })

    // RULE 1 - balance gate: never start what the float can't finish.
    // PHASE_7D: on Arc gas is paid in USDC from this same wallet, so the float
    // must cover payouts PLUS a little gas. Require owed + a small buffer so a
    // batch funded to the exact cent can't pass here then fail the last payout
    // on gas. Buffer is tiny on Arc testnet; tune via CIRCLE_GAS_BUFFER_USDC.
    const gasBuffer = Number(process.env.CIRCLE_GAS_BUFFER_USDC ?? '0.05')
    const required  = owed + gasBuffer
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    if (balance < required) {
      return res.status(400).json({
        error: `Float balance (${balance} USDC) is below the ${required} USDC needed (${owed} owed + ${gasBuffer} gas headroom) for this batch. Top up the float first.`,
        code:  'insufficient_float',
        balance, owed, gasBuffer, required,
      })
    }

    await db.run(sql`UPDATE payroll_batches SET status = 'processing' WHERE id = ${batchId}`)

    // Fire and forget: the client polls the batch for progress.
    runBatchPayout(batchId).catch(() => {})

    res.json({ status: 'processing', owed, balance })
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

// GET /payroll/disbursement/status
//
// Reports whether the platform disbursement wallet (Phase 7a, MPC) is
// configured and its current USDC balance. Used to verify provisioning and,
// later, to check a batch can be funded. Read-only; exposes no secrets.
router.get('/disbursement/status', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) {
    return res.json({ configured: false, reason: 'PAYROLL_DISBURSEMENT_WALLET_ID not set' })
  }
  try {
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    res.json({ configured: true, walletId, balance })
  } catch (err: any) {
    res.status(502).json({ configured: true, error: err.message })
  }
})

// GET /payroll/disbursement/address
//
// The address employers send USDC to when topping up the float. Read from the
// live wallet so it can never drift from what was provisioned.
router.get('/disbursement/address', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })
  try {
    const { getDisbursementAddress } = await import('../services/platformDisbursement')
    const address = await getDisbursementAddress(walletId)
    res.json({ address })
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

// POST /payroll/disbursement/fund   { funderAddress, amount, txHash }
//
// Record an employer top-up of the reusable float. The employer has already
// signed a USDC transfer to the disbursement address (client side); here we
// log it and confirm it by re-reading the live wallet balance. We do NOT trust
// the client's word that it landed - we check Circle.
router.post('/disbursement/fund', async (req, res) => {
  const { funderAddress, amount, txHash } = req.body ?? {}
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID

  if (!walletId)       return res.status(400).json({ error: 'Disbursement wallet not configured' })
  if (!funderAddress)  return res.status(400).json({ error: 'funderAddress is required' })
  if (!(Number(amount) > 0)) return res.status(400).json({ error: 'A positive amount is required' })

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    // Record the intent first (audit trail), then confirm against the chain.
    await db.run(sql`
      INSERT INTO payroll_disbursement_funding
        (id, funder_address, amount, tx_hash, status, created_at)
      VALUES (${id}, ${String(funderAddress)}, ${Number(amount)},
              ${txHash ? String(txHash) : null}, 'pending', ${now})`)

    // Confirm by reading the live balance. We don't assert an exact delta
    // (fees, timing, concurrent tops make that brittle) - a balance at least
    // as large as this top-up is sufficient evidence it landed.
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)

    const landed = balance >= Number(amount)
    if (landed) {
      await db.run(sql`
        UPDATE payroll_disbursement_funding
        SET status = 'confirmed', confirmed_at = ${now}
        WHERE id = ${id}`)
    }

    res.json({ id, status: landed ? 'confirmed' : 'pending', balance })
  } catch (err: any) {
    await db.run(sql`
      UPDATE payroll_disbursement_funding SET status = 'failed' WHERE id = ${id}`)
      .catch(() => {})
    res.status(502).json({ error: err.message })
  }
})

// GET /payroll/disbursement/funding   top-up history (newest first)
router.get('/disbursement/funding', async (_req, res) => {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT id, funder_address, amount, tx_hash, status, created_at, confirmed_at
      FROM payroll_disbursement_funding
      ORDER BY created_at DESC
      LIMIT 100`))
    res.json({ funding: rows })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
