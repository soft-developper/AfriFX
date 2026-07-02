'use client'
import { useState, useEffect, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import { AdminShell } from '@/components/admin/AdminShell'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import {
  Lock, ShieldCheck, ShieldOff, Loader2, AlertCircle,
  CheckCircle, KeyRound, Copy, Check,
} from 'lucide-react'

function ChangePasswordCard() {
  const { changePassword } = useAdminAuth()
  const [current,  setCurrent]  = useState('')
  const [next,     setNext]     = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [success,  setSuccess]  = useState(false)
  const [busy,     setBusy]     = useState(false)

  async function handleSubmit() {
    setError(null); setSuccess(false)
    if (!current || !next) { setError('All fields are required'); return }
    if (next !== confirm)  { setError('New passwords do not match'); return }

    setBusy(true)
    try {
      const result = await changePassword(current, next)
      if (result.success) {
        setSuccess(true)
        setCurrent(''); setNext(''); setConfirm('')
      } else {
        setError((result as any).error ?? 'Could not change password')
      }
    } finally { setBusy(false) }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Lock className="h-4 w-4 text-app-accent" /> Change password</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input type="password" placeholder="Current password" autoComplete="current-password"
          value={current} onChange={e => setCurrent(e.target.value)} />
        <Input type="password" placeholder="New password" autoComplete="new-password"
          value={next} onChange={e => setNext(e.target.value)} />
        <Input type="password" placeholder="Confirm new password" autoComplete="new-password"
          value={confirm} onChange={e => setConfirm(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && handleSubmit()} />
        <p className="text-[11px] text-app-muted">
          Min 12 characters, with uppercase, lowercase, a number, and a special character.
        </p>
        <Button onClick={handleSubmit} disabled={busy}>
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
        </Button>
        {success && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
            <CheckCircle className="h-3.5 w-3.5" /> Password updated
          </div>
        )}
        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function TwoFactorCard({ autoStart }: { autoStart: boolean }) {
  const { admin, setup2FA, verify2FA } = useAdminAuth()
  const [stage, setStage]   = useState<'idle' | 'qr' | 'recovery'>('idle')
  const [qrCode, setQrCode] = useState('')
  const [secret, setSecret] = useState('')
  const [code,   setCode]   = useState('')
  const [codes,  setCodes]  = useState<string[]>([])
  const [copied, setCopied] = useState(false)
  const [error,  setError]  = useState<string | null>(null)
  const [busy,   setBusy]   = useState(false)

  useEffect(() => {
    if (autoStart && admin && !admin.totpEnabled) handleStart()
  }, [autoStart, admin?.id])

  async function handleStart() {
    setError(null); setBusy(true)
    try {
      const result = await setup2FA()
      if (result.success) {
        setQrCode(result.qrCode!); setSecret(result.secret!); setStage('qr')
      } else {
        setError((result as any).error ?? 'Could not start 2FA setup')
      }
    } finally { setBusy(false) }
  }

  async function handleVerify() {
    setError(null)
    if (code.length !== 6) { setError('Enter the 6-digit code'); return }
    setBusy(true)
    try {
      const result = await verify2FA(code)
      if (result.success) {
        setCodes(result.recoveryCodes ?? [])
        setStage('recovery')
      } else {
        setError((result as any).error ?? 'Invalid code')
      }
    } finally { setBusy(false) }
  }

  function copyRecoveryCodes() {
    navigator.clipboard.writeText(codes.join('\n')).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  const enabled = admin?.totpEnabled && stage !== 'recovery'

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-app-accent" /> Two-factor authentication
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {enabled && stage === 'idle' && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
            <ShieldCheck className="h-4 w-4" /> 2FA is enabled on your account
          </div>
        )}

        {!enabled && stage === 'idle' && (
          <>
            <div className="flex items-center gap-2 rounded-lg bg-amber-900/20 px-3 py-2.5 text-xs text-amber-400">
              <ShieldOff className="h-4 w-4" /> 2FA is not enabled — we recommend turning it on
            </div>
            <Button onClick={handleStart} disabled={busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting…</> : <>Set up 2FA</>}
            </Button>
          </>
        )}

        {stage === 'qr' && (
          <div className="space-y-3">
            <p className="text-xs text-app-muted">
              Scan this QR code with an authenticator app (Google Authenticator, 1Password, Authy).
            </p>
            {qrCode && (
              <div className="flex justify-center rounded-lg bg-white p-3">
                <img src={qrCode} alt="2FA QR code" className="h-40 w-40" />
              </div>
            )}
            <p className="break-all rounded-lg bg-app-bg p-2 text-center font-mono text-[10px] text-app-muted">
              {secret}
            </p>
            <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
              maxLength={6} inputMode="numeric"
              value={code} onChange={e => setCode(e.target.value.replace(/\D/g, ''))}
              onKeyDown={e => e.key === 'Enter' && handleVerify()} />
            <Button onClick={handleVerify} disabled={code.length !== 6 || busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & enable</>}
            </Button>
          </div>
        )}

        {stage === 'recovery' && (
          <div className="space-y-3">
            <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="h-4 w-4" /> 2FA enabled
            </div>
            <p className="text-xs text-app-muted">
              Save these recovery codes somewhere safe — each can be used once if you lose access to your authenticator.
            </p>
            <div className="grid grid-cols-2 gap-1.5 rounded-lg bg-app-bg p-3 font-mono text-xs text-app-text">
              {codes.map(c => <span key={c}>{c}</span>)}
            </div>
            <Button variant="outline" onClick={copyRecoveryCodes}>
              {copied ? <><Check className="h-4 w-4" /> Copied</> : <><Copy className="h-4 w-4" /> Copy codes</>}
            </Button>
          </div>
        )}

        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function SettingsBody() {
  const { admin } = useAdminAuth()
  const searchParams = useSearchParams()
  const autoStart2FA = searchParams.get('onboarding') === '2fa'

  return (
    <div className="mx-auto max-w-xl space-y-6">
      <div>
        <h1 className="text-lg font-semibold text-app-text">Account settings</h1>
        {admin && (
          <p className="text-sm text-app-muted">
            Signed in as <span className="text-app-accent">{admin.username}</span> · {admin.email}
          </p>
        )}
      </div>
      <ChangePasswordCard />
      <TwoFactorCard autoStart={autoStart2FA} />
    </div>
  )
}

export default function AdminSettingsPage() {
  return (
    <AdminShell>
      <Suspense fallback={
        <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-app-accent" /></div>
      }>
        <SettingsBody />
      </Suspense>
    </AdminShell>
  )
}
