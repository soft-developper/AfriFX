'use client'
import React from 'react'
import { cn } from '@/lib/utils'
import type { Currency } from '@/types'

import { CURRENCY_FLAG as FLAG, LOCAL_CURRENCIES } from '@/lib/corridor'

interface CurrencyInputProps {
  label: string
  amount: string
  currency: Currency
  onAmountChange?: (v: string) => void
  onCurrencyChange?: (v: Currency) => void
  readOnly?: boolean
  currencies?: Currency[]
  className?: string
}

const DEFAULT_CURRENCIES: Currency[] = [...LOCAL_CURRENCIES, 'USDC', 'EURC']

export function CurrencyInput({
  label, amount, currency,
  onAmountChange, onCurrencyChange,
  readOnly = false,
  currencies = DEFAULT_CURRENCIES,
  className,
}: CurrencyInputProps) {
  return (
    <div className={cn('rounded-lg border border-app-border bg-app-bg p-3.5', className)}>
      <p className="mb-2 text-[10px] font-semibold uppercase tracking-widest text-app-muted">{label}</p>
      <div className="flex items-center gap-3">
        <input
          type="number"
          value={amount}
          readOnly={readOnly}
          onChange={(e) => onAmountChange?.(e.target.value)}
          placeholder="0.00"
          className={cn(
            'w-0 flex-1 bg-transparent font-mono text-2xl font-medium text-app-text outline-none',
            'placeholder:text-app-border',
            readOnly && 'opacity-70'
          )}
        />
        <select
          value={currency}
          onChange={(e) => onCurrencyChange?.(e.target.value as Currency)}
          className="flex cursor-pointer items-center gap-2 rounded-md border border-app-border bg-app-surface px-3 py-1.5 text-sm font-medium text-app-text outline-none"
        >
          {currencies.map((c) => (
            <option key={c} value={c}>{FLAG[c]} {c}</option>
          ))}
        </select>
      </div>
    </div>
  )
}
