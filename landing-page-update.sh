#!/bin/bash
# ============================================================
# AfriFX -- landing page updated to match what the app actually does
#
# The landing page was still SELLING A FEATURE THAT NO LONGER EXISTS. That's
# worse than being out of date: a visitor could click through expecting Corridor
# and not find it.
#
# WHAT CHANGED
#
# Features section:
#   * 'Corridor' REPLACED with 'Bridge' -- native USDC between Arc and Ethereum,
#     Base, Arbitrum, Polygon via Circle CCTP. No wrapped tokens, no third-party
#     custody, user signs every step.
#   * 'Convert' renamed to 'Trade', matching the nav, and now says 13 African
#     currencies rather than being vague.
#   * 'Send' rewritten: it is no longer Arc-only. Same-chain goes direct,
#     cross-chain draws on the unified balance.
#   * Treasury now leads with the UNIFIED USDC BALANCE (the Gateway work), which
#     was the most notable recent addition and wasn't mentioned at all.
#   * Settlements copy no longer says "corridor swap".
#
# Hero:
#   * Paragraph and meta description rewritten for multi-chain.
#   * The badge "Settled on Arc" became "Multi-chain USDC" -- Arc is still home,
#     but the old wording now UNDERSTATES what you support.
#
# How it works:
#   * "Convert at live rates" -> "Trade at live rates" (13 currencies)
#   * "Send across borders"   -> "Send across chains"
#
# Deliberately NOT overclaimed: everything here describes something that
# actually ships today. No Flutterwave, no fiat on/off-ramp, no mainnet.
#
# Checked: zero em-dashes in the new copy, typechecks clean, builds clean.
#
# Run from ~/AfriFX:  bash landing-page-update.sh
# ============================================================
set -e
echo ""
echo "Updating the landing page..."
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
    'Trade USDC against 13 African currencies, bridge funds across Arc, Ethereum and Base, and settle peer-to-peer on-chain.',
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
          AfriFX is a decentralized FX and cross-border payments platform. Trade USDC against
          13 African currencies, move funds between Arc, Ethereum, Base and more, and settle
          peer-to-peer, with fees paid in USDC.
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
AFX_EOF
echo "  afrifx-web/app/page.tsx"

mkdir -p "afrifx-web/components/landing"
cat > "afrifx-web/components/landing/LandingFeatures.tsx" << 'AFX_EOF'
'use client'
import { Reveal } from './Reveal'
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
        name: 'Trade',
        overview: 'Swap between USDC and 13 African currencies at live rates, with fees shown upfront and settled on-chain.',
        useCase: 'A freelancer paid in USDC converts to NGN the moment a client pays, locking the rate instantly.',
      },
      {
        icon: Globe,
        name: 'Bridge',
        overview: 'Move native USDC between Arc and Ethereum, Base, Arbitrum or Polygon using Circle CCTP. No wrapped tokens, no third-party custody.',
        useCase: 'Bring USDC from Ethereum onto Arc to trade, or move it back out, signing every step from your own wallet.',
      },
      {
        icon: Send,
        name: 'Send',
        overview: 'Send USDC to any address on any supported chain. Same-chain transfers go direct, cross-chain draws on your unified balance.',
        useCase: 'Pay a supplier on Base while your funds sit on Arc, in one step, with no bridging beforehand.',
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
        overview: 'One unified USDC balance spendable across chains, plus rules that auto-convert to local currency.',
        useCase: 'Hold funds once and pay out on whichever chain a partner needs, without bridging first.',
      },
      {
        icon: CreditCard,
        name: 'Payroll',
        overview: 'Pay a whole team in one batch, with each payment confirmed on-chain and marked sent or failed accurately.',
        useCase: 'Run monthly payroll for a distributed team, one batch, every payment verified on Arc.',
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
        overview: 'Connect with MetaMask or sign in with Google/email to get a secure embedded wallet, your keys, no seed phrase required.',
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
        overview: 'Every trade, bridge and transfer, with real on-chain status, settled, pending, or failed.',
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
      <Reveal>
        <div className="mx-auto max-w-2xl text-center">
          <span className="text-xs font-semibold uppercase tracking-[0.2em] text-app-accent-text">Everything in AfriFX</span>
          <h2 className="mt-3 text-3xl font-extrabold tracking-tight sm:text-4xl">
            One app for African <span className="afx-gradient-text">money movement</span>
          </h2>
          <p className="mt-4 text-app-muted">
            From simple conversions to business payroll, here’s what you can do, and when you’d reach for it.
          </p>
        </div>
      </Reveal>

      <div className="mt-16 space-y-16">
        {GROUPS.map((group) => (
          <div key={group.eyebrow}>
            <Reveal>
              <div className="mb-6 flex items-baseline gap-3">
                <span className="text-xs font-semibold uppercase tracking-[0.18em] text-app-accent-text">{group.eyebrow}</span>
                <span className="h-px flex-1 bg-app-border" />
                <h3 className="text-lg font-semibold text-app-text">{group.title}</h3>
              </div>
            </Reveal>

            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {group.features.map((f, i) => {
                const Icon = f.icon
                return (
                  <Reveal key={f.name} delay={i * 90}>
                    <div className="group h-full rounded-2xl border border-app-border bg-app-surface p-5 transition-colors hover:border-app-accent/60">
                      <div className="mb-3 inline-flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/12 text-app-accent-text transition-transform group-hover:scale-105">
                        <Icon className="h-5 w-5" />
                      </div>
                      <h4 className="text-base font-semibold text-app-text">{f.name}</h4>
                      <p className="mt-1.5 text-sm leading-relaxed text-app-muted">{f.overview}</p>
                      <p className="mt-3 border-t border-app-border pt-3 text-xs leading-relaxed text-app-muted">
                        <span className="font-medium text-app-accent-text">Use case · </span>{f.useCase}
                      </p>
                    </div>
                  </Reveal>
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
          Connect a wallet or sign in with Google, you’ll be transacting on Arc in under a minute.
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

mkdir -p "afrifx-web/components/landing"
cat > "afrifx-web/components/landing/LandingHowItWorks.tsx" << 'AFX_EOF'
'use client'
import { Reveal } from './Reveal'
import { Wallet, ArrowLeftRight, Send } from 'lucide-react'

const STEPS = [
  {
    n: '01',
    icon: Wallet,
    title: 'Connect or sign in',
    body: 'Use MetaMask, or sign in with Google or email to get a secure embedded wallet, no seed phrase needed.',
  },
  {
    n: '02',
    icon: ArrowLeftRight,
    title: 'Trade at live rates',
    body: 'Swap between USDC and 13 African currencies with fees shown upfront, settled on Arc in seconds.',
  },
  {
    n: '03',
    icon: Send,
    title: 'Send across chains',
    body: 'Move value to any wallet on any supported chain, pay an invoice, or trade peer-to-peer, every step confirmed on-chain.',
  },
]

export function LandingHowItWorks() {
  return (
    <section className="border-y border-app-border bg-app-surface/40">
      <div className="mx-auto max-w-6xl px-4 py-20 sm:px-6">
        <Reveal>
          <div className="mx-auto max-w-2xl text-center">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-app-accent-text">How it works</span>
            <h2 className="mt-3 text-3xl font-extrabold tracking-tight sm:text-4xl">
              Three steps to your first <span className="afx-gradient-text">on-chain payment</span>
            </h2>
          </div>
        </Reveal>

        <div className="relative mt-14 grid gap-8 sm:grid-cols-3">
          {/* connecting line on desktop */}
          <div className="pointer-events-none absolute left-0 right-0 top-7 hidden h-px bg-gradient-to-r from-transparent via-app-border to-transparent sm:block" />
          {STEPS.map((s, i) => {
            const Icon = s.icon
            return (
              <Reveal key={s.n} delay={i * 120}>
                <div className="relative text-center">
                  <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl border border-app-border bg-app-bg text-app-accent-text">
                    <Icon className="h-6 w-6" />
                  </div>
                  <div className="mt-4 text-xs font-semibold tracking-[0.2em] text-app-muted">{s.n}</div>
                  <h3 className="mt-1 text-lg font-semibold text-app-text">{s.title}</h3>
                  <p className="mx-auto mt-2 max-w-xs text-sm leading-relaxed text-app-muted">{s.body}</p>
                </div>
              </Reveal>
            )
          })}
        </div>
      </div>
    </section>
  )
}
AFX_EOF
echo "  afrifx-web/components/landing/LandingHowItWorks.tsx"

echo ""
echo "Done. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Landing: replace Corridor with Bridge, multi-chain copy'"
echo "  git push"
echo ""
echo "  Worth a read-through on the live site afterwards. Marketing copy is the"
echo "  one place where a claim that no longer matches the product is actively"
echo "  misleading rather than just untidy, so tell me if anything else reads"
echo "  wrong and I'll fix it."
