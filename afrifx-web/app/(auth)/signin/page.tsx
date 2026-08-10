'use client'

import { useState, useEffect, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, type Account } from '@/hooks/useAuth'
import { provisionWallet } from '@/hooks/useWalletProvisioning'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'choose' | 'email' | 'sent'

/**
 * The single door into the app.
 *
 * There is no separate sign-up. You pick a sign-in method; if it's your
 * first time we make the account, create your wallet, and send you on to
 * choose a username. If you've been here before you land on the
 * dashboard. Nothing is asked for up front.
 */
export default function SignInPage() {
  const router = useRouter()

  const [stage, setStage] = useState<Stage>('choose')
  const [email, setEmail] = useState('')
  const [busy,  setBusy]  = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const enter = useCallback(async (userToken: string, encryptionKey: string) => {
    setBusy('Signing you in')
    try {
      const res = await fetch(`${API}/auth/session`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        // Send the email when we know it, so accounts created via the
        // code flow have one without asking again later.
        body: JSON.stringify({ userToken, email: email.trim() || undefined }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) { setError(data.error ?? 'Could not sign you in'); setBusy(null); return }

      persistSession(data.token, data.account as Account)
      clearAuthCookies()

      // First time in: make the wallet before letting them through, so
      // the dashboard is never reached in a half-provisioned state.
      if (data.needsWallet) {
        try {
          await provisionWallet(userToken, encryptionKey, setBusy)
        } catch (e: any) {
          setError(`${e?.message ?? 'Wallet setup did not finish'} You are signed in, so you can retry.`)
          setBusy(null)
          return
        }
      }

      // ProfileGuard sends anyone without a profile to /profile/setup,
      // so the dashboard is the right destination either way.
      router.push('/dashboard')
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [email, router])

  // Registered on mount: Google sends the browser away and back, so the
  // callback has to be listening before anything is clicked.
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
      void enter(result.userToken, result.encryptionKey)
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
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-10">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-app-accent/20">
          <ArrowLeftRight className="h-6 w-6 text-app-accent-text" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-app-text">AfriFX</h1>
          <p className="text-xs text-app-muted">Dollars that move like messages</p>
        </div>
      </div>

      <div className="w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6">
        <h2 className="mb-1 text-base font-semibold text-app-text">Sign in</h2>
        <p className="mb-5 text-xs text-app-muted">
          New here? Signing in creates your account. No wallet or seed phrase needed.
        </p>

        {error && (
          <div className="mb-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {busy && (
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2.5 text-xs text-app-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" /> {busy}…
          </div>
        )}

        {stage === 'choose' && (
          <div className="space-y-2">
            <Button className="w-full" variant="outline"
              onClick={onGoogle} disabled={Boolean(busy)}>
              Continue with Google
            </Button>
            <Button className="w-full" variant="outline"
              onClick={() => { setStage('email'); setError(null) }} disabled={Boolean(busy)}>
              <Mail className="h-4 w-4" /> Continue with email
            </Button>
          </div>
        )}

        {stage === 'email' && (
          <div className="space-y-3">
            <div>
              <label htmlFor="email" className="mb-1 block text-xs text-app-muted">
                Email address
              </label>
              <Input id="email" type="email" autoFocus autoComplete="email"
                placeholder="you@example.com"
                value={email} onChange={e => setEmail(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && email.trim()) void onSendCode() }} />
            </div>
            <Button className="w-full" onClick={onSendCode}
              disabled={!email.trim() || Boolean(busy)}>
              Send me a code
            </Button>
            <button onClick={() => { setStage('choose'); setError(null) }}
              className="flex w-full items-center justify-center gap-1 text-xs text-app-muted hover:text-app-text">
              <ArrowLeft className="h-3 w-3" /> Back
            </button>
          </div>
        )}

        {stage === 'sent' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              We sent a code to <span className="text-app-text">{email}</span>. It expires shortly.
            </p>
            <Button className="w-full" onClick={() => openCodeEntry()}>Enter code</Button>
            <button onClick={() => { setStage('email'); setError(null) }}
              className="w-full text-xs text-app-muted hover:text-app-text">
              Use a different email
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
