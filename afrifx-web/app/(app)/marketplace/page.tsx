'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useEffect, useState } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { UserDisplay } from '@/components/profile/UserDisplay'
import { useP2P } from '@/hooks/useP2P'
import { arcTestnet } from '@/lib/arc-chain'
import { Plus, Clock, Zap, ShieldCheck, Loader2, ArrowRight, CheckCircle } from 'lucide-react'
import type { P2POffer } from '@/types'
import { LOCAL_CURRENCIES, CURRENCY_FLAG } from '@/lib/corridor'
import type { Currency } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'


function normalizeOffer(row: any): P2POffer {
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: Number(row[3]), local_currency: row[4],
      local_amount: Number(row[5]), rate_offered: Number(row[6]),
      status: row[7], maker_confirmed: Number(row[8] ?? 0),
      taker_confirmed: Number(row[9] ?? 0),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: Number(row[12]), created_at: Number(row[13]),
      updated_at: Number(row[14]),
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

function formatTimer(secs: number): string {
  if (secs >= 7200) return `${secs / 3600}h window`
  if (secs >= 3600) return '1h window'
  return `${Math.round(secs / 60)}min window`
}

// Accept states for clear UX
type AcceptState =
  | { phase: 'idle' }
  | { phase: 'signing';     offerId: string }
  | { phase: 'confirming';  offerId: string; txHash: string }
  | { phase: 'updating_db'; offerId: string }
  | { phase: 'done';        offerId: string }

function MarketplacePageInner() {
  const { address }                    = useAccount()
  const router                         = useRouter()
  const publicClient                   = usePublicClient({ chainId: arcTestnet.id })
  const [offers,   setOffers]          = useState<P2POffer[]>([])
  const [loading,  setLoading]         = useState(true)
  const [currency, setCurrency]        = useState('all')
  const [acceptState, setAcceptState]  = useState<AcceptState>({ phase: 'idle' })
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
    if (!address || acceptState.phase !== 'idle') return
    const timerSecs = (offer as any).maker_timer_seconds ?? 1800

    try {
      // Step 1: Sign + submit tx
      setAcceptState({ phase: 'signing', offerId: offer.id })
      const hash = await acceptOffer(offer.id as `0x${string}`, timerSecs)

      // Step 2: Wait for on-chain confirmation
      setAcceptState({ phase: 'confirming', offerId: offer.id, txHash: hash as string })
      if (publicClient) {
        await publicClient.waitForTransactionReceipt({
          hash: hash as `0x${string}`,
        })
      }

      // Step 3: Update DB immediately (don't rely on event listener timing)
      setAcceptState({ phase: 'updating_db', offerId: offer.id })
      await fetch(`${API}/offers/${offer.id}/accept`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          takerAddress:  address,
          timerSeconds:  timerSecs,
        }),
      }).catch(() => {}) // Non-fatal, watcher will catch it

      // Step 4: DB is updated safe to redirect now
      setAcceptState({ phase: 'done', offerId: offer.id })

      // Small delay so user sees the success state
      await new Promise(r => setTimeout(r, 600))

      router.push(`/marketplace/${offer.id}?accepted=1`)
    } catch (err: any) {
      // User rejected or tx failed
      setAcceptState({ phase: 'idle' })
    }
  }

  const busyId = acceptState.phase !== 'idle' ? acceptState.offerId : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">P2P Marketplace</h1>
          <p className="text-sm text-app-muted">Buy USDC directly from verified traders.</p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm"><Plus className="h-4 w-4" /> Create offer</Button>
        </Link>
      </div>

      {/* Global accepting banner */}
      {acceptState.phase !== 'idle' && (
        <div className="mb-4 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3">
          <div className="flex items-center gap-3">
            {acceptState.phase === 'done'
              ? <CheckCircle className="h-5 w-5 shrink-0 text-emerald-400" />
              : <Loader2 className="h-5 w-5 shrink-0 animate-spin text-app-accent-text" />
            }
            <div>
              <p className="text-sm font-medium text-app-text">
                {acceptState.phase === 'signing'     && 'Waiting for wallet signature…'}
                {acceptState.phase === 'confirming'  && 'Confirming on Arc blockchain…'}
                {acceptState.phase === 'updating_db' && 'Finalising trade setup…'}
                {acceptState.phase === 'done'        && 'Trade accepted! Redirecting…'}
              </p>
              <p className="text-xs text-app-muted">
                {acceptState.phase === 'signing'     && 'Please approve the transaction in your wallet'}
                {acceptState.phase === 'confirming'  && 'This usually takes a few seconds'}
                {acceptState.phase === 'updating_db' && 'Almost there…'}
                {acceptState.phase === 'done'        && 'Taking you to the settlement interface'}
              </p>
            </div>
          </div>
          {/* Step progress */}
          <div className="mt-3 flex items-center gap-2">
            {[
              { key: 'signing',     label: 'Sign' },
              { key: 'confirming',  label: 'Confirm' },
              { key: 'updating_db', label: 'Finalise' },
              { key: 'done',        label: 'Done' },
            ].map(({ key, label }, idx) => {
              const phases = ['signing','confirming','updating_db','done']
              const currentIdx = phases.indexOf(acceptState.phase)
              const stepIdx    = phases.indexOf(key)
              const isDone     = stepIdx < currentIdx || acceptState.phase === 'done'
              const isActive   = stepIdx === currentIdx && acceptState.phase !== 'done'
              return (
                <div key={key} className="flex items-center gap-2">
                  <div className={`flex h-6 w-6 items-center justify-center rounded-full text-[10px] font-bold transition-colors
                    ${isDone    ? 'bg-emerald-500 text-white'
                    : isActive  ? 'bg-app-accent text-app-on-accent'
                    :             'bg-app-border text-app-muted'}`}>
                    {isDone ? '✓' : idx + 1}
                  </div>
                  <span className={`text-xs ${isActive || isDone ? 'text-app-text' : 'text-app-muted'}`}>
                    {label}
                  </span>
                  {idx < 3 && <div className="h-px w-4 bg-app-border" />}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Trust badges */}
      <div className="mb-6 flex flex-wrap gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow'   },
          { icon: Zap,         label: 'Arc settlement'   },
          { icon: Clock,       label: 'Perpetual orders' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-muted">
            <Icon className="h-3.5 w-3.5 text-app-accent-text" />{label}
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all', ...LOCAL_CURRENCIES].map(c => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-app-accent text-app-on-accent'
                : 'border border-app-border text-app-muted hover:text-app-text'}`}>
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c as Currency]} ${c}`}
          </button>
        ))}
        <button onClick={load}
          className="ml-auto rounded-full border border-app-border px-3 py-1 text-xs text-app-muted hover:text-app-text">
          ↻ Refresh
        </button>
      </div>

      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => <div key={i} className="h-24 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-app-border bg-app-surface p-10 text-center">
          <p className="text-sm text-app-muted">No open offers right now.</p>
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
          const isBusy = busyId === offer.id

          return (
            <div key={offer.id}
              className={`rounded-xl border bg-app-surface p-4 transition-colors
                ${isBusy ? 'border-app-accent/40' : 'border-app-border'}`}>
              <div className="flex items-center gap-4">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-bg text-xl">
                  {CURRENCY_FLAG[offer.local_currency as Currency] ?? '🌍'}
                </div>

                <div className="flex-1 min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-app-text">
                      {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      <span className="mx-1.5 text-app-muted">→</span>
                      {Number(offer.usdc_amount).toFixed(2)} USDC
                    </p>
                    {isOwn && <Badge variant="arc">Your offer</Badge>}
                    <Badge variant={type === 'limit' ? 'warning' : 'arc'}>{type}</Badge>
                  </div>
                  <div className="mt-1.5 flex flex-wrap items-center gap-3">
                    <ClientOnly fallback={<span className="text-xs text-app-muted">…</span>}>
                      <UserDisplay address={offer.maker_address} size="xs" suffix={isOwn ? '(you)' : undefined} />
                    </ClientOnly>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="text-xs text-app-muted">
                      1 USDC = {Number(offer.rate_offered) > 0
                        ? (1 / Number(offer.rate_offered)).toFixed(2)
                        : '-'} {offer.local_currency}
                    </span>
                    <span className="text-xs text-app-muted">·</span>
                    <span className="flex items-center gap-1 text-xs text-app-muted">
                      <Clock className="h-3 w-3" />{formatTimer(timer)}
                    </span>
                  </div>
                </div>

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
                        disabled={!address || !!busyId}>
                        {isBusy ? (
                          <><Loader2 className="h-3.5 w-3.5 animate-spin" />
                          {acceptState.phase === 'signing'    ? 'Signing…'
                          : acceptState.phase === 'confirming' ? 'Confirming…'
                          : acceptState.phase === 'done'       ? 'Redirecting…'
                          : 'Processing…'}
                          </>
                        ) : 'Buy USDC'}
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
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}

export default function MarketplacePage() {
  return (
    <SectionGuard section="marketplace">
      <MarketplacePageInner />
    </SectionGuard>
  )
}
