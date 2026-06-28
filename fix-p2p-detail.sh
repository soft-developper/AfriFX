#!/bin/bash
# Run from ~/AfriFX:  bash fix-p2p-detail.sh
set -e
echo "🔧  Fixing marketplace → detail page link + offer normalization..."

# ============================================================
# 1 — Clean up the test offer from curl
# ============================================================
turso db shell afrifx \
  "DELETE FROM p2p_offers WHERE id = '0x1234567890123456789012345678901234567890123456789012345678901234';" \
  && echo "✅  Test offer removed"

# ============================================================
# 2 — Marketplace page — add View/Accept buttons that link
#     to the detail page
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

function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: row[3], local_currency: row[4], local_amount: row[5],
      rate_offered: row[6], status: row[7], maker_confirmed: row[8],
      taker_confirmed: row[9], arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: row[12], created_at: row[13], updated_at: row[14],
    }
  }
  return row as P2POffer
}

function timeLeft(expiresAt: number): string {
  const secs = expiresAt - Math.floor(Date.now() / 1000)
  if (secs <= 0) return 'Expired'
  if (secs > 3600) return `${Math.floor(secs / 3600)}h left`
  const mins = Math.floor(secs / 60)
  return mins > 0 ? `${mins}m left` : `${secs}s left`
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
      const rows = Array.isArray(data) ? data : []
      setOffers(rows.map(normalizeOffer))
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address) return
    setAccepting(offer.id)
    try {
      await acceptOffer(offer.id as `0x${string}`)
      // Navigate to detail page after accepting
      router.push(`/marketplace/${offer.id}`)
    } catch {
      setAccepting(null)
    }
  }

  return (
    <div>
      {/* Header */}
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
          { icon: ShieldCheck, label: 'USDC in escrow' },
          { icon: Zap,         label: 'Arc settlement' },
          { icon: Clock,       label: '30 min timeout' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#64748B]">
            <Icon className="h-3.5 w-3.5 text-[#378ADD]" />
            {label}
          </div>
        ))}
      </div>

      {/* Currency filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all', 'NGN', 'GHS', 'KES', 'ZAR', 'EGP'].map((c) => (
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

      {/* Offers */}
      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => (
            <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
          ))}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <p className="text-sm text-[#64748B]">No offers right now.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" className="mt-4" size="sm">
              <Plus className="h-4 w-4" /> Create the first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const isTaker  = address?.toLowerCase() === offer.taker_address?.toLowerCase()
          const expired  = offer.expires_at < Math.floor(Date.now() / 1000)
          const isMyOffer = isOwn || isTaker

          return (
            <div key={offer.id}
              className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">

              {/* Currency flag */}
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
              </div>

              {/* Details */}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="font-medium text-[#E2E8F0]">
                    {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                    <span className="mx-1.5 text-[#64748B]">→</span>
                    {Number(offer.usdc_amount).toFixed(2)} USDC
                  </p>
                  {isOwn   && <Badge variant="arc">Your offer</Badge>}
                  {isTaker && <Badge variant="success">You accepted</Badge>}
                </div>
                <div className="mt-0.5 flex items-center gap-3 text-xs text-[#64748B]">
                  <span>Rate: {Number(offer.rate_offered).toFixed(4)} USDC/{offer.local_currency}</span>
                  {offer.status === 'open' && (
                    <span className="flex items-center gap-1">
                      <Clock className="h-3 w-3" />{timeLeft(offer.expires_at)}
                    </span>
                  )}
                  <Badge variant={
                    offer.status === 'open'      ? 'warning' :
                    offer.status === 'accepted'  ? 'arc'     :
                    offer.status === 'released'  ? 'success' : 'danger'
                  }>
                    {offer.status}
                  </Badge>
                </div>
              </div>

              {/* Action buttons */}
              <div className="flex shrink-0 items-center gap-2">
                {/* View detail — always visible for own/involved offers */}
                {isMyOffer && (
                  <Link href={`/marketplace/${offer.id}`}>
                    <Button variant="outline" size="sm">
                      View <ArrowRight className="h-3.5 w-3.5" />
                    </Button>
                  </Link>
                )}

                {/* Accept — visible to others on open offers */}
                {!isMyOffer && offer.status === 'open' && !expired && (
                  <ClientOnly>
                    <Button size="sm"
                      onClick={() => handleAccept(offer)}
                      disabled={!address || accepting === offer.id}>
                      {accepting === offer.id
                        ? <><Loader2 className="h-3.5 w-3.5 animate-spin" /> Accepting…</>
                        : 'Accept offer'
                      }
                    </Button>
                  </ClientOnly>
                )}

                {!isMyOffer && offer.status === 'open' && expired && (
                  <Badge variant="danger">Expired</Badge>
                )}

                {!isMyOffer && offer.status !== 'open' && (
                  <Link href={`/marketplace/${offer.id}`}>
                    <Button variant="outline" size="sm">
                      View <ArrowRight className="h-3.5 w-3.5" />
                    </Button>
                  </Link>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  marketplace/page.tsx — View detail link on every offer"

# ============================================================
# 3 — Fix detail page: robust normalization for Turso rows
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, Clock, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw,
} from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

// Handles both Turso array rows and object rows
function normalizeOffer(row: any): P2POffer | null {
  if (!row) return null
  if (row.error) return null
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

function shortenAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export default function OfferDetailPage() {
  const params            = useParams()
  const { address }       = useAccount()
  const [offer, setOffer] = useState<P2POffer | null>(null)
  const [loading, setLoading]   = useState(true)
  const [notFound, setNotFound] = useState(false)

  const {
    makerConfirm, takerConfirm,
    isLoading: actionLoading,
    error, txHash,
  } = useP2P()

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) { setNotFound(true); return }
      const data = await res.json()
      const normalized = normalizeOffer(data)
      if (normalized) setOffer(normalized)
      else setNotFound(true)
    } catch {
      setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [params.id])

  useEffect(() => { load() }, [load])

  // Poll every 5s to detect confirmations + release
  useEffect(() => {
    const interval = setInterval(load, 5000)
    return () => clearInterval(interval)
  }, [load])

  if (loading) {
    return (
      <div className="space-y-4">
        <div className="h-8 w-48 animate-pulse rounded bg-[#0F1729]" />
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    )
  }

  if (notFound || !offer) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm text-[#64748B]">Offer not found.</p>
        <Link href="/marketplace">
          <Button variant="outline" size="sm">← Back to marketplace</Button>
        </Link>
      </div>
    )
  }

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`

  const statusBadge = {
    open:      'warning',
    accepted:  'arc',
    released:  'success',
    cancelled: 'danger',
  }[offer.status] as any

  const steps = [
    {
      n:    1,
      label: 'Offer accepted by taker',
      done:  offer.status !== 'open',
      desc:  'USDC locked in vault escrow on Arc',
    },
    {
      n:    2,
      label: 'Maker sent local currency',
      done:  !!offer.maker_confirmed,
      desc:  `${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} sent off-chain`,
    },
    {
      n:    3,
      label: 'Taker confirmed receipt',
      done:  !!offer.taker_confirmed,
      desc:  'Taker confirms receiving local currency',
    },
    {
      n:    4,
      label: 'USDC released to taker',
      done:  offer.status === 'released',
      desc:  'Platform auto-releases within 15 seconds',
    },
  ]

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
            <Badge variant={statusBadge}>{offer.status}</Badge>
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0, 26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">

        {/* Offer summary card */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Summary</p>

          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">
                {Number(offer.local_amount).toLocaleString()}
              </p>
              <p className="text-xs text-[#64748B]">{offer.local_currency}</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">
                {Number(offer.usdc_amount).toFixed(2)}
              </p>
              <p className="text-xs text-[#64748B]">USDC</p>
            </div>
          </div>

          <div className="space-y-2.5 text-xs">
            {[
              ['Rate', `${Number(offer.rate_offered).toFixed(6)} USDC/${offer.local_currency}`],
              ['Maker', offer.maker_address ? `${shortenAddr(offer.maker_address)}${isMaker ? ' (you)' : ''}` : '—'],
              ['Taker', offer.taker_address ? `${shortenAddr(offer.taker_address)}${isTaker ? ' (you)' : ''}` : 'Waiting…'],
            ].map(([label, val]) => (
              <div key={label} className="flex justify-between">
                <span className="text-[#64748B]">{label}</span>
                <span className="font-mono text-[#E2E8F0]">{val}</span>
              </div>
            ))}

            {offer.arc_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Create tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline">
                  {offer.arc_tx_hash.slice(0, 14)}…
                  <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}

            {offer.release_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Release tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                  {offer.release_tx_hash.slice(0, 14)}…
                  <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
          </div>
        </div>

        {/* Confirmation flow card */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Progress</p>

          {/* Steps */}
          <div className="mb-5 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {done ? '✓' : n}
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
            {/* Released */}
            {offer.status === 'released' && (
              <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                <p className="text-sm font-medium text-emerald-400">Complete — USDC released to taker</p>
              </div>
            )}

            {/* Cancelled */}
            {offer.status === 'cancelled' && (
              <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                <p className="text-sm font-medium text-red-400">Cancelled — USDC returned to maker</p>
              </div>
            )}

            {/* Open — waiting for taker */}
            {offer.status === 'open' && isMaker && (
              <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                <Clock className="mx-auto mb-1 h-4 w-4" />
                Waiting for a taker to accept…
              </div>
            )}

            {/* Accepted — action buttons */}
            {offer.status === 'accepted' && (
              <div className="space-y-3">

                {/* Maker instruction */}
                {isMaker && !offer.maker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                    <p className="font-medium text-[#E2E8F0]">Action required</p>
                    <p className="mt-1 text-[#64748B]">
                      Send <strong className="text-[#E2E8F0]">
                        {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      </strong> to the taker via bank or mobile money, then confirm below.
                    </p>
                  </div>
                )}

                {/* Taker instruction */}
                {isTaker && !offer.taker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                    <p className="font-medium text-[#E2E8F0]">
                      {offer.maker_confirmed
                        ? 'Maker says they sent the money — confirm once you receive it'
                        : `Waiting for maker to send ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                      }
                    </p>
                  </div>
                )}

                {/* Maker confirm button */}
                {isMaker && (
                  <Button className="w-full"
                    onClick={async () => { await makerConfirm(offerId); await load() }}
                    disabled={!!offer.maker_confirmed || actionLoading}
                    variant={offer.maker_confirmed ? 'outline' : 'default'}>
                    {actionLoading
                      ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming on Arc…</>
                      : offer.maker_confirmed
                      ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed sending</>
                      : `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                    }
                  </Button>
                )}

                {/* Taker confirm button */}
                {isTaker && (
                  <Button className="w-full"
                    onClick={async () => { await takerConfirm(offerId); await load() }}
                    disabled={!!offer.taker_confirmed || actionLoading}
                    variant={offer.taker_confirmed ? 'outline' : 'default'}>
                    {actionLoading
                      ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming on Arc…</>
                      : offer.taker_confirmed
                      ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed receipt</>
                      : `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                    }
                  </Button>
                )}

                {/* Waiting states */}
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

                {/* Both confirmed — pending platform release */}
                {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                  <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Both confirmed — releasing USDC automatically within 15 seconds…
                  </div>
                )}

                {/* Not involved */}
                {!isInvolved && (
                  <p className="text-center text-xs text-[#64748B]">
                    This offer is in progress between two parties.
                  </p>
                )}
              </div>
            )}
          </ClientOnly>

          {/* Error */}
          {error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              {error}
            </div>
          )}

          {/* Confirmation tx link */}
          {txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline">
              <ExternalLink className="h-3 w-3" />
              View confirmation tx on ArcScan
            </a>
          )}
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  marketplace/[id]/page.tsx — robust normalization + full flow"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Done. Restart frontend:"
echo "    cd afrifx-web && npm run dev"
echo ""
echo "  Key fixes:"
echo "  • Marketplace: View button on every offer (own + involved)"
echo "  • After accepting: auto-redirect to /marketplace/:id"
echo "  • Detail page: handles both Turso array and object rows"
echo "  • Detail page: polls every 5s for live updates"
echo "  • Test offer removed from Turso"
echo ""
echo "  To test existing accepted offers, navigate directly:"
echo "  http://localhost:3000/marketplace/0xbddcfa39f9cb9b82b3475fc2139bd2d5ba4c4e2f1ad157a24d8e318a4da1a69c"
echo "══════════════════════════════════════════════════════"
