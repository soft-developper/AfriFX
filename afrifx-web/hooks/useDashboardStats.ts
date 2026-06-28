'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDashboardStats() {
  const { address } = useAccount()
  return useQuery({
    queryKey:  ['dashboard-stats', address],
    queryFn:   async () => {
      if (!address) return null
      const res  = await fetch(`${API}/user/${address}/stats`)
      if (!res.ok) throw new Error('Failed to fetch stats')
      return res.json()
    },
    enabled:        !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
