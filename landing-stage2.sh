#!/bin/bash
# ============================================================
# AfriFX -- Landing page STAGE 2: feature sections
#
# Adds the full feature showcase to the landing page (requires stage 1).
# Every app capability, grouped like the app nav, each as a card with a
# brief overview + a concrete use case:
#
#   Exchange   -> Convert, Corridor, Send
#   P2P Market -> Marketplace, My Trades
#   Payments   -> Invoices, Settlements
#   Treasury   -> Treasury, Payroll
#   Account    -> Wallet, Dashboard, History, Profile
#
# Ends with a closing "Launch app" CTA. The section is anchored at #features,
# so the header/hero "Explore features" and "Features" links jump to it.
#
# Run from ~/AfriFX:  bash landing-stage2.sh
# ============================================================
set -e
echo ""
echo "Adding landing page feature sections (stage 2)..."
echo ""

mkdir -p "afrifx-web/components/landing"
cat > "afrifx-web/components/landing/LandingFeatures.tsx" << 'AFX_EOF'
'use client'
import {
  ArrowLeftRight, Globe, Send, Store, FileText, BarChart3,
  Building2, CreditCard, Wallet, LayoutDashboard, History, User, TrendingUp,
} from 'lucide-react'

interface Feature {
  icon: any
  name: string
  overview: string
  useCase: string
}

interface Group {
  eyebrow: string
  title: string
  features: Feature[]
}

const GROUPS: Group[] = [
  {
    eyebrow: 'Exchange',
    title: 'Convert and move value',
    features: [
      {
        icon: ArrowLeftRight,
        name: 'Convert',
        overview: 'Swap between USDC and African currencies at live rates, with fees shown upfront and settled on-chain.',
        useCase: 'A freelancer paid in USDC converts to NGN the moment a client pays, locking the rate instantly.',
      },
      {
        icon: Globe,
        name: 'Corridor',
        overview: 'A two-step cross-border route (e.g. NGN → USDC → KES) that bridges two African currencies through USDC in one flow.',
        useCase: 'Send money from Nigeria to Kenya without a bank wire — the corridor handles both legs and confirms each on-chain.',
      },
      {
        icon: Send,
        name: 'Send',
        overview: 'Transfer USDC directly to any wallet address on Arc, with a balance check so you never overspend.',
        useCase: 'Pay a supplier in seconds by sending USDC straight to their wallet, no intermediary.',
      },
    ],
  },
  {
    eyebrow: 'P2P Market',
    title: 'Trade peer-to-peer',
    features: [
      {
        icon: Store,
        name: 'Marketplace',
        overview: 'Browse and accept peer offers to buy or sell USDC for local currency, with funds held in an on-chain escrow until both sides confirm.',
        useCase: 'Cash out USDC to local currency by matching with someone nearby, protected by escrow and a dispute process.',
      },
      {
        icon: TrendingUp,
        name: 'My Trades',
        overview: 'Track every offer you have created or accepted, with live status and built-in dispute resolution if something goes wrong.',
        useCase: 'Follow an in-progress trade from acceptance to release, and raise a dispute with admin support if needed.',
      },
    ],
  },
  {
    eyebrow: 'Payments',
    title: 'Invoice and settle',
    features: [
      {
        icon: FileText,
        name: 'Invoices',
        overview: 'Create shareable payment requests that anyone can pay in USDC, with a PDF receipt emailed on completion.',
        useCase: 'Send a client a payment link; they pay in USDC and both of you get a receipt automatically.',
      },
      {
        icon: BarChart3,
        name: 'Settlements',
        overview: 'A full, exportable history of your payments with USD equivalents, ready for accounting.',
        useCase: 'Export a month of settlements with USD values for your bookkeeper at tax time.',
      },
    ],
  },
  {
    eyebrow: 'Treasury',
    title: 'Run business finances',
    features: [
      {
        icon: Building2,
        name: 'Treasury',
        overview: 'Automate conversions with rules, manage funds, and keep a clear view of business balances.',
        useCase: 'Set a rule to auto-convert incoming USDC to local currency above a threshold, so cash is always ready.',
      },
      {
        icon: CreditCard,
        name: 'Payroll',
        overview: 'Pay a whole team in one batch, with each payment confirmed on-chain and marked sent or failed accurately.',
        useCase: 'Run monthly payroll for a distributed team — one batch, every payment verified on Arc.',
      },
    ],
  },
  {
    eyebrow: 'Account',
    title: 'Your wallet and activity',
    features: [
      {
        icon: Wallet,
        name: 'Wallet',
        overview: 'Connect with MetaMask or sign in with Google/email to get a secure embedded wallet — your keys, no seed phrase required.',
        useCase: 'A first-time user signs in with Google and starts transacting immediately, no crypto setup.',
      },
      {
        icon: LayoutDashboard,
        name: 'Dashboard',
        overview: 'Your at-a-glance home: balances, recent activity, live rates, and quick actions.',
        useCase: 'Open the app and see your USDC balance, latest transactions, and today’s rates in one view.',
      },
      {
        icon: History,
        name: 'History',
        overview: 'Every conversion and corridor swap, with real on-chain status — settled, pending, or failed.',
        useCase: 'Check whether last night’s conversion actually settled on-chain, with the transaction hash to verify.',
      },
      {
        icon: User,
        name: 'Profile',
        overview: 'Manage your display name, contact details, and notification preferences.',
        useCase: 'Set a username so counterparties see a name instead of a wallet address in P2P trades.',
      },
    ],
  },
]

export function LandingFeatures() {
  return (
    <section id="features" className="mx-auto max-w-6xl px-4 py-20 sm:px-6 sm:py-28">
      <div className="mx-auto max-w-2xl text-center">
        <span className="text-xs font-semibold uppercase tracking-[0.2em] text-app-accent-text">Everything in AfriFX</span>
        <h2 className="mt-3 text-3xl font-extrabold tracking-tight sm:text-4xl">
          One app for African <span className="afx-gradient-text">money movement</span>
        </h2>
        <p className="mt-4 text-app-muted">
          From simple conversions to business payroll — here’s what you can do, and when you’d reach for it.
        </p>
      </div>

      <div className="mt-16 space-y-16">
        {GROUPS.map((group) => (
          <div key={group.eyebrow}>
            <div className="mb-6 flex items-baseline gap-3">
              <span className="text-xs font-semibold uppercase tracking-[0.18em] text-app-accent-text">{group.eyebrow}</span>
              <span className="h-px flex-1 bg-app-border" />
              <h3 className="text-lg font-semibold text-app-text">{group.title}</h3>
            </div>

            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {group.features.map((f) => {
                const Icon = f.icon
                return (
                  <div
                    key={f.name}
                    className="group rounded-2xl border border-app-border bg-app-surface p-5 transition-colors hover:border-app-accent/60"
                  >
                    <div className="mb-3 inline-flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/12 text-app-accent-text transition-transform group-hover:scale-105">
                      <Icon className="h-5 w-5" />
                    </div>
                    <h4 className="text-base font-semibold text-app-text">{f.name}</h4>
                    <p className="mt-1.5 text-sm leading-relaxed text-app-muted">{f.overview}</p>
                    <p className="mt-3 border-t border-app-border pt-3 text-xs leading-relaxed text-app-muted">
                      <span className="font-medium text-app-accent-text">Use case · </span>{f.useCase}
                    </p>
                  </div>
                )
              })}
            </div>
          </div>
        ))}
      </div>

      {/* Closing CTA */}
      <div className="mt-20 overflow-hidden rounded-3xl border border-app-border bg-app-surface p-10 text-center">
        <h3 className="text-2xl font-extrabold tracking-tight sm:text-3xl">
          Ready to move money the <span className="afx-gradient-text">modern way?</span>
        </h3>
        <p className="mx-auto mt-3 max-w-xl text-app-muted">
          Connect a wallet or sign in with Google — you’ll be transacting on Arc in under a minute.
        </p>
        <a
          href="/dashboard" target="_blank" rel="noopener noreferrer"
          className="mt-6 inline-flex items-center gap-2 rounded-xl bg-app-accent px-6 py-3 text-base font-semibold text-app-on-accent transition-transform hover:scale-[1.03]"
        >
          Launch app
        </a>
      </div>
    </section>
  )
}
AFX_EOF
echo "  afrifx-web/components/landing/LandingFeatures.tsx"

mkdir -p "afrifx-web/app"
cat > "afrifx-web/app/page.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { ArrowUpRight } from 'lucide-react'
import { LandingRates } from '@/components/landing/LandingRates'
import { LandingFeatures } from '@/components/landing/LandingFeatures'

export const metadata = {
  title: 'AfriFX — Stablecoin FX & cross-border payments on Arc',
  description:
    'Convert between USDC and African currencies, send across borders, and trade peer-to-peer — settled on the Arc blockchain in under a second.',
}

export default function LandingPage() {
  return (
    <div className="min-h-screen bg-app-bg text-app-text">
      <LandingHeader />
      <Hero />
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
          and African currencies, send across borders, and trade peer-to-peer — all on the Arc
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

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Landing stage 2: feature sections'"
echo "  git push"
echo ""
echo "  The landing page now has: hero -> feature sections (all capabilities"
echo "  with overviews + use cases) -> closing CTA -> footer. The 'Features'"
echo "  and 'Explore features' links scroll to the #features section."
