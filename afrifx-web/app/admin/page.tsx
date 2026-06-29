'use client'
import { useState } from 'react'
import { useAccount, useConnect } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Shield, Wallet, Lock, Loader2,
  CheckCircle, AlertCircle, ArrowRight,
} from 'lucide-react'

const PERMISSION_PAGES = [
  { perm: 'manage_offers',    path: '/admin/offers'     },
  { perm: 'resolve_disputes', path: '/admin/disputes'   },
  { perm: 'manage_users',     path: '/admin/users'      },
  { perm: 'view_analytics',   path: '/admin/analytics'  },
  { perm: 'manage_admins',    path: '/admin/sub-admins' },
  { perm: 'view_audit_log',   path: '/admin/audit'      },
]

function getRedirectPath(role: string, permissions: string[]): string {
  if (role === 'super_admin' || permissions.includes('view_dashboard')) {
    return '/admin/dashboard'
  }
  const first = PERMISSION_PAGES.find(p => permissions.includes(p.perm))
  return first ? first.path : '/admin/no-access'
}

export default function AdminLoginPage() {
  const router                   = useRouter()
  const { address, isConnected } = useAccount()
  const { connect, connectors }  = useConnect()
  const { verifyWallet, login }  = useAdminAuth()

  const [step,       setStep]       = useState<1|2>(1)
  const [walletOk,   setWalletOk]   = useState(false)
  const [checking,   setChecking]   = useState(false)
  const [identifier, setIdentifier] = useState('')
  const [password,   setPassword]   = useState('')
  const [error,      setError]      = useState<string|null>(null)
  const [loggingIn,  setLoggingIn]  = useState(false)

  // NO useEffect — no auto-verify — user must click button
  // This prevents the infinite verify-wallet loop

  async function handleVerifyWallet() {
    if (!address || checking) return
    setChecking(true)
    setError(null)
    try {
      const result = await verifyWallet(address)
      if (result.valid) {
        setWalletOk(true)
        setTimeout(() => setStep(2), 600)
      } else {
        setError(result.error ?? 'This wallet is not authorised for admin access')
      }
    } catch {
      setError('Failed to verify wallet — check your connection')
    } finally {
      setChecking(false)
    }
  }

  async function handleLogin() {
    if (!identifier || !password || loggingIn) return
    setLoggingIn(true)
    setError(null)
    try {
      const result = await login(identifier, password, address)
      if (result.success) {
        const perms: string[] = (result as any).admin?.permissions ?? []
        const role: string    = (result as any).admin?.role ?? ''
        // Use hard navigation — avoids 307 redirect stripping Authorization header
        window.location.href = getRedirectPath(role, perms)
        return
      } else {
        setError((result as any).error ?? 'Login failed')
      }
    } finally {
      setLoggingIn(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
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
                <p className="text-xs text-[#64748B]">Connect then click Verify</p>
              </div>

              {!isConnected ? (
                <div className="space-y-2">
                  {connectors.slice(0, 3).map(c => (
                    <Button key={c.id} className="w-full" variant="outline"
                      onClick={() => connect({ connector: c })}>
                      <Wallet className="h-4 w-4" /> Connect {c.name}
                    </Button>
                  ))}
                </div>
              ) : walletOk ? (
                <div className="flex items-center justify-center gap-2 rounded-lg bg-emerald-900/20 py-3 text-sm text-emerald-400">
                  <CheckCircle className="h-4 w-4" /> Wallet authorised
                </div>
              ) : (
                <div className="rounded-lg bg-[#080D1B] p-4 text-center space-y-3">
                  <p className="font-mono text-xs text-[#378ADD]">
                    {address?.slice(0,10)}…{address?.slice(-8)}
                  </p>
                  <p className="text-xs text-[#64748B]">Connected — click below to verify</p>
                  <Button className="w-full" onClick={handleVerifyWallet} disabled={checking}>
                    {checking
                      ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</>
                      : <>Verify wallet <ArrowRight className="h-3.5 w-3.5" /></>
                    }
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
                <p className="text-sm font-medium text-[#E2E8F0]">Enter credentials</p>
                <p className="text-xs text-[#64748B]">Username or email + password</p>
              </div>
              <div className="space-y-3">
                <Input placeholder="Username or email" autoComplete="off"
                  value={identifier} onChange={e => setIdentifier(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                <Input type="password" placeholder="Password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleLogin()} />
              </div>
              <Button className="w-full" onClick={handleLogin}
                disabled={!identifier || !password || loggingIn}>
                {loggingIn
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Signing in…</>
                  : <><Lock className="h-4 w-4" /> Sign in</>
                }
              </Button>
              <button onClick={() => { setStep(1); setWalletOk(false); setError(null) }}
                className="w-full text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                ← Use different wallet
              </button>
            </div>
          )}

          {error && (
            <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
        </div>

        <p className="mt-4 text-center text-xs text-[#64748B]">
          🔒 Restricted area — all actions are logged
        </p>
      </div>
    </div>
  )
}
