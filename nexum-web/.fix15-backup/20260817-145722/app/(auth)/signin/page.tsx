'use client'

import { useState, useEffect, useCallback, Suspense } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import { ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft, ShieldCheck } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, useAuth, type Account } from '@/hooks/useAuth'
import { provisionWallet } from '@/hooks/useWalletProvisioning'
import { saveSigningSession } from '@/hooks/useCircleTx'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'choose' | 'email' | 'sent'

/** Google's multicolour glyph, inline so it needs no asset. */
function GoogleGlyph() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92a8.78 8.78 0 0 0 2.68-6.62z"/>
      <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.83.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.33A9 9 0 0 0 9 18z"/>
      <path fill="#FBBC05" d="M3.97 10.72a5.4 5.4 0 0 1 0-3.44V4.95H.96a9 9 0 0 0 0 8.1z"/>
      <path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58A8.99 8.99 0 0 0 .96 4.95l3.01 2.33C4.68 5.16 6.66 3.58 9 3.58z"/>
    </svg>
  )
}

/**
 * The single door into the app.
 *
 * There is no separate sign-up. You pick a sign-in method; if it's your
 * first time we make the account, create your wallet, and send you on to
 * choose a username. If you've been here before you land on the
 * dashboard. Nothing is asked for up front.
 */
function SignInInner() {
  const router = useRouter()
  const returnTo = useSearchParams().get('returnTo') || '/dashboard'
  const { account, loading } = useAuth()

  // Already signed in (e.g. opened /signin from a bookmark, or bounced
  // here by the guard after the session was restored): don't ask again.
  useEffect(() => {
    if (!loading && account) router.replace(returnTo)
  }, [loading, account, router])

  const reason = useSearchParams().get('reason')

  const [stage, setStage] = useState<Stage>('choose')
  const [email, setEmail] = useState('')
  const [busy,  setBusy]  = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const enter = useCallback(async (
    userToken: string, encryptionKey: string,
    social?: { email?: string; name?: string },
  ) => {
    setBusy('Signing you in')
    try {
      const res = await fetch(`${API}/auth/session`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          userToken,
          email: social?.email ?? email.trim() ?? undefined,
          name:  social?.name,
        }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) { setError(data.error ?? 'Could not sign you in'); setBusy(null); return }

      persistSession(data.token, data.account as Account)
      saveSigningSession(userToken, encryptionKey)
      clearAuthCookies()

      if (data.needsWallet) {
        try {
          await provisionWallet(userToken, encryptionKey, setBusy)
        } catch (e: any) {
          setError(`${e?.message ?? 'Wallet setup did not finish'} You are signed in, so you can retry.`)
          setBusy(null)
          return
        }
      }

      router.push(returnTo)
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [email, router])

  useEffect(() => {
    if (!circleConfigured()) {
      setError('Sign-in is not configured yet. Set NEXT_PUBLIC_CIRCLE_APP_ID.')
      return
    }
    let cancelled = false

    getSdk((err, result) => {
      if (cancelled) return
      if (err || !result) {
        setBusy(null)
        setError('Sign-in was cancelled or failed. Try again.')
        return
      }
      void enter(result.userToken, result.encryptionKey, { email: result.email, name: result.name })
    }).catch(() => setError('Could not load sign-in. Refresh and try again.'))

    return () => { cancelled = true }
  }, [enter])

  async function onGoogle() {
    setError(null); setBusy('Opening Google')
    try { await startGoogleLogin('signin') }
    catch (e: any) { setError(e?.message ?? 'Could not start Google sign-in'); setBusy(null) }
  }

  async function onSendCode() {
    setError(null); setBusy('Sending your code')
    try { await sendEmailCode(email.trim()); setStage('sent') }
    catch (e: any) { setError(e?.message ?? 'Could not send the code') }
    finally { setBusy(null) }
  }

  return (
    <div className="relative flex min-h-screen flex-col items-center justify-center overflow-hidden px-4 py-10">
      {/* Ambient warm glow — the one flourish, kept subtle. */}
      <div aria-hidden className="pointer-events-none absolute left-1/2 top-24 h-72 w-72 -translate-x-1/2 rounded-full bg-app-accent/10 blur-3xl" />

      <div className="relative z-10 mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl border border-app-accent/30 bg-app-accent/15">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-app-text">Nexum</h1>
          <p className="text-xs text-app-muted">Dollars that move like messages</p>
        </div>
      </div>

      <div className="relative z-10 w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-7 shadow-xl shadow-black/20">
        <h2 className="mb-1.5 text-lg font-semibold text-app-text">Sign in</h2>
        <p className="mb-6 text-[13px] leading-relaxed text-app-muted">
          New here? Signing in creates your account. No wallet or seed phrase needed.
        </p>

        {reason === 'idle' && !error && (
          <div className="mb-4 flex items-start gap-2 rounded-xl border border-app-accent/30 bg-app-accent/10 px-3 py-2.5 text-xs text-app-accent-text">
            <ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>You were signed out after a period of inactivity. Sign in to continue.</span>
          </div>
        )}

        {error && (
          <div className="mb-4 flex items-start gap-2 rounded-xl border border-red-900/40 bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {busy && (
          <div className="mb-4 flex items-center gap-2 rounded-xl bg-app-bg px-3 py-2.5 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> {busy}…
          </div>
        )}

        {stage === 'choose' && (
          <div className="space-y-2.5">
            <button onClick={onGoogle} disabled={Boolean(busy)}
              className="flex h-12 w-full items-center justify-center gap-2.5 rounded-xl border border-app-border bg-app-bg text-sm font-medium text-app-text transition-all hover:border-app-accent/40 hover:bg-app-surface disabled:pointer-events-none disabled:opacity-50">
              <GoogleGlyph /> Continue with Google
            </button>
            <button onClick={() => { setStage('email'); setError(null) }} disabled={Boolean(busy)}
              className="flex h-12 w-full items-center justify-center gap-2.5 rounded-xl border border-app-border bg-app-bg text-sm font-medium text-app-text transition-all hover:border-app-accent/40 hover:bg-app-surface disabled:pointer-events-none disabled:opacity-50">
              <Mail className="h-4 w-4 text-app-muted" /> Continue with email
            </button>
          </div>
        )}

        {stage === 'email' && (
          <div className="space-y-3">
            <div>
              <label htmlFor="email" className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-app-muted">
                Email address
              </label>
              <Input id="email" type="email" autoFocus autoComplete="email"
                placeholder="you@example.com"
                value={email} onChange={e => setEmail(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && email.trim()) void onSendCode() }} />
            </div>
            <Button className="w-full" size="lg" onClick={onSendCode}
              disabled={!email.trim() || Boolean(busy)}>
              Send me a code
            </Button>
            <button onClick={() => { setStage('choose'); setError(null) }}
              className="flex w-full items-center justify-center gap-1 text-xs text-app-muted transition-colors hover:text-app-text">
              <ArrowLeft className="h-3 w-3" /> Back
            </button>
          </div>
        )}

        {stage === 'sent' && (
          <div className="space-y-3">
            <p className="text-[13px] leading-relaxed text-app-muted">
              We sent a code to <span className="text-app-text">{email}</span>. It expires shortly.
            </p>
            <Button className="w-full" size="lg" onClick={() => openCodeEntry()}>Enter code</Button>
            <button onClick={() => { setStage('email'); setError(null) }}
              className="w-full text-xs text-app-muted transition-colors hover:text-app-text">
              Use a different email
            </button>
          </div>
        )}

        <div className="mt-6 flex items-center gap-2.5">
          <div className="h-px flex-1 bg-app-border" />
          <span className="flex items-center gap-1 text-[11px] text-app-muted">
            <ShieldCheck className="h-3 w-3 text-app-accent-text" /> secured by Circle
          </span>
          <div className="h-px flex-1 bg-app-border" />
        </div>
      </div>
    </div>
  )
}

export default function SignInPage() {
  return (
    <Suspense fallback={null}>
      <SignInInner />
    </Suspense>
  )
}
