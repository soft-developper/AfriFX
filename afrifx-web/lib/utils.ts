import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function shortenAddress(address: string | null | undefined): string {
  if (!address) return '-'
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

export function formatAmount(amount: number, decimals = 2): string {
  return amount.toLocaleString(undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

export function formatDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString([], {
    month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}
