#!/bin/bash
# ============================================================
# AfriFX — Phase 8: Trade Settlement
# Run from ~/AfriFX:  bash phase8-trade-settlement.sh
# ============================================================
set -e
echo ""
echo "📄  Building Phase 8 — Trade Settlement..."
echo ""

# ============================================================
# 1 — Turso migrations
# ============================================================
echo "  Creating settlement tables..."

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS invoices (
  id               TEXT PRIMARY KEY,
  creator_address  TEXT NOT NULL,
  payer_address    TEXT,
  amount           REAL NOT NULL,
  currency         TEXT NOT NULL DEFAULT 'USDC',
  description      TEXT,
  notes            TEXT,
  due_date         INTEGER,
  memo_ref         TEXT NOT NULL UNIQUE,
  status           TEXT NOT NULL DEFAULT 'draft',
  payment_tx_hash  TEXT,
  paid_at          INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);" && echo "  ✅  invoices"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS payments (
  id                TEXT PRIMARY KEY,
  sender_address    TEXT NOT NULL,
  recipient_address TEXT NOT NULL,
  amount            REAL NOT NULL,
  currency          TEXT NOT NULL DEFAULT 'USDC',
  local_currency    TEXT,
  local_amount      REAL,
  description       TEXT,
  invoice_ref       TEXT,
  memo_ref          TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending',
  arc_tx_hash       TEXT,
  created_at        INTEGER NOT NULL,
  settled_at        INTEGER
);" && echo "  ✅  payments"

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_invoices_creator ON invoices (creator_address, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_payer   ON invoices (payer_address,   created_at DESC);
CREATE INDEX IF NOT EXISTS idx_payments_sender  ON payments (sender_address,  created_at DESC);
CREATE INDEX IF NOT EXISTS idx_payments_recv    ON payments (recipient_address, created_at DESC);
" && echo "  ✅  indexes"

echo "✅  Settlement tables created"

# ============================================================
# 2 — Backend: invoices routes
# ============================================================
cat > afrifx-api/src/routes/invoices.ts << '__EOF__'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normInvoice(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], creator_address: r[1], payer_address: r[2],
    amount: Number(r[3]), currency: r[4], description: r[5],
    notes: r[6], due_date: r[7] ? Number(r[7]) : null,
    memo_ref: r[8], status: r[9], payment_tx_hash: r[10],
    paid_at: r[11] ? Number(r[11]) : null,
    created_at: Number(r[12]), updated_at: Number(r[13]),
  }
  return { ...r, amount: Number(r.amount) }
}

function genRef(prefix: string): string {
  const date = new Date().toISOString().slice(0,10).replace(/-/g,'')
  const rand = Math.random().toString(36).slice(2,6).toUpperCase()
  return `${prefix}-${date}-${rand}`
}

// GET /invoices?wallet=0x — invoices created by or addressed to wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices
          WHERE LOWER(creator_address) = ${wallet}
             OR LOWER(payer_address)   = ${wallet}
          ORDER BY created_at DESC LIMIT 100`
    )
    res.json(parseRows(rows).map(normInvoice))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/ref/:ref — by memo ref (for payment page)
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices WHERE memo_ref = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    res.json(normInvoice(r[0]))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/:id
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices WHERE id = ${req.params.id} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    res.json(normInvoice(r[0]))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /invoices — create invoice
router.post('/', async (req, res) => {
  const { walletAddress, amount, currency = 'USDC', description, notes, dueDate, payerAddress } = req.body
  if (!walletAddress || !amount) return res.status(400).json({ error: 'walletAddress and amount required' })

  const id      = randomUUID()
  const memoRef = genRef('INV')
  const now     = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO invoices
          (id, creator_address, payer_address, amount, currency,
           description, notes, due_date, memo_ref, status, created_at, updated_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()},
           ${payerAddress?.toLowerCase() ?? null},
           ${Number(amount)}, ${currency},
           ${description ?? null}, ${notes ?? null},
           ${dueDate ?? null}, ${memoRef}, 'draft', ${now}, ${now})`
    )
    res.status(201).json({ id, memoRef })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/:id/status — update status (send, pay, cancel)
router.patch('/:id/status', async (req, res) => {
  const { status, paymentTxHash, paidAt } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = ${status},
            payment_tx_hash = COALESCE(${paymentTxHash ?? null}, payment_tx_hash),
            paid_at         = COALESCE(${paidAt ?? null}, paid_at),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/ref/:ref/pay — mark paid by memo ref (called after on-chain tx)
router.patch('/ref/:ref/pay', async (req, res) => {
  const { txHash, payerAddress } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = 'paid',
            payment_tx_hash = ${txHash ?? null},
            payer_address   = COALESCE(${payerAddress?.toLowerCase() ?? null}, payer_address),
            paid_at         = ${now},
            updated_at      = ${now}
          WHERE memo_ref = ${req.params.ref}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /invoices/:id — cancel/delete draft
router.delete('/:id', async (req, res) => {
  try {
    await db.run(
      sql`UPDATE invoices SET status = 'cancelled', updated_at = ${Math.floor(Date.now()/1000)}
          WHERE id = ${req.params.id} AND status IN ('draft','sent')`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/invoices.ts"

# ============================================================
# 3 — Backend: payments routes
# ============================================================
cat > afrifx-api/src/routes/payments.ts << '__EOF__'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { getCachedRates } from '../services/rateOracle'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normPayment(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], sender_address: r[1], recipient_address: r[2],
    amount: Number(r[3]), currency: r[4],
    local_currency: r[5], local_amount: r[6] ? Number(r[6]) : null,
    description: r[7], invoice_ref: r[8], memo_ref: r[9],
    status: r[10], arc_tx_hash: r[11],
    created_at: Number(r[12]), settled_at: r[13] ? Number(r[13]) : null,
  }
  return {
    ...r,
    amount: Number(r.amount),
    local_amount: r.local_amount ? Number(r.local_amount) : null,
  }
}

function genRef(): string {
  const date = new Date().toISOString().slice(0,10).replace(/-/g,'')
  const rand = Math.random().toString(36).slice(2,6).toUpperCase()
  return `PAY-${date}-${rand}`
}

// GET /payments?wallet=0x — sent + received
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  const type   = req.query.type as string // 'sent' | 'received' | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = type === 'sent'
      ? await db.run(sql`SELECT * FROM payments WHERE LOWER(sender_address) = ${wallet} ORDER BY created_at DESC LIMIT 100`)
      : type === 'received'
      ? await db.run(sql`SELECT * FROM payments WHERE LOWER(recipient_address) = ${wallet} ORDER BY created_at DESC LIMIT 100`)
      : await db.run(sql`SELECT * FROM payments
          WHERE LOWER(sender_address) = ${wallet} OR LOWER(recipient_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 100`)
    res.json(parseRows(rows).map(normPayment))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /payments — record a payment
router.post('/', async (req, res) => {
  const {
    senderAddress, recipientAddress, amount,
    currency = 'USDC', localCurrency, description,
    invoiceRef, arcTxHash,
  } = req.body

  if (!senderAddress || !recipientAddress || !amount) {
    return res.status(400).json({ error: 'senderAddress, recipientAddress, amount required' })
  }

  const id      = randomUUID()
  const memoRef = genRef()
  const now     = Math.floor(Date.now() / 1000)

  // Calculate local currency equivalent
  let localAmount: number | null = null
  if (localCurrency) {
    const rates = getCachedRates()
    const rate  = rates.find(r => r.pair === `${localCurrency}/USDC`)?.rate
    if (rate) localAmount = parseFloat((amount * rate).toFixed(2))
  }

  try {
    await db.run(
      sql`INSERT INTO payments
          (id, sender_address, recipient_address, amount, currency,
           local_currency, local_amount, description, invoice_ref,
           memo_ref, status, arc_tx_hash, created_at)
          VALUES
          (${id}, ${senderAddress.toLowerCase()}, ${recipientAddress.toLowerCase()},
           ${Number(amount)}, ${currency},
           ${localCurrency ?? null}, ${localAmount},
           ${description ?? null}, ${invoiceRef ?? null},
           ${memoRef}, ${arcTxHash ? 'settled' : 'pending'},
           ${arcTxHash ?? null}, ${now})`
    )
    res.status(201).json({ id, memoRef })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /payments/:id/settle
router.patch('/:id/settle', async (req, res) => {
  const { arcTxHash } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE payments SET
            status      = 'settled',
            arc_tx_hash = COALESCE(${arcTxHash ?? null}, arc_tx_hash),
            settled_at  = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /payments/report?wallet=0x&from=ts&to=ts — settlement report data
router.get('/report', async (req, res) => {
  const wallet  = (req.query.wallet as string)?.toLowerCase()
  const fromTs  = Number(req.query.from ?? 0)
  const toTs    = Number(req.query.to   ?? Math.floor(Date.now() / 1000))
  if (!wallet)  return res.status(400).json({ error: 'wallet required' })

  try {
    // Payments sent
    const sentRows = await db.run(
      sql`SELECT * FROM payments
          WHERE LOWER(sender_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Payments received
    const recvRows = await db.run(
      sql`SELECT * FROM payments
          WHERE LOWER(recipient_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Invoices paid
    const invRows = await db.run(
      sql`SELECT * FROM invoices
          WHERE (LOWER(creator_address) = ${wallet} OR LOWER(payer_address) = ${wallet})
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )
    // Transactions (FX conversions)
    const txRows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${wallet}
            AND created_at BETWEEN ${fromTs} AND ${toTs}
          ORDER BY created_at DESC`
    )

    const sent     = parseRows(sentRows).map(normPayment)
    const received = parseRows(recvRows).map(normPayment)

    const totalSent     = sent.reduce((s, p) => s + p.amount, 0)
    const totalReceived = received.reduce((s, p) => s + p.amount, 0)

    res.json({
      summary: {
        totalSent:     parseFloat(totalSent.toFixed(2)),
        totalReceived: parseFloat(totalReceived.toFixed(2)),
        netFlow:       parseFloat((totalReceived - totalSent).toFixed(2)),
        sentCount:     sent.length,
        receivedCount: received.length,
      },
      payments: {
        sent,
        received,
      },
      invoices: parseRows(invRows),
      transactions: parseRows(txRows),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/payments.ts"

# ============================================================
# 4 — Register new routes in index.ts
# ============================================================
sed -i "s|import adminAuthRouter|import invoicesRouter              from './routes/invoices'\nimport paymentsRouter              from './routes/payments'\nimport adminAuthRouter|" \
  afrifx-api/src/index.ts

sed -i "s|app.use('/admin/auth',     adminAuthRouter)|app.use('/invoices',       invoicesRouter)\napp.use('/payments',       paymentsRouter)\napp.use('/admin/auth',     adminAuthRouter)|" \
  afrifx-api/src/index.ts

echo "✅  index.ts — invoices + payments routes registered"

# ============================================================
# 5 — Frontend: hooks
# ============================================================
cat > afrifx-web/hooks/useInvoices.ts << '__EOF__'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Invoice {
  id:              string
  creator_address: string
  payer_address:   string | null
  amount:          number
  currency:        string
  description:     string | null
  notes:           string | null
  due_date:        number | null
  memo_ref:        string
  status:          'draft' | 'sent' | 'paid' | 'overdue' | 'cancelled'
  payment_tx_hash: string | null
  paid_at:         number | null
  created_at:      number
  updated_at:      number
}

export function useInvoices() {
  const { address } = useAccount()
  return useQuery<Invoice[]>({
    queryKey:        ['invoices', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/invoices?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useInvoice(id: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice', id],
    queryFn:         async () => {
      if (!id) return null
      const res = await fetch(`${API}/invoices/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 5_000,
  })
}

export function useInvoiceByRef(ref: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice-ref', ref],
    queryFn:         async () => {
      if (!ref) return null
      const res = await fetch(`${API}/invoices/ref/${ref}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!ref,
    refetchInterval: 5_000,
  })
}

export function useCreateInvoice() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      amount: number; currency?: string; description?: string
      notes?: string; dueDate?: number; payerAddress?: string
    }) => {
      const res = await fetch(`${API}/invoices`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['invoices', address] }),
  })
}

export function useUpdateInvoiceStatus() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status, paymentTxHash, paidAt }: {
      id: string; status: string; paymentTxHash?: string; paidAt?: number
    }) => {
      const res = await fetch(`${API}/invoices/${id}/status`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, paymentTxHash, paidAt }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['invoices', address] })
    },
  })
}
__EOF__
echo "✅  hooks/useInvoices.ts"

cat > afrifx-web/hooks/usePayments.ts << '__EOF__'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Payment {
  id:                string
  sender_address:    string
  recipient_address: string
  amount:            number
  currency:          string
  local_currency:    string | null
  local_amount:      number | null
  description:       string | null
  invoice_ref:       string | null
  memo_ref:          string
  status:            'pending' | 'settled' | 'failed'
  arc_tx_hash:       string | null
  created_at:        number
  settled_at:        number | null
}

export function usePayments(type?: 'sent'|'received') {
  const { address } = useAccount()
  return useQuery<Payment[]>({
    queryKey:        ['payments', address, type],
    queryFn:         async () => {
      if (!address) return []
      const q   = type ? `&type=${type}` : ''
      const res = await fetch(`${API}/payments?wallet=${address}${q}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useCreatePayment() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      recipientAddress: string; amount: number; currency?: string
      localCurrency?: string; description?: string
      invoiceRef?: string; arcTxHash?: string
    }) => {
      const res = await fetch(`${API}/payments`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ senderAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payments', address] }),
  })
}

export function useSettlementReport(fromTs?: number, toTs?: number) {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['settlement-report', address, fromTs, toTs],
    queryFn:  async () => {
      if (!address) return null
      const params = new URLSearchParams({ wallet: address })
      if (fromTs) params.set('from', String(fromTs))
      if (toTs)   params.set('to',   String(toTs))
      const res = await fetch(`${API}/payments/report?${params}`)
      return res.ok ? res.json() : null
    },
    enabled: !!address,
  })
}
__EOF__
echo "✅  hooks/usePayments.ts"

# ============================================================
# 6 — Frontend: Invoices list page
# ============================================================
mkdir -p "afrifx-web/app/(app)/invoices"
mkdir -p "afrifx-web/app/(app)/invoices/create"
mkdir -p "afrifx-web/app/(app)/invoices/[id]"
mkdir -p "afrifx-web/app/(app)/pay/[ref]"
mkdir -p "afrifx-web/app/(app)/settlements"

cat > "afrifx-web/app/(app)/invoices/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoices } from '@/hooks/useInvoices'
import { useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Copy, Check, ExternalLink,
  FileText, Send, ArrowRight, Loader2,
} from 'lucide-react'

const STATUS_BADGE: Record<string, any> = {
  draft:     'default',
  sent:      'arc',
  paid:      'success',
  overdue:   'danger',
  cancelled: 'danger',
}

export default function InvoicesPage() {
  return (
    <ClientOnly fallback={<div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />}>
      <InvoicesContent />
    </ClientOnly>
  )
}

function InvoicesContent() {
  const { address }               = useAccount()
  const { data: invoices = [], isLoading } = useInvoices()
  const updateStatus              = useUpdateInvoiceStatus()
  const [copied, setCopied]       = useState<string|null>(null)
  const [filter, setFilter]       = useState('all')

  const filtered = filter === 'all'
    ? invoices
    : invoices.filter(i => i.status === filter)

  const created  = invoices.filter(i => i.creator_address.toLowerCase() === address?.toLowerCase())
  const received = invoices.filter(i => i.payer_address?.toLowerCase() === address?.toLowerCase())

  function copyPayLink(memoRef: string) {
    const url = `${window.location.origin}/pay/${memoRef}`
    navigator.clipboard.writeText(url)
    setCopied(memoRef)
    setTimeout(() => setCopied(null), 2000)
  }

  async function markSent(id: string) {
    await updateStatus.mutateAsync({ id, status: 'sent' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Invoices</h1>
          <p className="text-sm text-[#64748B]">
            {created.length} created · {received.length} to pay
          </p>
        </div>
        <Link href="/invoices/create">
          <Button size="sm"><Plus className="h-4 w-4" /> New invoice</Button>
        </Link>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          { label: 'Total invoiced', value: `$${formatAmount(created.reduce((s,i)=>s+i.amount,0))}`, color: 'text-[#378ADD]' },
          { label: 'Paid',           value: String(created.filter(i=>i.status==='paid').length),      color: 'text-emerald-400' },
          { label: 'Pending',        value: String(created.filter(i=>i.status==='sent').length),      color: 'text-amber-400' },
          { label: 'To pay',         value: String(received.filter(i=>i.status==='sent').length),     color: 'text-red-400' },
        ].map(({ label, value, color }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-center">
            <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
            <p className="mt-1 text-xs text-[#64748B]">{label}</p>
          </div>
        ))}
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {['all','draft','sent','paid','overdue','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="space-y-2">{[1,2,3].map(i=><div key={i} className="h-20 animate-pulse rounded-xl bg-[#0F1729]"/>)}</div>
      ) : filtered.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <FileText className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No invoices yet</p>
          <Link href="/invoices/create">
            <Button variant="outline" size="sm" className="mt-3">Create your first invoice</Button>
          </Link>
        </div>
      ) : (
        <div className="space-y-2">
          {filtered.map(inv => {
            const isCreator = inv.creator_address.toLowerCase() === address?.toLowerCase()
            const isPayer   = inv.payer_address?.toLowerCase() === address?.toLowerCase()
            const isOverdue = inv.due_date && inv.due_date < Math.floor(Date.now()/1000) && inv.status === 'sent'
            return (
              <div key={inv.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
                <div className="flex items-center gap-4">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#080D1B]">
                    <FileText className="h-4 w-4 text-[#378ADD]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-mono text-sm font-medium text-[#E2E8F0]">
                        {formatAmount(inv.amount)} {inv.currency}
                      </p>
                      <Badge variant={STATUS_BADGE[isOverdue ? 'overdue' : inv.status]}>
                        {isOverdue ? 'overdue' : inv.status}
                      </Badge>
                      <Badge variant={isCreator ? 'arc' : 'warning'}>
                        {isCreator ? 'Sent by you' : 'To pay'}
                      </Badge>
                    </div>
                    <p className="text-xs text-[#64748B]">
                      {inv.memo_ref} · {inv.description ?? 'No description'}
                      {inv.due_date && ` · Due ${new Date(inv.due_date*1000).toLocaleDateString()}`}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-2">
                    {isCreator && inv.status === 'draft' && (
                      <Button size="sm" variant="outline" onClick={() => markSent(inv.id)}>
                        <Send className="h-3.5 w-3.5" /> Send
                      </Button>
                    )}
                    {isCreator && inv.status !== 'paid' && inv.status !== 'cancelled' && (
                      <button onClick={() => copyPayLink(inv.memo_ref)}
                        className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-2.5 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                        {copied === inv.memo_ref ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                        {copied === inv.memo_ref ? 'Copied!' : 'Copy link'}
                      </button>
                    )}
                    {isPayer && inv.status === 'sent' && (
                      <Link href={`/pay/${inv.memo_ref}`}>
                        <Button size="sm">Pay now <ArrowRight className="h-3.5 w-3.5" /></Button>
                      </Link>
                    )}
                    {inv.payment_tx_hash && (
                      <a href={`https://testnet.arcscan.app/tx/${inv.payment_tx_hash}`}
                        target="_blank" rel="noopener noreferrer"
                        className="text-[#64748B] hover:text-[#378ADD]">
                        <ExternalLink className="h-4 w-4" />
                      </a>
                    )}
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  invoices/page.tsx"

# ============================================================
# 7 — Invoice create page
# ============================================================
cat > "afrifx-web/app/(app)/invoices/create/page.tsx" << '__EOF__'
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

  // Local currency equivalent preview
  const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
  const localEquiv = rate && amount ? (parseFloat(amount) * rate).toLocaleString() : null

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
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Create invoice</h1>
          <p className="text-sm text-[#64748B]">Generate a payment link with a unique Memo reference</p>
        </div>
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Invoice details</p>
            <div className="space-y-3">
              {/* Amount + currency */}
              <div className="flex gap-3">
                <div className="flex-1">
                  <label className="mb-1 block text-xs text-[#64748B]">Amount *</label>
                  <Input type="number" placeholder="0.00" value={amount}
                    onChange={e => setAmount(e.target.value)} />
                </div>
                <div className="w-32">
                  <label className="mb-1 block text-xs text-[#64748B]">Currency</label>
                  <select value={currency} onChange={e => setCurrency(e.target.value)}
                    className="w-full rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-2 text-sm text-[#E2E8F0] outline-none">
                    {['USDC','NGN','GHS','KES','ZAR','EGP'].map(c => (
                      <option key={c} value={c}>{c}</option>
                    ))}
                  </select>
                </div>
              </div>

              {/* Local equivalent preview */}
              {localEquiv && currency !== 'USDC' && (
                <p className="text-xs text-emerald-400">
                  ≈ {localEquiv} local units at current rate
                </p>
              )}

              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Description *</label>
                <Input placeholder="What is this invoice for?" value={description}
                  onChange={e => setDescription(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Notes (optional)</label>
                <textarea value={notes} onChange={e => setNotes(e.target.value)}
                  placeholder="Additional payment instructions, bank details, etc."
                  rows={3}
                  className="w-full resize-none rounded-lg border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] placeholder:text-[#64748B] outline-none focus:ring-1 focus:ring-[#378ADD]" />
              </div>
            </div>
          </div>

          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Payer details (optional)</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Payer wallet address</label>
                <Input placeholder="0x… (leave blank for open invoice)"
                  value={payerAddress} onChange={e => setPayerAddress(e.target.value)}
                  className="font-mono text-xs" />
                <p className="mt-1 text-[10px] text-[#64748B]">
                  If set, only this wallet can pay the invoice
                </p>
              </div>
              <div>
                <label className="mb-1 block text-xs text-[#64748B]">Due date</label>
                <Input type="date" value={dueDate} onChange={e => setDueDate(e.target.value)} />
              </div>
            </div>
          </div>
        </div>

        {/* Preview */}
        <div className="space-y-4">
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-3 text-sm font-medium text-[#E2E8F0]">Preview</p>
            <div className="space-y-2 text-xs">
              <div className="flex justify-between">
                <span className="text-[#64748B]">Amount</span>
                <span className="font-mono text-[#E2E8F0]">
                  {amount ? `${parseFloat(amount).toLocaleString()} ${currency}` : '—'}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-[#64748B]">Description</span>
                <span className="text-[#E2E8F0] truncate max-w-28">{description || '—'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-[#64748B]">Due</span>
                <span className="text-[#E2E8F0]">{dueDate || 'No deadline'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-[#64748B]">Reference</span>
                <span className="font-mono text-[#378ADD]">INV-YYYYMMDD-XXXX</span>
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

          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs text-[#64748B]">
            <p className="mb-2 font-medium text-[#E2E8F0]">After creating</p>
            <ol className="space-y-1.5">
              {[
                'Invoice created with unique Memo ref',
                'Share payment link with payer',
                'Payer visits link and pays USDC on-chain',
                'Invoice updates to "paid" automatically',
                'Settlement visible on ArcScan',
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
__EOF__
echo "✅  invoices/create/page.tsx"

# ============================================================
# 8 — Invoice detail page (shows share link + status)
# ============================================================
cat > "afrifx-web/app/(app)/invoices/[id]/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useInvoice, useUpdateInvoiceStatus } from '@/hooks/useInvoices'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import {
  ArrowLeft, Copy, Check, ExternalLink,
  FileText, Send, Loader2, CheckCircle, X,
} from 'lucide-react'

export default function InvoiceDetailPage() {
  return <ClientOnly><InvoiceDetail /></ClientOnly>
}

function InvoiceDetail() {
  const { id }                      = useParams()
  const { address }                 = useAccount()
  const { data: invoice }           = useInvoice(id as string)
  const updateStatus                = useUpdateInvoiceStatus()
  const [copied, setCopied]         = useState(false)

  if (!invoice) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
    </div>
  )

  const payLink   = `${typeof window !== 'undefined' ? window.location.origin : ''}/pay/${invoice.memo_ref}`
  const isCreator = invoice.creator_address.toLowerCase() === address?.toLowerCase()

  function copy() {
    navigator.clipboard.writeText(payLink)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  async function cancel() {
    if (!confirm('Cancel this invoice?')) return
    await updateStatus.mutateAsync({ id: invoice.id, status: 'cancelled' })
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/invoices">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">Invoice</h1>
            <Badge variant={invoice.status === 'paid' ? 'success' : invoice.status === 'cancelled' ? 'danger' : 'arc'}>
              {invoice.status}
            </Badge>
          </div>
          <p className="font-mono text-xs text-[#378ADD]">{invoice.memo_ref}</p>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {/* Details */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Invoice details</p>
          <div className="space-y-3">
            <div className="flex justify-between items-center rounded-lg bg-[#080D1B] px-4 py-3">
              <span className="text-xs text-[#64748B]">Amount</span>
              <span className="font-mono text-lg font-bold text-[#E2E8F0]">
                {formatAmount(invoice.amount)} {invoice.currency}
              </span>
            </div>
            {[
              ['Description', invoice.description ?? '—'],
              ['Reference',   invoice.memo_ref],
              ['Created',     new Date(invoice.created_at * 1000).toLocaleString()],
              ['Due',         invoice.due_date ? new Date(invoice.due_date * 1000).toLocaleDateString() : 'No deadline'],
              ['Payer',       invoice.payer_address ? invoice.payer_address.slice(0,10)+'…' : 'Open (anyone)'],
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between text-xs">
                <span className="text-[#64748B]">{label}</span>
                <span className="font-mono text-[#E2E8F0]">{value}</span>
              </div>
            ))}
            {invoice.notes && (
              <div className="rounded-lg bg-[#080D1B] p-3 text-xs">
                <p className="mb-1 text-[#64748B]">Notes</p>
                <p className="text-[#E2E8F0] whitespace-pre-wrap">{invoice.notes}</p>
              </div>
            )}
          </div>
        </div>

        {/* Share + status */}
        <div className="space-y-4">
          {invoice.status === 'paid' ? (
            <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-5 text-center">
              <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
              <p className="font-medium text-emerald-400">Invoice paid!</p>
              <p className="mt-1 text-xs text-emerald-600">
                Paid {invoice.paid_at ? new Date(invoice.paid_at * 1000).toLocaleString() : ''}
              </p>
              {invoice.payment_tx_hash && (
                <a href={`https://testnet.arcscan.app/tx/${invoice.payment_tx_hash}`}
                  target="_blank" rel="noopener noreferrer"
                  className="mt-3 inline-flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline">
                  <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
                </a>
              )}
            </div>
          ) : invoice.status !== 'cancelled' && isCreator && (
            <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
              <p className="mb-3 text-sm font-medium text-[#E2E8F0]">Payment link</p>
              <div className="mb-3 flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2.5">
                <p className="flex-1 truncate font-mono text-xs text-[#378ADD]">{payLink}</p>
                <button onClick={copy} className="shrink-0 text-[#64748B] hover:text-[#E2E8F0]">
                  {copied ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5" />}
                </button>
              </div>
              <p className="text-xs text-[#64748B]">
                Share this link with your payer. They visit it, connect their wallet, and pay on-chain.
              </p>
              {invoice.status === 'draft' && (
                <Button className="mt-3 w-full" size="sm"
                  onClick={() => updateStatus.mutateAsync({ id: invoice.id, status: 'sent' })}>
                  <Send className="h-3.5 w-3.5" /> Mark as sent
                </Button>
              )}
            </div>
          )}

          {isCreator && !['paid','cancelled'].includes(invoice.status) && (
            <Button variant="danger" size="sm" className="w-full" onClick={cancel}>
              <X className="h-4 w-4" /> Cancel invoice
            </Button>
          )}

          {!isCreator && invoice.status === 'sent' && (
            <Link href={`/pay/${invoice.memo_ref}`}>
              <Button className="w-full">Pay this invoice</Button>
            </Link>
          )}
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  invoices/[id]/page.tsx"

# ============================================================
# 9 — Public payment page /pay/:ref
# ============================================================
cat > "afrifx-web/app/(app)/pay/[ref]/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits } from 'viem'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useCreatePayment } from '@/hooks/usePayments'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs, MEMO_ADDRESS } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import {
  FileText, CheckCircle, AlertCircle,
  Loader2, ExternalLink, Wallet,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function PayPage() {
  return <ClientOnly><PayContent /></ClientOnly>
}

function PayContent() {
  const { ref }                          = useParams()
  const { address, isConnected }         = useAccount()
  const publicClient                     = usePublicClient({ chainId: arcTestnet.id })
  const { data: invoice, isLoading }     = useInvoiceByRef(ref as string)
  const createPayment                    = useCreatePayment()
  const { writeContractAsync }           = useWriteContract()

  const [paying,  setPaying]  = useState(false)
  const [txHash,  setTxHash]  = useState<string|null>(null)
  const [error,   setError]   = useState<string|null>(null)
  const [success, setSuccess] = useState(false)

  if (isLoading) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
    </div>
  )

  if (!invoice) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <AlertCircle className="h-8 w-8 text-red-400" />
      <p className="text-sm text-[#64748B]">Invoice not found</p>
    </div>
  )

  const alreadyPaid   = invoice.status === 'paid'
  const isCancelled   = invoice.status === 'cancelled'
  const isCreator     = address?.toLowerCase() === invoice.creator_address.toLowerCase()
  const wrongPayer    = invoice.payer_address && address?.toLowerCase() !== invoice.payer_address.toLowerCase()

  async function handlePay() {
    if (!address || !isConnected) return
    setPaying(true); setError(null)
    try {
      const amount  = parseUnits(invoice!.amount.toFixed(6), USDC_DECIMALS)
      const memoId  = buildMemoId(`invoice-${invoice!.memo_ref}`)
      const target  = invoice!.creator_address as `0x${string}`

      // Check Memo availability
      const code = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!code && code !== '0x'

      let hash: `0x${string}`
      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, target, invoice!.amount, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'p2p-create', ref: invoice!.memo_ref },
        )
        hash = await writeContractAsync(args)
      } else {
        hash = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [target, amount],
        })
      }

      setTxHash(hash)

      // Wait for confirmation
      if (publicClient) {
        await publicClient.waitForTransactionReceipt({ hash })
      }

      // Mark invoice paid
      await fetch(`${API}/invoices/ref/${invoice!.memo_ref}/pay`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ txHash: hash, payerAddress: address }),
      })

      // Record payment
      await createPayment.mutateAsync({
        recipientAddress: invoice!.creator_address,
        amount:           invoice!.amount,
        currency:         invoice!.currency,
        description:      invoice!.description ?? undefined,
        invoiceRef:       invoice!.memo_ref,
        arcTxHash:        hash,
      })

      setSuccess(true)
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Payment failed')
    } finally {
      setPaying(false)
    }
  }

  return (
    <div className="mx-auto max-w-lg">
      <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
        <div className="mb-5 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-[#080D1B]">
            <FileText className="h-6 w-6 text-[#378ADD]" />
          </div>
          <div>
            <p className="text-sm font-medium text-[#E2E8F0]">Payment request</p>
            <p className="font-mono text-xs text-[#378ADD]">{invoice.memo_ref}</p>
          </div>
          <Badge className="ml-auto" variant={
            alreadyPaid ? 'success' : isCancelled ? 'danger' : 'arc'
          }>
            {invoice.status}
          </Badge>
        </div>

        {/* Amount */}
        <div className="mb-5 rounded-xl bg-[#080D1B] p-5 text-center">
          <p className="text-xs text-[#64748B]">Amount due</p>
          <p className="mt-1 font-mono text-4xl font-bold text-[#E2E8F0]">
            {formatAmount(invoice.amount)}
          </p>
          <p className="text-sm text-[#378ADD]">{invoice.currency}</p>
        </div>

        {/* Details */}
        <div className="mb-5 space-y-2 text-xs">
          {[
            ['From',        invoice.creator_address.slice(0,12)+'…'],
            ['Description', invoice.description ?? '—'],
            ['Due',         invoice.due_date ? new Date(invoice.due_date*1000).toLocaleDateString() : 'No deadline'],
          ].map(([l, v]) => (
            <div key={l} className="flex justify-between">
              <span className="text-[#64748B]">{l}</span>
              <span className="text-[#E2E8F0]">{v}</span>
            </div>
          ))}
          {invoice.notes && (
            <div className="rounded-lg bg-[#080D1B] p-2.5 text-[#64748B]">
              {invoice.notes}
            </div>
          )}
        </div>

        {/* States */}
        {success ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
            <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
            <p className="font-medium text-emerald-400">Payment sent!</p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-[#378ADD] hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
              </a>
            )}
          </div>
        ) : alreadyPaid ? (
          <div className="rounded-xl bg-emerald-900/20 p-4 text-center text-sm text-emerald-400">
            ✓ This invoice has already been paid
          </div>
        ) : isCancelled ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-sm text-red-400">
            This invoice has been cancelled
          </div>
        ) : isCreator ? (
          <div className="rounded-xl bg-amber-900/20 p-4 text-center text-xs text-amber-400">
            You created this invoice — share this link with your payer
          </div>
        ) : wrongPayer ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            This invoice is addressed to a specific wallet — connected wallet doesn't match
          </div>
        ) : !isConnected ? (
          <div className="rounded-xl bg-[#080D1B] p-4 text-center text-sm text-[#64748B]">
            <Wallet className="mx-auto mb-2 h-6 w-6" />
            Connect your wallet to pay this invoice
          </div>
        ) : (
          <>
            <Button className="w-full" size="lg" onClick={handlePay} disabled={paying}>
              {paying
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Processing…</>
                : `Pay ${formatAmount(invoice.amount)} ${invoice.currency}`
              }
            </Button>
            {error && (
              <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
                <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
              </div>
            )}
            <p className="mt-2 text-center text-[10px] text-[#64748B]">
              Payment sent on-chain via Arc with Memo reference {invoice.memo_ref}
            </p>
          </>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  pay/[ref]/page.tsx — public payment page"

# ============================================================
# 10 — Settlement reports page
# ============================================================
cat > "afrifx-web/app/(app)/settlements/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useSettlementReport } from '@/hooks/usePayments'
import { ClientOnly } from '@/components/ui/client-only'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { formatAmount } from '@/lib/utils'
import { Download, Loader2, TrendingUp, TrendingDown, ExternalLink } from 'lucide-react'

export default function SettlementsPage() {
  return <ClientOnly><SettlementsContent /></ClientOnly>
}

function SettlementsContent() {
  const { address }   = useAccount()
  const [range,       setRange] = useState('30')
  const [activeTab,   setTab]   = useState<'sent'|'received'|'invoices'|'transactions'>('sent')

  const now   = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  const { data, isLoading, refetch } = useSettlementReport(fromTs, now)

  function downloadCSV() {
    if (!data) return
    const rows: any[] = []
    const headers = ['Type','Reference','Amount','Currency','Counterparty','Date','Status','TxHash']
    rows.push(headers.join(','))

    data.payments.sent.forEach((p: any) => {
      rows.push([
        'Payment Sent', p.memo_ref, p.amount, p.currency,
        p.recipient_address, new Date(p.created_at*1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.payments.received.forEach((p: any) => {
      rows.push([
        'Payment Received', p.memo_ref, p.amount, p.currency,
        p.sender_address, new Date(p.created_at*1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.invoices.forEach((inv: any) => {
      rows.push([
        'Invoice', inv.memo_ref, inv.amount, inv.currency,
        inv.creator_address, new Date(inv.created_at*1000).toISOString(),
        inv.status, inv.payment_tx_hash ?? '',
      ].join(','))
    })
    data.transactions.forEach((tx: any) => {
      rows.push([
        'FX Conversion', tx.reference ?? tx.id, tx.from_amount, tx.from_currency,
        'AfriFX Vault', new Date((tx.created_at ?? tx[15])*1000).toISOString(),
        tx.status, tx.arc_tx_hash ?? '',
      ].join(','))
    })

    const csv  = rows.join('\n')
    const blob = new Blob([csv], { type: 'text/csv' })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href     = url
    a.download = `afrifx-settlements-${new Date().toISOString().slice(0,10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const tabData = {
    sent:         data?.payments.sent         ?? [],
    received:     data?.payments.received     ?? [],
    invoices:     data?.invoices              ?? [],
    transactions: data?.transactions          ?? [],
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Settlement reports</h1>
          <p className="text-sm text-[#64748B]">Full payment history and export</p>
        </div>
        <div className="flex gap-2">
          <select value={range} onChange={e => setRange(e.target.value)}
            className="rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#E2E8F0] outline-none">
            {[['7','Last 7 days'],['30','Last 30 days'],['90','Last 90 days'],['365','Last year']].map(([v,l]) => (
              <option key={v} value={v}>{l}</option>
            ))}
          </select>
          <Button size="sm" onClick={downloadCSV} disabled={!data}>
            <Download className="h-4 w-4" /> Export CSV
          </Button>
        </div>
      </div>

      {/* Summary */}
      {data && (
        <div className="mb-6 grid grid-cols-3 gap-4">
          {[
            { label: 'Total sent',     value: `$${formatAmount(data.summary.totalSent)}`,     icon: TrendingDown, color: 'text-red-400'     },
            { label: 'Total received', value: `$${formatAmount(data.summary.totalReceived)}`,  icon: TrendingUp,   color: 'text-emerald-400' },
            { label: 'Net position',   value: `${data.summary.netFlow>=0?'+':''}$${formatAmount(Math.abs(data.summary.netFlow))}`,
              icon: data.summary.netFlow >= 0 ? TrendingUp : TrendingDown,
              color: data.summary.netFlow >= 0 ? 'text-emerald-400' : 'text-red-400' },
          ].map(({ label, value, icon: Icon, color }) => (
            <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex items-center justify-between">
                <p className="text-xs text-[#64748B]">{label}</p>
                <Icon className={`h-4 w-4 ${color}`} />
              </div>
              <p className={`mt-1 font-mono text-xl font-bold ${color}`}>{value}</p>
            </div>
          ))}
        </div>
      )}

      {/* Tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {[
          ['sent',         'Sent'],
          ['received',     'Received'],
          ['invoices',     'Invoices'],
          ['transactions', 'FX conversions'],
        ].map(([t, l]) => (
          <button key={t} onClick={() => setTab(t as any)}
            className={`rounded-md px-3 py-1.5 text-xs transition-colors
              ${activeTab === t ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {l} {data ? `(${(tabData as any)[t].length})` : ''}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (tabData as any)[activeTab].length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-8 text-center text-sm text-[#64748B]">
          No {activeTab} in this period
        </div>
      ) : (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-[#1B2B4B] text-left text-xs text-[#64748B]">
                <th className="px-4 py-3 font-medium">Reference</th>
                <th className="px-4 py-3 font-medium">Amount</th>
                <th className="px-4 py-3 font-medium">Counterparty</th>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {(tabData as any)[activeTab].map((item: any) => {
                const ref    = item.memo_ref ?? item.reference ?? item.id?.slice(0,12)
                const amount = item.amount ?? item.from_amount
                const currency = item.currency ?? item.from_currency
                const counterparty = item.recipient_address ?? item.sender_address ?? item.creator_address ?? 'AfriFX'
                const date   = new Date((item.created_at || item[15] || 0) * 1000).toLocaleDateString()
                const status = item.status ?? 'settled'
                const hash   = item.arc_tx_hash ?? item.payment_tx_hash

                return (
                  <tr key={item.id} className="border-b border-[#1B2B4B]/50 last:border-0">
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#378ADD]">{ref}</span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#E2E8F0]">
                        {formatAmount(Number(amount))} {currency}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#64748B]">
                        {typeof counterparty === 'string' && counterparty.startsWith('0x')
                          ? counterparty.slice(0,8)+'…'
                          : counterparty
                        }
                      </span>
                    </td>
                    <td className="px-4 py-3 text-xs text-[#64748B]">{date}</td>
                    <td className="px-4 py-3">
                      <Badge variant={
                        status === 'settled' || status === 'paid' ? 'success' :
                        status === 'failed'  || status === 'cancelled' ? 'danger' : 'warning'
                      }>{status}</Badge>
                    </td>
                    <td className="px-4 py-3">
                      {hash && (
                        <a href={`https://testnet.arcscan.app/tx/${hash}`}
                          target="_blank" rel="noopener noreferrer"
                          className="text-[#64748B] hover:text-[#378ADD]">
                          <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  settlements/page.tsx — with CSV export"

# ============================================================
# 11 — Update Sidebar with new routes
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2, Shield, FileText,
  BarChart3, CreditCard,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsAdmin } from '@/hooks/useIsAdmin'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',  icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor', icon: Globe,          label: 'Corridor' },
    { href: '/send',     icon: Send,           label: 'Send'     },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Payments', items: [
    { href: '/invoices',    icon: FileText,  label: 'Invoices'    },
    { href: '/settlements', icon: BarChart3, label: 'Settlements' },
  ]},
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2, label: 'Treasury' },
    { href: '/treasury/payroll', icon: CreditCard, label: 'Payroll'  },
  ]},
  { label: 'Account', items: [
    { href: '/wallet',    icon: Wallet,          label: 'Wallet'    },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname          = usePathname()
  const { data: isAdmin } = useIsAdmin()

  return (
    <aside className="w-52 shrink-0 overflow-y-auto border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}

      {isAdmin && (
        <div className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            Admin
          </p>
          <Link href="/admin"
            className={cn(
              'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
              pathname.startsWith('/admin')
                ? 'bg-amber-900/30 font-medium text-amber-400'
                : 'text-amber-500/70 hover:bg-amber-900/20 hover:text-amber-400'
            )}>
            <Shield className="h-4 w-4 shrink-0" />
            Admin panel
          </Link>
        </div>
      )}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Invoices + Settlements links added"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 8 — Trade Settlement complete!"
echo ""
echo "  New pages:"
echo "  /invoices          — list all invoices + quick actions"
echo "  /invoices/create   — create invoice with Memo ref"
echo "  /invoices/:id      — detail + shareable payment link"
echo "  /pay/:ref          — public payment page for payer"
echo "  /settlements       — full settlement report + CSV export"
echo ""
echo "  Flow:"
echo "  1. Creator: /invoices/create → fills amount + description"
echo "  2. System generates INV-YYYYMMDD-XXXX Memo reference"
echo "  3. Creator copies /pay/:ref link → shares with payer"
echo "  4. Payer visits link → connects wallet → pays on-chain"
echo "  5. Invoice auto-updates to 'paid' after tx confirms"
echo "  6. Both see ArcScan link for settlement proof"
echo "  7. /settlements → CSV export for accounting"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
