import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normRule(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], wallet_address: row[1], name: row[2],
      trigger_threshold: Number(row[3]),
      action_percent: row[4] != null ? Number(row[4]) : null,
      action_amount:  row[5] != null ? Number(row[5]) : null,
      target_currency: row[6], status: row[7],
      last_triggered: row[8] ? Number(row[8]) : null,
      created_at: Number(row[9]), updated_at: Number(row[10]),
    }
  }
  return {
    ...row,
    trigger_threshold: Number(row.trigger_threshold),
    action_percent:    row.action_percent != null ? Number(row.action_percent) : null,
    action_amount:     row.action_amount  != null ? Number(row.action_amount)  : null,
  }
}

// GET /treasury/rules?wallet=0x
router.get('/rules', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM treasury_rules
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC`
    )
    res.json(parseRows(rows).map(normRule))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /treasury/rules create rule
router.post('/rules', async (req, res) => {
  const {
    walletAddress, name,
    triggerThreshold, actionPercent, actionAmount,
    targetCurrency,
  } = req.body

  if (!walletAddress || !name || !triggerThreshold || !targetCurrency) {
    return res.status(400).json({ error: 'Missing required fields' })
  }

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO treasury_rules
          (id, wallet_address, name, trigger_threshold,
           action_percent, action_amount, target_currency,
           created_at, updated_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()}, ${name},
           ${triggerThreshold}, ${actionPercent ?? null}, ${actionAmount ?? null},
           ${targetCurrency}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /treasury/rules/:id toggle status / update
router.patch('/rules/:id', async (req, res) => {
  const { status, lastTriggered } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE treasury_rules SET
            status         = COALESCE(${status         ?? null}, status),
            last_triggered = COALESCE(${lastTriggered  ?? null}, last_triggered),
            updated_at     = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /treasury/rules/:id
router.delete('/rules/:id', async (req, res) => {
  try {
    await db.run(sql`DELETE FROM treasury_rules WHERE id = ${req.params.id}`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
