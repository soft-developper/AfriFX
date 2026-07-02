'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function ResetPasswordPage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { resetPassword } = useAdminAuth()

  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleReset() {
    setError(null)
    if (!password) { setError('Enter a new password'); return }
    if (password !== confirm) { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await resetPassword(params.token, password)
      if (result.success) setDone(true)
      else setError((result as any).error ?? 'Reset failed — the link may have expired')
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#378ADD]/10">
            <Shield className="h-7 w-7 text-[#378ADD]" />
          </div>
          <h1 className="text-2xl font-bold text-[#E2E8F0]">Reset password</h1>
          <p className="text-sm text-[#64748B]">Choose a new password for your admin account</p>
        </div>

        <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          {done ? (
            <div className="flex flex-col items-center gap-3 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-[#E2E8F0]">Password updated</p>
              <Link href="/admin" className="w-full">
                <Button className="w-full">Go to sign in</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="New password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Confirm new password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleReset()} />
              </div>
              <p className="text-[11px] text-[#64748B] leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleReset} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
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
