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
