'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TokenBalance {
  symbol:   string
  name:     string
  balance:  number
  usdValue: number
  color:    string
  address:  string
}

export interface WalletData {
  tokens:       TokenBalance[]
  escrow:       { locked: number; openOffers: number; activeOffers: number }
  p2p:          { completed: number; totalVolume: number }
  localEquiv:   { currency: string; flag: string; rate: number; amount: number }[]
  transactions: {
    id: string; fromCurrency: string; toCurrency: string
    fromAmount: number; toAmount: number
    status: string; arcTxHash: string | null
    reference: string | null; createdAt: number
  }[]
}

export function useWallet() {
  const { address } = useAccount()
  return useQuery<WalletData | null>({
    queryKey:        ['wallet', address],
    queryFn:         async () => {
      if (!address) return null
      const res = await fetch(`${API}/wallet/${address}`)
      if (!res.ok) throw new Error('Failed to fetch wallet')
      return res.json()
    },
    enabled:         !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
