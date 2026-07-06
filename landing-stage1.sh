#!/bin/bash
# ============================================================
# AfriFX -- Landing page STAGE 1 (hero + branded header) + app upgrades
#
# This is the FIRST of two stages. It sets up:
#   * A public landing page at "/" (was: redirect to /convert) -- liqdx-style
#     hero with a big headline, "Launch app" CTA (opens the app in a NEW TAB),
#     a live-rates strip, and a footer with About/Contact. Feature sections
#     for each app capability come in STAGE 2 (after you review this look).
#   * A branded AfriFX wordmark (hexagon mark + colorful gold gradient on the
#     name) used in the app header, landing, and About/Contact chrome --
#     replacing the old plain icon+text header.
#   * App default page is now DASHBOARD, not Convert (post-connect and
#     post-profile-setup now route to /dashboard).
#   * About/Contact links removed from inside the app (they now live on the
#     landing); the About/Contact pages themselves stay, with updated chrome.
#
# Run from ~/AfriFX:  bash landing-stage1.sh
# ============================================================
set -e
echo ""
echo "Applying landing page stage 1 + header/brand upgrade..."
echo ""

mkdir -p "afrifx-web/styles"
cat > "afrifx-web/styles/globals.css" << 'AFX_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

/*
  Semantic color tokens as "R G B" channel triples so Tailwind can apply
  opacity modifiers, e.g. bg-app-accent/10.

  :root defines the DARK theme (warm espresso + gold). html.light overrides
  them with the LIGHT theme (warm ivory + deeper bronze). Every component
  reads these variables, so switching themes is purely a variable swap.

  Extra accent tokens keep text readable in BOTH themes:
    --app-accent        gold fill (buttons, bars, active states)
    --app-accent-hover  hover state for accent fills
    --app-accent-text   the accent used as READING text (links/labels);
                        deeper in light mode so it stays legible on ivory
    --app-on-accent     text/icons that sit ON a gold fill (dark in dark
                        mode, white in light mode) — replaces raw text-white
*/
:root {
  --app-bg:           18 16 11;    /* #12100B */
  --app-surface:      28 24 16;    /* #1C1810 */
  --app-border:       51 41 27;    /* #33291B */
  --app-accent:       217 164 65;  /* #D9A441 */
  --app-accent-hover: 196 143 46;  /* #C48F2E */
  --app-accent-text:  217 164 65;  /* #D9A441 — bright gold reads well on dark */
  --app-on-accent:    18 16 11;    /* #12100B — dark text on gold fill */
  --app-text:         242 233 216; /* #F2E9D8 */
  --app-muted:        156 138 110; /* #9C8A6E */

  /* Legacy aliases (kept for any direct var() consumers) */
  --bg:      #12100B;
  --card:    #1C1810;
  --border:  #33291B;
  --accent:  #D9A441;
  --success: #5BAE7B;
  --danger:  #D9694A;
  --muted:   #9C8A6E;
  --text:    #F2E9D8;
}

html.light {
  --app-bg:           247 241 230; /* #F7F1E6 — warm ivory */
  --app-surface:      255 253 248; /* #FFFDF8 — near-white warm surface */
  --app-border:       228 217 196; /* #E4D9C4 — soft sand */
  --app-accent:       138 94 19;   /* #8A5E13 — deep bronze, readable as fill+text on ivory */
  --app-accent-hover: 110 74 15;   /* #6E4A0F */
  --app-accent-text:  138 94 19;   /* #8A5E13 — passes AA (5.06:1) for link/label text */
  --app-on-accent:    255 255 255; /* #FFFFFF — white text on bronze fill */
  --app-text:         43 36 22;    /* #2B2416 — warm near-black */
  --app-muted:        107 95 73;   /* #6B5F49 — warm gray-brown, passes AA (5.56:1) */

  --bg:      #F7F1E6;
  --card:    #FFFDF8;
  --border:  #E4D9C4;
  --accent:  #8A5E13;
  --success: #2E7D53;
  --danger:  #C0492E;
  --muted:   #6B5F49;
  --text:    #2B2416;
}

* { box-sizing: border-box; }

/* Smooth the dark <-> light transition (kept subtle; excludes transforms) */
body, [class*="bg-app-"], [class*="border-app-"], [class*="text-app-"] {
  transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease;
}

body {
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

input[type='number']::-webkit-outer-spin-button,
input[type='number']::-webkit-inner-spin-button {
  -webkit-appearance: none;
  margin: 0;
}

/*
  Light-mode semantic color fixes.

  The status colors (emerald/amber/red at the -400/-500 shades) are tuned for
  the dark theme and wash out on the light ivory background — a light green on
  near-white has almost no contrast. Under html.light we remap these specific
  text utilities to darker shades that pass WCAG AA on ivory, without touching
  the dark theme. Badge FILLS are handled separately via the `light:` variant
  in components/ui/badge.tsx.

  !important is required to win over Tailwind's own utility classes.
*/
.light .text-emerald-400,
.light .text-emerald-500 { color: #047857 !important; } /* emerald-700 — 4.88:1 on ivory */
.light .text-amber-400,
.light .text-amber-500  { color: #92400e !important; } /* amber-800 — passes on ivory */
.light .text-red-400,
.light .text-red-500    { color: #b91c1c !important; } /* red-700 — 5.76:1 on ivory */

/*
  Brand wordmark gradients (AfriFXLogo). "Afri" uses the warm gold-bronze
  gradient; "FX" uses a brighter gold so the pair reads with a colorful accent
  without leaving the brand palette. Works in both themes.
*/
.afx-gradient-text {
  background: linear-gradient(120deg, #EAC15C 0%, #D9A441 45%, #B9822A 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  color: transparent;
}
.afx-gradient-text-bright {
  background: linear-gradient(120deg, #F5D77E 0%, #E9B84E 60%, #D9A441 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  color: transparent;
}
.light .afx-gradient-text {
  background: linear-gradient(120deg, #B9822A 0%, #8A5E13 60%, #6E4A0F 100%);
  -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent; color: transparent;
}
.light .afx-gradient-text-bright {
  background: linear-gradient(120deg, #C48F2E 0%, #A9741B 60%, #8A5E13 100%);
  -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent; color: transparent;
}
AFX_EOF
echo "  afrifx-web/styles/globals.css"

mkdir -p "afrifx-web/components/brand"
cat > "afrifx-web/components/brand/AfriFXLogo.tsx" << 'AFX_EOF'
import Link from 'next/link'

/*
  AfriFX brand lockup: the hexagon "A×" mark + a colorful gradient wordmark.
  Used in the app header and the landing page. The gradient gives the name the
  "colorful" treatment while staying on-brand (warm gold -> amber -> bronze).

  Sizes: sm (header), lg (landing hero).
*/
export function AfriFXLogo({
  size = 'sm',
  href = '/',
  showMark = true,
}: { size?: 'sm' | 'md' | 'lg'; href?: string; showMark?: boolean }) {
  const dims = {
    sm: { mark: 30, text: 'text-xl',  sub: 'text-[9px]' },
    md: { mark: 40, text: 'text-2xl', sub: 'text-[10px]' },
    lg: { mark: 64, text: 'text-5xl sm:text-6xl', sub: 'text-xs' },
  }[size]

  const inner = (
    <span className="inline-flex items-center gap-2.5">
      {showMark && (
        <svg width={dims.mark} height={dims.mark} viewBox="0 0 120 124" fill="none" className="shrink-0">
          <defs>
            <linearGradient id="afx-mark-g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stopColor="#EAC15C" />
              <stop offset="1" stopColor="#B9822A" />
            </linearGradient>
          </defs>
          <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="url(#afx-mark-g)" strokeWidth="7" strokeLinejoin="round" />
          <g fill="none" stroke="currentColor" strokeWidth="8" strokeLinecap="round" strokeLinejoin="round" className="text-app-text">
            <path d="M36 88 L52 40 L68 88" /><path d="M43 70 L61 70" />
          </g>
          <g fill="none" stroke="url(#afx-mark-g)" strokeWidth="8" strokeLinecap="round">
            <path d="M74 52 L96 84" /><path d="M96 52 L74 84" />
          </g>
        </svg>
      )}
      <span className="flex flex-col leading-none">
        <span className={`font-extrabold tracking-tight ${dims.text}`}>
          <span className="afx-gradient-text">Afri</span>
          <span className="afx-gradient-text-bright">FX</span>
        </span>
        {size === 'lg' && (
          <span className={`mt-1 font-medium uppercase tracking-[0.2em] text-app-muted ${dims.sub}`}>
            Stablecoin FX on Arc
          </span>
        )}
      </span>
    </span>
  )

  if (href) return <Link href={href} className="inline-flex">{inner}</Link>
  return inner
}
AFX_EOF
echo "  afrifx-web/components/brand/AfriFXLogo.tsx"

mkdir -p "afrifx-web/components/landing"
cat > "afrifx-web/components/landing/LandingRates.tsx" << 'AFX_EOF'
'use client'
import { useFXRates } from '@/hooks/useFXRate'
import { TrendingUp, TrendingDown } from 'lucide-react'

const FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬', EURC: '🇪🇺',
}

export function LandingRates() {
  const { data: rates, isLoading } = useFXRates()

  return (
    <div className="rounded-2xl border border-app-border bg-app-surface/60 p-4 backdrop-blur">
      <div className="mb-3 flex items-center justify-between px-1">
        <span className="text-xs font-medium uppercase tracking-wider text-app-muted">Live rates</span>
        <span className="flex items-center gap-1.5 text-xs text-app-muted">
          <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" /> Updating
        </span>
      </div>

      {isLoading || !rates ? (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="h-14 animate-pulse rounded-xl bg-app-border/50" />
          ))}
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {rates.slice(0, 6).map((r) => {
            const ccy = r.pair.split('/')[0]
            const up = (r.change24h ?? 0) >= 0
            return (
              <div key={r.pair} className="flex items-center justify-between rounded-xl bg-app-bg/60 px-3 py-2.5">
                <span className="flex items-center gap-2">
                  <span className="text-lg leading-none">{FLAG[ccy] ?? '💱'}</span>
                  <span className="text-sm font-medium text-app-text">{r.pair}</span>
                </span>
                <span className="text-right">
                  <span className="block font-mono text-sm text-app-text">
                    {r.rate.toLocaleString(undefined, { maximumFractionDigits: 3 })}
                  </span>
                  <span className={`flex items-center justify-end gap-0.5 text-[10px] ${up ? 'text-emerald-400' : 'text-red-400'}`}>
                    {up ? <TrendingUp className="h-2.5 w-2.5" /> : <TrendingDown className="h-2.5 w-2.5" />}
                    {Math.abs(r.change24h ?? 0).toFixed(2)}%
                  </span>
                </span>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/landing/LandingRates.tsx"

mkdir -p "afrifx-web/app"
cat > "afrifx-web/app/page.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { ArrowUpRight } from 'lucide-react'
import { LandingRates } from '@/components/landing/LandingRates'

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

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/TopNav.tsx" << 'AFX_EOF'
'use client'
import Link              from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { ConnectButton }  from '@rainbow-me/rainbowkit'
import { useAccount }     from 'wagmi'
import { useProfile }     from '@/hooks/useProfile'
import { ProfileAvatar }  from '@/components/profile/ProfileAvatar'
import { ClientOnly }     from '@/components/ui/client-only'
import { NotificationBell } from '@/components/notifications/NotificationBell'
import { ThemeToggle }     from '@/components/layout/ThemeToggle'
import { AfriFXLogo }      from '@/components/brand/AfriFXLogo'

// Custom ConnectButton that shows our profile avatar when connected
function NavProfile() {
  const { isConnected }   = useAccount()
  const { data: profile } = useProfile()

  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        mounted,
      }) => {
        const ready = mounted
        if (!ready) return (
          <div className="h-8 w-24 animate-pulse rounded-full bg-app-border" />
        )

        if (!account) {
          return (
            <button onClick={openConnectModal}
              className="rounded-xl bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-opacity hover:opacity-90">
              Connect wallet
            </button>
          )
        }

        if (chain?.unsupported) {
          return (
            <button onClick={openChainModal}
              className="rounded-xl bg-red-500/20 px-4 py-2 text-sm font-medium text-red-400 transition-opacity hover:opacity-90">
              Wrong network
            </button>
          )
        }

        return (
          <div className="flex items-center gap-2">
            {/* Profile avatar → opens RainbowKit account modal (has copy address) */}
            <button onClick={openAccountModal}
              className="flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-2.5 py-1.5 transition-colors hover:bg-app-border">
              {profile ? (
                <>
                  <ProfileAvatar
                    displayName={profile.display_name}
                    avatarColor={profile.avatar_color}
                    size="xs"
                    verified={profile.verified}
                  />
                  <div className="hidden sm:block text-left">
                    <p className="text-xs font-medium text-app-text leading-none">
                      {profile.display_name}
                    </p>
                    <p className="text-[10px] text-app-accent-text leading-none mt-0.5">
                      @{profile.username}
                    </p>
                  </div>
                </>
              ) : (
                <>
                  {/* No profile yet — show shortened address */}
                  <div className="h-5 w-5 rounded-full bg-app-accent/30 flex items-center justify-center">
                    <span className="text-[8px] font-bold text-app-accent-text">
                      {account.address.slice(2,4).toUpperCase()}
                    </span>
                  </div>
                  <span className="hidden sm:block font-mono text-xs text-app-text">
                    {account.displayName}
                  </span>
                </>
              )}
              {/* Balance badge */}
              {account.displayBalance && (
                <span className="hidden md:block rounded-lg bg-app-border px-2 py-0.5 font-mono text-[10px] text-app-muted">
                  {account.displayBalance}
                </span>
              )}
            </button>
          </div>
        )
      }}
    </ConnectButton.Custom>
  )
}

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
          <NavProfile />
        </div>
      </ClientOnly>
    </header>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/TopNav.tsx"

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/Sidebar.tsx" << 'AFX_EOF'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield, FileText, BarChart3,
  CreditCard,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsAdmin } from '@/hooks/useIsAdmin'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',  icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor', icon: Globe,          label: 'Corridor' },
    { href: '/send',     icon: Send,           label: 'Send'     },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Payments', items: [
    { href: '/invoices',    icon: FileText,  label: 'Invoices'    },
    { href: '/settlements', icon: BarChart3, label: 'Settlements' },
  ]},
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2,  label: 'Treasury' },
    { href: '/treasury/payroll', icon: CreditCard, label: 'Payroll'  },
  ]},
  { label: 'Account', items: [
    { href: '/wallet',    icon: Wallet,          label: 'Wallet'    },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname          = usePathname()
  const { data: isAdmin } = useIsAdmin()

  return (
    // Hidden on mobile (md:flex), visible on desktop
    <aside className="hidden md:flex md:w-52 md:shrink-0 flex-col overflow-y-auto border-r border-app-border py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-app-border font-medium text-app-text'
                    : 'text-app-muted hover:bg-app-surface hover:text-app-text'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}

      {isAdmin && (
        <div className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
            Admin
          </p>
          <Link href="/admin"
            className={cn(
              'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
              pathname.startsWith('/admin')
                ? 'bg-amber-900/30 font-medium text-amber-400'
                : 'text-amber-500/70 hover:bg-amber-900/20 hover:text-amber-400'
            )}>
            <Shield className="h-4 w-4 shrink-0" />
            Admin panel
          </Link>
        </div>
      )}
    </aside>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/Sidebar.tsx"

mkdir -p "afrifx-web/components/public"
cat > "afrifx-web/components/public/PublicChrome.tsx" << 'AFX_EOF'
import Link from 'next/link'
import { ArrowUpRight } from 'lucide-react'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'

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

mkdir -p "afrifx-web/app/(auth)/connect"
cat > "afrifx-web/app/(auth)/connect/page.tsx" << 'AFX_EOF'
'use client'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useEffect } from 'react'
import { ArrowLeftRight, Zap, Shield, Globe } from 'lucide-react'
import { ConnectButton } from '@/components/wallet/ConnectButton'

const features = [
  { icon: Zap,           title: 'Sub-second settlement', desc: 'Arc finalises transactions in under 1 second.' },
  { icon: Shield,        title: 'USDC-native',           desc: 'Gas fees paid in USDC — no volatile ETH needed.' },
  { icon: Globe,         title: 'Pan-African corridors', desc: 'NGN, GHS, KES, ZAR and more coming soon.' },
]

export default function ConnectPage() {
  const { isConnected } = useAccount()
  const router = useRouter()

  useEffect(() => {
    if (isConnected) router.push('/dashboard')
  }, [isConnected, router])

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-app-accent/20">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-app-text">AfriFX</h1>
          <p className="text-xs text-app-muted">Stablecoin FX on Arc</p>
        </div>
      </div>

      <div className="mb-8 w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6">
        <h2 className="mb-1 text-base font-semibold text-app-text">Connect your wallet</h2>
        <p className="mb-5 text-xs text-app-muted">
          Connect to Arc Testnet (Chain ID 5042002) to start converting currencies instantly.
        </p>
        <ConnectButton />
      </div>

      <div className="grid w-full max-w-sm gap-3">
        {features.map(({ icon: Icon, title, desc }) => (
          <div key={title} className="flex gap-3 rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-app-accent/10">
              <Icon className="h-3.5 w-3.5 text-app-accent-text" />
            </div>
            <div>
              <p className="text-sm font-medium text-app-text">{title}</p>
              <p className="text-xs text-app-muted">{desc}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(auth)/connect/page.tsx"

mkdir -p "afrifx-web/app/(auth)/profile/setup"
cat > "afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { getAvatarColor } from '@/lib/avatar'
import { checkUsername } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeftRight, CheckCircle, XCircle,
  Loader2, Sparkles, Twitter, AtSign,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ProfileSetupClient() {
  const { address, isConnected } = useAccount()
  const router      = useRouter()
  const queryClient = useQueryClient()

  const [username,    setUsername]    = useState('')
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [step,        setStep]        = useState(1)

  const [usernameState, setUsernameState] = useState<'idle'|'checking'|'available'|'taken'|'invalid'>('idle')
  const [usernameError, setUsernameError] = useState('')
  const [submitting,    setSubmitting]    = useState(false)
  const [submitError,   setSubmitError]   = useState('')

  const avatarColor = username ? getAvatarColor(username) : '#D9A441'

  useEffect(() => {
    if (!username) { setUsernameState('idle'); return }
    if (username.length < 3)  { setUsernameState('invalid'); setUsernameError('Min 3 characters'); return }
    if (username.length > 20) { setUsernameState('invalid'); setUsernameError('Max 20 characters'); return }
    if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      setUsernameState('invalid'); setUsernameError('Letters, numbers, underscores only'); return
    }
    setUsernameState('checking')
    const t = setTimeout(async () => {
      const result = await checkUsername(username)
      if (result.error) { setUsernameState('invalid'); setUsernameError(result.error) }
      else if (result.available) { setUsernameState('available'); setUsernameError('') }
      else { setUsernameState('taken'); setUsernameError('This username is taken') }
    }, 500)
    return () => clearTimeout(t)
  }, [username])

  async function handleSubmit() {
    if (!address || usernameState !== 'available' || !displayName.trim()) return
    setSubmitting(true); setSubmitError('')
    try {
      const res = await fetch(`${API}/profile`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress:  address,
          username,
          displayName:    displayName.trim(),
          bio:            bio.trim() || null,
          twitterHandle:  twitter.trim() || null,
          telegramHandle: telegram.trim() || null,
          showSocials,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setSubmitError(data.error ?? 'Failed'); return }

      // ── KEY FIX: write profile directly into cache ──────────
      // This means ProfileGuard sees the profile IMMEDIATELY
      // when the router navigates — no refetch race condition.
      const now = Math.floor(Date.now() / 1000)
      queryClient.setQueryData(['profile', address], {
        wallet_address:  address.toLowerCase(),
        username:        username.toLowerCase(),
        display_name:    displayName.trim(),
        bio:             bio.trim() || null,
        twitter_handle:  twitter.trim() || null,
        telegram_handle: telegram.trim() || null,
        avatar_color:    data.avatarColor ?? avatarColor,
        trade_count:     0,
        dispute_count:   0,
        verified:        false,
        show_socials:    showSocials,
        created_at:      now,
        updated_at:      now,
        maker_trades:    0,
        taker_trades:    0,
      })
      // ─────────────────────────────────────────────────────────

      setStep(3)
    } catch (e: any) {
      setSubmitError(e.message)
    } finally {
      setSubmitting(false)
    }
  }

  if (!isConnected) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet first.</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <div className="mb-8 flex items-center gap-2">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/20">
          <ArrowLeftRight className="h-5 w-5 text-app-accent-text" />
        </div>
        <span className="text-xl font-semibold text-app-text">AfriFX</span>
      </div>

      {step === 3 && (
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex justify-center">
            <ProfileAvatar displayName={displayName} avatarColor={avatarColor} size="xl" />
          </div>
          <h1 className="mb-2 text-2xl font-semibold text-app-text">Welcome, {displayName}!</h1>
          <p className="mb-2 text-sm text-app-muted">
            Your profile <span className="text-app-accent-text">@{username}</span> is ready.
          </p>
          <p className="mb-8 text-xs text-app-muted">
            You can update your profile anytime from the sidebar.
          </p>
          <Button className="w-full" size="lg" onClick={() => router.push('/dashboard')}>
            <Sparkles className="h-4 w-4" /> Enter AfriFX
          </Button>
        </div>
      )}

      {step < 3 && (
        <div className="w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-2xl font-semibold text-app-text">Create your profile</h1>
            <p className="mt-1 text-sm text-app-muted">Your identity on AfriFX. Username is permanent.</p>
          </div>

          <div className="mb-8 flex items-center gap-2">
            {[1,2].map((s) => (
              <div key={s} className="flex items-center gap-2">
                <div className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold
                  ${step >= s ? 'bg-app-accent text-app-on-accent' : 'bg-app-border text-app-muted'}`}>
                  {step > s ? '✓' : s}
                </div>
                <span className={`text-xs ${step >= s ? 'text-app-text' : 'text-app-muted'}`}>
                  {s === 1 ? 'Identity' : 'Socials'}
                </span>
                {s < 2 && <div className="h-px w-8 bg-app-border" />}
              </div>
            ))}
          </div>

          {step === 1 && (
            <div className="space-y-4">
              <div className="flex items-center gap-4 rounded-xl border border-app-border bg-app-surface p-4">
                <ProfileAvatar displayName={displayName || username || 'A'} avatarColor={avatarColor} size="lg" />
                <div>
                  <p className="text-sm font-medium text-app-text">{displayName || 'Your name'}</p>
                  <p className="text-xs text-app-muted">{username ? `@${username}` : '@username'}</p>
                </div>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Username <span className="text-red-400">*</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={username}
                    onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g,''))}
                    placeholder="yourname" className="pl-7 font-mono" maxLength={20} />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2">
                    {usernameState === 'checking'  && <Loader2 className="h-4 w-4 animate-spin text-app-muted" />}
                    {usernameState === 'available' && <CheckCircle className="h-4 w-4 text-emerald-400" />}
                    {(usernameState === 'taken' || usernameState === 'invalid') && <XCircle className="h-4 w-4 text-red-400" />}
                  </span>
                </div>
                {usernameState === 'available' && <p className="mt-1 text-xs text-emerald-400">@{username} is available!</p>}
                {usernameError && <p className="mt-1 text-xs text-red-400">{usernameError}</p>}
                <p className="mt-1 text-[10px] text-app-muted">3–20 chars · letters, numbers, underscores · permanent</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Display name <span className="text-red-400">*</span>
                </label>
                <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="Your full name" maxLength={40} />
                <p className="mt-1 text-[10px] text-app-muted">Shown instead of your wallet address everywhere</p>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                  Bio <span className="font-normal normal-case text-app-muted">(optional)</span>
                </label>
                <textarea value={bio} onChange={(e) => setBio(e.target.value)}
                  placeholder="Tell others about yourself…" maxLength={160} rows={3}
                  className="w-full rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent resize-none" />
                <p className="mt-1 text-right text-[10px] text-app-muted">{bio.length}/160</p>
              </div>

              <Button className="w-full" size="lg" onClick={() => setStep(2)}
                disabled={usernameState !== 'available' || !displayName.trim()}>
                Next — Add socials
              </Button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <p className="text-xs text-app-muted">
                Connect your socials so traders can verify and trust you. All optional.
              </p>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <Twitter className="h-3.5 w-3.5" /> Twitter / X
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={twitter} onChange={(e) => setTwitter(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-app-muted">
                  <AtSign className="h-3.5 w-3.5" /> Telegram
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-app-muted">@</span>
                  <Input value={telegram} onChange={(e) => setTelegram(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div className="flex items-center justify-between rounded-lg border border-app-border bg-app-surface p-3">
                <div>
                  <p className="text-sm font-medium text-app-text">Show socials publicly</p>
                  <p className="text-xs text-app-muted">Others can see your Twitter and Telegram</p>
                </div>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-6 w-11 rounded-full transition-colors ${showSocials ? 'bg-app-accent' : 'bg-app-border'}`}>
                  <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-5' : 'translate-x-0.5'}`} />
                </button>
              </div>

              {submitError && <p className="text-xs text-red-400">{submitError}</p>}

              <div className="flex gap-2">
                <Button variant="outline" className="flex-1" onClick={() => setStep(1)}>Back</Button>
                <Button className="flex-1" size="lg" onClick={handleSubmit} disabled={submitting}>
                  {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</> : 'Create profile'}
                </Button>
              </div>
              <button onClick={handleSubmit} disabled={submitting}
                className="w-full text-xs text-app-muted hover:text-app-text transition-colors">
                Skip socials →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx"

mkdir -p "afrifx-web/public/brand"
cat > "afrifx-web/public/brand/afrifx-mark.svg" << 'AFX_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 124" width="120" height="124">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#EAC15C"/><stop offset="1" stop-color="#C48F2E"/></linearGradient></defs>
  <rect x="0" y="0" width="120" height="124" rx="26" fill="#12100B"/>
  <g transform="translate(0,2)">
  <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="url(#g)" stroke-width="7" stroke-linejoin="round"/>
  <g fill="none" stroke="#F2E9D8" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"><path d="M36 88 L52 40 L68 88"/><path d="M43 70 L61 70"/></g>
  <g fill="none" stroke="url(#g)" stroke-width="8" stroke-linecap="round"><path d="M74 52 L96 84"/><path d="M96 52 L74 84"/></g>
  </g>
</svg>
AFX_EOF
echo "  afrifx-web/public/brand/afrifx-mark.svg"

mkdir -p "afrifx-web/public/brand"
cat > "afrifx-web/public/brand/afrifx-mark-coin.svg" << 'AFX_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E9B84E"/><stop offset="1" stop-color="#B9822A"/></linearGradient></defs>
  <rect x="0" y="0" width="100" height="100" rx="26" fill="#12100B"/>
  <circle cx="50" cy="48" r="34" fill="none" stroke="url(#g)" stroke-width="7"/>
  <path d="M28 60 C 42 32, 58 66, 74 36" fill="none" stroke="#F2E9D8" stroke-width="5" stroke-linecap="round"/>
  <circle cx="28" cy="60" r="6" fill="#E9B84E"/><circle cx="74" cy="36" r="6" fill="#E9B84E" stroke="#12100B" stroke-width="2"/>
</svg>
AFX_EOF
echo "  afrifx-web/public/brand/afrifx-mark-coin.svg"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Landing stage 1: hero + branded header, app default -> dashboard'"
echo "  git push"
echo ""
echo "  Review the deployed site:"
echo "    /            -> new landing (hero, live rates, Launch app opens app in new tab)"
echo "    app header   -> colorful AfriFX wordmark + hexagon mark"
echo "    launch app   -> opens /dashboard in a new tab"
echo ""
echo "  When you're happy with the look, tell me and I'll build STAGE 2:"
echo "  the feature sections (Convert, Corridor, Send, Marketplace, Invoices,"
echo "  Treasury/Payroll, Wallet, Profile) with overviews + use cases."
