'use client'

import { useState, useEffect, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import {
  ArrowLeftRight, Mail, AlertCircle, Loader2, ArrowLeft, Check,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  getSdk, startGoogleLogin, sendEmailCode, openCodeEntry,
  clearAuthCookies, circleConfigured,
} from '@/lib/circle'
import { persistSession, type Account } from '@/hooks/useAuth'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type Stage = 'details' | 'verify' | 'sent'
type Fields = { firstName: string; lastName: string; username: string; email: string }

export default function SignUpPage() {
  const router = useRouter()

  const [stage,  setStage]  = useState<Stage>('details')
  const [fields, setFields] = useState<Fields>({ firstName: '', lastName: '', username: '', email: '' })
  const [errors, setErrors] = useState<Partial<Record<keyof Fields, string>>>({})
  const [taken,  setTaken]  = useState<Partial<Record<'username' | 'email', boolean>>>({})
  const [busy,   setBusy]   = useState<string | null>(null)
  const [error,  setError]  = useState<string | null>(null)

  const set = (k: keyof Fields, v: string) => {
    setFields(f => ({ ...f, [k]: v }))
    setErrors(e => ({ ...e, [k]: undefined }))
  }

  /** Create the account once Circle has proven the email. */
  const submit = useCallback(async (userToken: string, data: Fields) => {
    setBusy('Creating your account')
    try {
      const res = await fetch(`${API}/auth/signup`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ userToken, ...data }),
      })
      const body = await res.json().catch(() => ({}))

      if (!res.ok) {
        if (body.fields) { setErrors(body.fields); setStage('details') }
        setError(body.error ?? 'Could not create your account')
        setBusy(null)
        return
      }

      persistSession(body.token, body.account as Account)
      clearAuthCookies()
      router.push('/dashboard')
    } catch {
      setError('Could not reach the server. Check your connection and try again.')
      setBusy(null)
    }
  }, [router])

  // Keep the latest form values available to the SDK callback, which is
  // registered once and would otherwise close over the initial empty state.
  const fieldsRef = useRef(fields)
  fieldsRef.current = fields

  useEffect(() => {
    if (!circleConfigured()) {
      setError('Sign-up is not configured yet. Set NEXT_PUBLIC_CIRCLE_APP_ID.')
      return
    }
    let cancelled = false

    getSdk((err, result) => {
      if (cancelled) return
      if (err || !result) {
        setBusy(null)
        setError('Verification was cancelled. Try again.')
        return
      }
      void submit(result.userToken, fieldsRef.current)
    }).catch(() => setError('Could not load sign-up. Refresh and try again.'))

    // Arriving from the sign-in page after Circle said "no account yet":
    // they are already verified, so go straight to the details form.
    const pending = sessionStorage.getItem('pending_user_token')
    if (pending) sessionStorage.removeItem('pending_user_token')

    return () => { cancelled = true }
  }, [submit])

  /** Ask the server whether a username or email is free. */
  async function checkAvailability(): Promise<boolean> {
    const qs = new URLSearchParams({
      username: fields.username.trim(),
      email:    fields.email.trim(),
    })
    try {
      const res  = await fetch(`${API}/auth/available?${qs}`)
      const data = await res.json()
      const next: Partial<Record<keyof Fields, string>> = {}
      if (data.username && !data.username.available) next.username = data.username.reason
      if (data.email && !data.email.available)       next.email    = data.email.reason
      setErrors(e => ({ ...e, ...next }))
      setTaken({ username: !next.username, email: !next.email })
      return Object.keys(next).length === 0
    } catch {
      // Availability is a convenience; the server enforces uniqueness on
      // submit anyway, so a failed check shouldn't block the user.
      return true
    }
  }

  async function onContinue() {
    setError(null)
    const missing: Partial<Record<keyof Fields, string>> = {}
    if (!fields.firstName.trim()) missing.firstName = 'Enter your first name'
    if (!fields.lastName.trim())  missing.lastName  = 'Enter your last name'
    if (!fields.username.trim())  missing.username  = 'Choose a username'
    if (!fields.email.trim())     missing.email     = 'Enter your email address'
    if (Object.keys(missing).length) { setErrors(missing); return }

    setBusy('Checking availability')
    const ok = await checkAvailability()
    setBusy(null)
    if (ok) setStage('verify')
  }

  async function onGoogle() {
    setError(null); setBusy('Opening Google')
    try { await startGoogleLogin('signup') }
    catch (e: any) { setError(e?.message ?? 'Could not start Google sign-up'); setBusy(null) }
  }

  async function onSendCode() {
    setError(null); setBusy('Sending your code')
    try { await sendEmailCode(fields.email.trim()); setStage('sent') }
    catch (e: any) { setError(e?.message ?? 'Could not send the code') }
    finally { setBusy(null) }
  }

  const field = (k: keyof Fields, label: string, props: Record<string, unknown> = {}) => (
    <div>
      <label htmlFor={k} className="mb-1 block text-xs text-app-muted">{label}</label>
      <Input id={k} value={fields[k]} onChange={e => set(k, e.target.value)}
        aria-invalid={Boolean(errors[k])} {...props} />
      {errors[k] && <p className="mt-1 text-[11px] text-red-400">{errors[k]}</p>}
      {!errors[k] && taken[k as 'username' | 'email'] && fields[k].trim() && (
        <p className="mt-1 flex items-center gap-1 text-[11px] text-emerald-500">
          <Check className="h-3 w-3" /> Available
        </p>
      )}
    </div>
  )

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
        <h2 className="mb-1 text-base font-semibold text-app-text">
          {stage === 'details' ? 'Create your account' : 'Confirm it\u2019s you'}
        </h2>
        <p className="mb-5 text-xs text-app-muted">
          {stage === 'details'
            ? 'Takes about a minute. No wallet or seed phrase needed.'
            : 'One last step, so we know the email is yours.'}
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

        {stage === 'details' && (
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-2">
              {field('firstName', 'First name', { autoComplete: 'given-name', autoFocus: true })}
              {field('lastName',  'Last name',  { autoComplete: 'family-name' })}
            </div>
            {field('username', 'Username', { placeholder: 'ada_lovelace', autoComplete: 'username' })}
            {field('email',    'Email address', { type: 'email', placeholder: 'you@example.com', autoComplete: 'email' })}

            <Button className="w-full" onClick={onContinue} disabled={Boolean(busy)}>
              Continue
            </Button>
          </div>
        )}

        {stage === 'verify' && (
          <div className="space-y-2">
            <Button className="w-full" variant="outline" onClick={onGoogle} disabled={Boolean(busy)}>
              Continue with Google
            </Button>
            <Button className="w-full" variant="outline" onClick={onSendCode} disabled={Boolean(busy)}>
              <Mail className="h-4 w-4" /> Email me a code
            </Button>
            <button onClick={() => { setStage('details'); setError(null) }}
              className="flex w-full items-center justify-center gap-1 pt-1 text-xs text-app-muted hover:text-app-text">
              <ArrowLeft className="h-3 w-3" /> Edit my details
            </button>
          </div>
        )}

        {stage === 'sent' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              We sent a code to <span className="text-app-text">{fields.email}</span>.
            </p>
            <Button className="w-full" onClick={() => openCodeEntry()}>Enter code</Button>
            <button onClick={() => { setStage('verify'); setError(null) }}
              className="w-full text-xs text-app-muted hover:text-app-text">
              Back
            </button>
          </div>
        )}
      </div>

      <p className="mt-5 text-xs text-app-muted">
        Already have an account?{' '}
        <Link href="/signin" className="text-app-accent-text hover:underline">Sign in</Link>
      </p>
    </div>
  )
}
