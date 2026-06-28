'use client'
import { useState, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useCreateBatch } from '@/hooks/usePayroll'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { formatAmount } from '@/lib/utils'
import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle } from 'lucide-react'
import Link from 'next/link'

interface Recipient {
  name:          string
  walletAddress: string
  amount:        string
  error?:        string
}

function isValidAddress(addr: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(addr)
}

export function PayrollCreateContent() {
  const router              = useRouter()
  const { formatted: balance } = useUSDCBalance()
  const createBatch         = useCreateBatch()

  const [batchName,    setBatchName]    = useState('')
  const [description,  setDescription]  = useState('')
  const [activeTab,    setActiveTab]    = useState<'manual'|'csv'>('manual')
  const [recipients,   setRecipients]   = useState<Recipient[]>([
    { name: '', walletAddress: '', amount: '' }
  ])
  const [csvError,     setCsvError]     = useState<string | null>(null)
  const [csvSuccess,   setCsvSuccess]   = useState<string | null>(null)
  const fileInputRef   = useRef<HTMLInputElement>(null)

  const totalAmount = recipients.reduce((s, r) => s + (parseFloat(r.amount) || 0), 0)
  const validCount  = recipients.filter(r =>
    isValidAddress(r.walletAddress) && parseFloat(r.amount) > 0
  ).length

  // ── Manual recipient management ───────────────────────────
  function addRecipient() {
    setRecipients(prev => [...prev, { name: '', walletAddress: '', amount: '' }])
  }

  function removeRecipient(i: number) {
    setRecipients(prev => prev.filter((_, idx) => idx !== i))
  }

  function updateRecipient(i: number, field: keyof Recipient, value: string) {
    setRecipients(prev => prev.map((r, idx) => {
      if (idx !== i) return r
      const validationError: string | undefined =
        field === 'walletAddress' && value && !isValidAddress(value)
          ? 'Invalid address'
          : undefined
      const updated: Recipient = { ...r, [field]: value, error: validationError }
      return updated
    }))
  }

  // ── CSV upload ─────────────────────────────────────────────
  function handleCSV(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setCsvError(null); setCsvSuccess(null)

    const reader = new FileReader()
    reader.onload = (ev) => {
      const text   = ev.target?.result as string
      const lines  = text.trim().split('\n')
      const header = lines[0].toLowerCase()

      // Detect column positions
      const cols   = header.split(',').map(c => c.trim().replace(/"/g,''))
      const nameI  = cols.indexOf('name')
      const addrI  = cols.findIndex(c => c.includes('wallet') || c.includes('address'))
      const amtI   = cols.findIndex(c => c.includes('amount'))

      if (addrI === -1 || amtI === -1) {
        setCsvError('CSV must have columns: name (optional), wallet_address, amount')
        return
      }

      const parsed: Recipient[] = []
      const errors: string[]    = []

      for (let i = 1; i < lines.length; i++) {
        const row  = lines[i].split(',').map(c => c.trim().replace(/"/g,''))
        const addr = row[addrI] ?? ''
        const amt  = row[amtI]  ?? ''
        const name = nameI >= 0 ? (row[nameI] ?? '') : ''

        if (!addr && !amt) continue // skip empty rows

        if (!isValidAddress(addr)) {
          errors.push(`Row ${i + 1}: invalid address "${addr}"`)
          continue
        }
        if (isNaN(parseFloat(amt)) || parseFloat(amt) <= 0) {
          errors.push(`Row ${i + 1}: invalid amount "${amt}"`)
          continue
        }
        parsed.push({ name, walletAddress: addr, amount: amt })
      }

      if (errors.length) {
        setCsvError(errors.slice(0, 3).join(' · ') + (errors.length > 3 ? ` +${errors.length - 3} more` : ''))
      }

      if (parsed.length) {
        setRecipients(parsed)
        setActiveTab('manual') // switch to manual to show/edit
        setCsvSuccess(`Imported ${parsed.length} recipient${parsed.length !== 1 ? 's' : ''} from CSV`)
      }
    }
    reader.readAsText(file)
    if (fileInputRef.current) fileInputRef.current.value = ''
  }

  // ── Create batch ──────────────────────────────────────────
  async function handleCreate() {
    const valid = recipients.filter(r =>
      isValidAddress(r.walletAddress) && parseFloat(r.amount) > 0
    )
    if (!batchName || !valid.length) return

    const result = await createBatch.mutateAsync({
      name:        batchName,
      description: description || undefined,
      recipients:  valid.map(r => ({
        name:          r.name || undefined,
        walletAddress: r.walletAddress,
        amount:        parseFloat(r.amount),
      })),
    })

    if (result?.id) {
      router.push(`/treasury/payroll/${result.id}`)
    }
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">New payroll batch</h1>
          <p className="text-sm text-[#64748B]">
            Send USDC to multiple wallets · each payment gets a unique Memo reference
          </p>
        </div>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">

          {/* Batch details */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-3 text-sm font-medium text-[#E2E8F0]">Batch details</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Batch name *</label>
                <Input placeholder="e.g. June 2026 Payroll" value={batchName}
                  onChange={e => setBatchName(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Description (optional)</label>
                <Input placeholder="e.g. Monthly contractor payments"
                  value={description} onChange={e => setDescription(e.target.value)} />
              </div>
            </div>
          </div>

          {/* Recipients — tabs */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <div className="mb-4 flex items-center justify-between">
              <p className="text-sm font-medium text-[#E2E8F0]">Recipients</p>
              <div className="flex rounded-lg border border-[#1B2B4B] bg-[#080D1B] p-0.5">
                <button onClick={() => setActiveTab('manual')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'manual' ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
                  <Users className="h-3 w-3" /> Manual
                </button>
                <button onClick={() => setActiveTab('csv')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'csv' ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
                  <FileText className="h-3 w-3" /> CSV upload
                </button>
              </div>
            </div>

            {/* CSV tab */}
            {activeTab === 'csv' && (
              <div className="space-y-3">
                {/* Format guide */}
                <div className="rounded-lg bg-[#080D1B] p-3 text-xs">
                  <p className="mb-1 font-medium text-[#E2E8F0]">Expected CSV format:</p>
                  <pre className="text-[#64748B]">{`name,wallet_address,amount
John Doe,0x1234...abcd,100
Jane Smith,0xabcd...1234,50`}</pre>
                  <p className="mt-1 text-[#64748B]">
                    • <code>name</code> is optional · <code>wallet_address</code> and <code>amount</code> required
                  </p>
                </div>

                <input ref={fileInputRef} type="file" accept=".csv,.txt"
                  onChange={handleCSV} className="hidden" />

                <button onClick={() => fileInputRef.current?.click()}
                  className="flex w-full flex-col items-center gap-3 rounded-xl border-2 border-dashed border-[#1B2B4B] bg-[#080D1B] p-8 hover:border-[#378ADD]/50 transition-colors">
                  <Upload className="h-8 w-8 text-[#64748B]" />
                  <div className="text-center">
                    <p className="text-sm font-medium text-[#E2E8F0]">Click to upload CSV</p>
                    <p className="text-xs text-[#64748B]">Supports .csv and .txt files</p>
                  </div>
                </button>

                {csvError && (
                  <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
                    <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{csvError}
                  </div>
                )}
                {csvSuccess && (
                  <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                    <CheckCircle className="h-3.5 w-3.5 shrink-0" />{csvSuccess}
                  </div>
                )}
              </div>
            )}

            {/* Manual tab */}
            {activeTab === 'manual' && (
              <div className="space-y-2">
                {/* Column headers */}
                <div className="hidden sm:grid grid-cols-12 gap-2 px-1 text-[10px] uppercase tracking-wider text-[#64748B]">
                  <div className="col-span-3">Name</div>
                  <div className="col-span-5">Wallet address</div>
                  <div className="col-span-3">Amount (USDC)</div>
                  <div className="col-span-1" />
                </div>

                {recipients.map((r, i) => (
                  <div key={i} className="grid grid-cols-12 items-start gap-2">
                    <div className="col-span-3">
                      <Input placeholder="Name" value={r.name}
                        onChange={e => updateRecipient(i, 'name', e.target.value)}
                        className="text-xs" />
                    </div>
                    <div className="col-span-5">
                      <Input
                        placeholder="0x..."
                        value={r.walletAddress}
                        onChange={e => updateRecipient(i, 'walletAddress', e.target.value)}
                        className={`font-mono text-xs ${r.error ? 'border-red-500' : ''}`}
                      />
                      {r.error && <p className="mt-0.5 text-[10px] text-red-400">{r.error}</p>}
                    </div>
                    <div className="col-span-3">
                      <Input type="number" placeholder="0.00" value={r.amount}
                        onChange={e => updateRecipient(i, 'amount', e.target.value)}
                        className="text-xs" />
                    </div>
                    <div className="col-span-1 flex justify-center pt-2">
                      {recipients.length > 1 && (
                        <button onClick={() => removeRecipient(i)}
                          className="text-[#64748B] hover:text-red-400 transition-colors">
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  </div>
                ))}

                <Button variant="outline" size="sm" onClick={addRecipient} className="w-full">
                  <Plus className="h-3.5 w-3.5" /> Add recipient
                </Button>
              </div>
            )}
          </div>
        </div>

        {/* Summary + action */}
        <div className="space-y-4">
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Batch summary</p>
            <div className="space-y-2.5 text-xs">
              {[
                ['Recipients',      `${validCount} valid`],
                ['Total payout',    `${formatAmount(totalAmount)} USDC`],
                ['Your balance',    `${balance} USDC`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span className="text-[#64748B]">{label}</span>
                  <span className="font-mono text-[#E2E8F0]">{val}</span>
                </div>
              ))}
              <div className="border-t border-[#1B2B4B] pt-2 flex justify-between">
                <span className="text-[#64748B]">Each payment</span>
                <span className="text-[#64748B]">Gets unique Memo ref</span>
              </div>
            </div>

            <Button className="mt-4 w-full" size="lg"
              onClick={handleCreate}
              disabled={!batchName || validCount === 0 || createBatch.isPending}>
              {createBatch.isPending ? 'Creating…' : `Review & send ${validCount} payment${validCount !== 1 ? 's' : ''}`}
            </Button>

            {createBatch.isError && (
              <p className="mt-2 text-xs text-red-400">Failed to create batch</p>
            )}
          </div>

          {/* How it works */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs text-[#64748B]">
            <p className="mb-2 font-medium text-[#E2E8F0]">How payroll works</p>
            <ol className="space-y-1.5">
              {[
                'Create batch with recipient list',
                'Review — confirm amounts are correct',
                'Execute — approve USDC, then send to each recipient',
                'Each payment gets a unique Memo reference (PAY-YYYYMMDD-XXXX)',
                'Track status live as payments confirm on Arc',
              ].map((s, i) => (
                <li key={i} className="flex gap-2">
                  <span className="shrink-0 text-[#378ADD]">{i+1}.</span>
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
