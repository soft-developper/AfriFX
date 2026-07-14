'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, User, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function AcceptInvitePage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { acceptInvite } = useAdminAuth()

  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleAccept() {
    setError(null)
    if (!username || !password) { setError('Username and password are required'); return }
    if (password !== confirm)   { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await acceptInvite(params.token, username, password)
      if (result.success) {
        setDone(true)
        setTimeout(() => router.push('/admin/dashboard'), 1200)
      } else {
        setError((result as any).error ?? 'Could not accept invitation')
      }
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-app-bg p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-app-accent/10">
            <Shield className="h-7 w-7 text-app-accent-text" />
          </div>
          <h1 className="text-2xl font-bold text-app-text">Accept invitation</h1>
          <p className="text-sm text-app-muted">Set up your AfriFX admin account</p>
        </div>

        <div className="rounded-2xl border border-app-border bg-app-surface p-6">
          {done ? (
            <div className="flex flex-col items-center gap-2 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-app-text">Account created, redirecting…</p>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" placeholder="Choose a username" autoComplete="off"
                  value={username} onChange={e => setUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleAccept()} />
              </div>
              <p className="text-[11px] text-app-muted leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleAccept} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Setting up…</> : <>Accept & create account</>}
              </Button>

              {error && (
                <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
