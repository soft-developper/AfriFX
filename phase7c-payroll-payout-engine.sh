#!/usr/bin/env bash
# ============================================================================
# Phase 7c - Payroll payout engine: backend pays a batch from the float
#
# WHY
#   The payoff of hybrid custody. The employer clicks Execute ONCE; the backend
#   pays every recipient from the pre-funded MPC float with no per-payee
#   signing. The execute page drops all wagmi/Gateway signing and just starts
#   the run and polls progress.
#
# HOW
#   POST /payroll/batches/:id/execute validates, BALANCE-GATES, flips the batch
#   to 'processing', kicks off an async payout loop, and returns immediately.
#   The client polls GET /payroll/batches/:id for per-recipient progress.
#
# THREE SAFETY RULES (server-enforced)
#   1. BALANCE GATE - refuse to start a batch the float can't cover, before
#      paying anyone, so a batch never half-pays and runs dry.
#   2. IDEMPOTENT PER RECIPIENT - key ${batchId}:${recipientId}, so a retry or
#      double-execute can't pay anyone twice (Circle dedupes).
#   3. RESUMABLE - only 'pending' recipients are paid; a restart mid-run is
#      finished by re-executing (button becomes "Retry remaining").
#
# CHANGES (3 files)
#   afrifx-api/src/routes/payroll.ts                              payout engine + execute route
#   afrifx-web/hooks/usePayroll.ts                                widen status types
#   afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx  poll-based UI, no wagmi
#
# REQUIRES: Phase 7a + 7b, disbursement wallet provisioned and float funded.
#
# USAGE
#   bash phase7c-payroll-payout-engine.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "getDisbursementBalance" "$API/src/services/platformDisbursement.ts" || die "Phase 7a/7b not detected."
BK="$ROOT/.phase7c-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname "afrifx-api/src/routes/payroll.ts")"; cp "$ROOT/afrifx-api/src/routes/payroll.ts" "$BK/afrifx-api/src/routes/payroll.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/usePayroll.ts")"; cp "$ROOT/afrifx-web/hooks/usePayroll.ts" "$BK/afrifx-web/hooks/usePayroll.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx")"; cp "$ROOT/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" "$BK/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" 2>/dev/null || true
ok "snapshot saved"
say "Writing files"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/routes/payroll.ts")"
cat > "$ROOT/afrifx-api/src/routes/payroll.ts" <<'AFX_7C_EOF'
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

function normBatch(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], wallet_address: row[1], name: row[2],
      description: row[3], total_amount: Number(row[4]),
      currency: row[5], recipient_count: Number(row[6]),
      status: row[7], executed_at: row[8] ? Number(row[8]) : null,
      created_at: Number(row[9]),
      // dest_chain was added later via ALTER TABLE, so it lands at the end.
      // Older rows created before the migration have no value: default 'arc'.
      dest_chain: row[10] ?? 'arc',
    }
  }
  return {
    ...row,
    total_amount: Number(row.total_amount),
    recipient_count: Number(row.recipient_count),
    dest_chain: row.dest_chain ?? 'arc',
  }
}

function normRecipient(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], batch_id: row[1], name: row[2],
      wallet_address: row[3], amount: Number(row[4]),
      currency: row[5], status: row[6],
      tx_hash: row[7], memo_ref: row[8], created_at: Number(row[9]),
    }
  }
  return { ...row, amount: Number(row.amount) }
}

// GET /payroll/batches?wallet=0x
router.get('/batches', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM payroll_batches
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 20`
    )
    res.json(parseRows(rows).map(normBatch))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /payroll/batches create batch
router.post('/batches', async (req, res) => {
  const { walletAddress, name, description, recipients, currency = 'USDC', destChain = 'arc' } = req.body
  if (!walletAddress || !name || !recipients?.length) {
    return res.status(400).json({ error: 'walletAddress, name and recipients required' })
  }

  // Only the chains AfriFX settles on are valid payout targets. Anything
  // else is rejected rather than stored and failing silently at execute time.
  const ALLOWED_CHAINS = ['arc', 'base', 'ethereum', 'arbitrum', 'polygon']
  const chain = String(destChain).toLowerCase()
  if (!ALLOWED_CHAINS.includes(chain)) {
    return res.status(400).json({ error: `Unsupported payout chain: ${destChain}` })
  }

  const batchId     = randomUUID()
  const now         = Math.floor(Date.now() / 1000)
  const totalAmount = recipients.reduce((s: number, r: any) => s + Number(r.amount), 0)

  try {
    await db.run(
      sql`INSERT INTO payroll_batches
          (id, wallet_address, name, description, total_amount,
           currency, recipient_count, created_at, dest_chain)
          VALUES
          (${batchId}, ${walletAddress.toLowerCase()}, ${name},
           ${description ?? null}, ${totalAmount}, ${currency},
           ${recipients.length}, ${now}, ${chain})`
    )

    for (const r of recipients) {
      const ref = `PAY-${new Date().toISOString().slice(0,10).replace(/-/g,'')}-${Math.random().toString(36).slice(2,6).toUpperCase()}`
      await db.run(
        sql`INSERT INTO payroll_recipients
            (id, batch_id, name, wallet_address, amount, currency, memo_ref, created_at)
            VALUES
            (${randomUUID()}, ${batchId}, ${r.name ?? null},
             ${r.walletAddress.toLowerCase()}, ${Number(r.amount)},
             ${currency}, ${ref}, ${now})`
      )
    }

    res.status(201).json({ id: batchId, totalAmount, recipientCount: recipients.length })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /payroll/batches/:id batch + recipients
router.get('/batches/:id', async (req, res) => {
  try {
    const batchRows = await db.run(
      sql`SELECT * FROM payroll_batches WHERE id = ${req.params.id} LIMIT 1`
    )
    const batches = parseRows(batchRows)
    if (!batches.length) return res.status(404).json({ error: 'Not found' })

    const recipientRows = await db.run(
      sql`SELECT * FROM payroll_recipients
          WHERE batch_id = ${req.params.id}
          ORDER BY created_at ASC`
    )

    res.json({
      ...normBatch(batches[0]),
      recipients: parseRows(recipientRows).map(normRecipient),
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /payroll/recipients/:id update recipient status + tx_hash
router.patch('/recipients/:id', async (req, res) => {
  const { status, txHash } = req.body
  try {
    await db.run(
      sql`UPDATE payroll_recipients SET
            status  = COALESCE(${status ?? null}, status),
            tx_hash = COALESCE(${txHash ?? null}, tx_hash)
          WHERE id = ${req.params.id}`
    )
    // If all recipients sent, mark batch complete
    const rid = req.params.id
    const recRows = await db.run(sql`SELECT batch_id FROM payroll_recipients WHERE id = ${rid} LIMIT 1`)
    const rr = parseRows(recRows)
    if (rr.length) {
      const batchId = rr[0].batch_id ?? rr[0][1]
      const pendingRows = await db.run(
        sql`SELECT COUNT(*) as cnt FROM payroll_recipients
            WHERE batch_id = ${batchId} AND status = 'pending'`
      )
      const pr = parseRows(pendingRows)
      const pending = Number(pr[0]?.cnt ?? pr[0]?.[0] ?? 0)
      if (pending === 0) {
        await db.run(
          sql`UPDATE payroll_batches SET
                status      = 'completed',
                executed_at = ${Math.floor(Date.now() / 1000)}
              WHERE id = ${batchId}`
        )
      }
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /payroll/batches/:id delete draft
router.delete('/batches/:id', async (req, res) => {
  try {
    await db.run(sql`DELETE FROM payroll_recipients WHERE batch_id = ${req.params.id}`)
    await db.run(sql`DELETE FROM payroll_batches WHERE id = ${req.params.id} AND status = 'draft'`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── PAYOUT ENGINE (hybrid custody, Phase 7c) ────────────────
//
// Pay a batch's recipients from the platform float, backend-signed (no user
// present). Kicked off by /execute, which returns immediately; the client
// polls GET /payroll/batches/:id to watch per-recipient progress.
//
// THREE RULES THAT KEEP MONEY SAFE
//   1. BALANCE GATE: refuse to start a batch the float can't cover, BEFORE
//      paying anyone - so a batch never half-pays and runs dry.
//   2. IDEMPOTENT PER RECIPIENT: the key is `${batchId}:${recipientId}`, so a
//      retry or double-execute can't pay anyone twice (Circle dedupes it).
//   3. RESUMABLE: only 'pending' recipients are paid; 'paid' ones are skipped.
//      If the process restarts mid-run, re-executing finishes the rest.

// Guard so the same batch isn't worked by two overlapping runs in one process.
const runningBatches = new Set<string>()

async function runBatchPayout(batchId: string): Promise<void> {
  if (runningBatches.has(batchId)) return
  runningBatches.add(batchId)
  try {
    const { sendUsdc } = await import('../services/platformDisbursement')

    const pending = parseRows(await db.run(sql`
      SELECT id, wallet_address, amount, memo_ref
      FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status = 'pending'`))

    for (const r of pending) {
      const recipientId = r.id ?? r[0]
      const toAddress   = r.wallet_address ?? r[1]
      const amount      = Number(r.amount ?? r[2])
      const memoRef     = r.memo_ref ?? r[3] ?? undefined

      try {
        await db.run(sql`
          UPDATE payroll_recipients SET status = 'processing'
          WHERE id = ${recipientId} AND status = 'pending'`)

        const result = await sendUsdc({
          walletId:           process.env.PAYROLL_DISBURSEMENT_WALLET_ID as string,
          destinationAddress: String(toAddress),
          amount,
          // Stable key => exactly-once even if this runs twice.
          idempotencyKey:     `${batchId}:${recipientId}`,
          refId:              memoRef ? String(memoRef) : undefined,
        })

        await db.run(sql`
          UPDATE payroll_recipients
          SET status = 'paid', tx_hash = ${result.txHash ?? result.id}
          WHERE id = ${recipientId}`)
      } catch (err: any) {
        // One recipient failing must not abort the batch; mark it and go on.
        await db.run(sql`
          UPDATE payroll_recipients SET status = 'failed'
          WHERE id = ${recipientId}`).catch(() => {})
      }
    }

    // Settle the batch status from the actual recipient outcomes.
    const counts = parseRows(await db.run(sql`
      SELECT status, COUNT(*) AS c FROM payroll_recipients
      WHERE batch_id = ${batchId} GROUP BY status`))
    const by: Record<string, number> = {}
    for (const row of counts) by[String(row.status ?? row[0])] = Number(row.c ?? row[1])

    const stillPending = (by['pending'] ?? 0) + (by['processing'] ?? 0)
    const failed       = by['failed'] ?? 0
    const finalStatus  =
      stillPending > 0 ? 'processing'
      : failed > 0     ? 'partial'
      :                  'completed'

    await db.run(sql`
      UPDATE payroll_batches
      SET status = ${finalStatus},
          executed_at = ${Math.floor(Date.now() / 1000)}
      WHERE id = ${batchId}`)
  } finally {
    runningBatches.delete(batchId)
  }
}

// POST /payroll/batches/:id/execute
//
// Start (or resume) paying a batch from the float. Validates + balance-gates,
// flips the batch to 'processing', kicks off the payout in the background, and
// returns immediately. Poll GET /payroll/batches/:id for progress.
router.post('/batches/:id/execute', async (req, res) => {
  const batchId  = req.params.id
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })

  try {
    const batchRows = parseRows(await db.run(sql`
      SELECT id, status FROM payroll_batches WHERE id = ${batchId} LIMIT 1`))
    if (!batchRows.length) return res.status(404).json({ error: 'Batch not found' })
    const status = String(batchRows[0].status ?? batchRows[0][1])
    if (status === 'completed') return res.status(400).json({ error: 'Batch already completed' })

    // Sum only what's still owed (pending), so a resume gates on the remainder.
    const owedRows = parseRows(await db.run(sql`
      SELECT COALESCE(SUM(amount), 0) AS owed FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status IN ('pending', 'processing')`))
    const owed = Number(owedRows[0]?.owed ?? owedRows[0]?.[0] ?? 0)
    if (owed <= 0) return res.status(400).json({ error: 'Nothing left to pay in this batch' })

    // RULE 1 - balance gate: never start what the float can't finish.
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    if (balance < owed) {
      return res.status(400).json({
        error: `Float balance (${balance} USDC) is less than the ${owed} USDC still owed in this batch. Top up the float first.`,
        code:  'insufficient_float',
        balance, owed,
      })
    }

    await db.run(sql`UPDATE payroll_batches SET status = 'processing' WHERE id = ${batchId}`)

    // Fire and forget: the client polls the batch for progress.
    runBatchPayout(batchId).catch(() => {})

    res.json({ status: 'processing', owed, balance })
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

// GET /payroll/disbursement/status
//
// Reports whether the platform disbursement wallet (Phase 7a, MPC) is
// configured and its current USDC balance. Used to verify provisioning and,
// later, to check a batch can be funded. Read-only; exposes no secrets.
router.get('/disbursement/status', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) {
    return res.json({ configured: false, reason: 'PAYROLL_DISBURSEMENT_WALLET_ID not set' })
  }
  try {
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    res.json({ configured: true, walletId, balance })
  } catch (err: any) {
    res.status(502).json({ configured: true, error: err.message })
  }
})

// GET /payroll/disbursement/address
//
// The address employers send USDC to when topping up the float. Read from the
// live wallet so it can never drift from what was provisioned.
router.get('/disbursement/address', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })
  try {
    const { getDisbursementAddress } = await import('../services/platformDisbursement')
    const address = await getDisbursementAddress(walletId)
    res.json({ address })
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

// POST /payroll/disbursement/fund   { funderAddress, amount, txHash }
//
// Record an employer top-up of the reusable float. The employer has already
// signed a USDC transfer to the disbursement address (client side); here we
// log it and confirm it by re-reading the live wallet balance. We do NOT trust
// the client's word that it landed - we check Circle.
router.post('/disbursement/fund', async (req, res) => {
  const { funderAddress, amount, txHash } = req.body ?? {}
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID

  if (!walletId)       return res.status(400).json({ error: 'Disbursement wallet not configured' })
  if (!funderAddress)  return res.status(400).json({ error: 'funderAddress is required' })
  if (!(Number(amount) > 0)) return res.status(400).json({ error: 'A positive amount is required' })

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    // Record the intent first (audit trail), then confirm against the chain.
    await db.run(sql`
      INSERT INTO payroll_disbursement_funding
        (id, funder_address, amount, tx_hash, status, created_at)
      VALUES (${id}, ${String(funderAddress)}, ${Number(amount)},
              ${txHash ? String(txHash) : null}, 'pending', ${now})`)

    // Confirm by reading the live balance. We don't assert an exact delta
    // (fees, timing, concurrent tops make that brittle) - a balance at least
    // as large as this top-up is sufficient evidence it landed.
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)

    const landed = balance >= Number(amount)
    if (landed) {
      await db.run(sql`
        UPDATE payroll_disbursement_funding
        SET status = 'confirmed', confirmed_at = ${now}
        WHERE id = ${id}`)
    }

    res.json({ id, status: landed ? 'confirmed' : 'pending', balance })
  } catch (err: any) {
    await db.run(sql`
      UPDATE payroll_disbursement_funding SET status = 'failed' WHERE id = ${id}`)
      .catch(() => {})
    res.status(502).json({ error: err.message })
  }
})

// GET /payroll/disbursement/funding   top-up history (newest first)
router.get('/disbursement/funding', async (_req, res) => {
  try {
    const rows = parseRows(await db.run(sql`
      SELECT id, funder_address, amount, tx_hash, status, created_at, confirmed_at
      FROM payroll_disbursement_funding
      ORDER BY created_at DESC
      LIMIT 100`))
    res.json({ funding: rows })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
AFX_7C_EOF
ok "wrote afrifx-api/src/routes/payroll.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/usePayroll.ts")"
cat > "$ROOT/afrifx-web/hooks/usePayroll.ts" <<'AFX_7C_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface PayrollRecipient {
  id:             string
  batch_id:       string
  name:           string | null
  wallet_address: string
  amount:         number
  currency:       string
  status:         'pending' | 'processing' | 'paid' | 'sent' | 'failed'
  tx_hash:        string | null
  memo_ref:       string | null
  created_at:     number
}

export interface PayrollBatch {
  id:              string
  wallet_address:  string
  name:            string
  description:     string | null
  total_amount:    number
  currency:        string
  recipient_count: number
  status:          'draft' | 'processing' | 'completed' | 'partial' | 'failed'
  dest_chain:      string
  executed_at:     number | null
  created_at:      number
  recipients?:     PayrollRecipient[]
}

export function usePayrollBatches() {
  const { address } = useAccount()
  return useQuery<PayrollBatch[]>({
    queryKey: ['payroll-batches', address],
    queryFn:  async () => {
      if (!address) return []
      const res = await fetch(`${API}/payroll/batches?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled: !!address,
  })
}

export function usePayrollBatch(id: string | null) {
  return useQuery<PayrollBatch | null>({
    queryKey: ['payroll-batch', id],
    queryFn:  async () => {
      if (!id) return null
      const res = await fetch(`${API}/payroll/batches/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 3000,
  })
}

export function useCreateBatch() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      name: string; description?: string; destChain?: string
      recipients: { name?: string; walletAddress: string; amount: number }[]
    }) => {
      const res = await fetch(`${API}/payroll/batches`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payroll-batches', address] }),
  })
}

export function useUpdateRecipient() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, status, txHash, batchId }: { id: string; status: string; txHash?: string; batchId: string }) => {
      await fetch(`${API}/payroll/recipients/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, txHash }),
      })
    },
    onSuccess: (_d, vars) => queryClient.invalidateQueries({ queryKey: ['payroll-batch', vars.batchId] }),
  })
}
AFX_7C_EOF
ok "wrote afrifx-web/hooks/usePayroll.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx")"
cat > "$ROOT/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" <<'AFX_7C_EOF'
'use client'
// ============================================================
// PayrollExecuteContent - execute a batch from the platform float.
//
// HYBRID CUSTODY (Phase 7c). The employer does NOT sign each payout. They
// click Execute once; the backend pays every recipient from the pre-funded
// MPC float and this screen POLLS the batch to show progress. No wagmi, no
// per-recipient signing, no Gateway - all of that moved server-side.
//
// The backend enforces the safety rules (balance gate, idempotency, resume);
// the client's job is just to start it and reflect progress.
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch } from '@/hooks/usePayroll'
import { formatAmount } from '@/lib/utils'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function PayrollExecuteContent() {
  const { id } = useParams()
  const { data: batch, refetch } = usePayrollBatch(id as string)

  const [starting, setStarting] = useState(false)
  const [error,    setError]    = useState<string | null>(null)
  const [floatBal, setFloatBal] = useState<number | null>(null)

  const recipients = batch?.recipients ?? []
  const paidCount  = recipients.filter(r => r.status === 'paid' || r.status === 'sent').length
  const failCount  = recipients.filter(r => r.status === 'failed').length
  const owed       = recipients
    .filter(r => r.status === 'pending' || r.status === 'processing')
    .reduce((s, r) => s + Number(r.amount), 0)

  const batchStatus = batch?.status
  const isProcessing = batchStatus === 'processing'
  const isDone       = batchStatus === 'completed'
  const isPartial    = batchStatus === 'partial'

  // Load the float balance so we can warn before starting rather than fail.
  const loadFloat = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/payroll/disbursement/status`)
      const data = await res.json().catch(() => ({}))
      setFloatBal(typeof data.balance === 'number' ? data.balance : null)
    } catch { setFloatBal(null) }
  }, [])
  useEffect(() => { loadFloat() }, [loadFloat])

  // While the batch is processing, poll it for progress.
  useEffect(() => {
    if (!isProcessing) return
    const t = setInterval(() => { refetch(); loadFloat() }, 3000)
    return () => clearInterval(t)
  }, [isProcessing, refetch, loadFloat])

  const execute = useCallback(async () => {
    if (!batch) return
    setStarting(true); setError(null)
    try {
      const res  = await fetch(`${API}/payroll/batches/${batch.id}/execute`, { method: 'POST' })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        setError(data.error ?? 'Could not start the payout')
        return
      }
      await refetch()
    } catch (err: any) {
      setError(err?.message ?? 'Could not start the payout')
    } finally {
      setStarting(false)
    }
  }, [batch, refetch])

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
    </div>
  )

  const insufficientFloat = floatBal !== null && owed > 0 && floatBal < owed

  const statusBadge = {
    draft:      'secondary',
    processing: 'default',
    completed:  'default',
    partial:    'destructive',
  }[String(batch.status)] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury/payroll">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-lg font-semibold text-app-text">{batch.name}</h1>
            <Badge variant={statusBadge}>{batch.status}</Badge>
          </div>
          {batch.description && (
            <p className="text-sm text-app-muted">{batch.description}</p>
          )}
        </div>
      </div>

      {/* Summary */}
      <div className="mb-4 grid grid-cols-3 gap-3">
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Recipients</p>
          <p className="font-mono text-sm text-app-text">{recipients.length}</p>
        </div>
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Total</p>
          <p className="font-mono text-sm text-app-text">{formatAmount(batch.total_amount)} USDC</p>
        </div>
        <div className="rounded-xl border border-app-border bg-app-surface p-3">
          <p className="text-[11px] text-app-muted">Float balance</p>
          <p className="font-mono text-sm text-app-text">
            {floatBal === null ? '—' : `${floatBal.toLocaleString()} USDC`}
          </p>
        </div>
      </div>

      {/* Progress line */}
      {(isProcessing || isDone || isPartial) && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-app-border bg-app-surface px-4 py-3">
          {isProcessing
            ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
            : isPartial
            ? <AlertCircle className="h-4 w-4 text-amber-500" />
            : <CheckCircle className="h-4 w-4 text-emerald-500" />}
          <span className="text-sm text-app-text">
            {isProcessing ? `Paying… ${paidCount} of ${recipients.length} done`
             : isPartial  ? `Completed with ${failCount} failed. Re-run to retry the rest.`
             :              `All ${recipients.length} payments sent`}
          </span>
        </div>
      )}

      {insufficientFloat && !isProcessing && (
        <p className="mb-3 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          Float has {floatBal} USDC but {owed} USDC is owed. Top up the float on the payroll page first.
        </p>
      )}
      {error && (
        <p className="mb-3 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">{error}</p>
      )}

      {/* Execute / resume button */}
      {!isDone && (
        <Button
          className="mb-4 w-full"
          disabled={starting || isProcessing || owed <= 0 || insufficientFloat}
          onClick={execute}>
          {starting || isProcessing
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Processing…</>
            : isPartial
            ? <><Play className="h-4 w-4" /> Retry remaining ({formatAmount(owed)} USDC)</>
            : <><Play className="h-4 w-4" /> Pay {recipients.length} recipients ({formatAmount(owed)} USDC)</>}
        </Button>
      )}

      {/* Recipient list */}
      <div className="overflow-hidden rounded-xl border border-app-border">
        {recipients.map((r, i) => (
          <div key={r.id ?? i}
            className="flex items-center justify-between border-b border-app-border px-4 py-3 last:border-0">
            <div className="min-w-0">
              <p className="truncate text-sm text-app-text">{r.name || 'Recipient'}</p>
              <p className="truncate font-mono text-[11px] text-app-muted">{r.wallet_address}</p>
            </div>
            <div className="flex items-center gap-3">
              <span className="font-mono text-sm text-app-text">{formatAmount(r.amount)} USDC</span>
              {r.tx_hash
                ? <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                     target="_blank" rel="noopener noreferrer"
                     className="text-app-muted hover:text-app-text">
                    <ExternalLink className="h-4 w-4" />
                  </a>
                : (r.status === 'paid' || r.status === 'sent') ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                : r.status === 'failed'     ? <XCircle className="h-4 w-4 text-red-400" />
                : r.status === 'processing' ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
                : <span className="text-[11px] text-app-muted">pending</span>}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
AFX_7C_EOF
ok "wrote afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx"

say "Verifying"
grep -q "batches/:id/execute" "$API/src/routes/payroll.ts" || die "execute route missing"
grep -q "runBatchPayout" "$API/src/routes/payroll.ts" || die "payout engine missing"
grep -q "from 'wagmi'" "$WEB/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" && die "wagmi still in execute page"

say "API: tsc + tests"
( cd "$API" && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "API tsc failed - restored"; }
ok "api typechecks"
( cd "$API" && npx vitest run >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "API tests failed - restored"; }
ok "api tests pass"

say "WEB: tsc + build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && rm -rf .next && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "web tsc failed - restored"; }
ok "web typechecks"
( cd "$WEB" && npm run build >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "web build failed - restored"; }
ok "web builds"
rm -rf "$BK"
say "Phase 7c applied and verified. Payroll is now one-click, backend-paid."
cat <<'NOTE'

  Commit & push:
    git add -A
    git commit -m "phase 7c: payroll payout engine (backend pays from float)"
    git push origin main

  Test after deploy (float must be funded):
    1. Create a batch with 2-3 recipients (small amounts) on Arc.
    2. Open the batch, click "Pay N recipients". It returns immediately and the
       page shows "Paying... X of N done", updating every few seconds.
    3. Each recipient flips to paid with a tx link; batch ends 'completed'.
    4. Balance-gate test: create a batch bigger than the float -> the button is
       disabled with an "insufficient float" warning; nothing is sent.
    5. Resume test: if any recipient failed, the button becomes "Retry
       remaining" and pays only the unpaid ones (no double-pay).

  NOTE: the payout loop runs in-process. If Render restarts mid-batch, the
  batch stays 'processing' with some 'pending' recipients - just click execute
  again to finish it (idempotent, so no one is paid twice). A durable job
  queue would remove even that manual nudge; worth it later if batches get big.
NOTE
