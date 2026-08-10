#!/usr/bin/env bash
# ============================================================
# browse-without-signin.sh
#
# Let people look around before signing in.
#
# Run AFTER fix-google-redirect.sh.
#
# WHAT CHANGES
#   - "Launch app" now opens the DASHBOARD, not the sign-in page.
#   - AuthGuard is removed from the (app) layout, so every screen is
#     browsable signed out. The top bar already shows a Sign in button
#     when there's no account, so that stays the way in.
#   - ProfileGuard is unchanged: it only redirects to /profile/setup
#     when a wallet address exists, so anonymous visitors are unaffected.
#
# NEW: components/auth/SignInPrompt.tsx
#   <SignInPrompt what="send money" />       a friendly inline prompt
#   <RequireAccount what="send money">...    renders children when
#                                            signed in, the prompt when not
#
#   Use these on the ACTIONS that need an account rather than blocking
#   whole pages. Someone evaluating the product should be able to see
#   what it does before being asked for anything.
#
# NOTHING LEAKS: every hook fetches by wallet address, and an anonymous
# visitor has none, so lists come back empty rather than showing another
# user's data.
#
# AuthGuard is kept in the codebase, unused, for any route that later
# genuinely must be private.
#
# VERIFIED: web tsc clean, npm run build succeeds.
#
# AFTER RUNNING:
#   cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-web/app/(app)/layout.tsx")"
cat > 'afrifx-web/app/(app)/layout.tsx' <<'AFX_P00_EOF'
import { TopNav }      from '@/components/layout/TopNav'
import { PlatformMaintenanceBanner } from '@/hooks/useMaintenance'
import { Sidebar }     from '@/components/layout/Sidebar'
import { MobileNav }   from '@/components/layout/MobileNav'
import { ProfileGuard } from '@/components/profile/ProfileGuard'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg">
      <TopNav />
      <PlatformMaintenanceBanner />
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar hidden on mobile, visible md+ */}
        <Sidebar />
        {/* Main content */}
        <main className="flex-1 overflow-y-auto p-4 pb-24 md:p-6 md:pb-6">
          <ProfileGuard>{children}</ProfileGuard>
        </main>
      </div>
      {/* Bottom nav mobile only */}
      <MobileNav />
    </div>
  )
}
AFX_P00_EOF
echo "  ✓ afrifx-web/app/(app)/layout.tsx"

mkdir -p "$(dirname "afrifx-web/app/page.tsx")"
cat > 'afrifx-web/app/page.tsx' <<'AFX_P01_EOF'
import Link from 'next/link'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { ArrowUpRight } from 'lucide-react'
import { LandingRates } from '@/components/landing/LandingRates'
import { LandingFeatures } from '@/components/landing/LandingFeatures'
import { LandingHowItWorks } from '@/components/landing/LandingHowItWorks'
// ThemeToggle is its own 'use client' component, so it can be dropped into
// this server component without making the whole page client-side.
import { ThemeToggle } from '@/components/layout/ThemeToggle'
import { ShieldCheck, Zap, Coins } from 'lucide-react'

export const metadata = {
  title: 'AfriFX, Stablecoin FX & cross-border payments on Arc',
  description:
    'Trade USDC for local currency peer-to-peer with on-chain escrow, bridge funds across Arc, Ethereum and Base, and track live African FX rates.',
}

export default function LandingPage() {
  return (
    <div className="min-h-screen bg-app-bg text-app-text">
      <LandingHeader />
      <Hero />
      <LandingHowItWorks />
      <LandingFeatures />
      <LandingFooter />
    </div>
  )
}

function LandingHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-app-border/60 bg-app-bg/80 backdrop-blur-md">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3.5 sm:px-6">
        <AfriFXLogo size="sm" href="/" />
        <nav className="flex items-center gap-1 sm:gap-4">
          <Link href="#features" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">Features</Link>
          <Link href="/about" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">About</Link>
          <Link href="/contact" className="hidden px-3 py-2 text-sm text-app-muted hover:text-app-text sm:block">Contact</Link>
          {/* Theme switch kept visible at every breakpoint (the text links
              hide on mobile, but the toggle is small enough to always fit). */}
          <ThemeToggle />
          <a
            href="/dashboard" target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-xl bg-app-accent px-4 py-2 text-sm font-semibold text-app-on-accent transition-transform hover:scale-[1.03]"
          >
            Launch app <ArrowUpRight className="h-4 w-4" />
          </a>
        </nav>
      </div>
    </header>
  )
}

function Hero() {
  return (
    <section className="relative overflow-hidden">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="absolute left-1/2 top-[-10%] h-[420px] w-[820px] -translate-x-1/2 rounded-full bg-app-accent/10 blur-[120px]" />
      </div>

      <div className="mx-auto max-w-6xl px-4 pb-20 pt-16 text-center sm:px-6 sm:pt-24">
        <span className="inline-flex items-center gap-2 rounded-full border border-app-border bg-app-surface px-4 py-1.5 text-xs font-medium text-app-muted">
          <span className="h-1.5 w-1.5 rounded-full bg-app-accent" />
          Live on Arc testnet
        </span>

        <h1 className="mx-auto mt-6 max-w-4xl text-4xl font-extrabold leading-[1.05] tracking-tight sm:text-6xl">
          Move money across Africa,
          <br className="hidden sm:block" />
          <span className="afx-gradient-text">settled in seconds.</span>
        </h1>

        <p className="mx-auto mt-6 max-w-2xl text-base leading-relaxed text-app-muted sm:text-lg">
          AfriFX is a decentralized FX and cross-border payments platform. Trade USDC for
          local currency peer-to-peer with on-chain escrow, move funds between Arc, Ethereum,
          Base and more, and track live rates across 13 African currencies.
        </p>

        <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <a
            href="/dashboard" target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-2 rounded-xl bg-app-accent px-6 py-3 text-base font-semibold text-app-on-accent transition-transform hover:scale-[1.03]"
          >
            Launch app <ArrowUpRight className="h-5 w-5" />
          </a>
          <Link
            href="#features"
            className="inline-flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-6 py-3 text-base font-medium text-app-text hover:border-app-accent"
          >
            Explore features
          </Link>
        </div>

        {/* Trust row */}
        <div className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-xs text-app-muted">
          <span className="inline-flex items-center gap-1.5"><ShieldCheck className="h-4 w-4 text-app-accent-text" /> Non-custodial</span>
          <span className="inline-flex items-center gap-1.5"><Zap className="h-4 w-4 text-app-accent-text" /> Multi-chain USDC</span>
          <span className="inline-flex items-center gap-1.5"><Coins className="h-4 w-4 text-app-accent-text" /> Fees in USDC</span>
        </div>

        <div className="mx-auto mt-16 max-w-3xl">
          <LandingRates />
        </div>
      </div>
    </section>
  )
}

function LandingFooter() {
  return (
    <footer className="border-t border-app-border">
      <div className="mx-auto max-w-6xl px-4 py-12 sm:px-6">
        <div className="flex flex-col justify-between gap-8 sm:flex-row">
          <div className="max-w-xs">
            <AfriFXLogo size="sm" href="/" />
            <p className="mt-3 text-sm text-app-muted">
              Decentralized stablecoin FX and cross-border payments, built on Arc.
            </p>
          </div>
          <div className="flex gap-12">
            <div>
              <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-app-muted">Product</p>
              <ul className="space-y-2 text-sm">
                <li><Link href="#features" className="text-app-text hover:text-app-accent-text">Features</Link></li>
                <li><a href="/dashboard" target="_blank" rel="noopener noreferrer" className="text-app-text hover:text-app-accent-text">Launch app</a></li>
              </ul>
            </div>
            <div>
              <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-app-muted">Company</p>
              <ul className="space-y-2 text-sm">
                <li><Link href="/about" className="text-app-text hover:text-app-accent-text">About</Link></li>
                <li><Link href="/contact" className="text-app-text hover:text-app-accent-text">Contact</Link></li>
              </ul>
            </div>
          </div>
        </div>
        <div className="mt-10 border-t border-app-border pt-6 text-xs text-app-muted">
          © {new Date().getFullYear()} AfriFX. Stablecoin FX on Arc.
        </div>
      </div>
    </footer>
  )
}
AFX_P01_EOF
echo "  ✓ afrifx-web/app/page.tsx"

mkdir -p "$(dirname "afrifx-web/components/auth/SignInPrompt.tsx")"
cat > 'afrifx-web/components/auth/SignInPrompt.tsx' <<'AFX_P02_EOF'
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
AFX_P02_EOF
echo "  ✓ afrifx-web/components/auth/SignInPrompt.tsx"

echo ""
echo "→ Done."
echo ""
echo "  Landing -> Launch app (new tab) -> dashboard, signed out."
echo "  Sign in from the top-right button whenever you like."
echo ""
echo "Then:  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo ""
