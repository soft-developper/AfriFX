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
