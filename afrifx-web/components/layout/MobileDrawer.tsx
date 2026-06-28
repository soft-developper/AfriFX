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
