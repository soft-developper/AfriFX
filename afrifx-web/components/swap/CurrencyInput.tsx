'use client'
import React from 'react'
import { cn } from '@/lib/utils'
import type { Currency } from '@/types'

const FLAG: Record<Currency, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪',
  ZAR: '🇿🇦', EGP: '🇪🇬', USDC: '💵', EURC: '🇪🇺',
}

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

const DEFAULT_CURRENCIES: Currency[] = ['NGN', 'GHS', 'KES', 'USDC', 'EURC']

export function CurrencyInput({
  label, amount, currency,
  onAmountChange, onCurrencyChange,
  readOnly = false,
  currencies = DEFAULT_CURRENCIES,
  className,
}: CurrencyInputProps) {
  return (
    <div className={cn('rounded-lg border border-[#1B2B4B] bg-[#080D1B] p-3.5', className)}>
      <p className="mb-2 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">{label}</p>
      <div className="flex items-center gap-3">
        <input
          type="number"
          value={amount}
          readOnly={readOnly}
          onChange={(e) => onAmountChange?.(e.target.value)}
          placeholder="0.00"
          className={cn(
            'w-0 flex-1 bg-transparent font-mono text-2xl font-medium text-[#E2E8F0] outline-none',
            'placeholder:text-[#1B2B4B]',
            readOnly && 'opacity-70'
          )}
        />
        <select
          value={currency}
          onChange={(e) => onCurrencyChange?.(e.target.value as Currency)}
          className="flex cursor-pointer items-center gap-2 rounded-md border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-sm font-medium text-[#E2E8F0] outline-none"
        >
          {currencies.map((c) => (
            <option key={c} value={c}>{FLAG[c]} {c}</option>
          ))}
        </select>
      </div>
    </div>
  )
}
