'use client'
import { useState, useEffect, useCallback } from 'react'
import { useAccount } from 'wagmi'
import {
  Loader2, AlertCircle, CheckCircle, RefreshCw, Clock, Building2, Smartphone,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface ProviderQuote {
  provider:    string
  displayName: string
  ok:          boolean
  error?:      string
  quote?: {
    rate:       number
    destAmount: number
    feeDest?:   number
    netDest?:   number
    etaLabel?:  string
    etaSeconds?: number
  }
}

/*
  Cash out USDC to a bank account or mobile money.

  This replaces the old "convert" flow, which moved USDC to a vault and wrote a
  database row without ever delivering fiat. Two things it must get right:

  1. RECIPIENT DETAILS ARE MANDATORY. You cannot pay someone fiat without
     knowing where to send it, so the form collects them and the button stays
     disabled until they're complete. Better to block here than to take the
     USDC and fail afterwards.

  2. PROVIDER CHOICE IS THE USER'S. Quotes are shown UNRANKED with rate, fee,
     net amount and speed side by side. The best rate is often not the fastest,
     and picking a "winner" would mean quietly steering people toward whichever
     provider we favour.
*/
export function CashOutCard({
  usdcAmount, destCurrency, country,
}: {
  usdcAmount: number
  destCurrency: string
  country: string
}) {
  const { address, isConnected } = useAccount()

  const [method,        setMethod]        = useState<'bank' | 'mobile_money'>('bank')
  const [accountName,   setAccountName]   = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [bankName,      setBankName]      = useState('')

  const [quotes,   setQuotes]   = useState<ProviderQuote[]>([])
  const [loadingQ, setLoadingQ] = useState(false)
  const [picked,   setPicked]   = useState<string | null>(null)

  const [submitting, setSubmitting] = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [transferId, setTransferId] = useState<string | null>(null)

  const detailsComplete =
    accountName.trim() && accountNumber.trim() && bankName.trim()

  const loadQuotes = useCallback(async () => {
    if (!(usdcAmount > 0) || !destCurrency || !country) return
    setLoadingQ(true); setError(null)
    try {
      const res = await fetch(`${API}/transfers/quotes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ usdcAmount, destCurrency, country, method }),
      })
      const data = await res.json()
      const list: ProviderQuote[] = data.quotes ?? []
      setQuotes(list)
      // Preselect the only working option, but never silently choose between
      // several: that decision belongs to the user.
      const usable = list.filter(q => q.ok)
      setPicked(usable.length === 1 ? usable[0].provider : null)
    } catch (err: any) {
      setError(err?.message ?? 'Could not load provider quotes')
    } finally { setLoadingQ(false) }
  }, [usdcAmount, destCurrency, country, method])

  useEffect(() => { loadQuotes() }, [loadQuotes])

  async function submit() {
    if (!address || !picked || !detailsComplete) return
    setSubmitting(true); setError(null)
    try {
      const res = await fetch(`${API}/transfers/cashout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address,
          usdcAmount, destCurrency, country,
          provider: picked,
          recipient: {
            name: accountName.trim(),
            method,
            account: accountNumber.trim(),
            bank: bankName.trim(),
          },
        }),
      })
      const data = await res.json()
      if (!res.ok) { setError(data.error ?? 'Could not start the payout'); return }
      setTransferId(data.transferId)
    } catch (err: any) {
      setError(err?.message ?? 'Could not start the payout')
    } finally { setSubmitting(false) }
  }

  if (transferId) {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-700 dark:text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Payout started
        </p>
        <p className="mt-1 text-xs text-emerald-800 dark:text-emerald-200/80">
          {usdcAmount} USDC is on its way to {accountName} as {destCurrency}.
        </p>
        <p className="mt-2 font-mono text-[10px] text-app-muted">{transferId}</p>
        <p className="mt-2 text-[11px] text-app-muted">
          You can track it under Settlements. The money arrives once the provider
          confirms, not immediately.
        </p>
      </div>
    )
  }

  const usable = quotes.filter(q => q.ok)

  return (
    <div className="space-y-4">
      {/* Provider comparison */}
      <div>
        <div className="mb-2 flex items-center justify-between">
          <p className="text-xs font-semibold text-app-text">Choose a provider</p>
          <button onClick={loadQuotes} disabled={loadingQ}
            className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
            <RefreshCw className={`h-3 w-3 ${loadingQ ? 'animate-spin' : ''}`} /> Refresh
          </button>
        </div>

        {loadingQ && !quotes.length ? (
          <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> Comparing providers...
          </div>
        ) : !usable.length ? (
          <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
            <p className="flex items-center gap-1.5 text-xs text-amber-800 dark:text-amber-400">
              <AlertCircle className="h-3.5 w-3.5" /> No provider available
            </p>
            <p className="mt-1 text-[11px] text-amber-800 dark:text-amber-200/80">
              None can currently send {destCurrency} to {country}. Your USDC has
              not been touched.
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            {quotes.map(q => {
              if (!q.ok) {
                // Failures stay visible: a provider silently missing looks the
                // same as one that doesn't exist.
                return (
                  <div key={q.provider}
                    className="rounded-lg border border-app-border bg-app-bg/50 p-3 opacity-60">
                    <p className="text-xs text-app-text">{q.displayName}</p>
                    <p className="text-[10px] text-app-muted">Unavailable: {q.error}</p>
                  </div>
                )
              }
              const sel = picked === q.provider
              const net = q.quote?.netDest ?? q.quote?.destAmount ?? 0
              return (
                <button
                  key={q.provider}
                  onClick={() => setPicked(q.provider)}
                  className={`w-full rounded-lg border p-3 text-left transition-colors ${
                    sel ? 'border-app-accent bg-app-accent/5' : 'border-app-border bg-app-surface hover:border-app-accent/50'
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <span className="text-xs font-medium text-app-text">{q.displayName}</span>
                    <span className="text-right">
                      <span className="block font-mono text-sm text-app-text">
                        {net.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                      </span>
                      <span className="block text-[10px] text-app-muted">{destCurrency} received</span>
                    </span>
                  </div>
                  <div className="mt-1.5 flex flex-wrap gap-3 text-[10px] text-app-muted">
                    <span>Rate {q.quote?.rate?.toLocaleString()}</span>
                    {q.quote?.feeDest != null && (
                      <span>Fee {q.quote.feeDest.toLocaleString()} {destCurrency}</span>
                    )}
                    {q.quote?.etaLabel && (
                      <span className="inline-flex items-center gap-0.5">
                        <Clock className="h-2.5 w-2.5" /> {q.quote.etaLabel}
                      </span>
                    )}
                  </div>
                </button>
              )
            })}
          </div>
        )}
      </div>

      {/* Recipient details, mandatory */}
      <div>
        <p className="mb-2 text-xs font-semibold text-app-text">Where should the money go?</p>

        <div className="mb-2 flex gap-2">
          {(['bank', 'mobile_money'] as const).map(m => (
            <button key={m} onClick={() => setMethod(m)}
              className={`flex flex-1 items-center justify-center gap-1.5 rounded-lg border py-2 text-xs ${
                method === m ? 'border-app-accent bg-app-accent/5 text-app-text'
                             : 'border-app-border text-app-muted hover:text-app-text'
              }`}>
              {m === 'bank' ? <Building2 className="h-3.5 w-3.5" /> : <Smartphone className="h-3.5 w-3.5" />}
              {m === 'bank' ? 'Bank transfer' : 'Mobile money'}
            </button>
          ))}
        </div>

        <div className="space-y-2">
          <Input placeholder="Account holder name" value={accountName}
            onChange={e => setAccountName(e.target.value)} />
          <Input
            placeholder={method === 'bank' ? 'Account number' : 'Phone number'}
            value={accountNumber} onChange={e => setAccountNumber(e.target.value)}
            className="font-mono" />
          <Input
            placeholder={method === 'bank' ? 'Bank name or code' : 'Mobile money provider'}
            value={bankName} onChange={e => setBankName(e.target.value)} />
        </div>

        <p className="mt-1.5 text-[10px] text-app-muted">
          Double-check these. Payments sent to a wrong account cannot be reversed.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-3">
          <p className="flex items-center gap-1.5 text-xs font-medium text-red-800 dark:text-red-400">
            <AlertCircle className="h-3.5 w-3.5" /> Payout not started
          </p>
          <p className="mt-1 text-[11px] text-red-800 dark:text-red-300/90">{error}</p>
        </div>
      )}

      <Button className="w-full" disabled={!isConnected || !picked || !detailsComplete || submitting}
        onClick={submit}>
        {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting payout...</>
          : !isConnected ? 'Connect a wallet'
          : !picked ? 'Choose a provider'
          : !detailsComplete ? 'Enter recipient details'
          : `Cash out ${usdcAmount} USDC`}
      </Button>
    </div>
  )
}
