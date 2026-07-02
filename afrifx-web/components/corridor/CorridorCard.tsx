'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import {
  ArrowRight, ArrowUpDown, CheckCircle,
  AlertCircle, Loader2, Hash, Coins
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { CurrencyInput } from '@/components/swap/CurrencyInput'
import { useRate } from '@/hooks/useFXRate'
import { useCorridorSwap } from '@/hooks/useCorridorSwap'
import {
  LOCAL_CURRENCIES, CURRENCY_FLAG, CURRENCY_LABELS,
  buildCorridorQuote, isCorridorSupported,
} from '@/lib/corridor'
import type { Currency } from '@/types'

export function CorridorCard() {
  const { isConnected } = useAccount()

  const [from,      setFrom]      = useState<Currency>('NGN')
  const [to,        setTo]        = useState<Currency>('KES')
  const [amount,    setAmount]    = useState('')
  const [quote,     setQuote]     = useState<ReturnType<typeof buildCorridorQuote> | null>(null)

  // Fetch both rates
  { rate: fromRate } = useRate(`${from}/USDC`)
  const { rate: toRate   } = useRate(`${to}/USDC`)

  const fromRateVal = fromRate?.rate ?? 0
  const toRateVal   = toRate?.rate   ?? 0
  const ratesReady  = fromRateVal > 0 && toRateVal > 0

  const {
    execute, reset,
    step, error,
    step1Hash, step2Hash, corridorId,
    isLoading, isComplete,
  } = useCorridorSwap()

  // Recalculate quote when inputs change
  useEffect(() => {
    const amt = parseFloat(amount)
    if (!amount || isNaN(amt) || amt <= 0 || !ratesReady) {
      setQuote(null); return
    }
    setQuote(buildCorridorQuote(from, to, amt, fromRateVal, toRateVal))
  }, [amount, from, to, fromRateVal, toRateVal])

  // Reset quote when user changes amount after completion
  function handleAmountChange(val: string) {
    if (val === '' || /^\d*\.?\d*$/.test(val)) {
      setAmount(val)
      if (isComplete) reset()
    }
  }

  function handleFromChange(c: Currency) {
    if (c === to) setTo(from) // auto-swap if same selected
    setFrom(c)
   setAmount('')
    setQuote(null)
    reset()
  }

  function handleToChange(c: Currency) {
    if (c === from) setFrom(to)
    setTo(c)
    setAmount('')
    setQuote(null)
    reset()
  }

  function flip() {
    setFrom(to)
    setTo(from)
    setAmount('')
    setQuote(null)
    reset()
  }

  async function handleExecute() {
    if (!quote) return
    await execute(quote)
  }

  const supported = isCorridorSupported(from, to)
  const canSwap   = isConnected && !!quote && supported && !isLoading

  // Step label helper
  const stepLabel: Record<string, string> = {
    'idle':          '',
    'step1-pending': 'Confirm Step 1 in MetaMask…',
    'step1-waiting': 'Step 1 settling on Arc…',
    'step1-done':    'Step 1 complete — preparing Step 2…',
    'step2-pending': 'Confirm Step 2 in MetaMask…',
    'step2-waiting': 'Step 2 settling on Arc…',
    'complete':      'Corridor swap complete!',
    'error':         'Something went wrong',
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5 shadow-xl">

      {/* Header */}
      <div className="mb-4 flex items-center gap-2">
        <Coins className="h-4 w-4 text-app-accent-text" />
        <span className="text-sm font-medium text-app-text">Cross-border corridor</span>
        <Badge variant="arc" className="ml-auto">2-step · via USDC</Badge>
      </div>

      {/* From currency */}
      <CurrencyInput
        label="You send"
        amount={amount}
        currency={from}
        onAmountChange={handleAmountChange}
        onCurrencyChange={handleFromChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== to)}
      />

      {/* Flip button */}
      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-app-border bg-app-surface p-2 text-app-muted transition-transform hover:rotate-180 hover:text-app-text"
        >
          <ArrowUpDown className="h-4 w-4" />
        </button>
      </div>

      {/* To currency */}
      <CurrencyInput
        label="Recipient receives (estimated)"
        amount={quote ? quote.step2.toAmount.toFixed(2) : ''}
        currency={to}
        onCurrencyChange={handleToChange}
        currencies={LOCAL_CURRENCIES.filter(c => c !== from)}
        readOnly
        className="mb-4"
      />

      {/* Route breakdown */}
      {quote && (
        <div className="mb-4 rounded-lg bg-app-bg p-3 text-xs">
          <p className="mb-2 font-medium text-app-text">Route</p>
          <div className="flex items-center gap-2 text-app-muted">
            <span>{CURRENCY_FLAG[from]} {from}</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>💵 USDC</span>
            <ArrowRight className="h-3 w-3 shrink-0" />
            <span>{CURRENCY_FLAG[to]} {to}</span>
          </div>
          <div className="mt-2 space-y-1">
            <div className="flex justify-between">
              <span className="text-app-muted">Step 1 · {from} → USDC</span>
              <span className="font-mono text-app-text">~{quote.step1.toAmount.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Step 2 · USDC → {to}</span>
              <span className="font-mono text-app-text">{quote.step2.toAmount.toFixed(2)} {to}</span>
            </div>
            <div className="flex justify-between border-t border-app-border pt-1">
              <span className="text-app-muted">Total fees</span>
              <span className="font-mono text-app-text">${quote.totalFee.toFixed(4)} USDC</span>
            </div>
            <div className="flex justify-between">
              <span className="text-app-muted">Corridor ID</span>
              <span className="font-mono text-[10px] text-app-accent-text">{quote.corridorId}</span>
            </div>
          </div>
        </div>
      )}

      {/* Step progress indicator */}
      {step !== 'idle' && (
        <div className="mb-3 rounded-lg border border-app-border bg-app-bg p-3">
          <div className="mb-2 flex items-center gap-4">
            {/* Step 1 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${['step1-done','step2-pending','step2-waiting','complete'].includes(step)
                  ? 'bg-emerald-500 text-white'
                  : ['step1-pending','step1-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {['step1-done','step2-pending','step2-waiting','complete'].includes(step) ? '✓' : '1'}
              </div>
              <span className="text-xs text-app-muted">{from} → USDC</span>
            </div>
            <ArrowRight className="h-3 w-3 text-app-border" />
            {/* Step 2 indicator */}
            <div className="flex items-center gap-1.5">
              <div className={`flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold
                ${step === 'complete'
                  ? 'bg-emerald-500 text-white'
                  : ['step2-pending','step2-waiting'].includes(step)
                  ? 'bg-app-accent text-app-on-accent'
                  : 'bg-app-border text-app-muted'}`}>
                {step === 'complete' ? '✓' : '2'}
              </div>
              <span className="text-xs text-app-muted">USDC → {to}</span>
            </div>
          </div>
          <p className="flex items-center gap-1.5 text-xs text-app-muted">
            {isLoading && <Loader2 className="h-3 w-3 animate-spin text-app-accent-text" />}
            {step === 'complete' && <CheckCircle className="h-3 w-3 text-emerald-400" />}
            {step === 'error' && <AlertCircle className="h-3 w-3 text-red-400" />}
            {stepLabel[step]}
          </p>
        </div>
      )}

      {/* Main button */}
      {!isComplete && (
        <Button
          className="w-full"
          size="lg"
          onClick={handleExecute}
          disabled={!canSwap || isLoading}
        >
          {isLoading ? (
            <><Loader2 className="h-4 w-4 animate-spin" />
              {step === 'step1-pending' || step === 'step1-waiting'
                ? 'Step 1 of 2 · settling…'
                : 'Step 2 of 2 · settling…'}
            </>
          ) : !isConnected ? (
            'Connect wallet'
          ) : !amount ? (
            'Enter an amount'
          ) : !supported ? (
            'Corridor not supported'
          ) : !ratesReady ? (
            'Fetching rates…'
          ) : (
            `Send ${parseFloat(amount || '0').toLocaleString()} ${from} → ${to}`
          )}
        </Button>
      )}

      {/* Error */}
      {error && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-red-900/50 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
     <div>
            <p>{error}</p>
            <button onClick={reset} className="mt-1 underline hover:no-underline">Try again</button>
          </div>
        </div>
      )}

      {/* Success */}
      {isComplete && (
        <div className="mt-3 rounded-lg border border-emerald-900/50 bg-emerald-900/20 px-3 py-3">
          <div className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-400" />
            <div className="flex-1 text-xs">
        <p className="font-medium text-emerald-400">
                Corridor complete · {CURRENCY_FLAG[from]} {from} → {CURRENCY_FLAG[to]} {to}
              </p>
              <p className="mt-0.5 text-emerald-500">
                Sent {parseFloat(amount).toLocaleString()} {from} ·
                Received ~{quote?.step2.toAmount.toFixed(2)} {to}
              </p>
              <div className="mt-1.5 flex items-center gap-1">
                <Hash className="h-3 w-3 text-emerald-600" />
                <span className="font-mono text-[10px] text-emerald-600">
                  {corridorId}
                </span>
              </div>
              <div className="mt-1 space-y-0.5">
                {step1Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step1Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 1 · {step1Hash.slice(0, 18)}… ↗
                  </a>
                )}
                {step2Hash && (
                  <a href={`https://testnet.arcscan.app/tx/${step2Hash}`} target="_blank"
                    rel="noopener noreferrer"
                    className="block font-mono text-[10px] text-emerald-700 hover:underline">
                    Step 2 · {step2Hash.slice(0, 18)}… ↗
                  </a>
                )}
              </div>
              <button
                onClick={() => { reset(); setAmount(''); setQuote(null) }}
                className="mt-2 rounded-md bg-emerald-900/40 px-3 py-1 text-emerald-400 hover:bg-emerald-900/60"
              >
                New corridor swap
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
