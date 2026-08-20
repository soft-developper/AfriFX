'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect, useRef } from 'react'
import {
  useRamp, useOnramp,
  type RampCustomerType, type RampCorridor, type RampVirtualAccount,
  type DepositInstructions, type RampActivityEvent,
} from '@/hooks/useRamp'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  ArrowDownUp, ShieldCheck, Loader2, ExternalLink, AlertCircle,
  CheckCircle, Clock, Building2, User as UserIcon,
  Copy, Check, ChevronLeft, Landmark, Wallet, ArrowRight, RefreshCw,
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

  // --- Verified: the on-ramp flow ---------------------------------------------
  if (verified) {
    return (
      <div>
        {header}
        <OnrampFlow />
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

// ═══════════════════════════════════════════════════════════════════════════
// On-ramp flow (verified users). Currency grid → confirm → deposit details +
// status tracker. Deposits land as USDC on Base in the user's Circle wallet.
// ═══════════════════════════════════════════════════════════════════════════

const CURRENCY_META: Record<string, { flag: string; name: string; rail: string }> = {
  usd: { flag: '🇺🇸', name: 'US Dollar',      rail: 'ACH or wire transfer' },
  eur: { flag: '🇪🇺', name: 'Euro',           rail: 'SEPA transfer' },
  gbp: { flag: '🇬🇧', name: 'British Pound',   rail: 'Faster Payments' },
  mxn: { flag: '🇲🇽', name: 'Mexican Peso',    rail: 'SPEI transfer' },
  brl: { flag: '🇧🇷', name: 'Brazilian Real',  rail: 'Pix' },
  cop: { flag: '🇨🇴', name: 'Colombian Peso',  rail: 'Bre-B' },
}

function meta(code: string) {
  return CURRENCY_META[code] ?? { flag: '🏦', name: code.toUpperCase(), rail: 'Bank transfer' }
}

type Stage = 'pick' | 'confirm' | 'details'

function OnrampFlow() {
  const {
    corridors, corridorsLoading, findVirtualAccount,
    creating, error, createVirtualAccount, loadVirtualAccounts,
  } = useOnramp()

  const [stage, setStage]       = useState<Stage>('pick')
  const [selected, setSelected] = useState<string | null>(null)
  const [account, setAccount]   = useState<RampVirtualAccount | null>(null)

  const pick = (currency: string) => {
    setSelected(currency)
    // If a rail already exists for this currency, jump straight to details.
    const existing = findVirtualAccount(currency)
    if (existing) { setAccount(existing); setStage('details') }
    else setStage('confirm')
  }

  const confirm = async () => {
    if (!selected) return
    const va = await createVirtualAccount(selected)
    if (va) { setAccount(va); setStage('details') }
  }

  const back = () => {
    if (stage === 'details') { setStage('pick'); setAccount(null); setSelected(null); loadVirtualAccounts() }
    else { setStage('pick'); setSelected(null) }
  }

  if (stage === 'details' && account) {
    return <DepositDetails account={account} onBack={back} />
  }

  if (stage === 'confirm' && selected) {
    const m = meta(selected)
    return (
      <div className="w-full max-w-lg">
        <button onClick={back}
          className="mb-4 inline-flex items-center gap-1 text-sm text-app-muted transition-colors hover:text-app-text">
          <ChevronLeft className="h-4 w-4" /> Back
        </button>
        <div className="space-y-5 rounded-2xl border border-app-border bg-app-surface p-6">
          <div className="flex items-center gap-3">
            <span className="text-3xl leading-none" aria-hidden>{m.flag}</span>
            <div>
              <p className="font-medium text-app-text">Deposit {m.name}</p>
              <p className="text-sm text-app-muted">Fund with {m.rail}</p>
            </div>
          </div>

          <div className="space-y-3 rounded-xl bg-app-bg p-4 text-sm">
            <Step n={1} text={`We'll give you ${selected.toUpperCase()} bank details in your name.`} />
            <Step n={2} text={`Send ${selected.toUpperCase()} to those details from your bank, any time.`} />
            <Step n={3} text="It arrives as USDC in your wallet on Base, automatically." />
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-app-border/60 bg-app-bg px-3 py-2 text-xs text-app-muted">
            <ShieldCheck className="h-4 w-4 shrink-0 text-app-accent-text" />
            No fees at launch. Creating deposit details doesn&rsquo;t move any money.
          </div>

          {error && <ErrorNote text={error} />}

          <Button className="w-full" size="lg" disabled={creating} onClick={confirm}>
            {creating
              ? <><Loader2 className="h-4 w-4 animate-spin" /> Setting up…</>
              : <>Get deposit details <ArrowRight className="h-4 w-4" /></>}
          </Button>
        </div>
      </div>
    )
  }

  // stage === 'pick'
  return (
    <div className="w-full max-w-lg">
      <div className="mb-4">
        <h2 className="text-sm font-medium text-app-text">Add money</h2>
        <p className="text-sm text-app-muted">Choose the currency you&rsquo;ll deposit from your bank.</p>
      </div>

      {corridorsLoading ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="h-24 animate-pulse rounded-xl border border-app-border bg-app-surface" />
          ))}
        </div>
      ) : corridors.length === 0 ? (
        <div className="rounded-2xl border border-app-border bg-app-surface p-6 text-sm text-app-muted">
          No deposit currencies are available right now. Please check back soon.
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {corridors.map((c: RampCorridor) => {
            const m = meta(c.currency)
            const has = !!findVirtualAccount(c.currency)
            return (
              <button key={c.currency} onClick={() => pick(c.currency)}
                className="group relative flex flex-col items-start gap-2 rounded-xl border border-app-border bg-app-surface p-4 text-left transition-all hover:border-app-accent/60 hover:bg-app-bg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-app-accent/50">
                <span className="text-2xl leading-none" aria-hidden>{m.flag}</span>
                <span className="text-sm font-medium text-app-text">{c.currency.toUpperCase()}</span>
                <span className="text-[11px] leading-tight text-app-muted">{m.name}</span>
                {has && (
                  <span className="absolute right-2 top-2 flex items-center gap-0.5 rounded-full bg-emerald-900/40 px-1.5 py-0.5 text-[9px] font-medium text-emerald-400">
                    <Check className="h-2.5 w-2.5" /> Ready
                  </span>
                )}
                <ArrowRight className="absolute bottom-3 right-3 h-4 w-4 text-app-muted opacity-0 transition-opacity group-hover:opacity-100" />
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

function Step({ n, text }: { n: number; text: string }) {
  return (
    <div className="flex items-start gap-2.5">
      <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-app-accent/15 text-[11px] font-semibold text-app-accent-text">
        {n}
      </span>
      <span className="text-app-text">{text}</span>
    </div>
  )
}

function ErrorNote({ text }: { text: string }) {
  return (
    <div className="flex items-start gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
      <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
      <span>{text}</span>
    </div>
  )
}

// ── Deposit details + status tracker ───────────────────────────────────────

// Field order per currency: only the fields Bridge returns for that currency
// are shown. Labels are user-facing (what they'll type into their bank).
const FIELD_LABELS: Record<string, string> = {
  bank_name:             'Bank name',
  bank_address:          'Bank address',
  bank_routing_number:   'Routing number',
  bank_account_number:   'Account number',
  bank_beneficiary_name: 'Beneficiary name',
  bank_beneficiary_address: 'Beneficiary address',
  iban:                  'IBAN',
  bic:                   'BIC / SWIFT',
  account_holder_name:   'Account holder',
  clabe:                 'CLABE',
  br_code:               'Pix code',
  account_number:        'Account number',
  sort_code:             'Sort code',
}
const FIELD_ORDER = [
  'bank_beneficiary_name', 'account_holder_name',
  'iban', 'bic',
  'account_number', 'sort_code', 'clabe', 'br_code',
  'bank_account_number', 'bank_routing_number',
  'bank_name', 'bank_address', 'bank_beneficiary_address',
]

function orderedFields(di: DepositInstructions): Array<[string, string]> {
  const out: Array<[string, string]> = []
  for (const key of FIELD_ORDER) {
    const v = di[key]
    if (typeof v === 'string' && v.trim()) out.push([key, v])
  }
  return out
}

function DepositDetails({ account, onBack }: { account: RampVirtualAccount; onBack: () => void }) {
  const m = meta(account.currency)
  const di = account.depositInstructions ?? {}
  const fields = orderedFields(di)
  const rails = Array.isArray(di.payment_rails) ? di.payment_rails : []

  return (
    <div className="w-full max-w-lg">
      <button onClick={onBack}
        className="mb-4 inline-flex items-center gap-1 text-sm text-app-muted transition-colors hover:text-app-text">
        <ChevronLeft className="h-4 w-4" /> All currencies
      </button>

      <div className="space-y-4">
        {/* Header */}
        <div className="flex items-center justify-between rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="flex items-center gap-3">
            <span className="text-3xl leading-none" aria-hidden>{m.flag}</span>
            <div>
              <p className="font-medium text-app-text">Deposit {m.name}</p>
              <p className="text-sm text-app-muted">Arrives as USDC on Base</p>
            </div>
          </div>
          <Badge variant="success">Ready</Badge>
        </div>

        {/* Deposit instructions */}
        <div className="space-y-3 rounded-2xl border border-app-border bg-app-surface p-5">
          <div className="flex items-center gap-2 text-app-text">
            <Landmark className="h-4 w-4 text-app-accent-text" />
            <span className="text-sm font-medium">Send {account.currency.toUpperCase()} to these details</span>
          </div>

          {fields.length === 0 ? (
            <p className="rounded-lg bg-app-bg px-3 py-4 text-center text-xs text-app-muted">
              Deposit details are being generated. Pull to refresh in a moment.
            </p>
          ) : (
            <div className="divide-y divide-app-border/60 overflow-hidden rounded-xl border border-app-border/60">
              {fields.map(([key, value]) => (
                <CopyRow key={key} label={FIELD_LABELS[key] ?? key} value={value} />
              ))}
            </div>
          )}

          {rails.length > 0 && (
            <div className="flex flex-wrap items-center gap-1.5 pt-1">
              <span className="text-[11px] text-app-muted">Accepts:</span>
              {rails.map(r => (
                <span key={r} className="rounded-full bg-app-bg px-2 py-0.5 text-[10px] font-medium text-app-muted">
                  {String(r).replace(/_/g, ' ')}
                </span>
              ))}
            </div>
          )}
        </div>

        {/* Where it lands */}
        <div className="flex items-start gap-2.5 rounded-2xl border border-app-border bg-app-surface p-4 text-sm">
          <Wallet className="mt-0.5 h-4 w-4 shrink-0 text-app-accent-text" />
          <div className="min-w-0">
            <p className="text-app-text">Delivered to your wallet on Base</p>
            <p className="truncate font-mono text-[11px] text-app-muted">{account.destinationAddress}</p>
          </div>
        </div>

        {/* Status tracker */}
        <DepositTracker currency={account.currency} />
      </div>
    </div>
  )
}

function CopyRow({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch { /* clipboard blocked; ignore */ }
  }
  return (
    <button onClick={copy}
      className="flex w-full items-center justify-between gap-3 bg-app-surface px-3 py-2.5 text-left transition-colors hover:bg-app-bg">
      <span className="min-w-0">
        <span className="block text-[11px] uppercase tracking-wide text-app-muted">{label}</span>
        <span className="block truncate font-mono text-sm text-app-text">{value}</span>
      </span>
      <span className={`flex shrink-0 items-center gap-1 text-[11px] ${copied ? 'text-emerald-400' : 'text-app-muted'}`}>
        {copied ? <><Check className="h-3.5 w-3.5" /> Copied</> : <><Copy className="h-3.5 w-3.5" /> Copy</>}
      </span>
    </button>
  )
}

// Ordered lifecycle for the tracker. Bridge event types map onto these stages.
const TRACKER_STEPS = [
  { key: 'awaiting',  label: 'Waiting for your deposit', match: [] as string[] },
  { key: 'received',  label: 'Funds received',           match: ['funds_received', 'funds_scheduled'] },
  { key: 'submitted', label: 'Converting to USDC',       match: ['payment_submitted'] },
  { key: 'delivered', label: 'USDC delivered',           match: ['payment_processed'] },
]

function stageIndexFor(events: RampActivityEvent[]): number {
  let idx = 0
  for (const ev of events) {
    for (let s = TRACKER_STEPS.length - 1; s >= 1; s--) {
      if (TRACKER_STEPS[s].match.includes(ev.type) && s > idx) idx = s
    }
  }
  return idx
}

function DepositTracker({ currency }: { currency: string }) {
  const { getActivity } = useOnramp()
  const [events, setEvents]   = useState<RampActivityEvent[]>([])
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const timer = useRef<ReturnType<typeof setInterval> | null>(null)

  const pull = async () => {
    const r = await getActivity(currency)
    if (r) setEvents(r.events)
    setLoading(false)
  }

  useEffect(() => {
    pull()
    // Poll while the page is open; deposits can take minutes to hours.
    timer.current = setInterval(pull, 15000)
    const onFocus = () => pull()
    window.addEventListener('focus', onFocus)
    return () => {
      if (timer.current) clearInterval(timer.current)
      window.removeEventListener('focus', onFocus)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currency])

  const manualRefresh = async () => { setRefreshing(true); await pull(); setRefreshing(false) }

  const idx = stageIndexFor(events)
  const delivered = idx >= TRACKER_STEPS.length - 1
  // The most recent processed event, for the receipt link.
  const processed = [...events].reverse().find(e => e.type === 'payment_processed')

  return (
    <div className="space-y-4 rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-app-text">
          <Clock className="h-4 w-4 text-app-accent-text" />
          <span className="text-sm font-medium">Deposit status</span>
        </div>
        <button onClick={manualRefresh} disabled={refreshing}
          className="inline-flex items-center gap-1 text-[11px] text-app-muted transition-colors hover:text-app-text disabled:opacity-50">
          <RefreshCw className={`h-3 w-3 ${refreshing ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {loading ? (
        <div className="h-28 animate-pulse rounded-lg bg-app-bg" />
      ) : (
        <ol className="relative space-y-4">
          {TRACKER_STEPS.map((step, i) => {
            const done    = i < idx || delivered && i <= idx
            const current = i === idx && !delivered
            return (
              <li key={step.key} className="flex items-start gap-3">
                <span className="relative flex flex-col items-center">
                  <span className={`flex h-6 w-6 items-center justify-center rounded-full border text-[11px] ${
                    done
                      ? 'border-emerald-500 bg-emerald-500 text-white'
                      : current
                        ? 'border-app-accent bg-app-accent/15 text-app-accent-text'
                        : 'border-app-border text-app-muted'}`}>
                    {done ? <Check className="h-3.5 w-3.5" />
                          : current ? <Loader2 className="h-3 w-3 animate-spin" />
                          : i + 1}
                  </span>
                  {i < TRACKER_STEPS.length - 1 && (
                    <span className={`mt-1 h-6 w-px ${i < idx ? 'bg-emerald-500/60' : 'bg-app-border'}`} />
                  )}
                </span>
                <div className="pt-0.5">
                  <p className={`text-sm ${done || current ? 'text-app-text' : 'text-app-muted'}`}>
                    {step.label}
                  </p>
                  {current && i === 0 && (
                    <p className="text-[11px] text-app-muted">
                      Send {currency.toUpperCase()} using the details above — this updates on its own.
                    </p>
                  )}
                </div>
              </li>
            )
          })}
        </ol>
      )}

      {delivered && processed?.receipt?.url && (
        <a href={processed.receipt.url} target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-xs text-app-accent-text hover:underline">
          View receipt <ExternalLink className="h-3 w-3" />
        </a>
      )}

      {!loading && events.length === 0 && (
        <p className="text-[11px] text-app-muted">
          No deposits yet. Once you send funds, they&rsquo;ll show here.
        </p>
      )}
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
