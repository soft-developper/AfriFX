'use client'
import { useQuery } from '@tanstack/react-query'
import type { FXRate } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

async function fetchRates(): Promise<FXRate[]> {
  const res = await fetch(`${API_BASE}/rates`)
  if (!res.ok) throw new Error('Failed to fetch FX rates')
  return res.json()
}

export function useFXRates() {
  return useQuery<FXRate[]>({
    queryKey: ['fx-rates'],
    queryFn: fetchRates,
    refetchInterval: 30_000,
    staleTime: 15_000,
  })
}

export function useRate(pair: string) {
  const { data: rates, ...rest } = useFXRates()
  const rate = rates?.find((r) => r.pair === pair)
  return { rate, ...rest }
}
