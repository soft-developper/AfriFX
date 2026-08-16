'use client'

/**
 * Gate for the signed-in app.
 *
 * Sends anyone without a session to /signin, and anyone whose wallet
 * never finished provisioning back to finish it, rather than dropping
 * them into a dashboard that cannot work.
 */

import { useEffect } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import { Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import { useIdleSignOut } from '@/hooks/useIdleSignOut'

export function AuthGuard({ children }: { children: React.ReactNode }) {
  const { account, loading } = useAuth()
  useIdleSignOut()
  const router   = useRouter()
  const pathname = usePathname()

  useEffect(() => {
    if (loading) return
    if (!account) {
      // Remember where they were headed so sign-in can return them.
      const next = pathname && pathname !== '/dashboard'
        ? `?next=${encodeURIComponent(pathname)}`
        : ''
      router.replace(`/signin${next}`)
    }
  }, [account, loading, pathname, router])

  // Hold the UI while the session is confirmed. Rendering children first
  // would flash protected content to a signed-out visitor.
  if (loading || !account) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
      </div>
    )
  }

  return <>{children}</>
}
