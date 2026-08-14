'use client'

/**
 * The signed-in account chip in the top bar.
 *
 * Replaces the wallet connect button. People no longer connect a wallet:
 * they sign in, and the wallet is created for them, so the top bar shows
 * who they are rather than asking them to bring something.
 */

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { User, LogOut, Copy, Check, Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'

export function AccountMenu() {
  const { account, loading, signOut } = useAuth()
  const [open,   setOpen]   = useState(false)
  const [copied, setCopied] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  // Close on outside click and on Escape, so the menu never traps focus.
  useEffect(() => {
    if (!open) return
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  if (loading) {
    return <div className="h-8 w-24 animate-pulse rounded-xl bg-app-border" />
  }

  if (!account) {
    return (
      <Link href="/signin"
        className="rounded-xl bg-app-accent px-3 py-1.5 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover">
        Sign in
      </Link>
    )
  }

  const initials = `${account.firstName?.[0] ?? ''}${account.lastName?.[0] ?? ''}`.toUpperCase()
  const address  = account.walletAddress

  async function copyAddress() {
    if (!address) return
    await navigator.clipboard.writeText(address).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div className="relative" ref={ref}>
      <button onClick={() => setOpen(o => !o)}
        aria-haspopup="menu" aria-expanded={open}
        className="flex items-center gap-2 rounded-xl border border-app-border px-2 py-1.5 hover:bg-app-surface">
        <span className="flex h-6 w-6 items-center justify-center rounded-full bg-app-accent/20 text-[10px] font-semibold text-app-accent-text">
          {initials || <User className="h-3 w-3" />}
        </span>
        <span className="hidden max-w-[10rem] truncate text-xs text-app-text sm:inline">
          {account.username}
        </span>
      </button>

      {open && (
        <div role="menu"
          className="absolute right-0 z-50 mt-2 w-60 rounded-xl border border-app-border bg-app-surface p-1 shadow-lg">
          <div className="border-b border-app-border px-3 py-2.5">
            <p className="truncate text-sm font-medium text-app-text">
              {account.firstName} {account.lastName}
            </p>
            <p className="truncate text-[11px] text-app-muted">{account.email}</p>

            {address ? (
              <button onClick={copyAddress}
                className="mt-2 flex w-full items-center gap-1.5 rounded-lg bg-app-bg px-2 py-1.5 text-left font-mono text-[10px] text-app-muted hover:text-app-text">
                {copied
                  ? <><Check className="h-3 w-3 shrink-0 text-emerald-500" /> Copied</>
                  : <><Copy className="h-3 w-3 shrink-0" /> {address.slice(0, 10)}…{address.slice(-6)}</>}
              </button>
            ) : (
              // Wallet setup didn't finish. Say so plainly and give them
              // the way to fix it rather than showing an empty space.
              <p className="mt-2 flex items-center gap-1.5 text-[10px] text-amber-500">
                <Loader2 className="h-3 w-3 animate-spin" /> Wallet setup unfinished
              </p>
            )}
          </div>

          <Link href="/profile" onClick={() => setOpen(false)} role="menuitem"
            className="flex items-center gap-2 rounded-lg px-3 py-2 text-xs text-app-text hover:bg-app-bg">
            <User className="h-3.5 w-3.5" /> Profile
          </Link>
          <button onClick={() => { setOpen(false); void signOut() }} role="menuitem"
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-xs text-app-text hover:bg-app-bg">
            <LogOut className="h-3.5 w-3.5" /> Sign out
          </button>
        </div>
      )}
    </div>
  )
}
