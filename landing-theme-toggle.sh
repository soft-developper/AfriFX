#!/bin/bash
# ============================================================
# AfriFX -- Dark/light toggle on the public pages
#
# The app had a theme switch but the PUBLIC pages didn't, so a visitor couldn't
# change theme until after launching the app.
#
# Adds the EXISTING ThemeToggle component (no new theme logic -- it reuses the
# same hook, storage key and behaviour as the in-app switch) to:
#   * the landing page nav
#   * PublicHeader, which About and Contact both use
# so every public page now behaves consistently.
#
# Notes:
#   * ThemeToggle is already a 'use client' component, so dropping it into the
#     landing page (a SERVER component) doesn't force the whole page
#     client-side. Verified by a clean production build.
#   * It's placed OUTSIDE the sm:block links, so it stays visible on mobile
#     where Features/About/Contact are hidden.
#   * The toggle keeps its existing niceties: a hydration-safe placeholder, and
#     the small accent dot indicating theme is on AUTO (following time of day)
#     until the visitor picks one manually.
#
# Web typechecks clean and builds.
#
# Run from ~/AfriFX:  bash landing-theme-toggle.sh
# ============================================================
set -e
echo ""
echo "Adding the theme toggle to public pages..."
echo ""

mkdir -p "afrifx-web/app"
cat > "afrifx-web/app/page.tsx" << 'AFX_EOF'
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
    'Convert between USDC and African currencies, send across borders, and trade peer-to-peer, settled on the Arc blockchain in under a second.',
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
          {/* Theme switch — kept visible at every breakpoint (the text links
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
          AfriFX is a decentralized FX and cross-border payments platform. Convert between USDC
          and African currencies, send across borders, and trade peer-to-peer, all on the Arc
          blockchain, with fees paid in USDC.
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
          <span className="inline-flex items-center gap-1.5"><Zap className="h-4 w-4 text-app-accent-text" /> Settled on Arc</span>
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
AFX_EOF
echo "  afrifx-web/app/page.tsx"

mkdir -p "afrifx-web/components/public"
cat > "afrifx-web/components/public/PublicChrome.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { ArrowUpRight } from 'lucide-react'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { ThemeToggle } from '@/components/layout/ThemeToggle'

export function PublicHeader({ active }: { active?: 'about' | 'contact' }) {
  return (
    <header className="border-b border-app-border bg-app-surface">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <AfriFXLogo size="sm" href="/" />
        <nav className="flex items-center gap-4 text-sm sm:gap-5">
          <Link href="/about"
            className={active === 'about' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            About
          </Link>
          <Link href="/contact"
            className={active === 'contact' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            Contact
          </Link>
          {/* Same theme switch as the landing page, so every public page
              behaves consistently. */}
          <ThemeToggle />
          <a href="/dashboard" target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 font-medium text-app-on-accent hover:bg-app-accent-hover">
            Launch app <ArrowUpRight className="h-3.5 w-3.5" />
          </a>
        </nav>
      </div>
    </header>
  )
}

export function PublicFooter() {
  return (
    <footer className="border-t border-app-border">
      <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-3 px-4 py-6 text-xs text-app-muted sm:flex-row">
        <span>© {new Date().getFullYear()} AfriFX. Stablecoin FX on Arc.</span>
        <div className="flex gap-4">
          <Link href="/" className="hover:text-app-text">Home</Link>
          <Link href="/about" className="hover:text-app-text">About</Link>
          <Link href="/contact" className="hover:text-app-text">Contact</Link>
        </div>
      </div>
    </footer>
  )
}
AFX_EOF
echo "  afrifx-web/components/public/PublicChrome.tsx"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Public pages: dark/light theme toggle'"
echo "  git push"
echo ""
echo "  After deploy, check the landing page, /about and /contact -- the sun/moon"
echo "  button sits next to 'Launch app'. Click it to switch; the choice persists"
echo "  (and carries into the app, since it's the same storage key)."
