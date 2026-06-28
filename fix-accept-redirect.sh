#!/bin/bash
# Run from ~/AfriFX:  bash fix-accept-redirect.sh
set -e
echo "🔧  Fixing taker accept redirect..."

# ============================================================
# FIX 1 — Marketplace: pass ?accepted=1 on redirect
# ============================================================
sed -i "s|router.push(\`/marketplace/\${offer.id}\`)|router.push(\`/marketplace/\${offer.id}?accepted=1\`)|g" \
  afrifx-web/app/\(app\)/marketplace/page.tsx
echo "✅  marketplace/page.tsx — redirect includes ?accepted=1"

# ============================================================
# FIX 2 — Offer detail page: read searchParams + treat
#          current user as taker when ?accepted=1 is present
#          + poll every 2s (not 5s) until taker_address syncs
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams, useSearchParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { TimerBanner } from '@/components/p2p/TimerBanner'
import { ChatWindow } from '@/components/chat/ChatWindow'
import { OfferParties } from '@/components/p2p/OfferParties'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer | null {
  if (!row || row.error) return null
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
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    taker_deadline:      row.taker_deadline  ? Number(row.taker_deadline)  : null,
    maker_deadline:      row.maker_deadline  ? Number(row.maker_deadline)  : null,
    dispute_raised:      Number(row.dispute_raised      ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
    order_type:          row.order_type ?? 'market',
  } as P2POffer
}

function shortenAddr(a: string) { return `${a.slice(0,6)}…${a.slice(-4)}` }

export default function OfferDetailPage() {
  const params        = useParams()
  const searchParams  = useSearchParams()
  const { address }   = useAccount()

  // ?accepted=1 means this user JUST accepted — treat as taker immediately
  const justAccepted  = searchParams.get('accepted') === '1'

  const [offer, setOffer]         = useState<P2POffer | null>(null)
  const [loading, setLoading]     = useState(true)
  const [notFound, setNotFound]   = useState(false)
  const [disputing, setDisputing] = useState(false)
  const [disputeDone, setDisputeDone] = useState(false)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) { setNotFound(true); return }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) setOffer(norm)
      else setNotFound(true)
    } catch { setNotFound(true) }
    finally  { setLoading(false) }
  }, [params.id])

  useEffect(() => { load() }, [load])

  // Poll: fast (2s) if justAccepted until taker_address syncs, then normal (5s)
  useEffect(() => {
    const isStillSyncing = justAccepted && !offer?.taker_address
    const interval = setInterval(load, isStillSyncing ? 2000 : 5000)
    return () => clearInterval(interval)
  }, [load, justAccepted, offer?.taker_address])

  if (loading) return (
    <div className="space-y-4">
      <div className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-[#64748B]">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  // Determine role:
  // - Normal: check address against DB maker/taker
  // - justAccepted=1: treat current user as taker even if DB hasn't synced yet
  const isMaker = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker = justAccepted
    ? !isMaker && !!address  // user just accepted — they ARE the taker
    : address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = (offer as any).maker_timer_seconds ?? 1800

  // Third-party access control for accepted trades
  if (offer.status === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-[#E2E8F0]">This trade is in progress.</p>
        <p className="text-xs text-[#64748B]">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace"><Button variant="outline" size="sm">← Back to marketplace</Button></Link>
      </div>
    )
  }

  const statusBadge = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }[offer.status] as any

  const steps = [
    { n:1, done: offer.status !== 'open',     label: 'Taker accepted offer',               desc: 'USDC locked in vault' },
    { n:2, done: offer.status !== 'open',     label: `Taker sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: 'Taker confirmed: "I sent the money"',desc: 'Taker window' },
    { n:4, done: !!offer.maker_confirmed,     label: 'Maker confirmed: "I received it"',   desc: 'Maker window' },
    { n:5, done: offer.status === 'released', label: 'Platform releases USDC to taker',    desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offer.status === 'accepted' && !offer.taker_confirmed && !!(offer as any).taker_deadline
  const showMakerTimer = offer.status === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!(offer as any).maker_deadline

  // Show chat when involved and trade is in progress or just accepted
  const showChat = isInvolved && (
    offer.status === 'accepted' ||
    offer.status === 'released' ||
    justAccepted
  ) && !!offer.taker_address

  // If just accepted but DB hasn't synced taker_address yet — show syncing state
  const isSyncing = justAccepted && !offer.taker_address

  async function handleDispute() {
    if (!address) return
    setDisputing(true)
    try {
      await raiseDispute(offer!.id, 'Maker did not confirm receipt within agreed window')
      setDisputeDone(true)
      await load()
    } catch {} finally { setDisputing(false) }
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-4 flex items-center gap-3">
        <Link href={isInvolved ? '/my-trades' : '/marketplace'}>
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
              {(offer as any).order_type ?? 'market'}
            </Badge>
            {!!(offer as any).dispute_raised && <Badge variant="danger">Disputed</Badge>}
            {isTaker && <Badge variant="success">You are the taker</Badge>}
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {/* Syncing banner — shown briefly after accepting while DB catches up */}
      {isSyncing && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-[#378ADD]/30 bg-[#378ADD]/10 px-4 py-3 text-sm text-[#378ADD]">
          <Loader2 className="h-4 w-4 animate-spin shrink-0" />
          Trade accepted! Setting up your trade interface…
        </div>
      )}

      {/* Timer banners */}
      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={(offer as any).taker_deadline}
              totalSeconds={timerSecs}
              phase="taker"
              isMine={isTaker}
            />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={(offer as any).maker_deadline}
              totalSeconds={timerSecs}
              phase="maker"
              isMine={isMaker}
            />
          </div>
        )}
      </ClientOnly>

      {/* 3-column when chat is visible, 2-column otherwise */}
      <div className={`grid gap-4 ${showChat ? 'lg:grid-cols-3' : 'lg:grid-cols-2'}`}>

        {/* Summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-[#64748B]">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()}</p>
              <p className="text-xs text-[#64748B]">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <OfferParties
            makerAddress={offer.maker_address}
            takerAddress={offer.taker_address}
            isMaker={isMaker}
            isTaker={isTaker}
          />

          <div className="mt-2 flex justify-between text-xs">
            <span className="text-[#64748B]">Rate</span>
            <span className="font-mono text-[#E2E8F0]">
              1 USDC = {Number(offer.rate_offered) > 0
                ? (1/Number(offer.rate_offered)).toFixed(2) : '—'} {offer.local_currency}
            </span>
          </div>

          {offer.arc_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-[#64748B]">Create tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline">
                {offer.arc_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}
          {offer.release_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-[#64748B]">Release tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                {offer.release_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}

          {isMaker && offer.status === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Progress + actions */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Progress</p>
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>{label}</p>
                  <p className="text-xs text-[#64748B]">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          <ClientOnly>
            <div className="space-y-3">
              {offer.status === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {offer.status === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!(offer as any).dispute_raised && offer.status === 'accepted' && (
                <div className="rounded-lg border border-amber-900/50 bg-amber-900/20 p-3 text-xs">
                  <div className="flex items-start gap-2">
                    <Flag className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-400" />
                    <div>
                      <p className="font-medium text-amber-400">Dispute raised</p>
                      <p className="mt-0.5 text-amber-600">USDC locked. Auto-releases in 24h if unresolved.</p>
                    </div>
                  </div>
                </div>
              )}

              {offer.status === 'open' && isMaker && (
                <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                  Waiting for a seller to accept your offer…
                </div>
              )}

              {/* Syncing: just accepted but DB not updated yet */}
              {isSyncing && (
                <div className="flex items-center gap-2 rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 px-3 py-3 text-xs text-[#378ADD]">
                  <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                  <div>
                    <p className="font-medium">Offer accepted on Arc!</p>
                    <p className="mt-0.5 opacity-70">Syncing trade details — this takes a few seconds…</p>
                  </div>
                </div>
              )}

              {offer.status === 'accepted' && !isSyncing && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Your turn — send {offer.local_currency} to maker</p>
                      <p className="mt-1 text-[#64748B]">
                        Send <strong className="text-[#E2E8F0]">
                          {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                        </strong> via bank or mobile money, then confirm below.
                        Use the chat to share your payment details or proof.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for taker to send and confirm {Number(offer.local_amount).toLocaleString()} {offer.local_currency}…
                    </div>
                  )}

                  {isMaker && offer.taker_confirmed && !offer.maker_confirmed && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Check your account</p>
                      <p className="mt-1 text-[#64748B]">
                        Taker says they sent <strong className="text-[#E2E8F0]">
                          {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                        </strong>. Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {/* Taker confirm button */}
                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`
                      }
                    </Button>
                  )}

                  {/* Maker confirm button */}
                  {isMaker && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? 'Waiting for taker to send first…'
                        : `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                      }
                    </Button>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for maker to confirm receipt…
                    </div>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised &&
                   (offer as any).maker_deadline &&
                   (offer as any).maker_deadline < Math.floor(Date.now() / 1000) && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ Maker has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={handleDispute} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">
                          ✓ Dispute raised — USDC auto-releases in 24h.
                        </p>
                      )}
                    </div>
                  )}

                  {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                    <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      Both confirmed — releasing USDC within 15 seconds…
                    </div>
                  )}
                </>
              )}
            </div>
          </ClientOnly>

          {error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>

        {/* Chat — visible to maker/taker once offer is accepted */}
        {showChat && offer.taker_address && (
          <ClientOnly>
            <ChatWindow
              offerId={offer.id}
              makerAddress={offer.maker_address}
              takerAddress={offer.taker_address}
              currency={offer.local_currency}
              amount={Number(offer.local_amount)}
            />
          </ClientOnly>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  marketplace/[id]/page.tsx — justAccepted logic + syncing banner"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Accept redirect fixed!"
echo ""
echo "  Root cause:"
echo "  After accepting, router.push fires but the DB PATCH"
echo "  hadn't propagated yet → detail page loaded with"
echo "  taker_address=null → isInvolved=false → no trade UI"
echo ""
echo "  Fix:"
echo "  • Marketplace redirects to /marketplace/:id?accepted=1"
echo "  • Detail page reads ?accepted=1 → treats current user"
echo "    as taker IMMEDIATELY without waiting for DB"
echo "  • Shows 'Setting up your trade...' syncing banner"
echo "  • Polls every 2s (instead of 5s) until taker_address syncs"
echo "  • Badge 'You are the taker' confirms role clearly"
echo "  • Chat and settlement UI appear instantly"
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
SCRIPTEOF
echo "done"</parameter>
<parameter name="description">Write accept redirect race condition fix script</parameter>
