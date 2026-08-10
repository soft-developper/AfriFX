'use client'

import Link from 'next/link'
import { LogIn } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'

/**
 * Shown in place of a feature that needs an account.
 *
 * People can browse the whole app signed out, so instead of blocking
 * them at the door we let them look and explain what signing in unlocks
 * at the point they try to use something. `what` names the action in
 * the same words the button uses.
 */
export function SignInPrompt({ what }: { what: string }) {
  return (
    <div className="rounded-xl border border-dashed border-app-border bg-app-surface p-6 text-center">
      <p className="mb-1 text-sm font-medium text-app-text">Sign in to {what}</p>
      <p className="mb-4 text-xs text-app-muted">
        Takes a few seconds. We create your wallet for you, no seed phrase.
      </p>
      <Link href="/signin"
        className="inline-flex items-center gap-1.5 rounded-xl bg-app-accent px-4 py-2 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover">
        <LogIn className="h-3.5 w-3.5" /> Sign in
      </Link>
    </div>
  )
}

/**
 * Wrap anything that only works with an account. Renders the children
 * when signed in, and a prompt when not.
 */
export function RequireAccount(
  { what, children }: { what: string; children: React.ReactNode },
) {
  const { account, loading } = useAuth()
  if (loading) return <div className="h-24 animate-pulse rounded-xl bg-app-surface" />
  if (!account) return <SignInPrompt what={what} />
  return <>{children}</>
}
