'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { ArrowUpDown, CheckCircle, AlertCircle, Loader2 } from 'lucide-react'
import { CurrencyInput } from './CurrencyInput'
import { RateDisplay } from './RateDisplay'
import { Button } from '@/components/ui/button'
import { useRate } from '@/hooks/useFXRate'
import { useSwap } from '@/hooks/useSwap'
import { LOCAL_CURRENCIES, countryForCurrency } from '@/lib/corridor'
import { CashOutCard } from './CashOutCard'  // single source of truth
import { useArcTransaction } from '@/hooks/useArcTransaction'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { SPREAD_BPS } from '@/lib/contracts'
import type { Currency } from '@/types'

const GAS_BUFFER = 0.001 // ~network fee per tx, kept aside so Max never over-spends

export function SwapCard() {
  const { isConnected } = useAccount()

  const [fromCurrency, setFromCurrency] = useState<Currency>('NGN')
  const [toCurrency,   setToCurrency]   = useState<Currency>('USDC')
  const [fromAmount,   setFromAmount]   = useState('')   // empty on load
  const [toAmount,     setToAmount]     = useState('')   // empty on load
  const [lastTx,       setLastTx]       = useState<{ hash: string; from: string; to: string } | null>(null)

  // Always resolve the LOCAL/USDC pair regardless of direction
  const localCurrency = toCurrency === 'USDC' ? fromCurrency : toCurrency

  /*
    Is this a cash-out? Only when spending USDC to receive a LOCAL currency,
    and only when we know which country to pay out in. Without a country a
    provider cannot quote, so we fall back to the original flow rather than
    showing a form that cannot succeed.
  */
  const cashOutCountry = toCurrency !== 'USDC' ? countryForCurrency(toCurrency) : undefined
  const isCashOut = fromCurrency === 'USDC' && toCurrency !== 'USDC' && !!cashOutCountry
  const pair = `${localCurrency}/USDC`

  const { rate: fxRate, isLoading: rateLoading } = useRate(pair)
  const rate   = fxRate?.rate ?? 0
  const spread = rate > 0 && fromAmount
    ? (parseFloat(fromAmount) / (toCurrency === 'USDC' ? rate : 1)) * (SPREAD_BPS / 10_000)
    : 0
  const netFee = 0.001

  const { buildQuote, execute, isLoading: swapping, error, txHash } = useSwap()
  const { isSuccess, explorerUrl } = useArcTransaction(txHash ?? undefined)
  const { formatted: usdcBalance } = useUSDCBalance()

  // USDC balance only matters when the user is SPENDING USDC (USDC → local).
  const spendingUsdc  = fromCurrency === 'USDC'
  const balanceNum    = parseFloat(usdcBalance) || 0
  const spendAmount   = parseFloat(fromAmount) || 0
  const maxSpendable  = Math.max(0, balanceNum - GAS_BUFFER)
  const insufficientUsdc = spendingUsdc && spendAmount > 0 && spendAmount > maxSpendable

  function setMaxUsdc() {
    setFromAmount(maxSpendable.toFixed(6))
  }

  // Recalculate receive amount whenever inputs change
  useEffect(() => {
    const from = parseFloat(fromAmount)
    if (!fromAmount || isNaN(from) || from <= 0 || rate === 0) {
      setToAmount('')
      return
    }

    let result: number
    if (toCurrency === 'USDC') {
      result = from / rate - spread - netFee
    } else {
      result = from * rate
    }

    setToAmount(result > 0 ? result.toFixed(toCurrency === 'USDC' ? 4 : 2) : '')
  }, [fromAmount, rate, toCurrency, spread])

  // Reset form after successful transaction
  useEffect(() => {
    if (isSuccess && txHash) {
      setLastTx({
        hash: txHash,
        from: `${parseFloat(fromAmount).toLocaleString()} ${fromCurrency}`,
        to:   `${toAmount} ${toCurrency}`,
      })
      // Reset fields
      setFromAmount('')
      setToAmount('')
    }
  }, [isSuccess, txHash])

  function flip() {
    const prevFrom   = fromCurrency
    const prevTo     = toCurrency
    const prevToAmt  = toAmount
    setFromCurrency(prevTo)
    setToCurrency(prevFrom)
    setFromAmount(prevToAmt || '')
    setToAmount('')
  }

  function handleFromAmountChange(val: string) {
    // Only allow positive numbers
    if (val === '' || /^\d*\.?\d*$/.test(val)) {
      setFromAmount(val)
      setLastTx(null) // clear success banner when user starts typing again
    }
  }

  async function handleConvert() {
    if (!isConnected || rate === 0 || !fromAmount || insufficientUsdc) return
    setLastTx(null)
    const quote = buildQuote(fromCurrency, toCurrency, parseFloat(fromAmount), rate)
    await execute(quote)
  }

  const fromCurrencies = toCurrency === 'USDC' ? LOCAL_CURRENCIES : (['USDC'] as Currency[])
  const toCurrencies   = fromCurrency === 'USDC' ? LOCAL_CURRENCIES : (['USDC', 'EURC'] as Currency[])
  const canConvert     = isConnected && rate > 0 && !!fromAmount && parseFloat(fromAmount) > 0 && !swapping && !insufficientUsdc

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5 shadow-xl">

      {/* Live rate banner */}
      {fxRate && rate > 0 && (
        <div className="mb-4 flex items-center justify-between rounded-lg bg-app-bg px-3 py-2 text-xs">
          <span className="text-app-muted">Live rate</span>
          <span className="font-mono font-medium text-app-text">
            1 USDC = {fxRate.rate.toLocaleString()} {localCurrency}
          </span>
          <span className={fxRate.change24h >= 0 ? 'text-emerald-400' : 'text-red-400'}>
            {fxRate.change24h >= 0 ? '+' : ''}{fxRate.change24h.toFixed(2)}%
          </span>
        </div>
      )}

      {/* USDC balance + Max only when spending USDC */}
      {spendingUsdc && isConnected && (
        <div className="mb-2 flex items-center justify-between text-xs">
          <span className="text-app-muted">Available balance</span>
          <span className="flex items-center gap-2">
            <span className="font-mono text-app-text">{usdcBalance} USDC</span>
            <button onClick={setMaxUsdc} className="text-app-accent-text hover:underline">Max</button>
          </span>
        </div>
      )}

      <CurrencyInput
        label="You send"
        amount={fromAmount}
        currency={fromCurrency}
        onAmountChange={handleFromAmountChange}
        onCurrencyChange={(c) => { setFromCurrency(c); setFromAmount(''); setToAmount('') }}
        currencies={fromCurrencies}
      />

      {/* Insufficient / remaining only when spending USDC */}
      {spendingUsdc && insufficientUsdc && (
        <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          Insufficient balance, you only have {usdcBalance} USDC
        </div>
      )}
      {spendingUsdc && !insufficientUsdc && spendAmount > 0 && (
        <p className="mt-2 text-xs text-emerald-400">
          Remaining after: {(balanceNum - spendAmount).toFixed(4)} USDC
        </p>
      )}

      <div className="my-1 flex justify-center">
        <button
          onClick={flip}
          className="rounded-full border border-app-border bg-app-surface p-2 text-app-muted transition-transform hover:rotate-180 hover:text-app-text"
          aria-label="Flip currencies"
        >
          <ArrowUpDown className="h-4 w-4" />
        </button>
      </div>

      <CurrencyInput
        label="You receive (estimated)"
        amount={toAmount}
        currency={toCurrency}
        onCurrencyChange={(c) => { setToCurrency(c); setToAmount('') }}
        currencies={toCurrencies}
        readOnly
        className="mb-4"
      />

      <RateDisplay
        fromCurrency={fromCurrency}
        toCurrency={toCurrency}
        rate={rate}
        spreadFee={spread}
        networkFee={netFee}
        isLoading={rateLoading || rate === 0}
      />

      {/*
        USDC to LOCAL CURRENCY is a real cash-out: it has to reach someone's
        bank account or mobile money. The old path just moved USDC to a vault
        and recorded a row, delivering nothing, so that direction now uses the
        payout flow instead. USDC-in (fiat to USDC) still uses the original
        path, since that leg is unchanged.
      */}
      {isCashOut ? (
        <div className="mt-4 border-t border-app-border pt-4">
          <CashOutCard
            usdcAmount={parseFloat(fromAmount) || 0}
            destCurrency={toCurrency}
            country={cashOutCountry!}
          />
        </div>
      ) : (
      <Button
        className="mt-4 w-full"
        size="lg"
        onClick={handleConvert}
        disabled={!canConvert}
      >
        {swapping ? (
          <><Loader2 className="h-4 w-4 animate-spin" /> Settling on Arc…</>
        ) : !isConnected ? (
          'Connect wallet to convert'
        ) : rate === 0 ? (
          'Fetching live rate…'
        ) : !fromAmount ? (
          'Enter an amount'
        ) : insufficientUsdc ? (
          'Insufficient USDC balance'
        ) : (
          `Convert ${parseFloat(fromAmount).toLocaleString()} ${fromCurrency} → ${toCurrency}`
        )}
      </Button>
      )}

      {/* Error state */}
      {error && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-red-900/50 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          {error}
        </div>
      )}

      {/* Success state shows last tx, clears when user types again */}
      {lastTx && (
        <a
          href={`https://testnet.arcscan.app/tx/${lastTx.hash}`}
          target="_blank"
          rel="noopener noreferrer"
          className="mt-3 flex items-start gap-2 rounded-lg border border-emerald-900/50 bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400 hover:underline"
        >
          <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <div>
            <p className="font-medium">Conversion successful · settled on Arc</p>
            <p className="mt-0.5 text-emerald-500">
              {lastTx.from} → {lastTx.to}
            </p>
            <p className="mt-0.5 font-mono text-[10px] text-emerald-700 dark:text-emerald-600">
              {lastTx.hash.slice(0, 20)}… · View on ArcScan ↗
            </p>
          </div>
        </a>
      )}
    </div>
  )
}
