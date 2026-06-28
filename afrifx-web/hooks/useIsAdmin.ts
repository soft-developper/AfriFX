'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useIsAdmin() {
  const { address } = useAccount()
  return useQuery({
    queryKey:        ['is-admin', address],
    queryFn:         async () => {
      if (!address) return false
      const res  = await fetch(`${API}/admin/auth/is-admin?wallet=${address}`)
      const data = await res.json()
      return data.isAdmin === true
    },
    enabled:         !!address,
    staleTime:       60_000,
    refetchInterval: false,
  })
}
