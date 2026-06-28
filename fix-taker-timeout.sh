#!/bin/bash
# Run from ~/AfriFX:  bash fix-taker-timeout.sh
set -e
echo "🔧  Fixing taker timeout flow..."

# ============================================================
# FIX 1 — Marketplace page: pass makerTimerSeconds to acceptOffer
# The normalizeOffer array mapping was only going to index 14.
# maker_timer_seconds is column 17 — was never being read.
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { useP2P } from '@/hooks/useP2P'
import { Plus, Clock, Zap, ShieldCheck, Loader2, ArrowRight } from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

// Full column mapping — must match PRAGMA table_info(p2p_offers) order
function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id:              row[0],
      maker_address:   row[1],
      taker_address:   row[2],
      usdc_amount:     Number(row[3]),
      local_currency:  row[4],
      local_amount:    Number(row[5]),
      rate_offered:    Number(row[6]),
      status:          row[7],
      maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]),
      arc_tx_hash:     row[10],
      release_tx_hash: row[11],
      expires_at:      Number(row[12]),
      created_at:      Number(row[13]),
      updated_at:      Number(row[14]),
      // New columns added via ALTER TABLE
      order_type:          row[15] ?? 'market',
      limit_rate:          row[16] ?? null,
      maker_timer_seconds: Number(row[17] ?? 1800),
      taker_deadline:      row[18] ? Number(row[18]) : null,
      maker_deadline:      row[19] ? Number(row[19]) : null,
      dispute_raised:      Number(row[20] ?? 0),
      dispute_id:          row[21] ?? null,
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
    taker_deadline:      row.taker_deadline ? Number(row.taker_deadline) : null,
    maker_deadline:      row.maker_deadline ? Number(row.maker_deadline) : null,
    dispute_raised:      Number(row.dispute_raised      ?? 0),
  } as P2POffer
}

function timeLeft(expiresAt: number): string {
  const secs = expiresAt - Math.floor(Date.now() / 1000)
  if (secs <= 0 || expiresAt === 9999999999) return 'Perpetual'
  const mins = Math.floor(secs / 60)
  return mins > 0 ? `${mins}m left` : `${secs}s left`
}

function formatTimer(secs: number): string {
  if (secs >= 7200) return `${secs / 3600}h window`
  if (secs >= 3600) return '1h window'
  return `${secs / 60}min window`
}

export default function MarketplacePage() {
  const { address }                    = useAccount()
  const router                         = useRouter()
  const [offers,   setOffers]          = useState<P2POffer[]>([])
  const [loading,  setLoading]         = useState(true)
  const [currency, setCurrency]        = useState('all')
  const [accepting, setAccepting]      = useState<string | null>(null)
  const { acceptOffer, error: p2pErr } = useP2P()

  async function load() {
    setLoading(true)
    try {
      const url  = currency === 'all'
        ? `${API}/offers`
        : `${API}/offers?currency=${currency}`
      const res  = await fetch(url)
      const data = await res.json()
      setOffers(Array.isArray(data) ? data.map(normalizeOffer) : [])
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address) return
    setAccepting(offer.id)
    try {
      // Pass makerTimerSeconds so taker_deadline is correctly calculated
      const timerSecs = (offer as any).maker_timer_seconds ?? 1800
      await acceptOffer(offer.id as `0x${string}`, timerSecs)
      router.push(`/marketplace/${offer.id}`)
    } catch {
      setAccepting(null)
    }
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">P2P Marketplace</h1>
          <p className="text-sm text-[#64748B]">
            Buy USDC directly from other users. Funds held in vault escrow.
          </p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> Create offer</Button>
        </Link>
      </div>

      {/* Trust badges */}
      <div className="mb-6 flex gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow'  },
          { icon: Zap,         label: 'Arc settlement'  },
          { icon: Clock,       label: 'Perpetual orders'},
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#64748B]">
            <Icon className="h-3.5 w-3.5 text-[#378ADD]" />{label}
          </div>
        ))}
      </div>

      {/* Currency filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all','NGN','GHS','KES','ZAR','EGP'].map((c) => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-[#378ADD] text-white'
                : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}>
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c]} ${c}`}
          </button>
        ))}
        <button onClick={load}
          className="ml-auto rounded-full border border-[#1B2B4B] px-3 py-1 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          ↻ Refresh
        </button>
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />)}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <p className="text-sm text-[#64748B]">No open offers right now.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create the first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const timer  = (offer as any).maker_timer_seconds ?? 1800
          const type   = (offer as any).order_type ?? 'market'

          return (
            <div key={offer.id}
              className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">

              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
              </div>

              <div className="flex-1 min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-medium text-[#E2E8F0]">
                    {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                    <span className="mx-1.5 text-[#64748B]">→</span>
                    {Number(offer.usdc_amount).toFixed(2)} USDC
                  </p>
                  {isOwn && <Badge variant="arc">Your offer</Badge>}
                  <Badge variant={type === 'limit' ? 'warning' : 'arc'}>{type}</Badge>
                </div>
                <div className="mt-0.5 flex flex-wrap items-center gap-3 text-xs text-[#64748B]">
                  <span>
                    Rate: {Number(offer.rate_offered) > 0
                      ? (1 / Number(offer.rate_offered)).toFixed(2)
                      : '—'} {offer.local_currency}/USDC
                  </span>
                  <span className="flex items-center gap-1">
                    <Clock className="h-3 w-3" />
                    {formatTimer(timer)}
                  </span>
                </div>
              </div>

              <div className="flex shrink-0 items-center gap-2">
                {isOwn ? (
                  <Link href={`/marketplace/${offer.id}`}>
                    <Button variant="outline" size="sm">
                      Manage <ArrowRight className="h-3.5 w-3.5" />
                    </Button>
                  </Link>
                ) : (
                  <ClientOnly>
                    <Button size="sm"
                      onClick={() => handleAccept(offer)}
                      disabled={!address || accepting === offer.id}>
                      {accepting === offer.id
                        ? <><Loader2 className="h-3.5 w-3.5 animate-spin" /> Accepting…</>
                        : 'Accept offer'}
                    </Button>
                  </ClientOnly>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{p2pErr}</div>
      )}
    </div>
  )
}
__EOF__
echo "✅  marketplace/page.tsx — makerTimerSeconds passed to acceptOffer"

# ============================================================
# FIX 2 — Watcher job 2: taker timeout
# When taker times out:
#   - Cancel on-chain (USDC back to maker)
#   - Set DB status = 'cancelled' (consistent with contract)
#   - Add cancellation_reason so maker knows why
# Note: maker must create a new offer to relist
# ============================================================
cat > afrifx-api/src/jobs/p2pReleaseWatcher.ts << '__EOF__'
import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release/cancel disabled')
    return
  }
  if (!process.env.AFRIFX_VAULT_ADDRESS) {
    console.warn('[P2PWatcher] AFRIFX_VAULT_ADDRESS not set — skipping watcher')
    return
  }
  console.log('[P2PWatcher] ✅ Started — polling every 15s')
  console.log('[P2PWatcher]    Vault:', process.env.AFRIFX_VAULT_ADDRESS)

  cron.schedule('*/15 * * * * *', async () => {
    await job1_releaseConfirmed()
    await job2_cancelTimedOutTakers()
    await job3_flagTimedOutMakers()
    await job4_autoSettleDisputes()
  })

  // Run immediately on boot
  setTimeout(async () => {
    await job1_releaseConfirmed()
    await job2_cancelTimedOutTakers()
    await job3_flagTimedOutMakers()
    await job4_autoSettleDisputes()
  }, 3000)
}

// ── Job 1: Both confirmed → release USDC to taker ────────
async function job1_releaseConfirmed() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND maker_confirmed = 1
            AND taker_confirmed = 1
            AND dispute_raised  = 0`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        console.log(`[P2PWatcher] Job1: releasing ${offerId.slice(0,14)}…`)
        const hash = await releasePlatform(offerId)
        await db.run(
          sql`UPDATE p2p_offers SET
                status          = 'released',
                release_tx_hash = ${hash},
                updated_at      = ${now}
              WHERE id = ${offerId}`
        )
        console.log(`[P2PWatcher] ✅ Released ${offerId.slice(0,14)}… tx: ${hash.slice(0,14)}…`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job1 release failed ${offerId.slice(0,14)}:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job1 error:', err.message) }
}

// ── Job 2: Taker didn't confirm in time → cancel + notify ─
async function job2_cancelTimedOutTakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id, maker_address FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 0
            AND taker_deadline  IS NOT NULL
            AND taker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        console.log(`[P2PWatcher] Job2: taker timed out on ${offerId.slice(0,14)}… — cancelling`)

        // Cancel on-chain → USDC returns to maker
        await cancelPlatform(offerId, 'Taker did not send within agreed window')

        // Mark as cancelled in DB — maker must create a new offer
        await db.run(
          sql`UPDATE p2p_offers SET
                status         = 'cancelled',
                taker_address  = NULL,
                taker_deadline = NULL,
                updated_at     = ${now}
              WHERE id = ${offerId}`
        )
        console.log(`[P2PWatcher] ✅ Job2: taker timed out — offer ${offerId.slice(0,14)} cancelled, USDC returned to maker`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job2 failed ${offerId.slice(0,14)}:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job2 error:', err.message) }
}

// ── Job 3: Maker didn't confirm in time → flag dispute ───
async function job3_flagTimedOutMakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 1
            AND maker_confirmed = 0
            AND dispute_raised  = 0
            AND maker_deadline  IS NOT NULL
            AND maker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      await db.run(
        sql`UPDATE p2p_offers
            SET dispute_raised = 1, updated_at = ${now}
            WHERE id = ${offerId}`
      ).catch(() => {})
      console.log(`[P2PWatcher] ⚠️  Job3: maker timed out — dispute auto-flagged ${offerId.slice(0,14)}`)
    }
  } catch (err: any) { console.error('[P2PWatcher] Job3 error:', err.message) }
}

// ── Job 4: Dispute 24h → auto-release to taker ───────────
async function job4_autoSettleDisputes() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT d.id as dispute_id, d.offer_id
          FROM disputes d
          JOIN p2p_offers o ON o.id = d.offer_id
          WHERE d.status         = 'open'
            AND d.auto_settle_at < ${now}
            AND o.status         = 'accepted'`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId   = (row.offer_id   ?? row[1]) as `0x${string}`
      const disputeId =  row.dispute_id ?? row[0]
      try {
        const hash = await releasePlatform(offerId)
        await db.run(
          sql`UPDATE p2p_offers SET
                status          = 'released',
                release_tx_hash = ${hash},
                updated_at      = ${now}
              WHERE id = ${offerId}`
        )
        await db.run(
          sql`UPDATE disputes SET status = 'auto_settled', settled_at = ${now}
              WHERE id = ${disputeId}`
        )
        console.log(`[P2PWatcher] ⚖️  Job4: auto-settled dispute — USDC released to taker ${offerId.slice(0,14)}`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Job4 failed:`, err.message)
      }
    }
  } catch (err: any) { console.error('[P2PWatcher] Job4 error:', err.message) }
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}
__EOF__
echo "✅  p2pReleaseWatcher.ts — fixed + verbose logging"

# ============================================================
# FIX 3 — Manual: reset the stuck offer in Turso so taker
#          can accept a fresh one (run only if needed)
# ============================================================
echo ""
echo "  If you have a stuck 'accepted' offer with no taker_deadline,"
echo "  reset it manually:"
echo ""
echo "  turso db shell afrifx \\"
echo "    \"UPDATE p2p_offers SET status='cancelled', updated_at=$(date +%s) WHERE status='accepted' AND taker_deadline IS NULL;\""
echo ""

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Taker timeout fix complete!"
echo ""
echo "  Root cause:"
echo "  • normalizeOffer() only mapped columns 0-14"
echo "  • maker_timer_seconds is column 17 → read as undefined"
echo "  • acceptOffer() received undefined timer → taker_deadline = NaN"
echo "  • NaN saved as NULL → watcher never found the offer"
echo ""
echo "  Fixes:"
echo "  • normalizeOffer() now maps all 22 columns correctly"
echo "  • makerTimerSeconds passed correctly to acceptOffer()"
echo "  • taker_deadline = now + timerSecs → saves correctly"
echo "  • Watcher verbose logging → see exactly what's happening"
echo "  • Taker timeout: cancel on-chain → USDC back to maker"
echo "    (maker must create new offer — consistent with contract)"
echo ""
echo "  Restart backend:  cd afrifx-api  && npm run dev"
echo "  Restart frontend: cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
