'use client'
import { useEffect, useState } from 'react'
import { DutyBanner } from '@/components/admin/DutyBanner'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { useTheme } from '@/hooks/useTheme'
import { ThemeToggle } from '@/components/layout/ThemeToggle'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2, Settings,
  Menu, X, Sun, Moon, FileText, Mail, Megaphone, Wrench } from 'lucide-react'

// Full-width labeled theme toggle for the admin sidebar footer
function ThemeToggleRow() {
  const { theme, source, toggle } = useTheme()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  if (!mounted) {
    return <div className="h-9 rounded-lg border border-app-border" />
  }
  const isDark = theme === 'dark'
  return (
    <button onClick={toggle}
      className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
      {isDark ? <Moon className="h-3.5 w-3.5 shrink-0" /> : <Sun className="h-3.5 w-3.5 shrink-0" />}
      {isDark ? 'Dark mode' : 'Light mode'}
      {source === 'auto' && <span className="ml-auto text-[9px] text-app-accent-text">AUTO</span>}
    </button>
  )
}

const NAV = [
  { href: '/admin/dashboard',  icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'   },
  { href: '/admin/offers',     icon: Store,           label: 'Offers',     perm: 'manage_offers'    },
  { href: '/admin/disputes',   icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes' },
  { href: '/admin/users',      icon: Users,           label: 'Users',      perm: 'manage_users'     },
  { href: '/admin/sub-admins', icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'    },
  { href: '/admin/content',    icon: FileText,        label: 'Site content', perm: 'manage_content' },
  { href: '/admin/messages',   icon: Mail,            label: 'Messages',   perm: 'view_messages'    },
  { href: '/admin/broadcasts', icon: Megaphone,       label: 'Broadcasts', perm: 'send_broadcasts'  },
  // Maintenance is SUPER ADMIN ONLY -- taking the platform offline is too
  // dangerous to delegate, so it is not a grantable permission at all.
  { href: '/admin/maintenance', icon: Wrench,         label: 'Maintenance', perm: 'manage_admins', superOnly: true },
  { href: '/admin/analytics',  icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'   },
  { href: '/admin/audit',      icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'   },
]

function SidebarContent({
  admin, pathname, visibleNav, onLogout, onNavigate,
}: {
  admin:      { username: string; role: string }
  pathname:   string
  visibleNav: typeof NAV
  onLogout:   () => void
  onNavigate?: () => void
}) {
  return (
    <>
      <nav className="flex-1 overflow-y-auto py-3">
        {visibleNav.map(({ href, icon: Icon, label }) => {
          const active = pathname === href
          return (
            <Link key={href} href={href} onClick={onNavigate}
              className={`flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors
                ${active
                  ? 'bg-app-border font-medium text-app-text'
                  : 'text-app-muted hover:bg-app-bg hover:text-app-text'}`}>
              <Icon className="h-4 w-4 shrink-0" /> {label}
            </Link>
          )
        })}
      </nav>
      <div className="shrink-0 border-t border-app-border p-3 space-y-2">
        <div className="rounded-lg bg-app-bg px-3 py-2">
          <p className="text-xs font-medium text-app-text">{admin.username}</p>
          <p className="text-[10px] text-app-accent-text">
            {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
          </p>
        </div>
        <Link href="/admin/settings" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <Settings className="h-3.5 w-3.5 shrink-0" />
          Settings
        </Link>
        <Link href="/dashboard" onClick={onNavigate}
          className="flex items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-app-text transition-colors">
          <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
          Main dashboard
        </Link>
        <button onClick={onLogout}
          className="flex w-full items-center gap-2 rounded-lg border border-app-border px-3 py-2 text-xs text-app-muted hover:bg-app-bg hover:text-red-400 transition-colors">
          <LogOut className="h-3.5 w-3.5 shrink-0" />
          Logout
        </button>
        <ThemeToggleRow />
      </div>
    </>
  )
}

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router   = useRouter()
  const pathname = usePathname()
  const { admin, loading, logout, hasPermission } = useAdminAuth()
  const [drawerOpen, setDrawerOpen] = useState(false)

  useEffect(() => {
    if (!loading && !admin) router.push('/admin')
  }, [loading, admin, router])

  // Close the mobile drawer on route change
  useEffect(() => { setDrawerOpen(false) }, [pathname])

  // Lock body scroll while the mobile drawer is open
  useEffect(() => {
    document.body.style.overflow = drawerOpen ? 'hidden' : ''
    return () => { document.body.style.overflow = '' }
  }, [drawerOpen])

  if (loading) return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!admin) return null

  // Sub-admin landing on dashboard without permission
  // → redirect to their first permitted page
  if (
    typeof window !== 'undefined' &&
    admin.role !== 'super_admin' &&
    !admin.permissions.includes('view_dashboard') &&
    window.location.pathname === '/admin/dashboard'
  ) {
    const PAGES = [
      { perm: 'manage_offers',    path: '/admin/offers'     },
      { perm: 'resolve_disputes', path: '/admin/disputes'   },
      { perm: 'manage_users',     path: '/admin/users'      },
      { perm: 'view_analytics',   path: '/admin/analytics'  },
      { perm: 'manage_admins',    path: '/admin/sub-admins' },
      { perm: 'view_audit_log',   path: '/admin/audit'      },
    ]
    const first = PAGES.find(p => admin.permissions.includes(p.perm))
    if (first) { window.location.replace(first.path); return null }
  }

  const visibleNav = NAV.filter(item =>
    (item as any).superOnly
      ? admin.role === 'super_admin'
      : hasPermission(item.perm))

  async function handleLogout() {
    setDrawerOpen(false)
    await logout()
    router.push('/admin')
  }

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg md:flex-row">
      {/* Mobile top bar — hidden md+ */}
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-app-border bg-app-surface px-4 md:hidden">
        <div className="flex items-center gap-2">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <button onClick={() => setDrawerOpen(true)}
            className="rounded-lg p-1.5 text-app-muted hover:bg-app-bg hover:text-app-text"
            aria-label="Open admin menu">
            <Menu className="h-5 w-5" />
          </button>
        </div>
      </header>

      {/* Mobile drawer — hidden md+ */}
      {drawerOpen && (
        <div className="md:hidden">
          <div
            className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
            onClick={() => setDrawerOpen(false)}
          />
          <div className="fixed inset-y-0 left-0 z-50 flex w-72 flex-col bg-app-surface shadow-2xl">
            <div className="flex shrink-0 items-center justify-between border-b border-app-border px-4 py-4">
              <div className="flex items-center gap-2">
                <Shield className="h-5 w-5 text-app-accent-text" />
                <span className="font-semibold text-app-text">AfriFX Admin</span>
              </div>
              <button onClick={() => setDrawerOpen(false)}
                className="rounded-lg p-1.5 text-app-muted hover:text-app-text"
                aria-label="Close admin menu">
                <X className="h-5 w-5" />
              </button>
            </div>
            <SidebarContent
              admin={admin} pathname={pathname} visibleNav={visibleNav}
              onLogout={handleLogout} onNavigate={() => setDrawerOpen(false)}
            />
          </div>
        </div>
      )}

      {/* Desktop sidebar — hidden on mobile */}
      <aside className="hidden md:flex md:w-56 md:shrink-0 flex-col border-r border-app-border bg-app-surface">
        <div className="flex items-center gap-2 border-b border-app-border px-4 py-4">
          <Shield className="h-5 w-5 text-app-accent-text" />
          <span className="font-semibold text-app-text">AfriFX Admin</span>
        </div>
        <SidebarContent
          admin={admin} pathname={pathname} visibleNav={visibleNav}
          onLogout={handleLogout}
        />
      </aside>

      <main className="flex-1 overflow-y-auto p-4 md:p-6">
        {/* Duty banner shows on EVERY admin page — a dispute-only sub-admin may
            never land on /admin/dashboard (they lack view_dashboard and get
            redirected), so the Resume duty control has to live in the shell. */}
        <DutyBanner />
        {children}
      </main>
    </div>
  )
}
