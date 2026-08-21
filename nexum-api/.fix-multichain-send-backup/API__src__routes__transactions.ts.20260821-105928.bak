import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /transactions?wallet=0x
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /transactions create
router.post('/', async (req, res) => {
  const {
    walletAddress, fromCurrency, toCurrency,
    fromAmount, toAmount, spreadFee, networkFee,
    arcTxHash, memoId, reference, corridorId, corridorStep,
  } = req.body

  const now = Math.floor(Date.now() / 1000)
  const id  = arcTxHash ?? `tx-${now}-${Math.random().toString(36).slice(2,8)}`

  try {
    await db.run(
      sql`INSERT OR IGNORE INTO transactions
          (id, wallet_address, from_currency, to_currency,
           from_amount, to_amount, spread_fee, network_fee,
           arc_tx_hash, memo_id, reference,
           corridor_id, corridor_step, status, created_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()}, ${fromCurrency}, ${toCurrency},
           ${fromAmount}, ${toAmount}, ${spreadFee ?? 0}, ${networkFee ?? 0.001},
           ${arcTxHash ?? null}, ${memoId ?? null}, ${reference ?? null},
           ${corridorId ?? null}, ${corridorStep ?? null}, 'pending', ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

/*
  PATCH /transactions/:hash, update status after on-chain confirmation.

  IMPORTANT DISTINCTION. A confirmed on-chain transfer means the USDC left the
  user's wallet. For a USDC to fiat conversion that is NOT the same as the
  conversion being SETTLED: settled should mean the recipient actually received
  their money, which happens later, via a payout provider.

  Calling that 'settled' told users their money had arrived when it had not.
  So an on-chain confirmation now records 'funded' for fiat-bound conversions,
  and only the payout completing marks them 'settled'. Callers can still pass an
  explicit status for other cases.
*/
router.patch('/:hash', async (req, res) => {
  const { status } = req.body
  const now        = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE transactions
          SET status     = ${status ?? 'funded'},
              settled_at = ${status === 'settled' ? now : null}
          WHERE arc_tx_hash = ${req.params.hash}
             OR id          = ${req.params.hash}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /transactions/ref/:ref
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions WHERE reference = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Not found' })
    res.json(r[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
