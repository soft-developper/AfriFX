'use client'
import Link              from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { AccountMenu }    from '@/components/auth/AccountMenu'
import { ClientOnly }     from '@/components/ui/client-only'
import { NotificationBell } from '@/components/notifications/NotificationBell'
import { ThemeToggle }     from '@/components/layout/ThemeToggle'
import { AfriFXLogo }      from '@/components/brand/AfriFXLogo'

export function TopNav() {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border px-4 md:px-6">
      <div className="flex items-center gap-2.5">
        <AfriFXLogo size="sm" href="/dashboard" />
        <span className="hidden sm:inline-flex items-center gap-1 rounded-full bg-app-accent/10 px-2 py-0.5 text-[10px] font-medium text-app-accent-text">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </div>

      <ClientOnly fallback={
        <div className="h-8 w-28 animate-pulse rounded-xl bg-app-border" />
      }>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <NotificationBell />
          <AccountMenu />
        </div>
      </ClientOnly>
    </header>
  )
}
