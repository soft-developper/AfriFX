'use client'

/**
 * The signed-in account chip in the top bar.
 *
 * People no longer connect a wallet: they sign in, and the wallet is
 * created for them, so the top bar shows who they are rather than asking
 * them to bring something.
 */

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { User, LogOut, Copy, Check, Loader2, ChevronDown, Wallet } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import { clearSigningSession } from '@/hooks/useCircleTx'

export function AccountMenu() {
  const { account, loading, signOut } = useAuth()
  const [open,   setOpen]   = useState(false)
  const [copied, setCopied] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

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
    return <div className="h-9 w-28 animate-pulse rounded-full bg-app-border" />
  }

  if (!account) {
    return (
      <Link href="/signin"
        className="rounded-full bg-app-accent px-4 py-2 text-xs font-medium text-app-on-accent transition-colors hover:bg-app-accent-hover">
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
        className="flex items-center gap-2.5 rounded-full border border-app-border bg-app-surface py-1 pl-1 pr-3 transition-colors hover:border-app-accent/40">
        <span className="flex h-7 w-7 items-center justify-center rounded-full border border-app-accent/50 bg-app-accent/15 text-[11px] font-semibold text-app-accent-text">
          {initials || <User className="h-3.5 w-3.5" />}
        </span>
        <span className="hidden text-left leading-tight sm:block">
          <span className="block max-w-[9rem] truncate text-xs font-medium text-app-text">{account.username}</span>
          {address && (
            <span className="block font-mono text-[10px] text-app-muted">
              {address.slice(0, 6)}…{address.slice(-5)}
            </span>
          )}
        </span>
        <ChevronDown className="h-3.5 w-3.5 text-app-muted" />
      </button>

      {open && (
        <div role="menu"
          className="absolute right-0 z-50 mt-2 w-64 overflow-hidden rounded-2xl border border-app-border bg-app-surface shadow-xl shadow-black/30">
          <div className="flex items-center gap-3 border-b border-app-border p-4">
            <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-app-accent/50 bg-app-accent/15 text-sm font-semibold text-app-accent-text">
              {initials || <User className="h-5 w-5" />}
            </span>
            <div className="min-w-0">
              <p className="truncate text-sm font-medium text-app-text">
                {account.firstName} {account.lastName}
              </p>
              <p className="truncate text-[11px] text-app-muted">{account.email}</p>
            </div>
          </div>

          {address ? (
            <div className="border-b border-app-border px-3 py-2.5">
              <button onClick={copyAddress}
                className="flex w-full items-center gap-1.5 rounded-lg bg-app-bg px-2.5 py-2 text-left font-mono text-[10px] text-app-muted transition-colors hover:text-app-text">
                {copied
                  ? <><Check className="h-3 w-3 shrink-0 text-emerald-500" /> Copied</>
                  : <><Copy className="h-3 w-3 shrink-0" /> {address.slice(0, 10)}…{address.slice(-6)}</>}
              </button>
            </div>
          ) : (
            <div className="border-b border-app-border px-4 py-2.5">
              <p className="flex items-center gap-1.5 text-[10px] text-amber-500">
                <Loader2 className="h-3 w-3 animate-spin" /> Wallet setup unfinished
              </p>
            </div>
          )}

          <div className="p-1.5">
            <Link href="/profile" onClick={() => setOpen(false)} role="menuitem"
              className="flex items-center gap-2.5 rounded-xl px-3 py-2.5 text-xs text-app-text transition-colors hover:bg-app-bg">
              <User className="h-4 w-4 text-app-muted" /> Profile
            </Link>
            <Link href="/wallet" onClick={() => setOpen(false)} role="menuitem"
              className="flex items-center gap-2.5 rounded-xl px-3 py-2.5 text-xs text-app-text transition-colors hover:bg-app-bg">
              <Wallet className="h-4 w-4 text-app-muted" /> Wallet
            </Link>
            <button onClick={() => { setOpen(false); clearSigningSession(); void signOut() }} role="menuitem"
              className="flex w-full items-center gap-2.5 rounded-xl px-3 py-2.5 text-xs text-red-400 transition-colors hover:bg-red-900/15">
              <LogOut className="h-4 w-4" /> Sign out
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
