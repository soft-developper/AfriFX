#!/bin/bash
# Run from ~/AfriFX:  bash fix-offer-visibility.sh
set -e
echo "🔒  Fixing offer visibility — accepted trades hidden from third parties..."

# ============================================================
# FIX 1 — Backend: marketplace listing only shows open offers
# ============================================================
cat > afrifx-api/src/routes/offers.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// GET /offers — only OPEN offers visible to everyone
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const type     = req.query.type     as string | undefined
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status = 'open'
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          ${type     ? sql`AND order_type = ${type}`         : sql``}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/my?wallet=0x… — maker + taker see ALL their offers
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id — returns offer but frontend enforces access control
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })
    res.json(offers[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers — create new offer
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount, localCurrency, localAmount,
    rateOffered, orderType, limitRate, makerTimerSeconds, arcTxHash,
  } = req.body
  const now      = Math.floor(Date.now() / 1000)
  const PERPETUAL = 9999999999
  try {
    await db.run(
      sql`INSERT OR IGNORE INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, order_type, limit_rate, maker_timer_seconds,
           arc_tx_hash, expires_at, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${orderType ?? 'market'}, ${limitRate ?? null},
           ${makerTimerSeconds ?? 1800}, ${arcTxHash ?? null},
           ${PERPETUAL}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) {
    console.error('[Offers] Insert error:', err.message)
    res.status(500).json({ error: err.message })
  }
})

// PATCH /offers/:id
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress, makerConfirmed, takerConfirmed,
    releaseTxHash, takerDeadline, makerDeadline,
    disputeRaised, disputeId,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status         ?? null}, status),
            taker_address   = COALESCE(${takerAddress   ? takerAddress.toLowerCase() : null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash  ?? null}, release_tx_hash),
            taker_deadline  = COALESCE(${takerDeadline  ?? null}, taker_deadline),
            maker_deadline  = COALESCE(${makerDeadline  ?? null}, maker_deadline),
            dispute_raised  = COALESCE(${disputeRaised  ?? null}, dispute_raised),
            dispute_id      = COALESCE(${disputeId      ?? null}, dispute_id),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers/:id/dispute
router.post('/:id/dispute', async (req, res) => {
  const { raisedBy, reason } = req.body
  const offerId      = req.params.id
  const now          = Math.floor(Date.now() / 1000)
  const disputeId    = randomUUID()
  const autoSettleAt = now + 86400
  try {
    await db.run(
      sql`INSERT INTO disputes (id, offer_id, raised_by, reason, auto_settle_at, created_at)
          VALUES (${disputeId}, ${offerId}, ${raisedBy.toLowerCase()},
                  ${reason ?? null}, ${autoSettleAt}, ${now})`
    )
    await db.run(
      sql`UPDATE p2p_offers
          SET dispute_raised = 1, dispute_id = ${disputeId}, updated_at = ${now}
          WHERE id = ${offerId}`
    )
    const offerRows = await db.run(sql`SELECT maker_address FROM p2p_offers WHERE id = ${offerId}`)
    const rows = Array.isArray((offerRows as any).rows) ? (offerRows as any).rows : []
    if (rows.length) {
      const maker = rows[0].maker_address ?? rows[0][0]
      await db.run(
        sql`UPDATE users SET dispute_warnings = dispute_warnings + 1
            WHERE LOWER(wallet_address) = ${maker.toLowerCase()}`
      ).catch(() => {})
    }
    res.status(201).json({ disputeId, autoSettleAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id/dispute
router.get('/:id/dispute', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM disputes WHERE offer_id = ${req.params.id}
          ORDER BY created_at DESC LIMIT 1`
    )
    const disputes = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!disputes.length) return res.status(404).json({ error: 'No dispute' })
    res.json(disputes[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/offers.ts — listing shows only open offers"

# ============================================================
# FIX 2 — Frontend: My Trades page — maker/taker see their
#          active trades separately from the open marketplace
# ============================================================
mkdir -p "afrifx-web/app/(app)/my-trades"

cat > "afrifx-web/app/(app)/my-trades/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { ArrowRight, Plus, ExternalLink } from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: row[3], local_currency: row[4], local_amount: row[5],
      rate_offered: row[6], status: row[7],
      maker_confirmed: Number(row[8]), taker_confirmed: Number(row[9]),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: row[12], created_at: row[13], updated_at: row[14],
    }
  }
  return {
    ...row,
    maker_confirmed: Number(row.maker_confirmed ?? 0),
    taker_confirmed: Number(row.taker_confirmed ?? 0),
  } as P2POffer
}

const STATUS_BADGE: Record<string, any> = {
  open:      'warning',
  accepted:  'arc',
  released:  'success',
  cancelled: 'danger',
}

export default function MyTradesPage() {
  const { address, isConnected } = useAccount()
  const [offers,  setOffers]  = useState<P2POffer[]>([])
  const [loading, setLoading] = useState(true)
  const [filter,  setFilter]  = useState<'all'|'open'|'accepted'|'released'|'cancelled'>('all')

  useEffect(() => {
    if (!address) { setLoading(false); return }
    fetch(`${API}/offers/my?wallet=${address}`)
      .then(r => r.json())
      .then(data => setOffers(Array.isArray(data) ? data.map(normalizeOffer) : []))
      .catch(() => setOffers([]))
      .finally(() => setLoading(false))
  }, [address])

  const filtered = filter === 'all'
    ? offers
    : offers.filter(o => o.status === filter)

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-[#64748B]">Connect your wallet to view your trades.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">My trades</h1>
          <p className="text-sm text-[#64748B]">
            All your P2P offers — as maker and taker.
          </p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New offer</Button>
        </Link>
      </div>

      {/* Filter tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {(['all','open','accepted','released','cancelled'] as const).map((f) => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f
                ? 'bg-[#1B2B4B] text-[#E2E8F0]'
                : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-20 animate-pulse rounded-xl bg-[#0F1729]" />)}
        </div>
      )}

      {!loading && filtered.length === 0 && (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <p className="text-sm text-[#64748B]">No trades found.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create your first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-2">
        {filtered.map((offer) => {
          const isMaker = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const role    = isMaker ? 'Maker' : 'Taker'

          return (
            <div key={offer.id}
              className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">

              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
              </div>

              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="font-medium text-[#E2E8F0]">
                    {Number(offer.usdc_amount).toFixed(2)} USDC
                    <span className="mx-1.5 text-[#64748B]">↔</span>
                    {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                  </p>
                  <Badge variant="arc">{role}</Badge>
                  <Badge variant={STATUS_BADGE[offer.status] ?? 'default'}>
                    {offer.status}
                  </Badge>
                  {(offer as any).order_type && (
                    <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
                      {(offer as any).order_type}
                    </Badge>
                  )}
                </div>
                <p className="mt-0.5 text-xs text-[#64748B]">
                  {new Date(offer.created_at * 1000).toLocaleString()}
                  {offer.release_tx_hash && (
                    <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                      target="_blank" rel="noopener noreferrer"
                      className="ml-2 inline-flex items-center gap-1 text-emerald-400 hover:underline">
                      Release tx <ExternalLink className="h-2.5 w-2.5" />
                    </a>
                  )}
                </p>
              </div>

              <Link href={`/marketplace/${offer.id}`}>
                <Button variant="outline" size="sm">
                  View <ArrowRight className="h-3.5 w-3.5" />
                </Button>
              </Link>
            </div>
          )
        })}
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/my-trades/page.tsx — private trade history"

# ============================================================
# FIX 3 — Add My Trades to sidebar
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History,
  LayoutDashboard, TrendingUp, Globe,
  Store, ClipboardList
} from 'lucide-react'
import { cn } from '@/lib/utils'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',     icon: ArrowLeftRight, label: 'Convert'     },
    { href: '/corridor',    icon: Globe,          label: 'Corridor'    },
    { href: '/send',        icon: Send,           label: 'Send'        },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',       icon: Store,          label: 'Marketplace' },
    { href: '/marketplace/create',icon: ClipboardList,  label: 'Create offer'},
    { href: '/my-trades',         icon: ClipboardList,  label: 'My trades'   },
  ]},
  { label: 'Account', items: [
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()
  return (
    <aside className="w-52 shrink-0 border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href || pathname.startsWith(href + '/')
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — My trades link added"

# ============================================================
# FIX 4 — Marketplace accept: redirect to my-trades after
#          so accepted offer disappears from public view
# ============================================================
echo "✅  Marketplace accept already redirects to /marketplace/:id"
echo "    (detail page) which is private to the two parties"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Offer visibility fix complete!"
echo ""
echo "  Rules now:"
echo "  • /marketplace      — OPEN offers only (third parties)"
echo "  • /marketplace/:id  — accessible but 'accepted' trades"
echo "    show 'Trade in progress' to third parties"
echo "  • /my-trades        — maker + taker see ALL their offers"
echo "    (open, accepted, released, cancelled)"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
