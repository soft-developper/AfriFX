#!/bin/bash
# ============================================================
# AfriFX — Replace all wallet addresses with profile names
# Run from ~/AfriFX:  bash replace-addresses-with-names.sh
# ============================================================
set -e
echo ""
echo "👤  Replacing wallet addresses with profile names..."
echo ""

# ============================================================
# 1 — Ensure shortenAddress exists in lib/utils.ts
# ============================================================
cat > afrifx-web/lib/utils.ts << '__EOF__'
import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function shortenAddress(address: string | null | undefined): string {
  if (!address) return '—'
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

export function formatAmount(amount: number, decimals = 2): string {
  return amount.toLocaleString(undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

export function formatDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString([], {
    month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}
__EOF__
echo "✅  lib/utils.ts — shortenAddress exported"

# ============================================================
# 2 — UserDisplay component — already exists but let's
#     make sure it has a compact "inline" mode for tables
# ============================================================
cat > afrifx-web/components/profile/UserDisplay.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { ProfileAvatar } from './ProfileAvatar'
import { useProfileByAddress } from '@/hooks/useProfile'
import { getAvatarColor } from '@/lib/avatar'
import { shortenAddress } from '@/lib/utils'

interface UserDisplayProps {
  address:     string | null | undefined
  size?:       'xs' | 'sm' | 'md'
  showAvatar?: boolean
  clickable?:  boolean
  suffix?:     string
  fallback?:   string   // custom fallback text if no address
}

export function UserDisplay({
  address,
  size       = 'sm',
  showAvatar = true,
  clickable  = true,
  suffix,
  fallback,
}: UserDisplayProps) {
  const { data: profile, isLoading } = useProfileByAddress(address)

  if (!address) {
    return <span className="text-xs text-[#64748B]">{fallback ?? '—'}</span>
  }

  if (isLoading) {
    return (
      <span className="inline-flex items-center gap-1.5">
        {showAvatar && (
          <span className={`${size === 'xs' ? 'h-5 w-5' : 'h-6 w-6'} animate-pulse rounded-full bg-[#1B2B4B]`} />
        )}
        <span className="h-3 w-20 animate-pulse rounded bg-[#1B2B4B]" />
      </span>
    )
  }

  const displayName = profile?.display_name ?? shortenAddress(address)
  const username    = profile?.username
  const color       = profile?.avatar_color ?? getAvatarColor(address)
  const verified    = profile?.verified ?? false

  const label = username ? `@${username}` : displayName

  const inner = (
    <span className="inline-flex items-center gap-1.5">
      {showAvatar && (
        <ProfileAvatar
          displayName={displayName}
          avatarColor={color}
          size={size === 'md' ? 'sm' : 'xs'}
          verified={verified}
        />
      )}
      <span className={`font-medium ${
        size === 'xs' ? 'text-[11px]' :
        size === 'sm' ? 'text-xs'     : 'text-sm'
      } text-[#E2E8F0]`}>
        {label}
        {suffix && <span className="ml-1 text-[#378ADD] text-[10px]">{suffix}</span>}
      </span>
    </span>
  )

  if (clickable && username) {
    return (
      <Link href={`/profile/${username}`} className="hover:opacity-80 transition-opacity">
        {inner}
      </Link>
    )
  }

  return inner
}
__EOF__
echo "✅  UserDisplay.tsx — updated with fallback + size props"

# ============================================================
# 3 — Marketplace listing: show maker profile on offer cards
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
import { UserDisplay } from '@/components/profile/UserDisplay'
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
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]), arc_tx_hash: row[10],
      release_tx_hash: row[11], expires_at: Number(row[12]),
      created_at: Number(row[13]), updated_at: Number(row[14]),
      order_type: row[15] ?? 'market', limit_rate: row[16] ?? null,
      maker_timer_seconds: Number(row[17] ?? 1800),
      taker_deadline: row[18] ? Number(row[18]) : null,
      maker_deadline: row[19] ? Number(row[19]) : null,
      dispute_raised: Number(row[20] ?? 0), dispute_id: row[21] ?? null,
    } as any
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
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
      const url = currency === 'all' ? `${API}/offers` : `${API}/offers?currency=${currency}`
      const res = await fetch(url)
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
      const timerSecs = (offer as any).maker_timer_seconds ?? 1800
      await acceptOffer(offer.id as `0x${string}`, timerSecs)
      router.push(`/marketplace/${offer.id}`)
    } catch { setAccepting(null) }
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">P2P Marketplace</h1>
          <p className="text-sm text-[#64748B]">Buy USDC directly from verified traders.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> Create offer</Button>
        </Link>
      </div>

      {/* Trust badges */}
      <div className="mb-6 flex gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow'   },
          { icon: Zap,         label: 'Arc settlement'   },
          { icon: Clock,       label: 'Perpetual orders' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#64748B]">
            <Icon className="h-3.5 w-3.5 text-[#378ADD]" />{label}
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all','NGN','GHS','KES','ZAR','EGP'].map(c => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c ? 'bg-[#378ADD] text-white' : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}>
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
              className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex items-center gap-4">
                {/* Flag */}
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                  {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
                </div>

                {/* Details */}
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

                  {/* Maker profile + rate + timer */}
                  <div className="mt-1.5 flex flex-wrap items-center gap-3">
                    <ClientOnly fallback={
                      <span className="text-xs text-[#64748B]">Loading…</span>
                    }>
                      <UserDisplay
                        address={offer.maker_address}
                        size="xs"
                        suffix={isOwn ? '(you)' : undefined}
                      />
                    </ClientOnly>
                    <span className="text-xs text-[#64748B]">·</span>
                    <span className="text-xs text-[#64748B]">
                      1 USDC = {Number(offer.rate_offered) > 0
                        ? (1 / Number(offer.rate_offered)).toFixed(2)
                        : '—'} {offer.local_currency}
                    </span>
                    <span className="text-xs text-[#64748B]">·</span>
                    <span className="flex items-center gap-1 text-xs text-[#64748B]">
                      <Clock className="h-3 w-3" />{formatTimer(timer)}
                    </span>
                  </div>
                </div>

                {/* Action */}
                <div className="shrink-0">
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
echo "✅  marketplace/page.tsx — UserDisplay on each offer card"

# ============================================================
# 4 — Offer detail page: replace shortenAddr with UserDisplay
# ============================================================
# Patch just the summary section addresses
cat > afrifx-web/components/p2p/OfferParties.tsx << '__EOF__'
'use client'
import { UserDisplay } from '@/components/profile/UserDisplay'

interface Props {
  makerAddress: string
  takerAddress: string | null | undefined
  isMaker:      boolean
  isTaker:      boolean
}

export function OfferParties({ makerAddress, takerAddress, isMaker, isTaker }: Props) {
  return (
    <div className="space-y-2 text-xs">
      <div className="flex items-center justify-between">
        <span className="text-[#64748B]">Maker (wants local)</span>
        <UserDisplay
          address={makerAddress}
          size="xs"
          suffix={isMaker ? '(you)' : undefined}
        />
      </div>
      <div className="flex items-center justify-between">
        <span className="text-[#64748B]">Taker (wants USDC)</span>
        {takerAddress
          ? <UserDisplay address={takerAddress} size="xs" suffix={isTaker ? '(you)' : undefined} />
          : <span className="text-[#64748B] text-xs">Waiting for taker…</span>
        }
      </div>
    </div>
  )
}
__EOF__
echo "✅  components/p2p/OfferParties.tsx — reusable maker/taker display"

# ============================================================
# 5 — My trades page: show profile names instead of addresses
# ============================================================
cat > "afrifx-web/app/(app)/my-trades/page.tsx" << '__EOF__'
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
        <p className="text-sm text-[#64748B]">Connect your wallet to view your trades.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">My trades</h1>
          <p className="text-sm text-[#64748B]">All your P2P offers — as maker and taker.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New offer</Button>
        </Link>
      </div>

      {/* Filter tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {(['all','open','accepted','released','cancelled'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />)}
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

      <div className="space-y-3">
        {filtered.map((offer) => {
          const isMaker  = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const isTaker  = address?.toLowerCase() === offer.taker_address?.toLowerCase()
          const myRole   = isMaker ? 'Maker' : 'Taker'
          const otherAddr = isMaker ? offer.taker_address : offer.maker_address
          const otherRole = isMaker ? 'Taker' : 'Maker'

          return (
            <div key={offer.id}
              className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex items-center gap-4">
                {/* Flag */}
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                  {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
                </div>

                {/* Details */}
                <div className="flex-1 min-w-0 space-y-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-[#E2E8F0]">
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                      <span className="mx-1.5 text-[#64748B]">↔</span>
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
                    <span className="text-xs text-[#64748B]">{otherRole}:</span>
                    <ClientOnly fallback={<span className="text-xs text-[#64748B]">Loading…</span>}>
                      {otherAddr
                        ? <UserDisplay address={otherAddr} size="xs" fallback="Waiting…" />
                        : <span className="text-xs text-[#64748B]">Waiting for taker…</span>
                      }
                    </ClientOnly>
                    <span className="text-xs text-[#64748B]">·</span>
                    <span className="text-xs text-[#64748B]">
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
__EOF__
echo "✅  my-trades/page.tsx — UserDisplay for counterparty"

# ============================================================
# 6 — Update offer detail page to use OfferParties component
# ============================================================
# Inject OfferParties import and usage into the detail page
# We patch the two address lines in the summary section
python3 - << 'PYEOF'
import re

path = "afrifx-web/app/(app)/marketplace/[id]/page.tsx"
try:
    with open(path, 'r') as f:
        content = f.read()

    # Add import after existing imports
    if 'OfferParties' not in content:
        content = content.replace(
            "import { useP2P } from '@/hooks/useP2P'",
            "import { useP2P } from '@/hooks/useP2P'\nimport { OfferParties } from '@/components/p2p/OfferParties'"
        )

    # Replace the old address rows with OfferParties component
    old = """            {[
              ['Maker', `${offer.maker_address ? shortenAddr(offer.maker_address) : '—'}${isMaker ? ' (you)' : ''}`],
              ['Taker', offer.taker_address ? `${shortenAddr(offer.taker_address!)}${isTaker ? ' (you)' : ''}` : 'Waiting…'],
              ['Rate',  `1 USDC = ${Number(offer.rate_offered) > 0 ? (1/Number(offer.rate_offered)).toFixed(2) : '—'} ${offer.local_currency}`],
            ].map(([l,v]) => (
              <div key={l} className="flex justify-between">
                <span className="text-[#64748B]">{l}</span>
                <span className="font-mono text-[#E2E8F0]">{v}</span>
              </div>
            ))}"""

    new = """            <OfferParties
              makerAddress={offer.maker_address}
              takerAddress={offer.taker_address}
              isMaker={isMaker}
              isTaker={isTaker}
            />
            <div className="flex justify-between text-xs">
              <span className="text-[#64748B]">Rate</span>
              <span className="font-mono text-[#E2E8F0]">
                1 USDC = {Number(offer.rate_offered) > 0
                  ? (1/Number(offer.rate_offered)).toFixed(2) : '—'} {offer.local_currency}
              </span>
            </div>"""

    if old in content:
        content = content.replace(old, new)
        print("Patched address rows with OfferParties")
    else:
        print("Pattern not found — OfferParties import added, manual patch may be needed")

    with open(path, 'w') as f:
        f.write(content)
    print("Done")
except FileNotFoundError:
    print(f"File not found: {path}")
PYEOF

echo "✅  marketplace/[id]/page.tsx — OfferParties injected"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Wallet addresses replaced with profile names!"
echo ""
echo "  Updated locations:"
echo "  • Marketplace listing — maker name + avatar on each card"
echo "  • Offer detail page  — maker/taker as clickable names"
echo "  • My trades page     — counterparty name shown"
echo ""
echo "  UserDisplay behaviour:"
echo "  • Has profile → shows avatar + @username"
echo "  • No profile  → shows shortened address (0x1F02…Ae6D)"
echo "  • Loading     → animated skeleton"
echo "  • Clickable   → links to /profile/@username"
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
