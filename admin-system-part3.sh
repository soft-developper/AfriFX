#!/bin/bash
# ============================================================
# AfriFX — Admin System Part 3: Frontend UI
# Run from ~/AfriFX:  bash admin-system-part3.sh
# (Run part1 + part2 FIRST)
# ============================================================
set -e
echo ""
echo "🔐  Building Admin System — Part 3 (Frontend)..."
echo ""

mkdir -p afrifx-web/app/admin
mkdir -p afrifx-web/components/admin
mkdir -p afrifx-web/hooks

# ============================================================
# 1 — useAdminAuth hook (session management)
# ============================================================
cat > afrifx-web/hooks/useAdminAuth.ts << '__EOF__'
'use client'
import { useState, useEffect, useCallback } from 'react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const TOKEN_KEY = 'afrifx_admin_token'

export interface AdminSession {
  id:          string
  username:    string
  email:       string
  role:        string
  permissions: string[]
}

export function useAdminAuth() {
  const [admin,   setAdmin]   = useState<AdminSession | null>(null)
  const [loading, setLoading] = useState(true)

  // Token stored in memory + sessionStorage (cleared on tab close)
  const getToken = () => typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  const verifySession = useCallback(async () => {
    const token = getToken()
    if (!token) { setLoading(false); return }
    try {
      const res = await fetch(`${API}/admin/auth/me`, {
        headers: { Authorization: `Bearer ${token}` },
      })
      if (res.ok) {
        const data = await res.json()
        setAdmin(data.admin)
      } else {
        sessionStorage.removeItem(TOKEN_KEY)
      }
    } catch {
      sessionStorage.removeItem(TOKEN_KEY)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { verifySession() }, [verifySession])

  // Step 1: verify wallet is admin
  async function verifyWallet(wallet: string) {
    const res = await fetch(`${API}/admin/auth/verify-wallet`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ wallet }),
    })
    return res.json()
  }

  // Step 2: login with credentials
  async function login(identifier: string, password: string, wallet?: string) {
    const res = await fetch(`${API}/admin/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier, password, wallet }),
    })
    const data = await res.json()
    if (res.ok && data.token) {
      sessionStorage.setItem(TOKEN_KEY, data.token)
      setAdmin(data.admin)
      return { success: true }
    }
    return { success: false, error: data.error ?? 'Login failed' }
  }

  async function logout() {
    const token = getToken()
    if (token) {
      await fetch(`${API}/admin/auth/logout`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    sessionStorage.removeItem(TOKEN_KEY)
    setAdmin(null)
  }

  function hasPermission(perm: string): boolean {
    if (!admin) return false
    if (admin.role === 'super_admin') return true
    return admin.permissions.includes(perm)
  }

  return { admin, loading, verifyWallet, login, logout, hasPermission, getToken }
}

// Authenticated fetch helper
export function adminFetch(path: string, options: RequestInit = {}) {
  const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
  return fetch(`${API}${path}`, {
    ...options,
    headers: {
      ...options.headers,
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
  })
}
__EOF__
echo "✅  hooks/useAdminAuth.ts"

# ============================================================
# 2 — Admin login page (two-step: wallet → credentials)
# ============================================================
cat > afrifx-web/app/admin/page.tsx << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useAccount, useConnect } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Shield, Wallet, Lock, Loader2,
  CheckCircle, AlertCircle, ArrowRight,
} from 'lucide-react'

export default function AdminLoginPage() {
  const router                       = useRouter()
  const { address, isConnected }     = useAccount()
  const { connect, connectors }      = useConnect()
  const { admin, loading, verifyWallet, login } = useAdminAuth()

  const [step,        setStep]        = useState<1|2>(1)
  const [walletOk,    setWalletOk]    = useState(false)
  const [checking,    setChecking]    = useState(false)
  const [identifier,  setIdentifier]  = useState('')
  const [password,    setPassword]    = useState('')
  const [error,       setError]       = useState<string|null>(null)
  const [loggingIn,   setLoggingIn]   = useState(false)

  // Already logged in → go to dashboard
  useEffect(() => {
    if (admin) router.push('/admin/dashboard')
  }, [admin, router])

  // Auto-verify wallet when connected
  useEffect(() => {
    if (isConnected && address && step === 1) {
      handleVerifyWallet()
    }
  }, [isConnected, address])

  async function handleVerifyWallet() {
    if (!address) return
    setChecking(true)
    setError(null)
    try {
      const result = await verifyWallet(address)
      if (result.valid) {
        setWalletOk(true)
        setTimeout(() => setStep(2), 800)
      } else {
        setError(result.error ?? 'This wallet is not authorised for admin access')
      }
    } catch {
      setError('Failed to verify wallet')
    } finally {
      setChecking(false)
    }
  }

  async function handleLogin() {
    if (!identifier || !password) return
    setLoggingIn(true)
    setError(null)
    const result = await login(identifier, password, address)
    if (result.success) {
      router.push('/admin/dashboard')
    } else {
      setError(result.error ?? 'Login failed')
      setLoggingIn(false)
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#080D1B]">
        <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
        {/* Logo */}
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#378ADD]/10">
            <Shield className="h-7 w-7 text-[#378ADD]" />
          </div>
          <h1 className="text-2xl font-bold text-[#E2E8F0]">AfriFX Admin</h1>
          <p className="text-sm text-[#64748B]">Secure two-factor access</p>
        </div>

        {/* Step indicator */}
        <div className="mb-6 flex items-center justify-center gap-2">
          <div className={`flex items-center gap-2 ${step >= 1 ? 'text-[#378ADD]' : 'text-[#64748B]'}`}>
            <div className={`flex h-7 w-7 items-center justify-center rounded-full text-xs font-bold
              ${walletOk ? 'bg-emerald-500 text-white' : step === 1 ? 'bg-[#378ADD] text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
              {walletOk ? '✓' : '1'}
            </div>
            <span className="text-xs">Wallet</span>
          </div>
          <div className="h-px w-8 bg-[#1B2B4B]" />
          <div className={`flex items-center gap-2 ${step >= 2 ? 'text-[#378ADD]' : 'text-[#64748B]'}`}>
            <div className={`flex h-7 w-7 items-center justify-center rounded-full text-xs font-bold
              ${step === 2 ? 'bg-[#378ADD] text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
              2
            </div>
            <span className="text-xs">Credentials</span>
          </div>
        </div>

        <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          {/* Step 1: Wallet */}
          {step === 1 && (
            <div className="space-y-4">
              <div className="text-center">
                <Wallet className="mx-auto mb-2 h-8 w-8 text-[#378ADD]" />
                <p className="text-sm font-medium text-[#E2E8F0]">Connect admin wallet</p>
                <p className="text-xs text-[#64748B]">
                  Your wallet must be registered for admin access
                </p>
              </div>

              {!isConnected ? (
                <div className="space-y-2">
                  {connectors.map(c => (
                    <Button key={c.id} className="w-full" onClick={() => connect({ connector: c })}>
                      <Wallet className="h-4 w-4" /> Connect {c.name}
                    </Button>
                  ))}
                </div>
              ) : checking ? (
                <div className="flex items-center justify-center gap-2 rounded-lg bg-[#080D1B] py-3 text-sm text-[#64748B]">
                  <Loader2 className="h-4 w-4 animate-spin" /> Verifying wallet…
                </div>
              ) : walletOk ? (
                <div className="flex items-center justify-center gap-2 rounded-lg bg-emerald-900/20 py-3 text-sm text-emerald-400">
                  <CheckCircle className="h-4 w-4" /> Wallet authorised
                </div>
              ) : (
                <div className="rounded-lg bg-[#080D1B] p-3 text-center">
                  <p className="font-mono text-xs text-[#64748B]">{address?.slice(0,10)}…{address?.slice(-8)}</p>
                  <Button size="sm" className="mt-2" onClick={handleVerifyWallet}>
                    Verify wallet <ArrowRight className="h-3.5 w-3.5" />
                  </Button>
                </div>
              )}
            </div>
          )}

          {/* Step 2: Credentials */}
          {step === 2 && (
            <div className="space-y-4">
              <div className="text-center">
                <Lock className="mx-auto mb-2 h-8 w-8 text-[#378ADD]" />
                <p className="text-sm font-medium text-[#E2E8F0]">Enter your credentials</p>
                <p className="text-xs text-[#64748B]">Username or email + password</p>
              </div>

              <div className="space-y-3">
                <Input
                  placeholder="Username or email"
                  value={identifier}
                  onChange={e => setIdentifier(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleLogin()}
                />
                <Input
                  type="password"
                  placeholder="Password"
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleLogin()}
                />
              </div>

              <Button className="w-full" onClick={handleLogin}
                disabled={!identifier || !password || loggingIn}>
                {loggingIn
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Signing in…</>
                  : <><Lock className="h-4 w-4" /> Sign in</>
                }
              </Button>
            </div>
          )}

          {/* Error */}
          {error && (
            <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
        </div>

        <p className="mt-4 text-center text-xs text-[#64748B]">
          🔒 This is a restricted area. All actions are logged.
        </p>
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/admin/page.tsx — two-step login"

# ============================================================
# 3 — Admin layout + sidebar (permission-gated nav)
# ============================================================
cat > afrifx-web/components/admin/AdminShell.tsx << '__EOF__'
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

        {/* Admin info + logout */}
        <div className="border-t border-[#1B2B4B] p-3">
          <div className="mb-2 rounded-lg bg-[#080D1B] px-3 py-2">
            <p className="text-xs font-medium text-[#E2E8F0]">{admin.username}</p>
            <p className="text-[10px] text-[#378ADD]">
              {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
            </p>
          </div>
          <Button variant="outline" size="sm" className="w-full" onClick={handleLogout}>
            <LogOut className="h-3.5 w-3.5" /> Logout
          </Button>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-y-auto p-6">
        {children}
      </main>
    </div>
  )
}
__EOF__
echo "✅  components/admin/AdminShell.tsx"

# ============================================================
# 4 — Admin dashboard (overview)
# ============================================================
mkdir -p afrifx-web/app/admin/dashboard
cat > afrifx-web/app/admin/dashboard/page.tsx << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from 'recharts'
import {
  TrendingUp, DollarSign, Store, AlertTriangle,
  Users, UserPlus, Loader2,
} from 'lucide-react'

export default function AdminDashboard() {
  const [data, setData]       = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/overview')
      .then(r => r.json())
      .then(setData)
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">Platform Overview</h1>

      {loading ? (
        <div className="flex h-64 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
        </div>
      ) : (
        <>
          {/* Stat cards */}
          <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
            {[
              { label: 'Total volume',  value: `$${(data?.totalVolume ?? 0).toLocaleString()}`, icon: TrendingUp, color: 'text-[#378ADD]' },
              { label: 'Fees collected',value: `$${(data?.totalFees ?? 0).toLocaleString()}`,   icon: DollarSign, color: 'text-emerald-400' },
              { label: 'Total users',   value: String(data?.totalUsers ?? 0),                   icon: Users,      color: 'text-[#378ADD]' },
              { label: 'New this week', value: `+${data?.newUsersWeek ?? 0}`,                    icon: UserPlus,   color: 'text-emerald-400' },
            ].map(({ label, value, icon: Icon, color }) => (
              <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
                <div className="mb-2 flex items-center justify-between">
                  <p className="text-xs text-[#64748B]">{label}</p>
                  <Icon className={`h-4 w-4 ${color}`} />
                </div>
                <p className="font-mono text-2xl font-bold text-[#E2E8F0]">{value}</p>
              </div>
            ))}
          </div>

          {/* P2P + disputes row */}
          <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-5">
            {[
              { label: 'Open offers',    value: data?.p2p.open      ?? 0, color: 'text-amber-400'   },
              { label: 'Active trades',  value: data?.p2p.accepted  ?? 0, color: 'text-[#378ADD]'   },
              { label: 'Completed',      value: data?.p2p.released  ?? 0, color: 'text-emerald-400' },
              { label: 'Cancelled',      value: data?.p2p.cancelled ?? 0, color: 'text-[#64748B]'   },
              { label: 'Open disputes',  value: data?.openDisputes  ?? 0, color: 'text-red-400'     },
            ].map(({ label, value, color }) => (
              <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-center">
                <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
                <p className="mt-1 text-xs text-[#64748B]">{label}</p>
              </div>
            ))}
          </div>

          {/* Volume chart */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Platform volume (14 days)</p>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={data?.chartData ?? []} barSize={20}>
                <XAxis dataKey="label" tick={{ fill: '#64748B', fontSize: 10 }} axisLine={{ stroke: '#1B2B4B' }} tickLine={false} />
                <YAxis tick={{ fill: '#64748B', fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={v => `$${v}`} />
                <Tooltip
                  contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: '#E2E8F0' }} itemStyle={{ color: '#E2E8F0' }}
                  cursor={{ fill: '#1B2B4B' }}
                  formatter={(v: number) => [`$${v.toLocaleString()}`, 'Volume']}
                />
                <Bar dataKey="volume" radius={[4,4,0,0]}>
                  {(data?.chartData ?? []).map((e: any, i: number) => (
                    <Cell key={i} fill={e.volume > 0 ? '#378ADD' : '#1B2B4B'} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </>
      )}
    </AdminShell>
  )
}
__EOF__
echo "✅  app/admin/dashboard/page.tsx"

echo ""
echo "  Building remaining admin pages..."

# Continue in part 3b due to size
echo "✅  Part 3a done — login, shell, dashboard"
echo ""
echo "  Run admin-system-part3b.sh next for:"
echo "  offers, disputes, users, sub-admins, analytics, audit pages"
