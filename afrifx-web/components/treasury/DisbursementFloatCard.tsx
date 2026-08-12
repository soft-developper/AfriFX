'use client'
// ============================================================
// DisbursementFloatCard - shows the platform payroll float balance and lets an
// employer top it up with one signed transfer (hybrid custody, Phase 7b).
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { Loader2, Wallet, Plus, CheckCircle } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { usePayrollFunding } from '@/hooks/usePayrollFunding'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function DisbursementFloatCard() {
  const [balance, setBalance]   = useState<number | null>(null)
  const [configured, setConfig] = useState<boolean | null>(null)
  const [amount, setAmount]     = useState('')
  const { step, error, note, balance: newBalance, fund, reset } = usePayrollFunding()

  const refresh = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/payroll/disbursement/status`)
      const data = await res.json().catch(() => ({}))
      setConfig(Boolean(data.configured))
      setBalance(typeof data.balance === 'number' ? data.balance : null)
    } catch {
      setConfig(false)
    }
  }, [])

  useEffect(() => { refresh() }, [refresh])
  // After a successful top-up, reflect the new balance.
  useEffect(() => {
    if (step === 'done') { refresh() }
  }, [step, refresh])

  const busy = ['preparing', 'signing', 'confirming'].includes(step)
  const shown = newBalance ?? balance

  if (configured === false) {
    return (
      <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-4">
        <p className="text-sm text-app-muted">
          Payroll disbursement isn&rsquo;t set up yet. Once the platform wallet is
          configured, you&rsquo;ll be able to fund payroll here.
        </p>
      </div>
    )
  }

  return (
    <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Wallet className="h-4 w-4 text-app-accent-text" />
          <span className="text-sm font-medium text-app-text">Payroll float</span>
        </div>
        <span className="font-mono text-sm text-app-text">
          {shown === null ? '—' : `${shown.toLocaleString()} USDC`}
        </span>
      </div>

      <p className="mt-1 text-[11px] text-app-muted">
        Top up once; pay out many batches from this balance without signing each payment.
      </p>

      <div className="mt-3 flex items-center gap-2">
        <input
          type="number" inputMode="decimal" min="0" placeholder="Amount (USDC)"
          value={amount}
          onChange={e => setAmount(e.target.value)}
          disabled={busy}
          className="flex-1 rounded-lg border border-app-border bg-app-bg px-3 py-2 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
        />
        <Button
          size="sm"
          disabled={busy || !(Number(amount) > 0)}
          onClick={() => fund(Number(amount))}>
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
                : <><Plus className="h-4 w-4" /> Top up</>}
        </Button>
      </div>

      {busy && note && <p className="mt-2 text-[11px] text-app-muted">{note}</p>}

      {step === 'done' && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-emerald-500">
          <CheckCircle className="h-3.5 w-3.5" /> Float topped up.
          <button onClick={() => { setAmount(''); reset() }} className="underline">Add more</button>
        </p>
      )}
      {step === 'error' && error && (
        <p className="mt-2 text-[11px] text-red-400">{error}</p>
      )}
    </div>
  )
}
