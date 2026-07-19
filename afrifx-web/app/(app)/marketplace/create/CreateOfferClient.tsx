'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders, AlertCircle } from 'lucide-react'
import Link from 'next/link'
import { LOCAL_CURRENCIES as CURRENCIES, CURRENCY_FLAG } from '@/lib/corridor'

const TIMER_OPTIONS = [
  { label: '30 min',  value: 1800 },
  { label: '1 hour',  value: 3600 },
  { label: '2 hours', value: 7200 },
  { label: 'Custom',  value: 0    },
]

export function CreateOfferClient() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,     setOrderType]     = useState<OrderType>('market')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [limitOffset,   setLimitOffset]   = useState(0)
  const [timerOption,   setTimerOption]   = useState(1800)
  const [customTimer,   setCustomTimer]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  // Payout details where the buyer sends the local-currency payment.
  const [paymentMethod, setPaymentMethod] = useState<'bank' | 'mobile_money'>('bank')
  const [accountName,   setAccountName]   = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [bankName,      setBankName]      = useState('')
  const [paymentNote,   setPaymentNote]   = useState('')
  const payoutComplete = accountName.trim() && accountNumber.trim() && bankName.trim()

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  // The offer locks usdcAmount of USDC from the wallet; keep a small gas buffer.
  const GAS_BUFFER    = 0.001
  const balanceNum    = parseFloat(balance) || 0
  const usdcNum       = parseFloat(usdcAmount) || 0
  const maxUsdc       = Math.max(0, balanceNum - GAS_BUFFER)
  const insufficientUsdc = usdcNum > 0 && usdcNum > maxUsdc
  function setMaxUsdc() { setUsdcAmount(maxUsdc.toFixed(6)) }

  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
        paymentMethod,
        accountName:       accountName.trim(),
        accountNumber:     accountNumber.trim(),
        bankName:          bankName.trim(),
        paymentNote:       paymentNote.trim() || undefined,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch (_e) {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create P2P offer</h1>
          <p className="text-sm text-app-muted">Lock USDC in escrow, perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-app-border bg-app-surface p-1">
          <button onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Description */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-app-accent-text" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate.'}
          </div>
        </div>

        {/* USDC + currency */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-app-muted">
              Balance: <span className="text-app-text">{balance}</span>
              <button type="button" onClick={setMaxUsdc}
                className="ml-2 text-app-accent-text hover:underline">Max</button>
            </span>
          </div>
          <div className="flex gap-2">
            <select value={localCurrency} onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none">
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input type="number" placeholder="0.00" value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className={`flex-1 font-mono text-lg ${insufficientUsdc ? 'border-red-500/50' : ''}`} />
          </div>

          {/* Insufficiency / remaining */}
          {insufficientUsdc && (
            <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {balance} USDC
            </div>
          )}
          {!insufficientUsdc && usdcNum > 0 && (
            <p className="mt-2 text-xs text-emerald-400">
              Remaining after: {(balanceNum - usdcNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Rate display + limit slider */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-app-muted">Live market rate</span>
              <span className="font-mono text-app-text">1 USDC = {marketRate.toLocaleString()} {localCurrency}</span>
            </div>
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-app-muted">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-app-text'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input type="range" min="-5" max="5" step="0.5" value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-app-accent" />
                <div className="mt-1 flex justify-between text-[10px] text-app-muted">
                  <span>-5%</span><span>Market</span><span>+5%</span>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated receive */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-app-muted">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-app-text">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-app-muted">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Timer */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Buyer completion window
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            {TIMER_OPTIONS.map((opt) => (
              <button key={opt.value} onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-app-accent text-app-on-accent'
                    : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input type="number" placeholder="Minutes (min 5, max 1440)"
                value={customTimer} onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono" />
              <span className="text-xs text-app-muted">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-app-muted">
            If the buyer doesn't send {localCurrency} within this window, the offer automatically cancels and USDC returns to you.
          </p>
        </div>

        {/* Payout details where the buyer sends the money */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Your payout details
          </label>
          <p className="mt-1 mb-3 text-xs text-app-muted">
            Where should the buyer send your {localCurrency}? Shown to a buyer only after they accept.
          </p>

          {/* Method toggle */}
          <div className="mb-3 flex gap-2">
            {(['bank', 'mobile_money'] as const).map((m) => (
              <button key={m} onClick={() => setPaymentMethod(m)}
                className={`flex-1 rounded-lg px-3 py-2 text-xs font-medium transition-colors
                  ${paymentMethod === m ? 'bg-app-accent text-app-on-accent' : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {m === 'bank' ? 'Bank account' : 'Mobile money'}
              </button>
            ))}
          </div>

          <div className="space-y-2.5">
            <Input placeholder="Account holder name" value={accountName}
              onChange={(e) => setAccountName(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Account number' : 'Phone number'}
              value={accountNumber}
              onChange={(e) => setAccountNumber(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Bank name' : 'Provider (e.g. M-Pesa, MTN)'}
              value={bankName}
              onChange={(e) => setBankName(e.target.value)} />
            <Input placeholder="Note / reference (optional)" value={paymentNote}
              onChange={(e) => setPaymentNote(e.target.value)} />
          </div>
          {!payoutComplete && (accountName || accountNumber || bankName) && (
            <p className="mt-2 text-xs text-amber-500">Fill in name, number, and bank/provider to continue.</p>
          )}
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs">
            <p className="mb-2 font-medium text-app-text">Order summary</p>
            <div className="space-y-1.5 text-app-muted">
              {[
                ['Order type', orderType],
                ['You lock',   `${usdcAmount} USDC`],
                ['You receive', `${localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${localCurrency}`],
                ['Buyer window', timerSeconds >= 3600 ? `${timerSeconds/3600}h` : `${timerSeconds/60}min`],
                ['Duration',    'Perpetual until filled or cancelled'],
                ['Platform fee', `${(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span>{label}</span>
                  <span className="text-app-text">{val}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Trade flow reminder */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <p className="mb-1 font-medium text-app-text">Trade flow</p>
          <ol className="space-y-0.5">
            {[
              'You lock USDC in vault escrow',
              `Buyer accepts + sends ${localCurrency} to you within the window`,
              'Buyer confirms: "I sent the money"',
              'You confirm: "I received it"',
              'Platform releases USDC to buyer',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button className="w-full" size="lg" onClick={handleCreate}
            disabled={
              isLoading || !usdcAmount || localAmount <= 0 || timerSeconds < 300 ||
              insufficientUsdc || !payoutComplete ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }>
            {isLoading
              ? 'Locking USDC in escrow…'
              : insufficientUsdc
              ? 'Insufficient USDC balance'
              : !payoutComplete
              ? 'Add your payout details'
              : `Create ${orderType} order, ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
