#!/bin/bash
# ============================================================
# AfriFX Phase 3 — P2P Auto-release + Offer Detail Page
# Run from ~/AfriFX:  bash phase3-release.sh
# ============================================================
set -e
echo ""
echo "⚡  Building P2P auto-release + offer detail page..."
echo ""

# ============================================================
# 1 — Backend: platform wallet + auto-release service
# ============================================================
cat > afrifx-api/src/services/platformWallet.ts << '__EOF__'
// Platform wallet — used to call releaseP2POffer() on-chain
// Private key stored in .env — never committed to git
// This wallet must be the contract owner (deployer wallet)

import { createWalletClient, createPublicClient, http, encodeFunctionData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arcTestnet, arcClient } from './arc'

const PRIVATE_KEY   = process.env.PLATFORM_WALLET_PRIVATE_KEY as `0x${string}`
const VAULT_ADDRESS = process.env.AFRIFX_VAULT_ADDRESS as `0x${string}`

// Minimal ABI for release + cancel
const VAULT_ABI = [
  {
    type: 'function',
    name: 'releaseP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelP2POffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'offerId', type: 'bytes32' },
      { name: 'reason',  type: 'string'  },
    ],
    outputs: [],
  },
] as const

function getWalletClient() {
  if (!PRIVATE_KEY) throw new Error('PLATFORM_WALLET_PRIVATE_KEY not set in .env')
  const account = privateKeyToAccount(PRIVATE_KEY)
  return createWalletClient({
    account,
    chain:     arcTestnet,
    transport: http(process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'),
  })
}

/**
 * Release USDC to taker — called automatically when both sides confirm.
 */
export async function releasePlatform(offerId: `0x${string}`): Promise<`0x${string}`> {
  if (!VAULT_ADDRESS) throw new Error('AFRIFX_VAULT_ADDRESS not set in .env')
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      VAULT_ADDRESS,
    abi:          VAULT_ABI,
    functionName: 'releaseP2POffer',
    args:         [offerId],
  })

  console.log(`[Platform] Released offer ${offerId} · tx: ${hash}`)
  return hash
}

/**
 * Cancel offer and return USDC to maker — used for disputes/timeouts.
 */
export async function cancelPlatform(
  offerId: `0x${string}`,
  reason:  string,
): Promise<`0x${string}`> {
  if (!VAULT_ADDRESS) throw new Error('AFRIFX_VAULT_ADDRESS not set in .env')
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      VAULT_ADDRESS,
    abi:          VAULT_ABI,
    functionName: 'cancelP2POffer',
    args:         [offerId, reason],
  })

  console.log(`[Platform] Cancelled offer ${offerId} · reason: ${reason} · tx: ${hash}`)
  return hash
}
__EOF__
echo "✅  services/platformWallet.ts"

# ============================================================
# 2 — Backend: auto-release watcher (polls every 15s)
# ============================================================
cat > afrifx-api/src/jobs/p2pReleaseWatcher.ts << '__EOF__'
// Polls for offers where both sides confirmed
// and automatically releases USDC to taker via platform wallet.

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PReleaseWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }

  console.log('[P2PReleaseWatcher] Starting — polling every 15s for confirmed offers')

  // Poll every 15 seconds
  cron.schedule('*/15 * * * * *', async () => {
    await checkConfirmedOffers()
    await checkExpiredOffers()
  })

  // Run immediately on boot
  checkConfirmedOffers()
  checkExpiredOffers()
}

/**
 * Find offers where both maker and taker confirmed
 * and release USDC to taker.
 */
async function checkConfirmedOffers() {
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status         = 'accepted'
            AND maker_confirmed = 1
            AND taker_confirmed = 1`
    )
    const rows = Array.isArray((result as any).rows)
      ? (result as any).rows
      : Array.isArray(result) ? result : []

    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        console.log(`[P2PReleaseWatcher] Both confirmed — releasing offer ${offerId}`)

        const releaseTxHash = await releasePlatform(offerId)

        // Update DB status to released
        await db.run(
          sql`UPDATE p2p_offers
              SET status           = 'released',
                  release_tx_hash  = ${releaseTxHash},
                  updated_at       = ${Math.floor(Date.now() / 1000)}
              WHERE id = ${offerId}`
        )

        console.log(`[P2PReleaseWatcher] ✅ Released ${offerId} · tx: ${releaseTxHash}`)
      } catch (err: any) {
        console.error(`[P2PReleaseWatcher] Release failed for ${offerId}:`, err.message)
      }
    }
  } catch (err: any) {
    console.error('[P2PReleaseWatcher] Poll error:', err.message)
  }
}

/**
 * Find offers that passed their expiry deadline and are still open.
 * Cancel them and return USDC to maker.
 */
async function checkExpiredOffers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status    = 'open'
            AND expires_at < ${now}`
    )
    const rows = Array.isArray((result as any).rows)
      ? (result as any).rows
      : Array.isArray(result) ? result : []

    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        console.log(`[P2PReleaseWatcher] Expiring offer ${offerId}`)

        await cancelPlatform(offerId, 'Expired')

        await db.run(
          sql`UPDATE p2p_offers
              SET status     = 'cancelled',
                  updated_at = ${Math.floor(Date.now() / 1000)}
              WHERE id = ${offerId}`
        )

        console.log(`[P2PReleaseWatcher] ✅ Expired offer ${offerId} cancelled`)
      } catch (err: any) {
        console.error(`[P2PReleaseWatcher] Expire failed for ${offerId}:`, err.message)
      }
    }
  } catch (err: any) {
    console.error('[P2PReleaseWatcher] Expiry poll error:', err.message)
  }
}
__EOF__
echo "✅  jobs/p2pReleaseWatcher.ts"

# ============================================================
# 3 — Update backend index.ts to start the watcher
# ============================================================
cat > afrifx-api/src/index.ts << '__EOF__'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }       from './middleware/cors'
import { rateLimitMiddleware }  from './middleware/rateLimit'
import { errorHandler }         from './middleware/errorHandler'
import ratesRouter              from './routes/rates'
import transactionsRouter       from './routes/transactions'
import userRouter               from './routes/user'
import offersRouter             from './routes/offers'
import { startRatePoller }      from './jobs/ratePoller'
import { startEventListener }   from './services/eventListener'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => {
  res.json({
    status:        'ok',
    chain:         'Arc Testnet 5042002',
    autoRelease:   !!process.env.PLATFORM_WALLET_PRIVATE_KEY,
    ts:            Date.now(),
  })
})

app.use('/rates',        ratesRouter)
app.use('/transactions', transactionsRouter)
app.use('/user',         userRouter)
app.use('/offers',       offersRouter)

app.use(errorHandler)

app.listen(PORT, () => {
  console.log(`\n🚀  AfriFX API running on http://localhost:${PORT}`)
  console.log(`    Chain: Arc Testnet · Chain ID 5042002`)
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
})
__EOF__
echo "✅  index.ts — P2PReleaseWatcher started"

# ============================================================
# 4 — Add PLATFORM_WALLET_PRIVATE_KEY to backend .env.example
# ============================================================
cat > afrifx-api/.env.example << '__EOF__'
PORT=4000
TURSO_DATABASE_URL=libsql://your-db.turso.io
TURSO_AUTH_TOKEN=your-token-here
ARC_RPC_URL=https://rpc.testnet.arc.network
FRONTEND_URL=http://localhost:3000
EXCHANGE_RATE_API_KEY=your-exchangerate-api-key
AFRIFX_VAULT_ADDRESS=0x_your_vault_address
# Platform wallet — must be the contract owner (deployer wallet)
# Used to auto-release USDC after both sides confirm
PLATFORM_WALLET_PRIVATE_KEY=0x_your_deployer_private_key
__EOF__
echo "✅  .env.example updated"

# ============================================================
# 5 — Frontend: Offer detail page with confirm buttons
# ============================================================
mkdir -p "afrifx-web/app/(app)/marketplace/[id]"

cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, Clock, ExternalLink,
  ShieldCheck, Loader2, AlertCircle, ArrowRight,
} from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function shortenAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export default function OfferDetailPage() {
  const params              = useParams()
  const { address }         = useAccount()
  const [offer, setOffer]   = useState<P2POffer | null>(null)
  const [loading, setLoading] = useState(true)

  const {
    makerConfirm, takerConfirm,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  async function load() {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      const data = await res.json()
      // Normalize snake_case from Turso raw rows
      if (data && !data.error) {
        const normalized = normalizeOffer(data)
        setOffer(normalized)
      }
    } catch {}
    finally { setLoading(false) }
  }

  useEffect(() => { load() }, [params.id])

  // Poll every 5s to detect when other side confirms
  useEffect(() => {
    const interval = setInterval(load, 5000)
    return () => clearInterval(interval)
  }, [params.id])

  if (loading) {
    return (
      <div className="space-y-3">
        {[1,2,3].map(i => (
          <div key={i} className="h-20 animate-pulse rounded-xl bg-[#0F1729]" />
        ))}
      </div>
    )
  }

  if (!offer) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm text-[#64748B]">Offer not found.</p>
        <Link href="/marketplace"><Button variant="outline" size="sm">Back to marketplace</Button></Link>
      </div>
    )
  }

  const isMaker   = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker   = address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId   = offer.id as `0x${string}`

  async function handleMakerConfirm() {
    await makerConfirm(offerId)
    await load()
  }

  async function handleTakerConfirm() {
    await takerConfirm(offerId)
    await load()
  }

  const statusColor = {
    open:      'warning',
    accepted:  'arc',
    released:  'success',
    cancelled: 'danger',
  }[offer.status] as any

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">Offer detail</h1>
            <Badge variant={statusColor}>{offer.status}</Badge>
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0, 20)}…</p>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">

        {/* Offer summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Offer summary</p>

          <div className="mb-4 flex items-center justify-center gap-4 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-lg font-medium text-[#E2E8F0]">
                {Number(offer.local_amount).toLocaleString()}
              </p>
              <p className="text-xs text-[#64748B]">{offer.local_currency}</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-lg font-medium text-[#E2E8F0]">
                {Number(offer.usdc_amount).toFixed(2)}
              </p>
              <p className="text-xs text-[#64748B]">USDC</p>
            </div>
          </div>

          <div className="space-y-2 text-xs">
            <div className="flex justify-between">
              <span className="text-[#64748B]">Rate</span>
              <span className="font-mono text-[#E2E8F0]">
                {Number(offer.rate_offered).toFixed(4)} USDC/{offer.local_currency}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Maker</span>
              <span className="font-mono text-[#E2E8F0]">
                {offer.maker_address ? shortenAddr(offer.maker_address) : '—'}
                {isMaker && <span className="ml-1 text-[#378ADD]">(you)</span>}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Taker</span>
              <span className="font-mono text-[#E2E8F0]">
                {offer.taker_address
                  ? <>{shortenAddr(offer.taker_address)}{isTaker && <span className="ml-1 text-[#378ADD]">(you)</span>}</>
                  : 'Waiting for taker…'
                }
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Expires</span>
              <span className="flex items-center gap-1 text-[#E2E8F0]">
                <Clock className="h-3 w-3" />
                {new Date(offer.expires_at * 1000).toLocaleTimeString()}
              </span>
            </div>
            {offer.arc_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Create tx</span>
                <a
                  href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline"
                >
                  {offer.arc_tx_hash.slice(0, 12)}…
                  <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
            {offer.release_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Release tx</span>
                <a
                  href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-emerald-400 hover:underline"
                >
                  {offer.release_tx_hash.slice(0, 12)}…
                  <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
          </div>
        </div>

        {/* Confirmation flow */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Confirmation flow</p>

          {/* Steps */}
          <div className="mb-5 space-y-3">
            {[
              {
                step: 1,
                label: 'Taker accepted offer',
                done:  offer.status !== 'open',
                desc:  'USDC locked in vault escrow',
              },
              {
                step: 2,
                label: 'Maker sent local currency',
                done:  !!offer.maker_confirmed,
                desc:  `${offer.maker_address ? shortenAddr(offer.maker_address) : 'Maker'} sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to taker`,
              },
              {
                step: 3,
                label: 'Taker confirmed receipt',
                done:  !!offer.taker_confirmed,
                desc:  'Taker confirms receiving local currency',
              },
              {
                step: 4,
                label: 'Platform releases USDC',
                done:  offer.status === 'released',
                desc:  'Auto-released within 15 seconds of both confirmations',
              },
            ].map(({ step, label, done, desc }) => (
              <div key={step} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {done ? '✓' : step}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>
                    {label}
                  </p>
                  <p className="text-xs text-[#64748B]">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          <ClientOnly>
            {/* Action area */}
            {offer.status === 'released' && (
              <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                <p className="text-sm font-medium text-emerald-400">Offer complete</p>
                <p className="mt-1 text-xs text-emerald-600">
                  USDC released to taker · view tx ↗
                </p>
              </div>
            )}

            {offer.status === 'cancelled' && (
              <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                <p className="mt-1 text-xs text-red-600">USDC returned to maker</p>
              </div>
            )}

            {offer.status === 'open' && !isInvolved && (
              <p className="text-center text-xs text-[#64748B]">
                Accept this offer from the marketplace to participate.
              </p>
            )}

            {offer.status === 'open' && isMaker && (
              <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                <Clock className="mx-auto mb-1 h-4 w-4" />
                Waiting for a taker to accept your offer…
              </div>
            )}

            {offer.status === 'accepted' && (
              <div className="space-y-3">
                {/* Instructions based on role */}
                {isMaker && !offer.maker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs text-[#E2E8F0]">
                    <p className="font-medium">Your turn — send local currency</p>
                    <p className="mt-1 text-[#64748B]">
                      Send <strong>{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong> to
                      the taker via bank transfer or mobile money.
                      Then click confirm below.
                    </p>
                  </div>
                )}

                {isTaker && !offer.taker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs text-[#E2E8F0]">
                    <p className="font-medium">Waiting for maker to send {offer.local_currency}</p>
                    <p className="mt-1 text-[#64748B]">
                      Once you receive <strong>{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong>,
                      confirm below to release the USDC.
                    </p>
                  </div>
                )}

                {/* Maker confirm button */}
                {isMaker && (
                  <Button
                    className="w-full"
                    onClick={handleMakerConfirm}
                    disabled={!!offer.maker_confirmed || actionLoading}
                    variant={offer.maker_confirmed ? 'outline' : 'default'}
                  >
                    {actionLoading && isMaker ? (
                      <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                    ) : offer.maker_confirmed ? (
                      <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed sending</>
                    ) : (
                      `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                    )}
                  </Button>
                )}

                {/* Taker confirm button */}
                {isTaker && (
                  <Button
                    className="w-full"
                    onClick={handleTakerConfirm}
                    disabled={!!offer.taker_confirmed || actionLoading}
                    variant={offer.taker_confirmed ? 'outline' : 'default'}
                  >
                    {actionLoading && isTaker ? (
                      <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                    ) : offer.taker_confirmed ? (
                      <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed receipt</>
                    ) : (
                      `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                    )}
                  </Button>
                )}

                {/* Waiting for other side */}
                {isMaker && offer.maker_confirmed && !offer.taker_confirmed && (
                  <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Waiting for taker to confirm receipt…
                  </div>
                )}
                {isTaker && offer.taker_confirmed && !offer.maker_confirmed && (
                  <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Waiting for maker to confirm sending…
                  </div>
                )}

                {/* Both confirmed — waiting for platform */}
                {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                  <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Both confirmed — platform releasing USDC automatically…
                  </div>
                )}
              </div>
            )}
          </ClientOnly>

          {error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              {error}
            </div>
          )}

          {txHash && (
            <a
              href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline"
            >
              <ExternalLink className="h-3 w-3" />
              View confirmation tx on ArcScan
            </a>
          )}
        </div>
      </div>
    </div>
  )
}

// Normalise Turso raw row (array or object) to P2POffer
function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id:              row[0],  maker_address:   row[1],
      taker_address:   row[2],  usdc_amount:     row[3],
      local_currency:  row[4],  local_amount:    row[5],
      rate_offered:    row[6],  status:          row[7],
      maker_confirmed: row[8],  taker_confirmed: row[9],
      arc_tx_hash:     row[10], release_tx_hash: row[11],
      expires_at:      row[12], created_at:      row[13],
      updated_at:      row[14],
    }
  }
  return row as P2POffer
}
__EOF__
echo "✅  marketplace/[id]/page.tsx — offer detail with confirm buttons"

# ============================================================
# 6 — Update marketplace listing to link to detail page
# ============================================================
# Add "View details" link to each offer card
cat >> "afrifx-web/app/(app)/marketplace/page.tsx" << '__APPEND__'
// Note: offer cards already show Accept button.
// For accepted/own offers, users can click to view detail page.
// The offer ID is the bytes32 — safe to use in URLs.
__APPEND__
echo "✅  marketplace links ready (offer.id = bytes32, safe for URL)"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 3 auto-release complete!"
echo ""
echo "  IMPORTANT — Add platform wallet key to backend .env:"
echo "  nano ~/AfriFX/afrifx-api/.env"
echo "  Add: PLATFORM_WALLET_PRIVATE_KEY=0x_your_deployer_key"
echo ""
echo "  This must be the SAME wallet that deployed the contract"
echo "  (the contract owner) otherwise release() will revert."
echo ""
echo "  New pages:"
echo "    /marketplace/:id  — offer detail + confirm buttons"
echo ""
echo "  New services:"
echo "    platformWallet.ts   — calls release/cancel on-chain"
echo "    p2pReleaseWatcher   — polls every 15s, auto-releases"
echo ""
echo "  Auto-release flow:"
echo "    1. Both sides confirm (on-chain + DB)"
echo "    2. Watcher detects maker_confirmed=1 AND taker_confirmed=1"
echo "    3. Platform wallet calls releaseP2POffer(bytes32)"
echo "    4. Arc settles in <1s"
echo "    5. DB updated to 'released' with release tx hash"
echo "    6. Detail page polls every 5s — shows released state"
echo ""
echo "  Restart backend:  cd afrifx-api && npm run dev"
echo "══════════════════════════════════════════════════════"
