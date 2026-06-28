#!/bin/bash
# Run from ~/AfriFX:  bash fix-p2p-flow.sh
set -e
echo "🔧  Fixing P2P confirmation flow order..."

# ============================================================
# 1 — Fix create offer page — correct flow description
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/create/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useP2P } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

export default function CreateOfferPage() {
  const router                       = useRouter()
  const { address, isConnected }     = useAccount()
  const { formatted: balance }       = useUSDCBalance()
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [localAmount,   setLocalAmount]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const impliedRate = usdcAmount && localAmount
    ? parseFloat(localAmount) / parseFloat(usdcAmount)
    : 0

  const rateVsMarket = marketRate > 0 && impliedRate > 0
    ? ((impliedRate - marketRate) / marketRate) * 100
    : 0

  async function handleCreate() {
    if (!usdcAmount || !localAmount) return
    try {
      await createOffer(
        parseFloat(usdcAmount),
        localCurrency,
        parseFloat(localAmount),
      )
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-[#64748B]">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Create P2P offer</h1>
          <p className="text-sm text-[#64748B]">
            Lock USDC in escrow — released to seller after you confirm receipt.
          </p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* How it works — CORRECT flow */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-2 flex items-center gap-2 text-xs font-medium text-[#E2E8F0]">
            <Info className="h-3.5 w-3.5 text-[#378ADD]" />
            How it works
          </div>
          <div className="space-y-2 text-xs text-[#64748B]">
            <div className="flex items-start gap-2">
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-[10px] font-bold text-[#378ADD]">1</span>
              <span>You (maker) lock USDC in the AfriFX vault escrow</span>
            </div>
            <div className="flex items-start gap-2">
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-[10px] font-bold text-[#378ADD]">2</span>
              <span>A seller (taker) accepts your offer and sends you {localCurrency || 'local currency'} via bank/mobile money</span>
            </div>
            <div className="flex items-start gap-2">
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-[10px] font-bold text-[#378ADD]">3</span>
              <span>Taker confirms they sent the local currency</span>
            </div>
            <div className="flex items-start gap-2">
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-[10px] font-bold text-[#378ADD]">4</span>
              <span>You confirm you received the local currency</span>
            </div>
            <div className="flex items-start gap-2">
              <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-[10px] font-bold text-[#378ADD]">5</span>
              <span>Platform automatically releases USDC to the taker ✓</span>
            </div>
          </div>
        </div>

        {/* USDC to lock */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-[#64748B]">
              Balance: <span className="text-[#E2E8F0]">{balance} USDC</span>
            </span>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={usdcAmount}
            onChange={(e) => setUsdcAmount(e.target.value)}
            className="font-mono text-lg"
          />
        </div>

        {/* Local currency you want */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <label className="mb-3 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
            Local currency you want in return
          </label>
          <div className="flex gap-2">
            <select
              value={localCurrency}
              onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] outline-none"
            >
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input
              type="number"
              placeholder="0"
              value={localAmount}
              onChange={(e) => setLocalAmount(e.target.value)}
              className="flex-1 font-mono text-lg"
            />
          </div>

          {/* Rate vs market */}
          {impliedRate > 0 && marketRate > 0 && (
            <div className="mt-3 flex items-center justify-between rounded-lg bg-[#080D1B] px-3 py-2 text-xs">
              <span className="text-[#64748B]">Your rate</span>
              <span className="font-mono text-[#E2E8F0]">
                1 USDC = {impliedRate.toFixed(2)} {localCurrency}
              </span>
              <span className={rateVsMarket >= 0 ? 'text-emerald-400' : 'text-red-400'}>
                {rateVsMarket >= 0 ? '+' : ''}{rateVsMarket.toFixed(2)}% vs market
              </span>
            </div>
          )}
        </div>

        {/* Summary */}
        {usdcAmount && localAmount && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs">
            <p className="mb-2 font-medium text-[#E2E8F0]">Offer summary</p>
            <div className="space-y-1.5 text-[#64748B]">
              <div className="flex justify-between">
                <span>You lock (escrow)</span>
                <span className="font-mono text-[#E2E8F0]">{usdcAmount} USDC</span>
              </div>
              <div className="flex justify-between">
                <span>You receive from seller</span>
                <span className="font-mono text-[#E2E8F0]">
                  {parseFloat(localAmount).toLocaleString()} {localCurrency}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Platform fee (0.3%)</span>
                <span className="font-mono text-[#E2E8F0]">
                  {(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC
                </span>
              </div>
              <div className="flex justify-between">
                <span>Offer expires in</span>
                <span className="text-[#E2E8F0]">30 minutes</span>
              </div>
            </div>
          </div>
        )}

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button
            className="w-full"
            size="lg"
            onClick={handleCreate}
            disabled={isLoading || !usdcAmount || !localAmount || parseFloat(usdcAmount) <= 0}
          >
            {isLoading
              ? 'Locking USDC in escrow…'
              : `Lock ${usdcAmount || '0'} USDC & Create Offer`
            }
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
            {error}
          </div>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  create/page.tsx — correct flow description"

# ============================================================
# 2 — Fix detail page confirmation order:
#     Taker confirms FIRST (sent local currency)
#     Maker confirms SECOND (received local currency)
#     Platform releases USDC to taker
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
    maker_confirmed: Number(row.maker_confirmed ?? 0),
    taker_confirmed: Number(row.taker_confirmed ?? 0),
  } as P2POffer
}

function shortenAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export default function OfferDetailPage() {
  const params              = useParams()
  const { address }         = useAccount()
  const [offer, setOffer]   = useState<P2POffer | null>(null)
  const [loading, setLoading]     = useState(true)
  const [notFound, setNotFound]   = useState(false)

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
      const norm = normalizeOffer(data)
      if (norm) setOffer(norm)
      else setNotFound(true)
    } catch { setNotFound(true) }
    finally  { setLoading(false) }
  }, [params.id])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    const t = setInterval(load, 5000)
    return () => clearInterval(t)
  }, [load])

  if (loading) return (
    <div className="space-y-4">
      {[1,2,3].map(i => <div key={i} className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />)}
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-[#64748B]">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`

  const statusBadge = {
    open: 'warning', accepted: 'arc',
    released: 'success', cancelled: 'danger',
  }[offer.status] as any

  // CORRECT flow:
  // Step 1 — Taker accepts
  // Step 2 — Taker sends local currency to maker (off-chain)
  // Step 3 — Taker confirms they sent (takerConfirm)
  // Step 4 — Maker confirms they received (makerConfirm)
  // Step 5 — Platform releases USDC to taker
  const steps = [
    {
      n: 1, done: offer.status !== 'open',
      label: 'Taker accepted offer',
      desc:  'USDC locked in vault escrow on Arc',
    },
    {
      n: 2, done: offer.status !== 'open',
      label: `Taker sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`,
      desc:  'Off-chain — bank transfer or mobile money',
    },
    {
      n: 3, done: !!offer.taker_confirmed,
      label: 'Taker confirmed: "I sent the money"',
      desc:  'Taker clicks confirm after sending local currency',
    },
    {
      n: 4, done: !!offer.maker_confirmed,
      label: 'Maker confirmed: "I received the money"',
      desc:  'Maker clicks confirm after receiving local currency',
    },
    {
      n: 5, done: offer.status === 'released',
      label: 'Platform releases USDC to taker',
      desc:  'Auto-released within 15 seconds of both confirmations',
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

        {/* Summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Summary</p>

          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">
                {Number(offer.usdc_amount).toFixed(2)}
              </p>
              <p className="text-xs text-[#64748B]">USDC (in escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">
                {Number(offer.local_amount).toLocaleString()}
              </p>
              <p className="text-xs text-[#64748B]">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <div className="space-y-2.5 text-xs">
            <div className="flex justify-between">
              <span className="text-[#64748B]">Maker (wants {offer.local_currency})</span>
              <span className="font-mono text-[#E2E8F0]">
                {offer.maker_address ? shortenAddr(offer.maker_address) : '—'}
                {isMaker && <span className="ml-1 text-[#378ADD]">(you)</span>}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Taker (wants USDC)</span>
              <span className="font-mono text-[#E2E8F0]">
                {offer.taker_address
                  ? <>{shortenAddr(offer.taker_address)}{isTaker && <span className="ml-1 text-[#378ADD]">(you)</span>}</>
                  : 'Waiting…'
                }
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-[#64748B]">Rate</span>
              <span className="font-mono text-[#E2E8F0]">
                1 USDC = {Number(offer.rate_offered) > 0
                  ? (1 / Number(offer.rate_offered)).toFixed(2)
                  : '—'} {offer.local_currency}
              </span>
            </div>

            {offer.arc_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Create tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline">
                  {offer.arc_tx_hash.slice(0, 14)}…<ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
            {offer.release_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Release tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                  {offer.release_tx_hash.slice(0, 14)}…<ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
          </div>
        </div>

        {/* Confirmation flow */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Progress</p>

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
                <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                <p className="mt-1 text-xs text-emerald-600">
                  USDC released to taker · maker received {offer.local_currency}
                </p>
              </div>
            )}

            {/* Cancelled */}
            {offer.status === 'cancelled' && (
              <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                <p className="mt-1 text-xs text-red-600">USDC returned to maker</p>
              </div>
            )}

            {/* Open — waiting for taker */}
            {offer.status === 'open' && isMaker && (
              <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                <Clock className="mx-auto mb-1 h-4 w-4" />
                Waiting for a seller to accept your offer…
              </div>
            )}

            {/* Accepted — action buttons */}
            {offer.status === 'accepted' && (
              <div className="space-y-3">

                {/* TAKER: send local currency then confirm */}
                {isTaker && !offer.taker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                    <p className="font-medium text-[#E2E8F0]">Your turn — send local currency</p>
                    <p className="mt-1 text-[#64748B]">
                      Send <strong className="text-[#E2E8F0]">
                        {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      </strong> to the maker via bank transfer or mobile money.
                      Once sent, click confirm below.
                    </p>
                  </div>
                )}

                {/* MAKER: waiting for taker to send + confirm */}
                {isMaker && !offer.taker_confirmed && (
                  <div className="rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
                    <Loader2 className="mb-1 h-4 w-4 animate-spin" />
                    Waiting for taker to send you {Number(offer.local_amount).toLocaleString()} {offer.local_currency} and confirm…
                  </div>
                )}

                {/* MAKER: taker confirmed sending — your turn to confirm receipt */}
                {isMaker && offer.taker_confirmed && !offer.maker_confirmed && (
                  <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                    <p className="font-medium text-[#E2E8F0]">Check your account</p>
                    <p className="mt-1 text-[#64748B]">
                      The taker says they sent you <strong className="text-[#E2E8F0]">
                        {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                      </strong>. Once you receive it, click confirm below to release USDC to them.
                    </p>
                  </div>
                )}

                {/* TAKER confirm button — confirms they SENT local currency */}
                {isTaker && (
                  <Button className="w-full"
                    onClick={async () => { await takerConfirm(offerId); await load() }}
                    disabled={!!offer.taker_confirmed || actionLoading}
                    variant={offer.taker_confirmed ? 'outline' : 'default'}>
                    {actionLoading
                      ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming on Arc…</>
                      : offer.taker_confirmed
                      ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed sending</>
                      : `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`
                    }
                  </Button>
                )}

                {/* MAKER confirm button — confirms they RECEIVED local currency */}
                {isMaker && (
                  <Button className="w-full"
                    onClick={async () => { await makerConfirm(offerId); await load() }}
                    disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                    variant={offer.maker_confirmed ? 'outline' : 'default'}>
                    {actionLoading
                      ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming on Arc…</>
                      : offer.maker_confirmed
                      ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed receipt</>
                      : !offer.taker_confirmed
                      ? `Waiting for taker to send ${offer.local_currency} first…`
                      : `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`
                    }
                  </Button>
                )}

                {/* Taker waiting for maker to confirm */}
                {isTaker && offer.taker_confirmed && !offer.maker_confirmed && (
                  <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Waiting for maker to confirm they received your {offer.local_currency}…
                  </div>
                )}

                {/* Both confirmed — platform releasing */}
                {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                  <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    Both confirmed — releasing USDC to taker within 15 seconds…
                  </div>
                )}

                {/* Not involved */}
                {!isInvolved && (
                  <p className="text-center text-xs text-[#64748B]">
                    This trade is in progress between two parties.
                  </p>
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
echo "✅  marketplace/[id]/page.tsx — correct flow order"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  P2P flow corrected!"
echo ""
echo "  CORRECT order:"
echo "  1. Maker locks USDC in vault (wants local currency)"
echo "  2. Taker accepts + sends local currency to maker"
echo "  3. Taker confirms: 'I sent the money'"
echo "  4. Maker confirms: 'I received the money'"
echo "  5. Platform releases USDC to taker"
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
