import { Router }   from 'express'
import { db }       from '../db/client'
import { sql }      from 'drizzle-orm'
import { createPublicClient, http, formatUnits } from 'viem'
import { getCachedRates } from '../services/rateOracle'

const router = Router()

const ARC_RPC   = process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
const USDC_ADDR = '0x3600000000000000000000000000000000000000' as const
const EURC_ADDR = '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a' as const

const ERC20_ABI = [{
  name: 'balanceOf', type: 'function', stateMutability: 'view',
  inputs:  [{ name: 'account', type: 'address' }],
  outputs: [{ name: '', type: 'uint256' }],
}] as const

const arcClient = createPublicClient({
  transport: http(ARC_RPC),
  chain: {
    id: 5042002, name: 'Arc Testnet',
    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },
    rpcUrls: { default: { http: [ARC_RPC] } },
  } as any,
})

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

router.get('/:address', async (req, res) => {
  const addr = req.params.address as `0x${string}`

  try {
    // ── On-chain balances ─────────────────────────────────
    const [usdcRaw, eurcRaw] = await Promise.all([
      arcClient.readContract({ address: USDC_ADDR, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }).catch(() => 0n),
      arcClient.readContract({ address: EURC_ADDR, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }).catch(() => 0n),
    ])
    const usdcBalance = parseFloat(formatUnits(BigInt(usdcRaw), 6))
    const eurcBalance = parseFloat(formatUnits(BigInt(eurcRaw), 6))

    // ── Escrow ────────────────────────────────────────────
    const escrowRows = await db.run(
      sql`SELECT SUM(usdc_amount) as locked FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr.toLowerCase()}
            AND status IN ('open', 'accepted')`
    )
    const er = parseRows(escrowRows)
    const escrowLocked = parseFloat(String(er[0]?.locked ?? er[0]?.[0] ?? 0)) || 0

    // ── P2P stats ─────────────────────────────────────────
    const p2pRows = await db.run(
      sql`SELECT status, COUNT(*) as cnt, SUM(usdc_amount) as vol
          FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr.toLowerCase()}
             OR LOWER(taker_address) = ${addr.toLowerCase()}
          GROUP BY status`
    )
    const p2pStats = { open: 0, accepted: 0, released: 0, cancelled: 0, totalVolume: 0 }
    for (const r of parseRows(p2pRows)) {
      const status = r.status ?? r[0]
      const cnt    = Number(r.cnt ?? r[1] ?? 0)
      const vol    = Number(r.vol ?? r[2] ?? 0)
      if (status in p2pStats) (p2pStats as any)[status] = cnt
      p2pStats.totalVolume += vol
    }

    // ── Rates from memory (always fresh) ─────────────────
    // open.er-api.com returns LOCAL units per 1 USD
    // e.g. NGN/USDC rate = 1372 means 1 USDC = 1372 NGN
    // NO inversion needed use rate directly
    const memRates = getCachedRates()
    const rates: Record<string, number> = {}
    for (const r of memRates) {
      rates[r.pair] = r.rate
    }

    // ── Local currency equivalents ────────────────────────
    // rate is already "local per USDC" multiply directly
    const localEquiv = [
      { currency: 'NGN', flag: '🇳🇬', pair: 'NGN/USDC' },
      { currency: 'GHS', flag: '🇬🇭', pair: 'GHS/USDC' },
      { currency: 'KES', flag: '🇰🇪', pair: 'KES/USDC' },
      { currency: 'ZAR', flag: '🇿🇦', pair: 'ZAR/USDC' },
      { currency: 'EGP', flag: '🇪🇬', pair: 'EGP/USDC' },
    ].map(({ currency, flag, pair }) => {
      const rate   = rates[pair] ?? 0   // local units per 1 USDC
      const amount = rate > 0 ? usdcBalance * rate : 0
      return {
        currency, flag,
        rate:   parseFloat(rate.toFixed(2)),
        amount: parseFloat(amount.toFixed(2)),
      }
    })

    // ── Recent transactions ───────────────────────────────
    const txRows = await db.run(
      sql`SELECT id, from_currency, to_currency, from_amount, to_amount,
                 status, arc_tx_hash, reference, created_at
          FROM transactions
          WHERE LOWER(wallet_address) = ${addr.toLowerCase()}
          ORDER BY created_at DESC LIMIT 10`
    )
    const transactions = parseRows(txRows).map((r: any) => Array.isArray(r) ? {
      id: r[0], fromCurrency: r[1], toCurrency: r[2],
      fromAmount: Number(r[3]), toAmount: Number(r[4]),
      status: r[5], arcTxHash: r[6], reference: r[7], createdAt: Number(r[8]),
    } : {
      id: r.id, fromCurrency: r.from_currency, toCurrency: r.to_currency,
      fromAmount: Number(r.from_amount), toAmount: Number(r.to_amount),
      status: r.status, arcTxHash: r.arc_tx_hash, reference: r.reference,
      createdAt: Number(r.created_at),
    })

    // EURC USD value: 1 EURC ≈ 1/rate USDC (rate = local per USD, EUR rate gives us EUR/USD)
    const eurcUsdValue = eurcBalance * (rates['EURC/USDC'] > 0 ? 1 / rates['EURC/USDC'] : 1.09)

    res.json({
      tokens: [
        { symbol: 'USDC', name: 'USD Coin',  balance: usdcBalance,
          usdValue: usdcBalance,  color: '#378ADD', address: USDC_ADDR },
        { symbol: 'EURC', name: 'Euro Coin', balance: eurcBalance,
          usdValue: parseFloat(eurcUsdValue.toFixed(6)),
          color: '#10B981', address: EURC_ADDR },
      ],
      escrow: {
        locked:       parseFloat(escrowLocked.toFixed(6)),
        openOffers:   p2pStats.open,
        activeOffers: p2pStats.accepted,
      },
      p2p: {
        completed:   p2pStats.released,
        totalVolume: parseFloat(p2pStats.totalVolume.toFixed(2)),
      },
      localEquiv,
      transactions,
    })
  } catch (err: any) {
    console.error('[Wallet]', err.message)
    res.status(500).json({ error: err.message })
  }
})

export default router
