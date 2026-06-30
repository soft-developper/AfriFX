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
import { useProfileByAddress } from '@/hooks/useProfile'
import { DisputeStatus } from '@/components/dispute/DisputeStatus'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

// Extend P2POffer with extra fields we use
interface OfferExtended extends P2POffer {
  taker_deadline?:      number | null
  maker_deadline?:      number | null
  dispute_raised?:      number
  dispute_id?:          string | null
  maker_timer_seconds?: number
  order_type?:          string
}

function normalizeOffer(row: unknown): OfferExtended | null {
  if (!row || (row as Record<string, unknown>).error) return null
  if (Array.isArray(row)) {
    return {
      id:              row[0],
      maker_address:   row[1],
      taker_address:   row[2],
      usdc_amount:     row[3],
      local_currency:  row[4],
      local_amount:    row[5],
      rate_offered:    row[6],
      status:          row[7],
      maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]),
      arc_tx_hash:     row[10],
      release_tx_hash: row[11],
      expires_at:      row[12],
      created_at:      row[13],
      updated_at:      row[14],
    } as OfferExtended
  }
  const r = row as Record<string, unknown>
  return {
    ...(r as unknown as P2POffer),
    maker_confirmed:     Number(r.maker_confirmed     ?? 0),
    taker_confirmed:     Number(r.taker_confirmed     ?? 0),
    taker_deadline:      r.taker_deadline  ? Number(r.taker_deadline)  : null,
    maker_deadline:      r.maker_deadline  ? Number(r.maker_deadline)  : null,
    dispute_raised:      Number(r.dispute_raised      ?? 0),
    maker_timer_seconds: Number(r.maker_timer_seconds ?? 1800),
    order_type:          (r.order_type as string) ?? 'market',
  } as OfferExtended
}

export default function OfferDetailPage() {
  const params       = useParams()
  const searchParams = useSearchParams()
  const { address }  = useAccount()

  const justAccepted = searchParams.get('accepted') === '1'

  const [offer,       setOffer]       = useState<OfferExtended | null>(null)
  const [loading,     setLoading]     = useState(true)
  const [notFound,    setNotFound]    = useState(false)
  const [disputing,   setDisputing]   = useState(false)
  const [disputeDone,    setDisputeDone]    = useState(false)
  const [disputeRecord,  setDisputeRecord]  = useState<{ id: string } | null>(null)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) {
        if (!justAccepted) setNotFound(true)
        return
      }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) {
        setOffer(norm)
        setNotFound(false)
      } else if (!justAccepted) {
        setNotFound(true)
      }
    } catch {
      if (!justAccepted) setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [params.id, justAccepted])

  useEffect(() => { load() }, [load])

  // Fetch dispute record when dispute is raised
  useEffect(() => {
    if (!offer?.dispute_raised || disputeRecord) return
    fetch(`${API}/disputes/offer/${offer.id}`)
      .then(r => r.json())
      .then(data => { if (data?.id) setDisputeRecord(data) })
      .catch(() => {})
  }, [offer?.dispute_raised, offer?.id])

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

  const offerStatus = offer.status as string

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = justAccepted
    ? !isMaker && !!address
    : address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = offer.maker_timer_seconds ?? 1800

  if (offerStatus === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-[#E2E8F0]">This trade is in progress.</p>
        <p className="text-xs text-[#64748B]">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace">
          <Button variant="outline" size="sm">← Back to marketplace</Button>
        </Link>
      </div>
    )
  }

  const statusBadgeMap: Record<string, string> = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }
  const statusBadge = (statusBadgeMap[offerStatus] ?? 'default') as
    'warning' | 'arc' | 'success' | 'danger' | 'default'

  const { data: makerProfile } = useProfileByAddress(offer?.maker_address)
  const { data: takerProfile } = useProfileByAddress(offer?.taker_address)

  const makerName = makerProfile?.display_name ?? makerProfile?.username ??
    (offer?.maker_address ? offer.maker_address.slice(0,8) + '…' : 'Seller')
  const takerName = takerProfile?.display_name ?? takerProfile?.username ??
    (offer?.taker_address ? offer.taker_address.slice(0,8) + '…' : 'Buyer')
  const myName    = isMaker ? makerName : takerName
  const otherName = isMaker ? takerName : makerName

  const steps = [
    { n:1, done: offerStatus !== 'open',     label: `${takerName} accepted offer`,               desc: 'USDC locked in vault' },
    { n:2, done: offerStatus !== 'open',     label: `${takerName} sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to ${makerName}`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: `${takerName} confirmed: "I sent the money"`, desc: 'Taker window' },
    { n:4, done: !!offer.maker_confirmed,     label: `${makerName} confirmed: "I received it"`,    desc: 'Maker window' },
    { n:5, done: offerStatus === 'released',  label: 'Platform releases USDC to taker',     desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offerStatus === 'accepted' && !offer.taker_confirmed && !!offer.taker_deadline
  const showMakerTimer = offerStatus === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!offer.maker_deadline

  const showChat = isInvolved && (
    offerStatus === 'accepted' ||
    offerStatus === 'released' ||
    justAccepted
  ) && !!offer.taker_address

  const isSyncing = justAccepted && !offer.taker_address

  async function handleDispute(
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address || !offer) return
    setDisputing(true)
    try {
      await raiseDispute(
        offer.id,
        disputeType === 'maker_silent'
          ? 'Maker did not confirm receipt — possible non-response'
          : 'Taker claims to have sent payment but maker did not receive it',
        disputeType,
        raisedByRole,
      )
      setDisputeDone(true)
      await load()
    } catch (_e) {}
    finally { setDisputing(false) }
  }

  const localAmountFormatted = Number(offer.local_amount).toLocaleString()
  const nowTs = Math.floor(Date.now() / 1000)

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
            <Badge variant={offer.order_type === 'limit' ? 'warning' : 'arc'}>
              {offer.order_type ?? 'market'}
            </Badge>
            {!!offer.dispute_raised && <Badge variant="danger">Disputed</Badge>}
            {isTaker && <Badge variant="success">You are the buyer</Badge>}
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {isSyncing && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-[#378ADD]/30 bg-[#378ADD]/10 px-4 py-3 text-sm text-[#378ADD]">
          <Loader2 className="h-4 w-4 animate-spin shrink-0" />
          Trade accepted! Setting up your trade interface…
        </div>
      )}

      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.taker_deadline as number}
              totalSeconds={timerSecs}
              phase="taker"
              isMine={isTaker}
            />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.maker_deadline as number}
              totalSeconds={timerSecs}
              phase="maker"
              isMine={isMaker}
            />
          </div>
        )}
      </ClientOnly>

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
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{localAmountFormatted}</p>
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
                ? (1 / Number(offer.rate_offered)).toFixed(2) : '—'} {offer.local_currency}
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

          {isMaker && offerStatus === 'open' && (
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
              {offerStatus === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {offerStatus === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!offer.dispute_raised && offerStatus === 'accepted' && (
                disputeRecord?.id ? (
                  <DisputeStatus
                    disputeId={disputeRecord.id}
                    offerId={offer.id}
                    userAddress={address ?? ''}
                    userRole={isMaker ? 'maker' : 'taker'}
                    username={undefined}
                  />
                ) : (
                  <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                    <p className="font-medium text-amber-400">⏳ Dispute raised — awaiting admin review</p>
                    <p className="mt-1 text-amber-600">An admin will accept and handle your dispute shortly.</p>
                  </div>
                )
              )}

              {offerStatus === 'open' && isMaker && (
                <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                  Waiting for a buyer to accept your offer…
                </div>
              )}

              {isSyncing && (
                <div className="flex items-center gap-2 rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 px-3 py-3 text-xs text-[#378ADD]">
                  <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                  <div>
                    <p className="font-medium">Offer accepted on Arc!</p>
                    <p className="mt-0.5 opacity-70">Syncing trade details…</p>
                  </div>
                </div>
              )}

              {offerStatus === 'accepted' && !isSyncing && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Your turn — send {offer.local_currency} to {makerName}</p>
                      <p className="mt-1 text-[#64748B]">
                        Send <strong className="text-[#E2E8F0]">
                          {localAmountFormatted} {offer.local_currency}
                        </strong> via bank or mobile money, then confirm below.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for {takerName} to send and confirm {localAmountFormatted} {offer.local_currency}…
                    </div>
                  )}

                  {isMaker && offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Check your account</p>
                      <p className="mt-1 text-[#64748B]">
                        {takerName} says they sent <strong className="text-[#E2E8F0]">
                          {localAmountFormatted} {offer.local_currency}
                        </strong>. Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${localAmountFormatted} ${offer.local_currency} to maker`
                      }
                    </Button>
                  )}

                  {isMaker && !offer.dispute_raised && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? `Waiting for ${takerName} to send first…`
                        : `✓ I received ${localAmountFormatted} ${offer.local_currency}`
                      }
                    </Button>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for maker to confirm receipt…
                    </div>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ {makerName} has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_silent', 'taker')} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">✓ Dispute raised — admin will review and contact both parties.</p>
                      )}
                    </div>
                  )}

                  {/* MAKER dispute: deadline elapsed, no dispute yet */}
                  {isMaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-red-900/40 bg-red-900/10 p-3 text-xs">
                        <p className="font-medium text-red-400">⚠️ {takerName} claims to have sent payment</p>
                        <p className="mt-1 text-red-600">
                          If you did not receive{' '}
                          <strong className="text-red-400">{localAmountFormatted} {offer.local_currency}</strong>,
                          raise a dispute for admin review.
                        </p>
                      </div>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_not_received', 'maker')}
                          disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : "I didn't receive payment — raise dispute"}
                        </Button>
                      ) : (
                        <div className="rounded-lg bg-amber-900/20 p-3 text-xs text-amber-400">
                          ✓ Dispute raised — admin will review.
                        </div>
                      )}
                    </div>
                  )}

                  {/* Both confirmed — waiting for release */}
                  {offer.maker_confirmed && offer.taker_confirmed && (
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
