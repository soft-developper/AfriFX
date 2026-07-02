'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2, ChevronDown, ChevronUp } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,     setEmail]   = useState('')
  const [prefs, setPrefs]       = useState({
    notify_trades:            true,
    notify_disputes:          true,
    notify_invoices:          true,
    notify_trade_accepted:    true,
    notify_trade_completed:   true,
    notify_trade_cancelled:   true,
    notify_dispute_raised:    true,
    notify_dispute_accepted:  true,
    notify_invoice_paid:      true,
    notify_invoice_reminder:  true,
    notify_receipts:          true,
  })
  const [saving,    setSaving]  = useState(false)
  const [saved,     setSaved]   = useState(false)
  const [showAll,   setShowAll] = useState(false)

  useEffect(() => {
    if (profile) {
      const p = profile as any
      setEmail(p.email ?? '')
      setPrefs({
        notify_trades:           Number(p.notify_trades           ?? 1) === 1,
        notify_disputes:         Number(p.notify_disputes         ?? 1) === 1,
        notify_invoices:         Number(p.notify_invoices         ?? 1) === 1,
        notify_trade_accepted:   Number(p.notify_trade_accepted   ?? 1) === 1,
        notify_trade_completed:  Number(p.notify_trade_completed  ?? 1) === 1,
        notify_trade_cancelled:  Number(p.notify_trade_cancelled  ?? 1) === 1,
        notify_dispute_raised:   Number(p.notify_dispute_raised   ?? 1) === 1,
        notify_dispute_accepted: Number(p.notify_dispute_accepted ?? 1) === 1,
        notify_invoice_paid:     Number(p.notify_invoice_paid     ?? 1) === 1,
        notify_invoice_reminder: Number(p.notify_invoice_reminder ?? 1) === 1,
        notify_receipts:         Number(p.notify_receipts         ?? 1) === 1,
      })
    }
  }, [profile])

  async function save() {
    if (!address) return
    setSaving(true)
    setSaved(false)
    try {
      await fetch(`${API}/notifications/email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ wallet: address, email: email || null, ...prefs }),
      })
      await refetch()
      setSaved(true)
      setTimeout(() => setSaved(false), 3000)
    } catch {} finally { setSaving(false) }
  }

  const validEmail = !email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)

  return (
    <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5 space-y-4">
      <div className="flex items-center gap-2">
        <Mail className="h-4 w-4 text-[#378ADD]" />
        <h2 className="text-sm font-medium text-[#E2E8F0]">Email notifications</h2>
      </div>

      <p className="text-xs text-[#64748B]">
        Get notified about your trades, disputes, and invoice payments by email.
      </p>

      <div className="space-y-2">
        <label className="text-xs uppercase tracking-wider text-[#64748B]">
          Email address (optional)
        </label>
        <Input
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={e => setEmail(e.target.value)}
          className={!validEmail ? 'border-red-500/50' : ''}
        />
        {!validEmail && <p className="text-xs text-red-400">Invalid email format</p>}
      </div>

      <div className="space-y-3 border-t border-[#1B2B4B] pt-4">
        <p className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
          Notification categories
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, completed, and cancelled" checked={prefs.notify_trades}    onChange={v => setPrefs(p => ({...p, notify_trades: v}))} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={prefs.notify_disputes}  onChange={v => setPrefs(p => ({...p, notify_disputes: v}))} />
        <Toggle label="Invoice and payments" description="Invoice paid and reminder alerts"  checked={prefs.notify_invoices}  onChange={v => setPrefs(p => ({...p, notify_invoices: v}))} />
        <Toggle label="Payment receipts"   description="Formal receipts for trades and invoices"  checked={prefs.notify_receipts}  onChange={v => setPrefs(p => ({...p, notify_receipts: v}))} />
      </div>

      {/* Granular toggles */}
      <button onClick={() => setShowAll(!showAll)}
        className="flex items-center gap-1 text-xs text-[#378ADD] hover:underline">
        {showAll ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
        {showAll ? 'Hide' : 'Show'} individual event toggles
      </button>

      {showAll && (
        <div className="space-y-2 border-t border-[#1B2B4B] pt-3">
          <p className="text-[10px] uppercase tracking-wider text-[#64748B]">Trade events</p>
          <MiniToggle label="Trade accepted" checked={prefs.notify_trade_accepted}   onChange={v => setPrefs(p => ({...p, notify_trade_accepted: v}))} />
          <MiniToggle label="Trade completed" checked={prefs.notify_trade_completed}  onChange={v => setPrefs(p => ({...p, notify_trade_completed: v}))} />
          <MiniToggle label="Trade auto-cancelled" checked={prefs.notify_trade_cancelled}  onChange={v => setPrefs(p => ({...p, notify_trade_cancelled: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-[#64748B] pt-2">Dispute events</p>
          <MiniToggle label="Dispute raised against you" checked={prefs.notify_dispute_raised}   onChange={v => setPrefs(p => ({...p, notify_dispute_raised: v}))} />
          <MiniToggle label="Admin accepted your dispute" checked={prefs.notify_dispute_accepted}  onChange={v => setPrefs(p => ({...p, notify_dispute_accepted: v}))} />

          <p className="text-[10px] uppercase tracking-wider text-[#64748B] pt-2">Invoice events</p>
          <MiniToggle label="Invoice paid" checked={prefs.notify_invoice_paid}     onChange={v => setPrefs(p => ({...p, notify_invoice_paid: v}))} />
          <MiniToggle label="Invoice unpaid reminder (48h)" checked={prefs.notify_invoice_reminder}  onChange={v => setPrefs(p => ({...p, notify_invoice_reminder: v}))} />
        </div>
      )}

      <Button onClick={save} disabled={!validEmail || saving} className="w-full">
        {saving
          ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</>
          : saved
          ? <><Check className="h-4 w-4 text-emerald-400" /> Saved</>
          : 'Save preferences'
        }
      </Button>
    </div>
  )
}

function Toggle({ label, description, checked, onChange }: {
  label: string, description: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-[#1B2B4B] bg-[#080D1B] p-3 hover:bg-[#0F1729] transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 cursor-pointer accent-[#378ADD]" />
      <div>
        <p className="text-sm font-medium text-[#E2E8F0]">{label}</p>
        <p className="text-xs text-[#64748B]">{description}</p>
      </div>
    </label>
  )
}

function MiniToggle({ label, checked, onChange }: {
  label: string, checked: boolean, onChange: (v: boolean) => void
}) {
  return (
    <label className="flex cursor-pointer items-center gap-2.5 rounded-lg bg-[#080D1B] px-3 py-2 hover:bg-[#0F1729] transition-colors">
      <input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)}
        className="h-3.5 w-3.5 shrink-0 cursor-pointer accent-[#378ADD]" />
      <span className="text-xs text-[#E2E8F0]">{label}</span>
    </label>
  )
}
