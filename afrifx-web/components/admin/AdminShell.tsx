'use client'
import { useEffect } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2,
} from 'lucide-react'

const NAV = [
  { href: '/admin/dashboard', icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'  },
  { href: '/admin/offers',    icon: Store,           label: 'Offers',     perm: 'manage_offers'   },
  { href: '/admin/disputes',  icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes'},
  { href: '/admin/users',     icon: Users,           label: 'Users',      perm: 'manage_users'    },
  { href: '/admin/sub-admins',icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'   },
  { href: '/admin/analytics', icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'  },
  { href: '/admin/audit',     icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'  },
]

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router   = useRouter()
  const pathname = usePathname()
  const pathname = usePathname()
  const { admin, loading, logout, hasPermission } = useAdminAuth()

  useEffect(() => {
    if (!loading && !admin) router.push('/admin')
  }, [loading, admin, router])

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#080D1B]">
        <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
      </div>
    )
  }

  if (!admin) return null

  const visibleNav = NAV.filter(item => hasPermission(item.perm))

  async function handleLogout() {
    await logout()
    router.push('/admin')
  }

  return (
    <div className="flex min-h-screen bg-[#080D1B]">
      {/* Sidebar */}
      <aside className="flex w-56 shrink-0 flex-col border-r border-[#1B2B4B] bg-[#0F1729]">
        <div className="flex items-center gap-2 border-b border-[#1B2B4B] px-4 py-4">
          <Shield className="h-5 w-5 text-[#378ADD]" />
          <span className="font-semibold text-[#E2E8F0]">AfriFX Admin</span>
        </div>

        <nav className="flex-1 py-3">
          {visibleNav.map(({ href, icon: Icon, label }) => {
            const active = pathname === href
            return (
              <Link key={href} href={href}
                className={`flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors
                  ${active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0]'}`}>
                <Icon className="h-4 w-4" /> {label}
              </Link>
            )
          })}
        </nav>

        {/* Admin info + actions */}
        <div className="border-t border-[#1B2B4B] p-3 space-y-2">
          <div className="rounded-lg bg-[#080D1B] px-3 py-2">
            <p className="text-xs font-medium text-[#E2E8F0]">{admin.username}</p>
            <p className="text-[10px] text-[#378ADD]">
              {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
            </p>
          </div>
          <Link href="/dashboard" className="flex items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0] transition-colors">
            <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
            Main dashboard
          </Link>
          <button onClick={handleLogout}
            className="flex w-full items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-red-400 transition-colors">
            <LogOut className="h-3.5 w-3.5 shrink-0" />
            Logout
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-y-auto p-6">
        {children}
      </main>
    </div>
  )
}
