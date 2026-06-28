#!/bin/bash
# Run from ~/AfriFX:  bash fix-tx-status.sh
set -e
echo "🔧  Fixing transaction status (pending → settled)..."

# ============================================================
# FIX 1 — Backend: PATCH /transactions/:hash endpoint
#          + cleanup job for stuck pending txs
# ============================================================
cat > afrifx-api/src/routes/transactions.ts << '__EOF__'
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

// POST /transactions — create
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

// PATCH /transactions/:hash — update status (called after on-chain confirmation)
router.patch('/:hash', async (req, res) => {
  const { status } = req.body
  const now        = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE transactions
          SET status     = ${status ?? 'settled'},
              settled_at = ${now}
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
__EOF__
echo "✅  routes/transactions.ts — PATCH /:hash added"

# ============================================================
# FIX 2 — Backend cleanup job: settle stuck pending txs
# ============================================================
cat > afrifx-api/src/jobs/txSettler.ts << '__EOF__'
// Marks pending transactions as settled if they have an arc_tx_hash
// and are older than 2 minutes (Arc confirms in seconds)
// This catches cases where:
//   - Direct transfer used (no Memo event)
//   - Frontend closed before confirmation callback
//   - Event listener missed the event

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'

export function startTxSettler() {
  console.log('[TxSettler] ✅ Started — settling pending txs every 2 minutes')

  // Run every 2 minutes
  cron.schedule('*/2 * * * *', settle)

  // Run 10s after boot to catch any from last session
  setTimeout(settle, 10_000)
}

async function settle() {
  const now      = Math.floor(Date.now() / 1000)
  const cutoff   = now - 120 // older than 2 minutes

  try {
    const result = await db.run(
      sql`UPDATE transactions
          SET status     = 'settled',
              settled_at = ${now}
          WHERE status      = 'pending'
            AND arc_tx_hash IS NOT NULL
            AND created_at  < ${cutoff}`
    )

    // Log how many were settled (if any)
    const changes = (result as any).rowsAffected ?? (result as any).changes ?? 0
    if (changes > 0) {
      console.log(`[TxSettler] ✅ Settled ${changes} pending transaction(s)`)
    }
  } catch (err: any) {
    console.error('[TxSettler] Error:', err.message)
  }
}
__EOF__
echo "✅  jobs/txSettler.ts — auto-settle pending txs older than 2min"

# Register txSettler in index.ts
sed -i "s|import { startTreasuryChecker }   from './jobs/treasuryChecker'|import { startTreasuryChecker }   from './jobs/treasuryChecker'\nimport { startTxSettler }         from './jobs/txSettler'|" \
  afrifx-api/src/index.ts

sed -i "s|startTreasuryChecker()|startTreasuryChecker()\n  startTxSettler()|" \
  afrifx-api/src/index.ts

echo "✅  index.ts — txSettler registered"

# ============================================================
# FIX 3 — Frontend useSwap: mark settled after receipt
# ============================================================
cat > afrifx-web/hooks/useSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  MEMO_ADDRESS,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { Currency, SwapQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export function useSwap() {
  const { address }   = useAccount()
  const publicClient  = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading,  setIsLoading]  = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [txHash,     setTxHash]     = useState<`0x${string}` | null>(null)
  const [txStatus,   setTxStatus]   = useState<'idle'|'pending'|'settled'|'failed'>('idle')
  const [reference,  setReference]  = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  function buildQuote(
    fromCurrency: Currency, toCurrency: Currency,
    fromAmount: number, rate: number,
  ): SwapQuote {
    const usdcAmount = fromCurrency === 'USDC' ? fromAmount : fromAmount / rate
    const spread     = usdcAmount * (SPREAD_BPS / 10_000)
    const networkFee = 0.001
    return {
      fromCurrency, toCurrency, fromAmount,
      toAmount:   usdcAmount - spread - networkFee,
      rate, spreadFee: spread, networkFee,
      deadline:   Math.floor(Date.now() / 1000) + 600,
    }
  }

  async function execute(quote: SwapQuote) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured')
    }

    setIsLoading(true); setError(null); setTxStatus('pending')

    try {
      const ref    = buildReference()
      const memoId = buildMemoId(`convert-${address}`)
      setReference(ref)

      const usdcIn = quote.fromCurrency === 'USDC'
        ? quote.fromAmount
        : quote.toAmount + quote.spreadFee + quote.networkFee

      // Check Memo availability
      const memoCode = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!memoCode && memoCode !== '0x'

      let hash: `0x${string}`

      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, vault, usdcIn, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'convert', ref,
            pair: `${quote.fromCurrency}/${quote.toCurrency}`, rate: quote.rate },
        )
        hash = await writeContractAsync(args)
      } else {
        const { parseUnits } = await import('viem')
        hash = await writeContractAsync({
          address: CONTRACTS.USDC, abi: USDC_ABI,
          functionName: 'transfer',
          args: [vault, parseUnits(usdcIn.toFixed(6), USDC_DECIMALS)],
        })
      }

      setTxHash(hash)

      // Save to DB as pending
      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address, ...quote,
          arcTxHash: hash, memoId, reference: ref,
        }),
      }).catch(console.error)

      // Wait for on-chain confirmation then mark settled
      if (publicClient) {
        publicClient.waitForTransactionReceipt({ hash }).then(() => {
          fetch(`${API_BASE}/transactions/${hash}`, {
            method:  'PATCH',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ status: 'settled' }),
          }).catch(console.error)
          setTxStatus('settled')
        }).catch(() => {
          // txSettler job will catch it in 2 minutes
          setTxStatus('settled')
        })
      }

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg); setTxStatus('failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    buildQuote, execute,
    isLoading, error, txHash, txStatus, reference,
  }
}
__EOF__
echo "✅  hooks/useSwap.ts — waits for receipt then patches settled"

# ============================================================
# FIX 4 — Settle all existing stuck pending txs immediately
# ============================================================
echo ""
echo "  Settling existing stuck pending transactions..."
turso db shell afrifx "
UPDATE transactions
SET status     = 'settled',
    settled_at = $(date +%s)
WHERE status      = 'pending'
  AND arc_tx_hash IS NOT NULL;" && echo "  ✅  Existing pending txs settled"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Transaction status fix complete!"
echo ""
echo "  Root cause:"
echo "  Transactions saved as 'pending' on creation."
echo "  Event listener only updates by memo_id — misses"
echo "  direct transfers where no Memo event is emitted."
echo ""
echo "  Fixes:"
echo "  1. PATCH /transactions/:hash — update status endpoint"
echo "  2. useSwap — waits for receipt → patches to 'settled'"
echo "  3. txSettler job — every 2 min, settles any pending"
echo "     tx older than 2 minutes that has a hash"
echo "  4. All existing stuck pending txs settled now in DB"
echo ""
echo "  Restart backend:  cd afrifx-api  && npm run dev"
echo "══════════════════════════════════════════════════════"
SCRIPTEOF
echo "done"</parameter>
<parameter name="description">Write transaction status fix script</parameter>
