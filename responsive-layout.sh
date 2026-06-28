#!/bin/bash
# ============================================================
# AfriFX — Full responsive layout for all screen sizes
# Run from ~/AfriFX:  bash responsive-layout.sh
# ============================================================
set -e
echo ""
echo "📱  Making AfriFX fully responsive..."
echo ""

# ============================================================
# 1 — App layout: hide sidebar on mobile, show hamburger
# ============================================================
cat > "afrifx-web/app/(app)/layout.tsx" << '__EOF__'
import { TopNav }      from '@/components/layout/TopNav'
import { Sidebar }     from '@/components/layout/Sidebar'
import { MobileNav }   from '@/components/layout/MobileNav'
import { ProfileGuard } from '@/components/profile/ProfileGuard'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen flex-col overflow-hidden bg-[#080D1B]">
      <TopNav />
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar — hidden on mobile, visible md+ */}
        <Sidebar />
        {/* Main content */}
        <main className="flex-1 overflow-y-auto p-4 pb-24 md:p-6 md:pb-6">
          <ProfileGuard>{children}</ProfileGuard>
        </main>
      </div>
      {/* Bottom nav — mobile only */}
      <MobileNav />
    </div>
  )
}
__EOF__
echo "✅  app/(app)/layout.tsx — mobile-aware layout"

# ============================================================
# 2 — Sidebar: hidden on mobile, slide-in drawer on md+
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
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
    <aside className="hidden md:flex md:w-52 md:shrink-0 flex-col overflow-y-auto border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
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
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
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
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
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
__EOF__
echo "✅  Sidebar.tsx — hidden on mobile (md:flex)"

# ============================================================
# 3 — Mobile bottom navigation (visible on mobile only)
# ============================================================
cat > afrifx-web/components/layout/MobileNav.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Store, LayoutDashboard,
  User, Menu,
} from 'lucide-react'
import { useState } from 'react'
import { MobileDrawer } from './MobileDrawer'
import { cn } from '@/lib/utils'

const BOTTOM_NAV = [
  { href: '/convert',     icon: ArrowLeftRight, label: 'Convert'   },
  { href: '/marketplace', icon: Store,          label: 'Market'    },
  { href: '/dashboard',   icon: LayoutDashboard, label: 'Dashboard' },
  { href: '/profile',     icon: User,           label: 'Profile'   },
]

export function MobileNav() {
  const pathname          = usePathname()
  const [drawerOpen, setDrawerOpen] = useState(false)

  return (
    <>
      {/* Bottom tab bar — mobile only */}
      <nav className="md:hidden fixed bottom-0 left-0 right-0 z-40 border-t border-[#1B2B4B] bg-[#080D1B]">
        <div className="flex items-center justify-around px-2 py-2">
          {BOTTOM_NAV.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex flex-col items-center gap-0.5 px-3 py-1.5 rounded-xl transition-colors',
                  active ? 'text-[#378ADD]' : 'text-[#64748B]'
                )}>
                <Icon className={cn('h-5 w-5', active && 'text-[#378ADD]')} />
                <span className="text-[10px] font-medium">{label}</span>
              </Link>
            )
          })}
          {/* More button opens full drawer */}
          <button
            onClick={() => setDrawerOpen(true)}
            className="flex flex-col items-center gap-0.5 px-3 py-1.5 rounded-xl text-[#64748B] transition-colors">
            <Menu className="h-5 w-5" />
            <span className="text-[10px] font-medium">More</span>
          </button>
        </div>
      </nav>

      {/* Full drawer */}
      <MobileDrawer open={drawerOpen} onClose={() => setDrawerOpen(false)} />
    </>
  )
}
__EOF__
echo "✅  MobileNav.tsx — bottom tab bar for mobile"

# ============================================================
# 4 — Mobile full drawer (all nav items)
# ============================================================
cat > afrifx-web/components/layout/MobileDrawer.tsx << '__EOF__'
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
      <div className="md:hidden fixed inset-y-0 left-0 z-50 w-72 overflow-y-auto bg-[#0F1729] shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-[#1B2B4B] px-4 py-4">
          <span className="font-semibold text-[#E2E8F0]">AfriFX</span>
          <button onClick={onClose} className="rounded-lg p-1.5 text-[#64748B] hover:text-[#E2E8F0]">
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Nav items */}
        <div className="py-3">
          {nav.map((section) => (
            <div key={section.label} className="mb-2">
              <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
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
                        ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                        : 'text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0]'
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
              <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
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
        </div>
      </div>
    </>
  )
}
__EOF__
echo "✅  MobileDrawer.tsx — full nav drawer for mobile"

# ============================================================
# 5 — TopNav: responsive (hide network badge on mobile)
# ============================================================
cat > afrifx-web/components/layout/TopNav.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { useAccount, useDisconnect } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { ConnectButton } from '@/components/wallet/ConnectButton'
import { ClientOnly } from '@/components/ui/client-only'

function NavProfile() {
  const { isConnected }  = useAccount()
  const { data: profile } = useProfile()
  const { disconnect }    = useDisconnect()

  if (!isConnected) return <ConnectButton />

  if (profile) {
    return (
      <div className="flex items-center gap-2">
        <Link href="/profile"
          className="flex items-center gap-2 hover:opacity-80 transition-opacity">
          <ProfileAvatar
            displayName={profile.display_name}
            avatarColor={profile.avatar_color}
            size="sm"
            verified={profile.verified}
          />
          {/* Hide name on very small screens */}
          <div className="hidden sm:block text-right">
            <p className="text-xs font-medium text-[#E2E8F0]">{profile.display_name}</p>
            <p className="text-[10px] text-[#378ADD]">@{profile.username}</p>
          </div>
        </Link>
        <button
          onClick={() => disconnect()}
          className="rounded-full border border-[#1B2B4B] px-2 py-1 text-[10px] text-[#64748B] hover:text-[#E2E8F0] transition-colors">
          Disconnect
        </button>
      </div>
    )
  }

  return <ConnectButton />
}

export function TopNav() {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-[#1B2B4B] px-4 md:px-6">
      <Link href="/convert"
        className="flex items-center gap-2 text-[#E2E8F0] font-semibold">
        <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-[#378ADD]/20">
          <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
        </div>
        <span className="text-sm md:text-base">AfriFX</span>
        {/* Hide network badge on mobile */}
        <span className="hidden sm:inline-flex items-center gap-1 rounded-full bg-[#378ADD]/10 px-2 py-0.5 text-[10px] font-medium text-[#378ADD]">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </Link>
      <ClientOnly fallback={
        <div className="h-8 w-24 animate-pulse rounded-full bg-[#1B2B4B]" />
      }>
        <NavProfile />
      </ClientOnly>
    </header>
  )
}
__EOF__
echo "✅  TopNav.tsx — responsive"

# ============================================================
# 6 — Fix grid layouts to be mobile-first across key pages
# ============================================================

# Dashboard: 1 col mobile → 4 col desktop
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/dashboard/page.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    # Stat cards: 2 cols on mobile, 4 on lg
    content = content.replace(
        'className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4"',
        'className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4"'
    )
    # Charts row: 1 col mobile
    content = content.replace(
        'className="mb-4 grid gap-4 lg:grid-cols-3"',
        'className="mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3"'
    )
    # Bottom row: 1 col mobile, 2 col lg
    content = content.replace(
        'className="grid gap-4 lg:grid-cols-2"',
        'className="grid gap-4 grid-cols-1 lg:grid-cols-2"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  dashboard — grid responsive")
else:
    print("⚠️  dashboard page not found")
PYEOF

# Wallet: token grid responsive
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/wallet/WalletContent.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()

    content = content.replace(
        'className="mb-4 grid gap-4 lg:grid-cols-3"',
        'className="mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3"'
    )
    content = content.replace(
        'className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"',
        'className="grid gap-3 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"'
    )
    content = content.replace(
        'className="grid gap-4 lg:grid-cols-2"',
        'className="grid gap-4 grid-cols-1 lg:grid-cols-2"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  wallet — grid responsive")
else:
    print("⚠️  WalletContent not found")
PYEOF

# Treasury: responsive grids
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/treasury/TreasuryContent.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4"',
        'className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4"'
    )
    content = content.replace(
        'className="grid gap-4 lg:grid-cols-2"',
        'className="grid gap-4 grid-cols-1 lg:grid-cols-2"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  treasury — grid responsive")
else:
    print("⚠️  TreasuryContent not found")
PYEOF

# Profile: responsive
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/profile/page.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'className="grid gap-4 lg:grid-cols-3"',
        'className="grid gap-4 grid-cols-1 lg:grid-cols-3"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  profile — grid responsive")
else:
    print("⚠️  profile page not found")
PYEOF

# Admin pages: wrap tables in overflow-x-auto
python3 - << 'PYEOF'
import os, glob

admin_pages = glob.glob(os.path.expanduser('~/AfriFX/afrifx-web/app/admin/**/*.tsx'), recursive=True)
count = 0
for path in admin_pages:
    with open(path) as f:
        content = f.read()
    # Wrap tables in overflow-x-auto
    if '<table' in content and 'overflow-x-auto' not in content:
        content = content.replace(
            '<div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden">',
            '<div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden overflow-x-auto">'
        )
        with open(path, 'w') as f:
            f.write(content)
        count += 1

print(f"✅  {count} admin pages — tables wrapped in overflow-x-auto")
PYEOF

# Settlements: table overflow
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/settlements/page.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden"',
        'className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden overflow-x-auto"'
    )
    # Stats cards responsive
    content = content.replace(
        'className="mb-6 grid grid-cols-3 gap-4"',
        'className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  settlements — responsive + table scroll")
else:
    print("⚠️  settlements page not found")
PYEOF

# Payroll: responsive grid + table
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'className="grid gap-6 lg:grid-cols-3"',
        'className="grid gap-6 grid-cols-1 lg:grid-cols-3"'
    )
    # Recipients grid
    content = content.replace(
        'className="grid grid-cols-12 gap-2 px-1',
        'className="hidden sm:grid grid-cols-12 gap-2 px-1'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  payroll — responsive grid")
else:
    print("⚠️  PayrollCreateContent not found")
PYEOF

# Invoice create: responsive
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/invoices/create/page.tsx')
if os.path.exists(path):
    with open(path) as f:
        content = f.read()
    content = content.replace(
        'className="grid gap-6 lg:grid-cols-3"',
        'className="grid gap-6 grid-cols-1 lg:grid-cols-3"'
    )
    with open(path, 'w') as f:
        f.write(content)
    print("✅  invoice create — responsive")
else:
    print("⚠️  invoice create not found")
PYEOF

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Full responsive layout complete!"
echo ""
echo "  Mobile (< 768px):"
echo "  • Sidebar hidden — replaced by bottom tab bar"
echo "  • 4 tabs: Convert | Market | Dashboard | Profile"
echo "  • 'More' button opens full nav drawer"
echo "  • Drawer slides in with backdrop, closes on nav"
echo "  • All grids stack to 1 column"
echo "  • Tables scroll horizontally"
echo "  • Bottom padding prevents content hiding behind tab bar"
echo ""
echo "  Tablet (768px–1024px):"
echo "  • Sidebar visible (md:flex)"
echo "  • Grids 2-column"
echo ""
echo "  Desktop (1024px+):"
echo "  • Full sidebar + multi-column grids"
echo "  • Unchanged from before"
echo ""
echo "  No restart needed — Next.js hot-reloads"
echo "══════════════════════════════════════════════════════"
