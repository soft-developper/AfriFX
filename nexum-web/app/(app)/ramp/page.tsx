'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect, useRef } from 'react'
import { useRamp, type RampCustomerType } from '@/hooks/useRamp'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  ArrowDownUp, ShieldCheck, Loader2, ExternalLink, AlertCircle,
  CheckCircle, Clock, Building2, User as UserIcon,
} from 'lucide-react'

const IS_SANDBOX = process.env.NEXT_PUBLIC_RAMP_ENV !== 'production'

function RampInner() {
  const {
    customer, loading, busy, error, verified,
    startVerification, refresh, simulateApprove,
  } = useRamp()

  const [fullName, setFullName] = useState('')
  const [type, setType]         = useState<RampCustomerType>('individual')
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const status = customer?.kycStatus
  const inProgress = customer?.exists && !verified &&
    status !== 'rejected' && status !== 'offboarded'

  // While the user is completing the hosted flow, poll for status. Also refresh
  // when they come back to this tab (they finish KYC in a new tab).
  useEffect(() => {
    if (!inProgress) return
    pollRef.current = setInterval(refresh, 8000)
    const onFocus = () => refresh()
    window.addEventListener('focus', onFocus)
    return () => {
      if (pollRef.current) clearInterval(pollRef.current)
      window.removeEventListener('focus', onFocus)
    }
  }, [inProgress, refresh])

  const header = (
    <div className="mb-6">
      <h1 className="flex items-center gap-2 text-xl font-semibold text-app-text">
        <ArrowDownUp className="h-5 w-5 text-app-accent-text" /> On/Off-ramp
      </h1>
      <p className="text-sm text-app-muted">
        Move money between your bank and USDC. Verify your identity once to get started.
      </p>
    </div>
  )

  if (loading) {
    return (
      <div>
        {header}
        <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="h-24 animate-pulse rounded-lg bg-app-border" />
        </div>
      </div>
    )
  }

  // --- Verified: ramp features land here in Phase 2 ---------------------------
  if (verified) {
    return (
      <div>
        {header}
        <div className="w-full max-w-md space-y-4 rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="flex items-center gap-2 text-emerald-400">
            <ShieldCheck className="h-5 w-5" />
            <span className="font-medium">Identity verified</span>
          </div>
          <p className="text-sm text-app-muted">
            You&rsquo;re cleared to use on/off-ramp. Deposit and withdrawal are being
            switched on next — you&rsquo;ll see them here shortly.
          </p>
          <Badge variant="success">Verified</Badge>
        </div>
      </div>
    )
  }

  // --- Rejected: show reasons + allow retry ----------------------------------
  if (customer?.exists && (status === 'rejected' || status === 'offboarded')) {
    return (
      <div>
        {header}
        <div className="w-full max-w-md space-y-3 rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="flex items-center gap-2 text-red-400">
            <AlertCircle className="h-5 w-5" />
            <span className="font-medium">Verification didn&rsquo;t pass</span>
          </div>
          {customer.rejectionReasons && customer.rejectionReasons.length > 0 && (
            <ul className="space-y-1 text-sm text-app-muted">
              {customer.rejectionReasons.map((r, i) => (
                <li key={i}>• {r.reason ?? r.developer_reason ?? 'Verification issue'}</li>
              ))}
            </ul>
          )}
          {customer.kycLink && (
            <a href={customer.kycLink} target="_blank" rel="noopener noreferrer">
              <Button className="w-full">
                <ExternalLink className="h-4 w-4" /> Try verification again
              </Button>
            </a>
          )}
        </div>
      </div>
    )
  }

  // --- In progress: hosted links + live status -------------------------------
  if (inProgress) {
    const tosDone = customer?.tosStatus === 'approved'
    return (
      <div>
        {header}
        <div className="w-full max-w-md space-y-4 rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="flex items-center gap-2 text-app-text">
            <Clock className="h-5 w-5 text-amber-400" />
            <span className="font-medium">Verification in progress</span>
          </div>
          <p className="text-sm text-app-muted">
            Complete these two steps in the new tab. This page updates automatically.
          </p>

          {/* Step 1: Terms of Service */}
          <div className="flex items-center justify-between rounded-lg border border-app-border p-3">
            <div className="flex items-center gap-2 text-sm">
              {tosDone
                ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                : <span className="h-4 w-4 rounded-full border border-app-muted" />}
              <span className={tosDone ? 'text-app-muted line-through' : 'text-app-text'}>
                Accept Terms of Service
              </span>
            </div>
            {!tosDone && customer?.tosLink && (
              <a href={customer.tosLink} target="_blank" rel="noopener noreferrer"
                className="text-xs text-app-accent-text hover:underline">
                Open <ExternalLink className="inline h-3 w-3" />
              </a>
            )}
          </div>

          {/* Step 2: Identity verification */}
          <div className="flex items-center justify-between rounded-lg border border-app-border p-3">
            <div className="flex items-center gap-2 text-sm">
              <span className="h-4 w-4 rounded-full border border-app-muted" />
              <span className="text-app-text">Verify your identity</span>
            </div>
            {customer?.kycLink && (
              <a href={customer.kycLink} target="_blank" rel="noopener noreferrer"
                className="text-xs text-app-accent-text hover:underline">
                Open <ExternalLink className="inline h-3 w-3" />
              </a>
            )}
          </div>

          <div className="flex items-center gap-1.5 text-xs text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> Checking status…
            <span className="ml-1">({status?.replace(/_/g, ' ')})</span>
          </div>

          {IS_SANDBOX && customer?.customerId && (
            <Button variant="outline" className="w-full" disabled={busy}
              onClick={() => simulateApprove()}>
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              Sandbox: simulate approval
            </Button>
          )}
        </div>
      </div>
    )
  }

  // --- Not started: onboarding form ------------------------------------------
  return (
    <div>
      {header}
      <div className="w-full max-w-md space-y-4 rounded-2xl border border-app-border bg-app-surface p-5">
        <div className="flex items-center gap-2 text-app-text">
          <ShieldCheck className="h-5 w-5 text-app-accent-text" />
          <span className="font-medium">Verify your identity</span>
        </div>
        <p className="text-sm text-app-muted">
          On/off-ramp moves real money, so we verify you first. It takes about a
          minute and is handled securely by our partner.
        </p>

        {/* Account type */}
        <div className="space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Account type
          </label>
          <div className="grid grid-cols-2 gap-2">
            <button
              onClick={() => setType('individual')}
              className={`flex items-center justify-center gap-2 rounded-lg border p-3 text-sm ${
                type === 'individual'
                  ? 'border-app-accent bg-app-bg text-app-text'
                  : 'border-app-border text-app-muted'}`}>
              <UserIcon className="h-4 w-4" /> Individual
            </button>
            <button
              onClick={() => setType('business')}
              className={`flex items-center justify-center gap-2 rounded-lg border p-3 text-sm ${
                type === 'business'
                  ? 'border-app-accent bg-app-bg text-app-text'
                  : 'border-app-border text-app-muted'}`}>
              <Building2 className="h-4 w-4" /> Business
            </button>
          </div>
        </div>

        {/* Legal name */}
        <div className="space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            {type === 'business' ? 'Legal business name' : 'Full legal name'}
          </label>
          <Input
            placeholder={type === 'business' ? 'Acme Inc.' : 'John Doe'}
            value={fullName}
            onChange={e => setFullName(e.target.value)}
          />
        </div>

        {error && (
          <div className="flex items-start gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        <Button className="w-full" size="lg" disabled={busy || !fullName.trim()}
          onClick={async () => {
            const c = await startVerification(fullName.trim(), type)
            // Open the ToS link immediately so the user starts the hosted flow.
            if (c?.tosLink) window.open(c.tosLink, '_blank', 'noopener')
          }}>
          {busy
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting…</>
            : 'Start verification'}
        </Button>
      </div>
    </div>
  )
}

export default function RampPage() {
  return (
    <SectionGuard section="ramp">
      <RampInner />
    </SectionGuard>
  )
}
