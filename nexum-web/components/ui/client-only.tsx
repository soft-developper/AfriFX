'use client'
import { useEffect, useState } from 'react'

/**
 * Renders children only on the client after first mount.
 * Use this to wrap any component that reads wallet/browser state
 * to prevent Next.js hydration mismatches.
 */
export function ClientOnly({ children, fallback = null }: {
  children: React.ReactNode
  fallback?: React.ReactNode
}) {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  return mounted ? <>{children}</> : <>{fallback}</>
}
