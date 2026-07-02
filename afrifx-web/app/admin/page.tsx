'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Shield, Lock, Mail, User, Loader2, AlertCircle,
  KeyRound, ArrowLeft,
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
  if (role === 'super_admin' || permissions.includes('view_dashboard') || permissions.includes('all')) {
    return '/admin/dashboard'
  }
  const first = PERMISSION_PAGES.find(p => permissions.includes(p.perm))
  return first ? first.path : '/admin/no-access'
}

type Mode = 'checking' | 'setup' | 'login'

export default function AdminLoginPage() {
  const router = useRouter()
  const { checkSetupStatus, setup, login, forgotPassword } = useAdminAuth()

  const [mode, setMode] = useState<Mode>('checking')

  // Setup fields
  const [setupUsername, setSetupUsername] = useState('')
  const [setupEmail,    setSetupEmail]    = useState('')
  const [setupPassword, setSetupPassword] = useState('')
  const [setupConfirm,  setSetupConfirm]  = useState('')

  // Login fields
  const [email,    setEmail]    = useState('')
  const [password, setPassword] = useState('')
  const [totpCode, setTotpCode] = useState('')
  const [needs2FA, setNeeds2FA] = useState(false)

  // Forgot password
  const [showForgot,   setShowForgot]   = useState(false)
  const [forgotEmail,  setForgotEmail]  = useState('')
  const [forgotSent,   setForgotSent]   = useState(false)

  const [error,   setError]   = useState<string | null>(null)
  const [busy,    setBusy]    = useState(false)

  useEffect(() => {
    checkSetupStatus()
      .then(needsSetup => setMode(needsSetup ? 'setup' : 'login'))
      .catch(() => setMode('login'))
  }, [])

  async function handleSetup() {
    setError(null)
    if (!setupUsername || !setupEmail || !setupPassword) {
      setError('All fields are required'); return
    }
    if (setupPassword !== setupConfirm) {
      setError('Passwords do not match'); return
    }
    setBusy(true)
    try {
      const result = await setup(setupEmail, setupPassword, setupUsername)
      if (result.success) {
        router.push('/admin/settings?onboarding=2fa')
      } else {
        setError((result as any).error ?? 'Setup failed')
      }
    } finally { setBusy(false) }
  }

  async function handleLogin() {
    setError(null)
    if (!email || !password) { setError('Email and password are required'); return }
    if (needs2FA && !totpCode) { setError('Enter your 6-digit authenticator code'); return }

    setBusy(true)
    try {
      const result = await login(email, password, needs2FA ? totpCode : undefined)
      if (result.success && result.admin) {
        router.push(getRedirectPath(result.admin.role, result.admin.permissions))
      } else if ((result as any).needs2FA) {
        setNeeds2FA(true)
      } else {
        setError((result as any).error ?? 'Login failed')
      }
    } finally { setBusy(false) }
  }

  async function handleForgot() {
    setError(null)
    if (!forgotEmail) { setError('Enter your email'); return }
    setBusy(true)
    try {
      const result = await forgotPassword(forgotEmail)
      if (result.success) setForgotSent(true)
      else setError((result as any).error ?? 'Request failed')
    } finally { setBusy(false) }
  }

  if (mode === 'checking') {
    return (
      <div className="flex min-h-screen items-center justify-center bg-app-bg">
        <Loader2 className="h-6 w-6 animate-spin text-app-accent" />
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-app-accent/10">
            <Shield className="h-7 w-7 text-app-accent" />
          </div>
          <h1 className="text-2xl font-bold text-app-text">AfriFX Admin</h1>
          <p className="text-sm text-app-muted">
            {mode === 'setup' ? 'Create the super admin account' : 'Sign in to continue'}
          </p>
        </div>

        <div className="rounded-2xl border border-app-border bg-app-surface p-6">
          {mode === 'setup' && (
            <div className="space-y-3">
              <div className="text-center mb-2">
                <p className="text-sm font-medium text-app-text">First-time setup</p>
                <p className="text-xs text-app-muted">No admin account exists yet — create the super admin</p>
              </div>
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" placeholder="Username" autoComplete="off"
                  value={setupUsername} onChange={e => setSetupUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                  value={setupEmail} onChange={e => setSetupEmail(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={setupPassword} onChange={e => setSetupPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={setupConfirm} onChange={e => setSetupConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleSetup()} />
              </div>
              <p className="text-[11px] text-app-muted leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleSetup} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating account…</>
                      : <>Create super admin</>}
              </Button>
            </div>
          )}

          {mode === 'login' && !showForgot && (
            <div className="space-y-3">
              {!needs2FA ? (
                <>
                  <div className="text-center mb-2">
                    <Lock className="mx-auto mb-2 h-8 w-8 text-app-accent" />
                    <p className="text-sm font-medium text-app-text">Enter credentials</p>
                  </div>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                    <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                      value={email} onChange={e => setEmail(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <div className="relative">
                    <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                    <Input className="pl-9" type="password" placeholder="Password" autoComplete="current-password"
                      value={password} onChange={e => setPassword(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <Button className="w-full" onClick={handleLogin} disabled={!email || !password || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Signing in…</>
                          : <><Lock className="h-4 w-4" /> Sign in</>}
                  </Button>
                  <button onClick={() => { setShowForgot(true); setError(null) }}
                    className="w-full text-xs text-app-muted hover:text-app-text transition-colors">
                    Forgot password?
                  </button>
                </>
              ) : (
                <>
                  <div className="text-center mb-2">
                    <KeyRound className="mx-auto mb-2 h-8 w-8 text-app-accent" />
                    <p className="text-sm font-medium text-app-text">Two-factor authentication</p>
                    <p className="text-xs text-app-muted">Enter the 6-digit code from your authenticator app</p>
                  </div>
                  <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
                    maxLength={6} inputMode="numeric" autoFocus
                    value={totpCode} onChange={e => setTotpCode(e.target.value.replace(/\D/g, ''))}
                    onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  <Button className="w-full" onClick={handleLogin} disabled={totpCode.length !== 6 || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & sign in</>}
                  </Button>
                  <button onClick={() => { setNeeds2FA(false); setTotpCode(''); setError(null) }}
                    className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text transition-colors">
                    <ArrowLeft className="h-3 w-3" /> Back
                  </button>
                </>
              )}
            </div>
          )}

          {mode === 'login' && showForgot && (
            <div className="space-y-3">
              {!forgotSent ? (
                <>
                  <div className="text-center mb-2">
                    <Mail className="mx-auto mb-2 h-8 w-8 text-app-accent" />
                    <p className="text-sm font-medium text-app-text">Reset your password</p>
                    <p className="text-xs text-app-muted">We'll email you a reset link</p>
                  </div>
                  <Input type="email" placeholder="Your admin email" autoComplete="off"
                    value={forgotEmail} onChange={e => setForgotEmail(e.target.value)}
                    onKeyDown={e => e.key === 'Enter' && handleForgot()} />
                  <Button className="w-full" onClick={handleForgot} disabled={!forgotEmail || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : <>Send reset link</>}
                  </Button>
                </>
              ) : (
                <div className="rounded-lg bg-emerald-900/20 px-3 py-4 text-center text-sm text-emerald-400">
                  If that email is registered, a reset link is on its way. Check your inbox.
                </div>
              )}
              <button onClick={() => { setShowForgot(false); setForgotSent(false); setError(null) }}
                className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text transition-colors">
                <ArrowLeft className="h-3 w-3" /> Back to sign in
              </button>
            </div>
          )}

          {error && (
            <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
        </div>
        <p className="mt-4 text-center text-xs text-app-muted">🔒 Restricted area — all actions are logged</p>
      </div>
    </div>
  )
}
