#!/bin/bash
# Run from ~/AfriFX:  bash fix-wallet-case.sh
set -e
echo "🔧  Fixing wallet address case sensitivity..."

# ============================================================
# FIX 1 — Backend: use LOWER() in all wallet queries
#          so case never matters
# ============================================================
cat > afrifx-api/src/routes/user.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { users, transactions } from '../db/schema'
import { eq, desc, sum, count, sql } from 'drizzle-orm'

const router = Router()

// GET /user/:address/stats
router.get('/:address/stats', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  const now  = Math.floor(Date.now() / 1000)
  const day  = 86400
  const thirtyDaysAgo = now - 30 * day
  const sevenDaysAgo  = now - 7  * day

  try {
    // Use LOWER() so case never causes a mismatch
    const [allTime] = await db
      .select({
        txCount:     count(),
        totalVolume: sum(transactions.fromAmount),
      })
      .from(transactions)
      .where(sql`LOWER(${transactions.walletAddress}) = ${addr}`)

    const [monthly] = await db
      .select({ volume: sum(transactions.fromAmount) })
      .from(transactions)
      .where(
        sql`LOWER(${transactions.walletAddress}) = ${addr}
          AND ${transactions.createdAt} >= ${thirtyDaysAgo}
          AND ${transactions.status} = 'settled'`
      )

    const weekly = await db
      .select({
        day:    sql<number>`CAST(${transactions.createdAt} / 86400 AS INTEGER)`,
        volume: sum(transactions.fromAmount),
        txs:    count(),
      })
      .from(transactions)
      .where(
        sql`LOWER(${transactions.walletAddress}) = ${addr}
          AND ${transactions.createdAt} >= ${sevenDaysAgo}`
      )
      .groupBy(sql`CAST(${transactions.createdAt} / 86400 AS INTEGER)`)
      .orderBy(sql`CAST(${transactions.createdAt} / 86400 AS INTEGER)`)

    const recent = await db
      .select()
      .from(transactions)
      .where(sql`LOWER(${transactions.walletAddress}) = ${addr}`)
      .orderBy(desc(transactions.createdAt))
      .limit(5)

    const pairBreakdown = await db
      .select({
        pair:   sql<string>`${transactions.fromCurrency} || '/' || ${transactions.toCurrency}`,
        txs:    count(),
        volume: sum(transactions.fromAmount),
      })
      .from(transactions)
      .where(sql`LOWER(${transactions.walletAddress}) = ${addr}`)
      .groupBy(sql`${transactions.fromCurrency} || '/' || ${transactions.toCurrency}`)
      .orderBy(desc(count()))
      .limit(5)

    // Build 7-day chart with day labels
    const dayLabels = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
    const todayDay  = Math.floor(now / day)
    const chartData = Array.from({ length: 7 }, (_, i) => {
      const d     = todayDay - (6 - i)
      const match = weekly.find(w => w.day === d)
      const date  = new Date(d * day * 1000)
      return {
        label:  dayLabels[date.getUTCDay()],
        volume: Number(match?.volume ?? 0),
        txs:    Number(match?.txs    ?? 0),
      }
    })

    res.json({
      allTime: {
        txCount:     Number(allTime?.txCount    ?? 0),
        totalVolume: Number(allTime?.totalVolume ?? 0),
      },
      monthly: { volume: Number(monthly?.volume ?? 0) },
      chartData,
      recent,
      pairBreakdown,
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /user/:address
router.get('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const [stats] = await db
      .select({ txCount: count(), volume: sum(transactions.toAmount) })
      .from(transactions)
      .where(sql`LOWER(${transactions.walletAddress}) = ${addr}`)

    res.json({
      walletAddress: addr,
      txCount:   Number(stats?.txCount ?? 0),
      volume30d: Number(stats?.volume  ?? 0),
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  user.ts — LOWER() on all wallet queries"

# ============================================================
# FIX 2 — Backend transactions route: lowercase wallet on save
#          so future inserts are always consistent
# ============================================================
cat > afrifx-api/src/routes/transactions.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { transactions } from '../db/schema'
import { eq, desc, sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import type { CreateTxBody } from '../types'

const router = Router()

// GET /transactions?wallet=0x…
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string | undefined)?.toLowerCase()
  try {
    const rows = await db
      .select()
      .from(transactions)
      .where(
        wallet
          ? sql`LOWER(${transactions.walletAddress}) = ${wallet}`
          : undefined
      )
      .orderBy(desc(transactions.createdAt))
      .limit(50)
    res.json(rows)
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /transactions/:hash
router.get('/:hash', async (req, res) => {
  try {
    const rows = await db
      .select()
      .from(transactions)
      .where(eq(transactions.id, req.params.hash))
      .limit(1)
    if (!rows.length) return res.status(404).json({ error: 'Not found' })
    res.json(rows[0])
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /transactions/ref/:reference
router.get('/ref/:reference', async (req, res) => {
  try {
    const rows = await db
      .select()
      .from(transactions)
      .where(eq(transactions.reference, req.params.reference))
      .limit(1)
    if (!rows.length) return res.status(404).json({ error: 'Not found' })
    res.json(rows[0])
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// POST /transactions
router.post('/', async (req, res) => {
  const body = req.body as CreateTxBody & {
    memoId?:      string
    reference?:   string
    corridorId?:  string
    corridorStep?: number
  }
  try {
    const id = body.arcTxHash ?? randomUUID()
    await db.insert(transactions).values({
      id,
      // Always store lowercase so queries are consistent
      walletAddress: body.walletAddress.toLowerCase(),
      fromCurrency:  body.fromCurrency,
      toCurrency:    body.toCurrency,
      fromAmount:    body.fromAmount,
      toAmount:      body.toAmount,
      spreadFee:     body.spreadFee,
      networkFee:    body.networkFee ?? 0.001,
      arcTxHash:     body.arcTxHash  ?? null,
      memoId:        body.memoId     ?? null,
      reference:     body.reference  ?? null,
      corridorId:    body.corridorId ?? null,
      corridorStep:  body.corridorStep ?? null,
      status:        'pending',
      createdAt:     Math.floor(Date.now() / 1000),
    })
    res.status(201).json({ id, reference: body.reference })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  transactions.ts — wallet address lowercased on insert"

# ============================================================
# FIX 3 — Normalise existing Turso records to lowercase
# ============================================================
echo "  Normalising existing wallet addresses in Turso..."
turso db shell afrifx \
  "UPDATE transactions SET wallet_address = LOWER(wallet_address);" \
  && echo "  ✅  Existing records normalised"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Wallet case fix applied"
echo ""
echo "  Root cause:"
echo "  • Transactions saved as mixed-case  0x1F0294C7..."
echo "  • Stats queried as lowercase        0x1f0294c7..."
echo "  • SQLite LIKE is case-sensitive → zero results"
echo ""
echo "  Fix:"
echo "  • All inserts now lowercase the wallet address"
echo "  • All queries use LOWER() for safe comparison"
echo "  • Existing Turso rows normalised"
echo ""
echo "  Restart backend:  cd afrifx-api && npm run dev"
echo "  Then test:  curl \"http://localhost:4000/user/YOUR_WALLET/stats\""
echo "══════════════════════════════════════════════════════"
