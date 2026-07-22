#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- STAGE 4 of 4: UI + NAV (the bridge goes live)
#
# Adds the Bridge page and reshapes the Exchange nav:
#     Trade  ->  Bridge  ->  Send
#
# NAV CHANGES (deliberately conservative)
#   * 'Convert' RENAMED to 'Trade' -- the LABEL only. The /convert route is
#     untouched, so every existing link, bookmark and the SectionGuard
#     maintenance section keep working. Convert executes real on-chain FX
#     trades; it is your FX product and was worth keeping.
#   * 'Corridor' REMOVED FROM THE NAV, but the /corridor ROUTE IS LEFT ON DISK.
#     Removing a nav link deletes nothing -- restoring it is a one-line change
#     if you change your mind. Verified the route still builds.
#   * Both Sidebar and MobileDrawer updated together, so desktop and mobile
#     can't drift apart.
#
# *** THE UI'S MOST IMPORTANT JOB: BE HONEST ABOUT WHERE THE MONEY IS ***
# Once the burn lands, funds are mid-flight and the mint is owed. So the error
# display branches on inFlight:
#   * failed BEFORE the burn -> RED "Transfer not started ... No funds were
#     moved. You can safely try again."
#   * failed AFTER the burn  -> AMBER "Transfer in progress ... Your funds are
#     burned on X and the mint on Y is still owed. It will be completed
#     automatically -- nothing is lost." Plus a link to the burn tx.
# Showing a burned-but-unminted transfer as a plain red error would make users
# think their money vanished when it hasn't. That distinction is the whole
# point of the failed-vs-stranded work in stage 2.
#
# The progress panel also tells a user mid-attestation that they can safely
# close the page -- true, because destinationCaller is bytes32(0), so anyone
# (including the reconciler) can complete the mint.
#
# Success state links the BURN tx on the source explorer and the MINT tx on the
# destination explorer, so the user can verify both legs themselves.
#
# NOTE: no SectionGuard on /bridge -- the maintenance sections are a fixed
# backend list and 'bridge' isn't one. Adding it would need an API change; say
# the word if you want to be able to take the bridge down independently.
#
# Verified: typechecks clean, builds clean, and /bridge, /convert AND /corridor
# all appear in the route manifest.
#
# Run from ~/AfriFX:  bash bridge-stage4-ui.sh
# ============================================================
set -e
echo ""
echo "Installing bridge UI + nav (stage 4)..."
echo ""

mkdir -p "afrifx-web/components/bridge"
cat > "afrifx-web/components/bridge/BridgeCard.tsx" << 'AFX_EOF'
'use client'
import { useState, useMemo } from 'react'
import { useAccount } from 'wagmi'
import {
  ArrowDown, Loader2, CheckCircle, AlertTriangle, ExternalLink, Info,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useBridge } from '@/hooks/useBridge'
import { cctpChains, chainByKey, isRouteSupported } from '@/lib/cctp-chains'

/*
  Bridge UI for CCTP transfers.

  The single most important job of this component is being HONEST about where
  the money is. Once the burn lands, funds are mid-flight and the mint is owed —
  so the copy at that point must never look like a plain error, or a user will
  think their money is gone when it isn't.
*/
export function BridgeCard() {
  const { address, isConnected } = useAccount()
  const { step, bridgeId, burnTx, mintTx, error, inFlight, bridge, reset, env } = useBridge()

  const chains = cctpChains()
  const [fromKey, setFromKey] = useState('arc')
  const [toKey,   setToKey]   = useState('base')
  const [amount,  setAmount]  = useState('')

  const from = chainByKey(fromKey)
  const to   = chainByKey(toKey)
  const routeOk = isRouteSupported(fromKey, toKey)
  const amt = Number(amount)
  const busy = ['creating','switching','approving','burning','attesting','minting'].includes(step)

  const canSubmit = isConnected && routeOk && amt > 0 && !busy

  function swapDirection() {
    setFromKey(toKey); setToKey(fromKey)
  }

  const stepLabel: Record<string, string> = {
    creating:  'Preparing transfer…',
    switching: `Switch your wallet to ${from?.name ?? 'the source chain'}`,
    approving: 'Approve USDC spending in your wallet',
    burning:   'Confirm the transfer in your wallet',
    attesting: 'Waiting for Circle to attest (usually under a minute)',
    minting:   `Switch to ${to?.name ?? 'the destination'} and confirm the final step`,
  }

  const explorerTx = (chainKey: string, hash: string) => {
    const c = chainByKey(chainKey)
    return c ? `${c.explorer}/tx/${hash}` : '#'
  }

  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-base font-semibold text-app-text">Bridge USDC</h2>
        <span className="rounded-full bg-app-bg px-2 py-0.5 text-[10px] uppercase tracking-wide text-app-muted">
          {env}
        </span>
      </div>

      {/* From */}
      <label className="mb-1 block text-xs text-app-muted">From</label>
      <select
        value={fromKey}
        onChange={e => setFromKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      <div className="my-1 flex justify-center">
        <button
          onClick={swapDirection}
          disabled={busy}
          title="Swap direction"
          className="flex h-8 w-8 items-center justify-center rounded-full border border-app-border bg-app-bg text-app-muted hover:text-app-text disabled:opacity-40"
        >
          <ArrowDown className="h-4 w-4" />
        </button>
      </div>

      {/* To */}
      <label className="mb-1 block text-xs text-app-muted">To</label>
      <select
        value={toKey}
        onChange={e => setToKey(e.target.value)}
        disabled={busy}
        className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}
      </select>

      {/* Amount */}
      <label className="mb-1 block text-xs text-app-muted">Amount (USDC)</label>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-4 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      {!routeOk && fromKey === toKey && (
        <p className="mb-3 text-xs text-amber-400">Source and destination must be different chains.</p>
      )}

      {/* Action */}
      {step === 'done' ? (
        <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">Bridge complete</p>
          <p className="mt-1 text-xs text-emerald-600">
            {amount} USDC arrived on {to?.name}
          </p>
          <div className="mt-3 flex flex-col gap-1 text-[11px]">
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
            {mintTx && (
              <a href={explorerTx(toKey, mintTx)} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center justify-center gap-1 text-app-accent-text hover:underline">
                Mint transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
          <Button size="sm" variant="outline" className="mt-3" onClick={reset}>
            Bridge again
          </Button>
        </div>
      ) : (
        <Button
          className="w-full"
          disabled={!canSubmit}
          onClick={() => bridge({ fromKey, toKey, amount: amt })}
        >
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
                : !isConnected ? 'Connect a wallet'
                : 'Bridge USDC'}
        </Button>
      )}

      {/* Progress */}
      {busy && (
        <div className="mt-3 rounded-lg bg-app-bg p-3">
          <p className="flex items-center gap-2 text-xs text-app-text">
            <Loader2 className="h-3 w-3 animate-spin" />
            {stepLabel[step] ?? 'Working…'}
          </p>
          {inFlight && (
            <p className="mt-1.5 text-[11px] text-app-muted">
              Your USDC has been burned on {from?.name} and will be minted on {to?.name}.
              You can safely close this page — the transfer completes on its own.
            </p>
          )}
        </div>
      )}

      {/* Errors — tone depends ENTIRELY on whether funds already moved */}
      {step === 'error' && error && (
        inFlight ? (
          // Burned but not minted. NOT a loss. Never show this as a plain error.
          <div className="mt-3 rounded-lg border border-amber-700/50 bg-amber-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-amber-400">
              <Info className="h-3.5 w-3.5" /> Transfer in progress
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-amber-200/90">
              {error}
            </p>
            <p className="mt-1.5 text-[11px] text-amber-200/70">
              Your funds are burned on {from?.name} and the mint on {to?.name} is
              still owed. It will be completed automatically — nothing is lost.
            </p>
            {burnTx && (
              <a href={explorerTx(fromKey, burnTx)} target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-[11px] text-amber-400 hover:underline">
                View burn transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        ) : (
          // Failed before the burn: nothing moved, safe to retry.
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertTriangle className="h-3.5 w-3.5" /> Transfer not started
            </p>
            <p className="mt-1 text-[11px] leading-relaxed text-red-300/90">{error}</p>
            <p className="mt-1.5 text-[11px] text-red-300/60">
              No funds were moved. You can safely try again.
            </p>
            <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
          </div>
        )
      )}

      <p className="mt-4 border-t border-app-border pt-3 text-[11px] leading-relaxed text-app-muted">
        Powered by Circle&apos;s CCTP. USDC is burned on the source chain and native
        USDC is minted on the destination — no wrapped tokens, no third-party
        bridge custody. You sign both transactions yourself.
      </p>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/bridge/BridgeCard.tsx"

mkdir -p "afrifx-web/app/(app)/bridge"
cat > "afrifx-web/app/(app)/bridge/page.tsx" << 'AFX_EOF'
import { BridgeCard } from '@/components/bridge/BridgeCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Bridge, AfriFX' }

function BridgeSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 h-5 w-32 animate-pulse rounded bg-app-border" />
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="mb-4 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="h-11 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

/*
  No SectionGuard here on purpose: the maintenance sections are a fixed list
  ('convert' | 'corridor' | 'send' | ...) and 'bridge' isn't one of them.
  Adding a new section would mean a backend change; that can come later if you
  want to be able to take the bridge down independently.
*/
export default function BridgePage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
        <p className="text-sm text-app-muted">
          Move native USDC between Arc and other chains using Circle&apos;s CCTP.
        </p>
      </div>
      <ClientOnly fallback={<BridgeSkeleton />}>
        <BridgeCard />
      </ClientOnly>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/bridge/page.tsx"

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
    { href: '/convert',  icon: ArrowLeftRight, label: 'Trade'    },
    { href: '/bridge',   icon: Globe,          label: 'Bridge'   },
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

mkdir -p "afrifx-web/components/layout"
cat > "afrifx-web/components/layout/MobileDrawer.tsx" << 'AFX_EOF'
'use client'
import { useEffect } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield, FileText, BarChart3,
  CreditCard, X,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsAdmin } from '@/hooks/useIsAdmin'
import { ThemeToggle } from '@/components/layout/ThemeToggle'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',  icon: ArrowLeftRight, label: 'Trade'    },
    { href: '/bridge',   icon: Globe,          label: 'Bridge'   },
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

interface Props {
  open:    boolean
  onClose: () => void
}

export function MobileDrawer({ open, onClose }: Props) {
  const pathname          = usePathname()
  const { data: isAdmin } = useIsAdmin()

  // Close on route change
  useEffect(() => { onClose() }, [pathname])

  // Prevent body scroll when open
  useEffect(() => {
    document.body.style.overflow = open ? 'hidden' : ''
    return () => { document.body.style.overflow = '' }
  }, [open])

  if (!open) return null

  return (
    <>
      {/* Backdrop */}
      <div
        className="md:hidden fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      {/* Drawer panel */}
      <div className="md:hidden fixed inset-y-0 left-0 z-50 w-72 overflow-y-auto bg-app-surface shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-app-border px-4 py-4">
          <span className="font-semibold text-app-text">AfriFX</span>
          <button onClick={onClose} className="rounded-lg p-1.5 text-app-muted hover:text-app-text">
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Nav items */}
        <div className="py-3">
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
                      'flex items-center gap-3 px-4 py-3 text-sm transition-colors',
                      active
                        ? 'bg-app-border font-medium text-app-text'
                        : 'text-app-muted hover:bg-app-bg hover:text-app-text'
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
                  'flex items-center gap-3 px-4 py-3 text-sm transition-colors',
                  pathname.startsWith('/admin')
                    ? 'bg-amber-900/30 font-medium text-amber-400'
                    : 'text-amber-500/70 hover:bg-amber-900/20 hover:text-amber-400'
                )}>
                <Shield className="h-4 w-4 shrink-0" />
                Admin panel
              </Link>
            </div>
          )}

          {/* Appearance */}
          <div className="mt-2 border-t border-app-border pt-3">
            <p className="mb-2 px-4 text-[10px] font-semibold uppercase tracking-widest text-app-muted">
              Appearance
            </p>
            <div className="flex items-center justify-between px-4">
              <span className="text-sm text-app-text">Theme</span>
              <ThemeToggle />
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
AFX_EOF
echo "  afrifx-web/components/layout/MobileDrawer.tsx"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Bridge stage 4: UI and nav'"
echo "  git push"
echo ""
echo "  ============ FIRST REAL TEST -- READ THIS ============"
echo ""
echo "  Bridging burns real USDC. For the FIRST run:"
echo "    1) Use TESTNET (NEXT_PUBLIC_CCTP_ENV is 'testnet' by default)."
echo "    2) Use a TRIVIAL amount -- 0.1 USDC. Not 100."
echo "    3) Try Base Sepolia -> Arc Testnet FIRST (not Arc -> Base), because"
echo "       Base's USDC is a normal ERC-20 with a well-known address, so the"
echo "       approve step is straightforward. Arc's USDC is the native gas"
echo "       token, which is the less standard direction."
echo "    4) Get Base Sepolia USDC from Circle's faucet:"
echo "       https://faucet.circle.com"
echo "    5) WATCH THE FUNDS ARRIVE on the destination before trying more."
echo ""
echo "  If it stalls at 'attesting', that is NOT a loss -- check:"
echo "     curl https://afrifx-api.onrender.com/bridge/meta/unresolved"
echo "  and the Render logs for [Bridge] lines."
echo ""
echo "  Set NEXT_PUBLIC_ARC_USDC to Arc's USDC ERC-20 address before bridging"
echo "  FROM Arc, or the approve step is skipped and the burn may revert."
