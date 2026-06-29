'use client'
import { useEffect, useRef } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2,
} from 'lucide-react'

const NAV = [
  { href: '/admin/dashboard',  icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'   },
  { href: '/admin/offers',     icon: Store,           label: 'Offers',     perm: 'manage_offers'    },
  { href: '/admin/disputes',   icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes' },
  { href: '/admin/users',      icon: Users,           label: 'Users',      perm: 'manage_users'     },
  { href: '/admin/sub-admins', icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'    },
  { href: '/admin/analytics',  icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'   },
  { href: '/admin/audit',      icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'   },
]

const PERMISSION_PAGES = [
  { perm: 'manage_offers',    path: '/admin/offers'     },
  { perm: 'resolve_disputes', path: '/admin/disputes'   },
  { perm: 'manage_users',     path: '/admin/users'      },
  { perm: 'view_analytics',   path: '/admin/analytics'  },
  { perm: 'manage_admins',    path: '/admin/sub-admins' },
  { perm: 'view_audit_log',   path: '/admin/audit'      },
]

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router        = useRouter()
  const pathname      = usePathname()
  const redirected    = useRef(false)
  const { admin, loading, logout, hasPermission } = useAdminAuth()

  useEffect(() => {
    if (loading) return
    if (redirected.current) return

    // Double-check sessionStorage directly in case module cache missed it
    const tokenInStorage = typeof window !== 'undefined'
      ? sessionStorage.getItem('afrifx_admin_token')
      : null

    // Not logged in → go to login
    if (!admin && !tokenInStorage) {
      redirected.current = true
      router.push('/admin')
      return
    }

    // Token exists but admin not loaded yet — wait
    if (!admin && tokenInStorage) return

    // Super admin → no restrictions
    if (admin.role === 'super_admin') return

    const perms = admin.permissions ?? []

    // Sub-admin on dashboard without permission → redirect to first allowed page
    if (pathname === '/admin/dashboard' && !perms.includes('view_dashboard')) {
      redirected.current = true
      const first = PERMISSION_PAGES.find(p => perms.includes(p.perm))
      router.push(first ? first.path : '/admin/no-access')
      return
    }

    // Sub-admin with no permissions at all → no-access
    if (perms.length === 0) {
      redirected.current = true
      router.push('/admin/no-access')
      return
    }
  }, [loading, admin, pathname, router])

  // Reset redirect flag on pathname change
  useEffect(() => {
    redirected.current = false
  }, [pathname])

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

        <div className="border-t border-[#1B2B4B] p-3 space-y-2">
          <div className="rounded-lg bg-[#080D1B] px-3 py-2">
            <p className="text-xs font-medium text-[#E2E8F0]">{admin.username}</p>
            <p className="text-[10px] text-[#378ADD]">
              {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
            </p>
          </div>
          <Link href="/dashboard"
            className="flex items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0] transition-colors">
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

      <main className="flex-1 overflow-y-auto p-6">
        {children}
      </main>
    </div>
  )
}
