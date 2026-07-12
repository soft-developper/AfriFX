'use client'
import { useState, useEffect, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import Link from 'next/link'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'
import { CheckCircle2, AlertCircle, Loader2 } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

function UnsubscribeInner() {
  const params = useSearchParams()
  const token  = params.get('token')

  const [state, setState] = useState<'idle' | 'working' | 'done' | 'error'>('idle')
  const [message, setMessage] = useState('')

  useEffect(() => {
    if (!token) { setState('error'); setMessage('This unsubscribe link is missing its token.') }
  }, [token])

  async function confirm() {
    if (!token) return
    setState('working')
    try {
      const r = await fetch(`${API}/profile/unsubscribe/${token}`, { method: 'POST' })
      const d = await r.json()
      if (!r.ok) { setState('error'); setMessage(d?.error ?? 'This link is not valid.'); return }
      setState('done'); setMessage(d.message)
    } catch {
      setState('error'); setMessage('Something went wrong. Please try again.')
    }
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-app-bg px-4 py-16">
      <div className="mb-8"><AfriFXLogo size="md" href="/" /></div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-8 text-center">
        {state === 'done' ? (
          <>
            <CheckCircle2 className="mx-auto mb-3 h-9 w-9 text-emerald-400" />
            <h1 className="text-lg font-semibold text-app-text">Unsubscribed</h1>
            <p className="mt-2 text-sm text-app-muted">{message}</p>
          </>
        ) : state === 'error' ? (
          <>
            <AlertCircle className="mx-auto mb-3 h-9 w-9 text-red-400" />
            <h1 className="text-lg font-semibold text-app-text">Link not valid</h1>
            <p className="mt-2 text-sm text-app-muted">{message}</p>
          </>
        ) : (
          <>
            <h1 className="text-lg font-semibold text-app-text">
              Unsubscribe from announcements?
            </h1>
            <p className="mt-2 text-sm text-app-muted">
              You'll stop receiving AfriFX announcements and product updates.
            </p>
            <p className="mt-3 rounded-lg bg-app-accent/[0.07] px-3 py-2 text-xs text-app-muted">
              You'll still receive essential emails about your own trades, disputes
              and invoices — those aren't affected.
            </p>
            <button onClick={confirm} disabled={state === 'working'}
              className="mt-5 inline-flex w-full items-center justify-center gap-2 rounded-xl bg-app-accent px-4 py-2.5 text-sm font-semibold text-app-on-accent hover:bg-app-accent-hover disabled:opacity-60">
              {state === 'working'
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
                : 'Confirm unsubscribe'}
            </button>
          </>
        )}

        <Link href="/" className="mt-5 inline-block text-xs text-app-muted hover:text-app-accent-text">
          Back to AfriFX
        </Link>
      </div>
    </div>
  )
}

export default function UnsubscribePage() {
  return (
    <Suspense fallback={
      <div className="flex min-h-screen items-center justify-center bg-app-bg">
        <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
      </div>
    }>
      <UnsubscribeInner />
    </Suspense>
  )
}
