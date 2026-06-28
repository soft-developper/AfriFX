'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, AlertTriangle, ArrowRight } from 'lucide-react'

export default function AdminDisputes() {
  const [disputes, setDisputes] = useState<any[]>([])
  const [loading,  setLoading]  = useState(true)
  const [busy,     setBusy]     = useState<string|null>(null)

  async function load() {
    setLoading(true)
    const res = await adminFetch('/admin/manage/disputes?status=open')
    const data = await res.json()
    setDisputes(Array.isArray(data) ? data : [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function resolve(d: any, resolution: 'release'|'refund') {
    const label = resolution === 'release' ? 'release USDC to the TAKER' : 'refund USDC to the MAKER'
    const reason = prompt(`Resolve dispute — this will ${label}.\nEnter a reason:`)
    if (reason === null) return
    setBusy(d.id)
    try {
      const res = await adminFetch(`/admin/manage/disputes/${d.id}/resolve`, {
        method: 'POST',
        body: JSON.stringify({ resolution, offerId: d.offer_id, reason }),
      })
      if (res.ok) await load()
      else alert((await res.json()).error)
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-[#E2E8F0]">Dispute resolution</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <AlertTriangle className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No open disputes 🎉</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map(d => (
            <div key={d.id} className="rounded-xl border border-amber-900/40 bg-amber-900/10 p-5">
              <div className="mb-3 flex items-center justify-between">
                <Badge variant="danger">Dispute open</Badge>
                <span className="text-xs text-[#64748B]">
                  {d.created_at ? new Date(Number(d.created_at) * 1000).toLocaleString() : ''}
                </span>
              </div>

              <div className="mb-3 grid grid-cols-2 gap-3 text-xs">
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Trade</p>
                  <p className="font-mono text-[#E2E8F0]">
                    {Number(d.usdc_amount ?? 0).toFixed(2)} USDC ↔ {Number(d.local_amount ?? 0).toLocaleString()} {d.local_currency}
                  </p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Reason</p>
                  <p className="text-[#E2E8F0]">{d.reason ?? 'Maker did not confirm'}</p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Maker</p>
                  <p className="font-mono text-[#E2E8F0]">{d.maker_address?.slice(0,16)}…</p>
                </div>
                <div className="rounded-lg bg-[#080D1B] p-3">
                  <p className="text-[#64748B]">Taker</p>
                  <p className="font-mono text-[#E2E8F0]">{d.taker_address?.slice(0,16)}…</p>
                </div>
              </div>

              <div className="flex gap-2">
                <Button size="sm" className="flex-1" onClick={() => resolve(d, 'release')} disabled={busy === d.id}>
                  {busy === d.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <>Release to taker <ArrowRight className="h-3.5 w-3.5" /></>}
                </Button>
                <Button size="sm" variant="danger" className="flex-1" onClick={() => resolve(d, 'refund')} disabled={busy === d.id}>
                  Refund maker
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </AdminShell>
  )
}
