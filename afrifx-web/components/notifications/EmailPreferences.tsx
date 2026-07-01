'use client'
import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mail, Check, Loader2 } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function EmailPreferences() {
  const { address } = useAccount()
  const { data: profile, refetch } = useProfile()

  const [email,            setEmail]   = useState('')
  const [notifyTrades,     setT]       = useState(true)
  const [notifyDisputes,   setD]       = useState(true)
  const [notifyInvoices,   setI]       = useState(true)
  const [saving,           setSaving]  = useState(false)
  const [saved,            setSaved]   = useState(false)

  useEffect(() => {
    if (profile) {
      setEmail((profile as any).email ?? '')
      setT(Number((profile as any).notify_trades   ?? 1) === 1)
      setD(Number((profile as any).notify_disputes ?? 1) === 1)
      setI(Number((profile as any).notify_invoices ?? 1) === 1)
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
        body: JSON.stringify({
          wallet:          address,
          email:           email || null,
          notify_trades:   notifyTrades,
          notify_disputes: notifyDisputes,
          notify_invoices: notifyInvoices,
        }),
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
          What to notify about
        </p>

        <Toggle label="Trade activity"     description="Offers accepted, trades completed" checked={notifyTrades}   onChange={setT} />
        <Toggle label="Dispute updates"    description="Always recommended for safety"     checked={notifyDisputes} onChange={setD} />
        <Toggle label="Invoice payments"   description="When customers pay your invoices"  checked={notifyInvoices} onChange={setI} />
      </div>

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
