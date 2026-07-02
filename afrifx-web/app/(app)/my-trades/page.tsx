'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { UserDisplay } from '@/components/profile/UserDisplay'
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
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]), arc_tx_hash: row[10],
      release_tx_hash: row[11], expires_at: Number(row[12]),
      created_at: Number(row[13]), updated_at: Number(row[14]),
      order_type: row[15] ?? 'market',
      maker_timer_seconds: Number(row[17] ?? 1800),
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
}

const STATUS_BADGE: Record<string, any> = {
  open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
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

  const filtered = filter === 'all' ? offers : offers.filter(o => o.status === filter)

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to view your trades.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">My trades</h1>
          <p className="text-sm text-app-muted">All your P2P trades — as buyer or seller.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New offer</Button>
        </Link>
      </div>

      {/* Filter tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {(['all','open','accepted','released','cancelled'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-app-border text-app-text' : 'text-app-muted hover:text-app-text'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
      )}

      {!loading && filtered.length === 0 && (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <p className="text-sm text-app-muted">No trades found.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" size="sm" className="mt-4">
              <Plus className="h-4 w-4" /> Create your first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {filtered.map((offer) => {
          const isMaker  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const isTaker  = address?.toLowerCase() === offer.taker_address?.toLowerCase()
          const myRole   = isMaker ? 'Seller' : 'Buyer'
          const otherAddr = isMaker ? offer.taker_address : offer.maker_address
          const otherRole = isMaker ? 'Buyer' : 'Seller'

          return (
            <div key={offer.id}
              className="rounded-xl border border-app-border bg-app-surface p-4">
              <div className="flex items-center gap-4">
                {/* Flag */}
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-bg text-xl">
                  {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
                </div>

                {/* Details */}
                <div className="flex-1 min-w-0 space-y-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-app-text">
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                      <span className="mx-1.5 text-app-muted">↔</span>
                      {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                    </p>
                    <Badge variant="arc">{myRole}</Badge>
                    <Badge variant={STATUS_BADGE[offer.status] ?? 'default'}>{offer.status}</Badge>
                    {(offer as any).order_type && (
                      <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
                        {(offer as any).order_type}
                      </Badge>
                    )}
                  </div>

                  {/* Counterparty + date */}
                  <div className="flex flex-wrap items-center gap-3">
                    <span className="text-xs text-app-muted">{otherRole}:</span>
                    <ClientOnly fallback={<span className="text-xs text-app-muted">Loading…</span>}>
                      {otherAddr
                        ? <UserDisplay address={otherAddr} size="xs" fallback="Waiting…" />
                        : <span className="text-xs text-app-muted">Waiting for buyer…</span>
                      }
                    </ClientOnly>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="text-xs text-app-muted">
                      {new Date(offer.created_at * 1000).toLocaleDateString()}
                    </span>
                    {offer.release_tx_hash && (
                      <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                        target="_blank" rel="noopener noreferrer"
                        className="inline-flex items-center gap-1 text-xs text-emerald-400 hover:underline">
                        Release tx <ExternalLink className="h-3 w-3" />
                      </a>
                    )}
                  </div>
                </div>

                <Link href={`/marketplace/${offer.id}`} className="shrink-0">
                  <Button variant="outline" size="sm">
                    View <ArrowRight className="h-3.5 w-3.5" />
                  </Button>
                </Link>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
