'use client'
import { useQuery } from '@tanstack/react-query'
import { TOKEN_KEY } from './useAdminAuth'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

// Admin identity is no longer tied to the connected wallet it's a
// separate email/password + 2FA session (see useAdminAuth). This just
// checks whether a valid admin session exists, for nav-link visibility.
export function useIsAdmin() {
  return useQuery({
    queryKey:        ['is-admin'],
    queryFn:         async () => {
      const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
      if (!token) return false
      const res = await fetch(`${API}/admin-auth/verify`, {
        headers: { Authorization: `Bearer ${token}` },
      })
      return res.ok
    },
    staleTime:       60_000,
    refetchInterval: false,
  })
}
