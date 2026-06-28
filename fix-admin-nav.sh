#!/bin/bash
# Run from ~/AfriFX:  bash fix-admin-nav.sh
set -e
echo "🔧  Adding admin link to sidebar for admin wallet..."

cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAccount } from 'wagmi'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield,
} from 'lucide-react'
import { cn } from '@/lib/utils'

const ADMIN_WALLET = process.env.NEXT_PUBLIC_ADMIN_WALLET?.toLowerCase()

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
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2, label: 'Treasury' },
    { href: '/treasury/payroll', icon: Send,      label: 'Payroll'  },
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
  const pathname   = usePathname()
  const { address } = useAccount()
  const isAdmin    = !!ADMIN_WALLET && address?.toLowerCase() === ADMIN_WALLET

  return (
    <aside className="w-52 shrink-0 overflow-y-auto border-r border-[#1B2B4B] py-4">
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

      {/* Admin link — only visible to admin wallet */}
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
echo "✅  Sidebar.tsx — admin link added (visible to admin wallet only)"

# Add NEXT_PUBLIC_ADMIN_WALLET to frontend .env.local
if ! grep -q "NEXT_PUBLIC_ADMIN_WALLET" afrifx-web/.env.local 2>/dev/null; then
  echo "" >> afrifx-web/.env.local
  echo "# Admin wallet — shows admin link in sidebar for this address only" >> afrifx-web/.env.local
  echo "NEXT_PUBLIC_ADMIN_WALLET=0xfAB99Fe25EDB59317A06db5B831b6B8fE0a7E879" >> afrifx-web/.env.local
  echo "✅  .env.local — NEXT_PUBLIC_ADMIN_WALLET added"
else
  echo "✅  NEXT_PUBLIC_ADMIN_WALLET already in .env.local"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Admin sidebar link added!"
echo ""
echo "  The 'Admin panel' link appears in the sidebar ONLY"
echo "  when the connected wallet matches NEXT_PUBLIC_ADMIN_WALLET"
echo "  All other wallets never see it."
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
