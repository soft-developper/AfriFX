'use client'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import { useCreateInvoice } from '@/hooks/useInvoices'
import { useFXRates } from '@/hooks/useFXRate'
import { ArrowLeft, FileText, Loader2 } from 'lucide-react'

export default function CreateInvoicePage() {
  return <ClientOnly><CreateInvoiceContent /></ClientOnly>
}

function CreateInvoiceContent() {
  const router        = useRouter()
  const createInvoice = useCreateInvoice()
  const { data: rates = [] } = useFXRates()

  const [amount,       setAmount]       = useState('')
  const [currency,     setCurrency]     = useState('USDC')
  const [description,  setDescription]  = useState('')
  const [notes,        setNotes]        = useState('')
  const [payerAddress, setPayerAddress] = useState('')
  const [dueDate,      setDueDate]      = useState('')

  // USD equivalent preview for non-USDC invoices
  const rateEntry = rates.find(r => r.pair === `${currency}/USDC`)
  const usdEquiv = rateEntry && amount && currency !== 'USDC'
    ? parseFloat((parseFloat(amount) / rateEntry.rate).toFixed(2))
    : null

  async function handleCreate() {
    if (!amount) return
    const result = await createInvoice.mutateAsync({
      amount:       parseFloat(amount),
      currency,
      description:  description || undefined,
      notes:        notes       || undefined,
      payerAddress: payerAddress || undefined,
      dueDate:      dueDate ? Math.floor(new Date(dueDate).getTime() / 1000) : undefined,
    })
    if (result?.id) router.push(`/invoices/${result.id}`)
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/invoices">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create invoice</h1>
          <p className="text-sm text-app-muted">Generate a payment link with a unique Memo reference</p>
        </div>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Invoice details</p>
            <div className="space-y-3">
              {/* Amount + currency */}
              <div className="flex gap-3">
                <div className="flex-1">
                  <label className="mb-1 block text-xs text-app-muted">Amount *</label>
                  <Input type="number" placeholder="0.00" value={amount}
                    onChange={e => setAmount(e.target.value)} />
                </div>
                <div className="w-32">
                  <label className="mb-1 block text-xs text-app-muted">Currency</label>
                  <select value={currency} onChange={e => setCurrency(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {['USDC','NGN','GHS','KES','ZAR','EGP'].map(c => (
                      <option key={c} value={c}>{c}</option>
                    ))}
                  </select>
                </div>
              </div>

              {/* USD equivalent preview */}
              {usdEquiv && (
                <p className="text-xs text-emerald-400">
                  ≈ ${usdEquiv.toLocaleString()} USD at current rate
                </p>
              )}

              <div>
                <label className="mb-1 block text-xs text-app-muted">Description *</label>
                <Input placeholder="What is this invoice for?" value={description}
                  onChange={e => setDescription(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Notes (optional)</label>
                <textarea value={notes} onChange={e => setNotes(e.target.value)}
                  placeholder="Additional payment instructions, bank details, etc."
                  rows={3}
                  className="w-full resize-none rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted outline-none focus:ring-1 focus:ring-app-accent" />
              </div>
            </div>
          </div>

          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Payer details (optional)</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-app-muted">Payer wallet address</label>
                <Input placeholder="0x… (leave blank for open invoice)"
                  value={payerAddress} onChange={e => setPayerAddress(e.target.value)}
                  className="font-mono text-xs" />
                <p className="mt-1 text-[10px] text-app-muted">
                  If set, only this wallet can pay the invoice
                </p>
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Due date</label>
                <Input type="date" value={dueDate} onChange={e => setDueDate(e.target.value)} />
              </div>
            </div>
          </div>
        </div>

        {/* Preview */}
        <div className="space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-3 text-sm font-medium text-app-text">Preview</p>
            <div className="space-y-2 text-xs">
              <div className="flex justify-between">
                <span className="text-app-muted">Amount</span>
                <span className="font-mono text-app-text">
                  {amount ? `${parseFloat(amount).toLocaleString()} ${currency}` : '—'}
                </span>
              </div>
              {usdEquiv && (
                <div className="flex justify-between">
                  <span className="text-app-muted">USD value</span>
                  <span className="font-mono text-emerald-400">${usdEquiv.toLocaleString()}</span>
                </div>
              )}
              <div className="flex justify-between">
                <span className="text-app-muted">Description</span>
                <span className="text-app-text truncate max-w-28">{description || '—'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-app-muted">Due</span>
                <span className="text-app-text">{dueDate || 'No deadline'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-app-muted">Reference</span>
                <span className="font-mono text-app-accent">INV-YYYYMMDD-XXXX</span>
              </div>
            </div>

            <Button className="mt-4 w-full" onClick={handleCreate}
              disabled={!amount || !description || createInvoice.isPending}>
              {createInvoice.isPending
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</>
                : <><FileText className="h-4 w-4" /> Create invoice</>
              }
            </Button>
          </div>

          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs text-app-muted">
            <p className="mb-2 font-medium text-app-text">After creating</p>
            <ol className="space-y-1.5">
              {[
                'Invoice created with unique Memo ref',
                'Share payment link with payer',
                'Payer visits link and pays USDC on-chain',
                'Invoice updates to "paid" automatically',
                'Settlement visible on ArcScan',
              ].map((s, i) => (
                <li key={i} className="flex gap-2">
                  <span className="shrink-0 text-app-accent">{i+1}.</span>
                  <span>{s}</span>
                </li>
              ))}
            </ol>
          </div>
        </div>
      </div>
    </div>
  )
}
