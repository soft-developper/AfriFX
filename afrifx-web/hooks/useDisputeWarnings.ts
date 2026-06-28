'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDisputeWarnings() {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['dispute-warnings', address],
    queryFn: async () => {
      const res  = await fetch(`${API}/user/${address}`)
      const data = await res.json()
      return Number(data.dispute_warnings ?? 0)
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}
