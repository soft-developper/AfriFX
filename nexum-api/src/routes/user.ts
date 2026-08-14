import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import { getCachedRates } from '../services/rateOracle'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Convert any currency amount to USD using live rates
// Rates are stored as "local units per 1 USDC (= 1 USD)"
function toUSD(amount: number, currency: string, rates: Record<string, number>): number {
  if (!amount || amount <= 0) return 0
  if (currency === 'USDC' || currency === 'USD') return amount
  if (currency === 'EURC') {
    const r = rates['EURC/USDC']
    // EURC/USDC rate is stored differently EURC ≈ 1.09 USD
    return r ? amount * (1 / r) : amount * 1.09
  }
  // Local currency: rate = local units per USDC
  // So 1 NGN = 1/1372 USD
  const rate = rates[`${currency}/USDC`]
  return rate && rate > 0 ? amount / rate : 0
}

// For each transaction, get the USD value of the trade
function txUSD(tx: any, rates: Record<string, number>): number {
  const fromCcy = tx.from_currency ?? tx[2]
  const toCcy   = tx.to_currency   ?? tx[3]
  const fromAmt = Number(tx.from_amount ?? tx[4] ?? 0)
  const toAmt   = Number(tx.to_amount   ?? tx[5] ?? 0)

  // Prefer the USDC side it's already in USD
  if (toCcy === 'USDC')   return toAmt
  if (fromCcy === 'USDC') return fromAmt
  // Corridor (local → local): convert from_amount to USD
  return toUSD(fromAmt, fromCcy, rates)
}

// GET /user/:address
router.get('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const rows = await db.run(
      sql`SELECT * FROM users WHERE LOWER(wallet_address) = ${addr} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.json({
      walletAddress: addr, volume30d: 0, txCount: 0, disputeWarnings: 0,
    })
    const u = r[0]
    res.json({
      walletAddress:   u.wallet_address  ?? u[0],
      volume30d:       Number(u.volume_30d      ?? u[1] ?? 0),
      txCount:         Number(u.tx_count        ?? u[2] ?? 0),
      disputeWarnings: Number(u.dispute_warnings ?? u[3] ?? 0),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /user/:address/stats
router.get('/:address/stats', async (req, res) => {
  const addr = req.params.address.toLowerCase()

  try {
    const now   = Math.floor(Date.now() / 1000)
    const day   = 86400
    const month = day * 30

    // Live rates for USD conversion
    const rateList = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of rateList) rates[r.pair] = r.rate

    // ── Transactions ──────────────────────────────────────
    const txRows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${addr}
          ORDER BY created_at DESC LIMIT 500`
    )
    const txs = parseRows(txRows).map((r: any) => {
      const obj = Array.isArray(r) ? {
        id: r[0], wallet_address: r[1], from_currency: r[2], to_currency: r[3],
        from_amount: Number(r[4]), to_amount: Number(r[5]),
        spread_fee: Number(r[6]), network_fee: Number(r[7]),
        arc_tx_hash: r[8], memo_id: r[9], reference: r[10],
        status: r[13], created_at: Number(r[15] ?? r[14]),
      } : {
        ...r,
        from_amount: Number(r.from_amount),
        to_amount:   Number(r.to_amount),
        created_at:  Number(r.created_at),
      }
      // Attach USD volume to each tx
      obj._usdVol = txUSD(obj, rates)
      return obj
    })

    // ── P2P offers ────────────────────────────────────────
    const offerRows = await db.run(
      sql`SELECT id, status, usdc_amount, maker_address, taker_address, created_at
          FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr}
             OR LOWER(taker_address) = ${addr}
          ORDER BY created_at DESC LIMIT 200`
    )
    const offers = parseRows(offerRows).map((r: any) => Array.isArray(r) ? {
      id: r[0], status: r[1], usdc_amount: Number(r[2]),
      maker_address: r[3], taker_address: r[4], created_at: Number(r[5]),
    } : { ...r, usdc_amount: Number(r.usdc_amount), created_at: Number(r.created_at) })

    // ── Dispute warnings ──────────────────────────────────
    const userRows = await db.run(
      sql`SELECT dispute_warnings FROM users WHERE LOWER(wallet_address) = ${addr} LIMIT 1`
    )
    const ur = parseRows(userRows)
    const disputeWarnings = Number(ur[0]?.dispute_warnings ?? ur[0]?.[0] ?? 0)

    // ── Volume in USD ─────────────────────────────────────
    const monthTxs = txs.filter(t => t.created_at > now - month)
    const monthVol = monthTxs.reduce((s, t) => s + t._usdVol, 0)
    const allVol   = txs.reduce((s, t) => s + t._usdVol, 0)

    // Also count P2P released volume (USDC = USD)
    const p2pReleased = offers.filter(o => o.status === 'released')
    const p2pVol      = p2pReleased.reduce((s, o) => s + o.usdc_amount, 0)

    // P2P stats
    const completedTrades = p2pReleased.length
    const activeTrades    = offers.filter(o => o.status === 'accepted').length
    const openOffers      = offers.filter(o =>
      o.status === 'open' && o.maker_address?.toLowerCase() === addr
    ).length

    // ── Weekly bar chart (last 7 days, correct alignment) ─
    // i=0: 6 days ago, i=6: today
    // dayStart = now - (daysAgo+1)*day, dayEnd = now - daysAgo*day
    const chartData = Array.from({ length: 7 }, (_, i) => {
      const daysAgo  = 6 - i
      const dayEnd   = now - daysAgo * day
      const dayStart = dayEnd - day
      const label    = daysAgo === 0
        ? 'Today'
        : new Date(dayStart * 1000).toLocaleDateString([], { weekday: 'short' })

      // FX conversion volume (USD)
      const txVol = txs
        .filter(t => t.created_at >= dayStart && t.created_at < dayEnd)
        .reduce((s, t) => s + t._usdVol, 0)

      // P2P released volume (USDC = USD)
      const p2pV = offers
        .filter(o =>
          o.status === 'released' &&
          o.created_at >= dayStart && o.created_at < dayEnd
        )
        .reduce((s, o) => s + o.usdc_amount, 0)

      return {
        label,
        volume: parseFloat((txVol + p2pV).toFixed(2)),
      }
    })

    // ── Inflow/Outflow (14 days) ──────────────────────────
    const flowData = Array.from({ length: 14 }, (_, i) => {
      const daysAgo  = 13 - i
      const dayEnd   = now - daysAgo * day
      const dayStart = dayEnd - day
      const label    = new Date(dayStart * 1000).toLocaleDateString([], {
        month: 'short', day: 'numeric',
      })

      // Outflow: USD value of all conversions sent out
      const outflow = txs
        .filter(t => t.created_at >= dayStart && t.created_at < dayEnd)
        .reduce((s, t) => s + t._usdVol, 0)

      // Inflow: USDC received from P2P as taker
      const inflow = offers
        .filter(o =>
          o.status === 'released' &&
          o.taker_address?.toLowerCase() === addr &&
          o.created_at >= dayStart && o.created_at < dayEnd
        )
        .reduce((s, o) => s + o.usdc_amount, 0)

      return {
        label,
        inflow:  parseFloat(inflow.toFixed(2)),
        outflow: parseFloat(outflow.toFixed(2)),
      }
    })

    // ── Top pairs (by USD volume) ─────────────────────────
    const pairMap: Record<string, { volume: number; txs: number }> = {}
    for (const t of txs) {
      const pair = `${t.from_currency ?? t[2]}/${t.to_currency ?? t[3]}`
      if (!pairMap[pair]) pairMap[pair] = { volume: 0, txs: 0 }
      pairMap[pair].volume += t._usdVol
      pairMap[pair].txs++
    }
    const pairBreakdown = Object.entries(pairMap)
      .map(([pair, d]) => ({ pair, volume: parseFloat(d.volume.toFixed(2)), txs: d.txs }))
      .sort((a, b) => b.volume - a.volume)
      .slice(0, 5)

    // ── Recent activity ───────────────────────────────────
    const recent = txs.slice(0, 8).map(t => ({
      id:           t.id,
      fromCurrency: t.from_currency,
      toCurrency:   t.to_currency,
      fromAmount:   t.from_amount,
      toAmount:     t.to_amount,
      usdVolume:    parseFloat(t._usdVol.toFixed(2)),
      status:       t.status,
      reference:    t.reference,
      arcTxHash:    t.arc_tx_hash,
      createdAt:    t.created_at,
    }))

    res.json({
      monthly: {
        volume:  parseFloat(monthVol.toFixed(2)),
        txCount: monthTxs.length,
      },
      allTime: {
        totalVolume: parseFloat((allVol + p2pVol).toFixed(2)),
        txCount:     txs.length,
      },
      p2p: { completedTrades, activeTrades, openOffers },
      disputeWarnings,
      chartData,
      flowData,
      pairBreakdown,
      recent,
    })
  } catch (err: any) {
    console.error('[Stats]', err.message)
    res.status(500).json({ error: err.message })
  }
})

export default router
