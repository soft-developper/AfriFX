#!/bin/bash
# ============================================================
# AfriFX — Business Treasury + Payroll
# Run from ~/AfriFX:  bash treasury-payroll.sh
# ============================================================
set -e
echo ""
echo "🏦  Building Business Treasury + Payroll..."
echo ""

# ============================================================
# 1 — Turso migrations
# ============================================================
echo "  Creating treasury tables..."

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS treasury_rules (
  id                TEXT PRIMARY KEY,
  wallet_address    TEXT NOT NULL,
  name              TEXT NOT NULL,
  trigger_threshold REAL NOT NULL,
  action_percent    REAL,
  action_amount     REAL,
  target_currency   TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'active',
  last_triggered    INTEGER,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);" && echo "  ✅  treasury_rules"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS payroll_batches (
  id               TEXT PRIMARY KEY,
  wallet_address   TEXT NOT NULL,
  name             TEXT NOT NULL,
  description      TEXT,
  total_amount     REAL NOT NULL DEFAULT 0,
  currency         TEXT NOT NULL DEFAULT 'USDC',
  recipient_count  INTEGER NOT NULL DEFAULT 0,
  status           TEXT NOT NULL DEFAULT 'draft',
  executed_at      INTEGER,
  created_at       INTEGER NOT NULL
);" && echo "  ✅  payroll_batches"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS payroll_recipients (
  id             TEXT PRIMARY KEY,
  batch_id       TEXT NOT NULL,
  name           TEXT,
  wallet_address TEXT NOT NULL,
  amount         REAL NOT NULL,
  currency       TEXT NOT NULL DEFAULT 'USDC',
  status         TEXT NOT NULL DEFAULT 'pending',
  tx_hash        TEXT,
  memo_ref       TEXT,
  created_at     INTEGER NOT NULL
);" && echo "  ✅  payroll_recipients"

echo "✅  All treasury tables created"

# ============================================================
# 2 — Backend: treasury routes (rules)
# ============================================================
cat > afrifx-api/src/routes/treasury.ts << '__EOF__'
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

function normRule(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], wallet_address: row[1], name: row[2],
      trigger_threshold: Number(row[3]),
      action_percent: row[4] != null ? Number(row[4]) : null,
      action_amount:  row[5] != null ? Number(row[5]) : null,
      target_currency: row[6], status: row[7],
      last_triggered: row[8] ? Number(row[8]) : null,
      created_at: Number(row[9]), updated_at: Number(row[10]),
    }
  }
  return {
    ...row,
    trigger_threshold: Number(row.trigger_threshold),
    action_percent:    row.action_percent != null ? Number(row.action_percent) : null,
    action_amount:     row.action_amount  != null ? Number(row.action_amount)  : null,
  }
}

// GET /treasury/rules?wallet=0x
router.get('/rules', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM treasury_rules
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC`
    )
    res.json(parseRows(rows).map(normRule))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /treasury/rules — create rule
router.post('/rules', async (req, res) => {
  const {
    walletAddress, name,
    triggerThreshold, actionPercent, actionAmount,
    targetCurrency,
  } = req.body

  if (!walletAddress || !name || !triggerThreshold || !targetCurrency) {
    return res.status(400).json({ error: 'Missing required fields' })
  }

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO treasury_rules
          (id, wallet_address, name, trigger_threshold,
           action_percent, action_amount, target_currency,
           created_at, updated_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()}, ${name},
           ${triggerThreshold}, ${actionPercent ?? null}, ${actionAmount ?? null},
           ${targetCurrency}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /treasury/rules/:id — toggle status / update
router.patch('/rules/:id', async (req, res) => {
  const { status, lastTriggered } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE treasury_rules SET
            status         = COALESCE(${status         ?? null}, status),
            last_triggered = COALESCE(${lastTriggered  ?? null}, last_triggered),
            updated_at     = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /treasury/rules/:id
router.delete('/rules/:id', async (req, res) => {
  try {
    await db.run(sql`DELETE FROM treasury_rules WHERE id = ${req.params.id}`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/treasury.ts"

# ============================================================
# 3 — Backend: payroll routes
# ============================================================
cat > afrifx-api/src/routes/payroll.ts << '__EOF__'
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
    }
  }
  return { ...row, total_amount: Number(row.total_amount), recipient_count: Number(row.recipient_count) }
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

// POST /payroll/batches — create batch
router.post('/batches', async (req, res) => {
  const { walletAddress, name, description, recipients, currency = 'USDC' } = req.body
  if (!walletAddress || !name || !recipients?.length) {
    return res.status(400).json({ error: 'walletAddress, name and recipients required' })
  }

  const batchId     = randomUUID()
  const now         = Math.floor(Date.now() / 1000)
  const totalAmount = recipients.reduce((s: number, r: any) => s + Number(r.amount), 0)

  try {
    await db.run(
      sql`INSERT INTO payroll_batches
          (id, wallet_address, name, description, total_amount,
           currency, recipient_count, created_at)
          VALUES
          (${batchId}, ${walletAddress.toLowerCase()}, ${name},
           ${description ?? null}, ${totalAmount}, ${currency},
           ${recipients.length}, ${now})`
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

// GET /payroll/batches/:id — batch + recipients
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

// PATCH /payroll/recipients/:id — update recipient status + tx_hash
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

// DELETE /payroll/batches/:id — delete draft
router.delete('/batches/:id', async (req, res) => {
  try {
    await db.run(sql`DELETE FROM payroll_recipients WHERE batch_id = ${req.params.id}`)
    await db.run(sql`DELETE FROM payroll_batches WHERE id = ${req.params.id} AND status = 'draft'`)
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/payroll.ts"

# ============================================================
# 4 — Register routes
# ============================================================
cat > afrifx-api/src/index.ts << '__EOF__'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import walletRouter               from './routes/wallet'
import treasuryRouter             from './routes/treasury'
import payrollRouter              from './routes/payroll'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',        ratesRouter)
app.use('/transactions', transactionsRouter)
app.use('/user',         userRouter)
app.use('/offers',       offersRouter)
app.use('/profile',      profileRouter)
app.use('/chat',         chatRouter)
app.use('/wallet',       walletRouter)
app.use('/treasury',     treasuryRouter)
app.use('/payroll',      payrollRouter)

app.use(errorHandler)

app.listen(PORT, () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
  startTreasuryChecker()
})
__EOF__
echo "✅  index.ts — treasury + payroll routes registered"

# ============================================================
# 5 — Treasury checker job (runs every hour)
# ============================================================
cat > afrifx-api/src/jobs/treasuryChecker.ts << '__EOF__'
// Checks auto-conversion rules every hour
// Marks triggered rules — user executes manually (no stored keys)
import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { createPublicClient, http, formatUnits } from 'viem'

const ARC_RPC   = process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
const USDC_ADDR = '0x3600000000000000000000000000000000000000' as const
const ERC20_ABI = [{
  name: 'balanceOf', type: 'function', stateMutability: 'view',
  inputs: [{ name: 'account', type: 'address' }],
  outputs: [{ name: '', type: 'uint256' }],
}] as const

const arcClient = createPublicClient({
  transport: http(ARC_RPC),
  chain: {
    id: 5042002, name: 'Arc Testnet',
    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },
    rpcUrls: { default: { http: [ARC_RPC] } },
  } as any,
})

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startTreasuryChecker() {
  console.log('[TreasuryChecker] ✅ Started — checks every hour')

  // Run every hour
  cron.schedule('0 * * * *', checkRules)

  // Also run 30s after boot
  setTimeout(checkRules, 30_000)
}

async function checkRules() {
  try {
    const rows = await db.run(
      sql`SELECT * FROM treasury_rules WHERE status = 'active'`
    )
    const rules = parseRows(rows)
    if (!rules.length) return

    const now = Math.floor(Date.now() / 1000)

    for (const r of rules) {
      const id        = r.id            ?? r[0]
      const wallet    = r.wallet_address ?? r[1]
      const threshold = Number(r.trigger_threshold ?? r[3])

      try {
        // Check on-chain USDC balance
        const raw      = await arcClient.readContract({
          address:      USDC_ADDR,
          abi:          ERC20_ABI,
          functionName: 'balanceOf',
          args:         [wallet as `0x${string}`],
        }).catch(() => 0n)

        const balance = parseFloat(formatUnits(BigInt(raw), 6))

        if (balance >= threshold) {
          await db.run(
            sql`UPDATE treasury_rules SET
                  status         = 'triggered',
                  last_triggered = ${now}
                WHERE id = ${id}`
          )
          console.log(`[TreasuryChecker] ⚡ Rule triggered for ${wallet.slice(0,10)}… — balance ${balance} >= ${threshold}`)
        }
      } catch {}
    }
  } catch (err: any) {
    console.error('[TreasuryChecker] Error:', err.message)
  }
}
__EOF__
echo "✅  jobs/treasuryChecker.ts"

# ============================================================
# 6 — Frontend hooks
# ============================================================
cat > afrifx-web/hooks/useTreasury.ts << '__EOF__'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TreasuryRule {
  id:                string
  wallet_address:    string
  name:              string
  trigger_threshold: number
  action_percent:    number | null
  action_amount:     number | null
  target_currency:   string
  status:            'active' | 'paused' | 'triggered'
  last_triggered:    number | null
  created_at:        number
}

export function useTreasuryRules() {
  const { address } = useAccount()
  return useQuery<TreasuryRule[]>({
    queryKey:        ['treasury-rules', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/treasury/rules?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}

export function useCreateRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: Omit<TreasuryRule, 'id'|'wallet_address'|'status'|'last_triggered'|'created_at'>) => {
      const res = await fetch(`${API}/treasury/rules`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useToggleRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => {
      await fetch(`${API}/treasury/rules/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status }),
      })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useDeleteRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (id: string) => {
      await fetch(`${API}/treasury/rules/${id}`, { method: 'DELETE' })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}
__EOF__
echo "✅  hooks/useTreasury.ts"

cat > afrifx-web/hooks/usePayroll.ts << '__EOF__'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface PayrollRecipient {
  id:             string
  batch_id:       string
  name:           string | null
  wallet_address: string
  amount:         number
  currency:       string
  status:         'pending' | 'sent' | 'failed'
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
  status:          'draft' | 'processing' | 'completed' | 'failed'
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
      name: string; description?: string
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
__EOF__
echo "✅  hooks/usePayroll.ts"

# ============================================================
# 7 — Frontend: Treasury page
# ============================================================
mkdir -p "afrifx-web/app/(app)/treasury"

cat > "afrifx-web/app/(app)/treasury/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { TreasuryContent } from './TreasuryContent'

export default function TreasuryPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="grid gap-4 lg:grid-cols-2">
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        </div>
      </div>
    }>
      <TreasuryContent />
    </ClientOnly>
  )
}
__EOF__

cat > "afrifx-web/app/(app)/treasury/TreasuryContent.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useWallet } from '@/hooks/useWallet'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { useTreasuryRules, useCreateRule, useToggleRule, useDeleteRule } from '@/hooks/useTreasury'
import { useFXRates } from '@/hooks/useFXRate'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Zap, Trash2, Pause, Play,
  AlertTriangle, ArrowRight, Users, Building2,
  ChevronDown, ChevronUp, ExternalLink,
} from 'lucide-react'

const CURRENCIES  = ['NGN','GHS','KES','ZAR','EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬'
}

export function TreasuryContent() {
  const { address }               = useAccount()
  const router                    = useRouter()
  const { data: wallet }          = useWallet()
  const { data: rules = [] }      = useTreasuryRules()
  const { data: batches = [] }    = usePayrollBatches()
  const { data: rates = [] }      = useFXRates()
  const createRule                = useCreateRule()
  const toggleRule                = useToggleRule()
  const deleteRule                = useDeleteRule()

  const [showRuleForm, setShowRuleForm] = useState(false)
  const [ruleName,     setRuleName]     = useState('')
  const [threshold,    setThreshold]    = useState('')
  const [actionType,   setActionType]   = useState<'percent'|'fixed'>('percent')
  const [actionVal,    setActionVal]    = useState('')
  const [targetCcy,    setTargetCcy]    = useState('NGN')

  const usdcBalance = wallet?.tokens.find(t => t.symbol === 'USDC')?.balance ?? 0
  const escrowLocked = wallet?.escrow.locked ?? 0
  const triggeredRules = rules.filter(r => r.status === 'triggered')

  async function handleCreateRule() {
    if (!ruleName || !threshold || !actionVal) return
    await createRule.mutateAsync({
      name:              ruleName,
      trigger_threshold: parseFloat(threshold),
      action_percent:    actionType === 'percent' ? parseFloat(actionVal) : null,
      action_amount:     actionType === 'fixed'   ? parseFloat(actionVal) : null,
      target_currency:   targetCcy,
    })
    setRuleName(''); setThreshold(''); setActionVal('')
    setShowRuleForm(false)
  }

  function getConversionAmount(rule: typeof rules[0]): number {
    if (rule.action_percent) return usdcBalance * (rule.action_percent / 100)
    return rule.action_amount ?? 0
  }

  function getLocalEquiv(usdcAmt: number, currency: string): string {
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate) return '—'
    return (usdcAmt / rate).toLocaleString(undefined, { maximumFractionDigits: 0 })
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Business Treasury</h1>
          <p className="text-sm text-[#64748B]">Automate conversions · manage payroll · track funds</p>
        </div>
        <Link href="/treasury/payroll">
          <Button size="sm">
            <Users className="h-4 w-4" /> New payroll
          </Button>
        </Link>
      </div>

      {/* Triggered rules alert */}
      {triggeredRules.length > 0 && (
        <div className="mb-4 rounded-xl border border-amber-900/50 bg-amber-900/20 p-4">
          <div className="flex items-start gap-3">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-400" />
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-400">
                {triggeredRules.length} auto-conversion rule{triggeredRules.length > 1 ? 's' : ''} triggered
              </p>
              {triggeredRules.map(r => {
                const amt = getConversionAmount(r)
                return (
                  <div key={r.id} className="mt-2 flex items-center justify-between text-xs">
                    <span className="text-amber-600">
                      "{r.name}" — convert {r.action_percent ? `${r.action_percent}%` : `${r.action_amount} USDC`} to {r.target_currency}
                      {amt > 0 && ` (≈ ${getLocalEquiv(amt, r.target_currency)} ${r.target_currency})`}
                    </span>
                    <div className="flex gap-2">
                      <Link href="/convert">
                        <Button size="sm" className="h-7 text-xs">
                          Convert now <ArrowRight className="h-3 w-3" />
                        </Button>
                      </Link>
                      <Button size="sm" variant="outline" className="h-7 text-xs"
                        onClick={() => toggleRule.mutate({ id: r.id, status: 'active' })}>
                        Dismiss
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* Stats row */}
      <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
        {[
          { label: 'Available USDC',   value: `$${formatAmount(usdcBalance)}`,  sub: 'ready to use'        },
          { label: 'In escrow',        value: `$${formatAmount(escrowLocked)}`, sub: 'locked in P2P offers' },
          { label: 'Active rules',     value: String(rules.filter(r => r.status === 'active').length),
            sub: 'auto-conversion rules' },
          { label: 'Payrolls run',     value: String(batches.filter(b => b.status === 'completed').length),
            sub: `$${formatAmount(batches.filter(b => b.status === 'completed').reduce((s,b) => s + b.total_amount, 0))} total paid` },
        ].map(({ label, value, sub }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <p className="text-xs text-[#64748B]">{label}</p>
            <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{value}</p>
            <p className="mt-0.5 text-xs text-[#64748B]">{sub}</p>
          </div>
        ))}
      </div>

      <div className="grid gap-4 lg:grid-cols-2">

        {/* Auto-conversion rules */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-[#E2E8F0]">Auto-conversion rules</p>
              <p className="text-xs text-[#64748B]">Trigger when USDC balance crosses a threshold</p>
            </div>
            <Button size="sm" variant="outline"
              onClick={() => setShowRuleForm(!showRuleForm)}>
              <Plus className="h-3.5 w-3.5" /> New rule
            </Button>
          </div>

          {/* Create rule form */}
          {showRuleForm && (
            <div className="mb-4 space-y-3 rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-4">
              <p className="text-xs font-medium text-[#E2E8F0]">New rule</p>
              <Input placeholder="Rule name (e.g. Convert excess NGN)"
                value={ruleName} onChange={e => setRuleName(e.target.value)} />
              <div className="flex gap-2">
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-[#64748B]">When USDC balance exceeds</p>
                  <Input type="number" placeholder="1000" value={threshold}
                    onChange={e => setThreshold(e.target.value)} />
                </div>
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-[#64748B]">Target currency</p>
                  <select value={targetCcy} onChange={e => setTargetCcy(e.target.value)}
                    className="w-full rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-2 text-sm text-[#E2E8F0] outline-none">
                    {CURRENCIES.map(c => (
                      <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
                    ))}
                  </select>
                </div>
              </div>
              <div>
                <p className="mb-1 text-[10px] text-[#64748B]">Convert</p>
                <div className="flex gap-2">
                  <div className="flex rounded-lg border border-[#1B2B4B] bg-[#0F1729]">
                    {(['percent','fixed'] as const).map(t => (
                      <button key={t} onClick={() => setActionType(t)}
                        className={`px-3 py-1.5 text-xs transition-colors rounded-lg
                          ${actionType === t ? 'bg-[#378ADD] text-white' : 'text-[#64748B]'}`}>
                        {t === 'percent' ? '%' : 'Fixed'}
                      </button>
                    ))}
                  </div>
                  <Input type="number"
                    placeholder={actionType === 'percent' ? '30 (%)' : 'Amount (USDC)'}
                    value={actionVal} onChange={e => setActionVal(e.target.value)}
                    className="flex-1" />
                </div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" className="flex-1"
                  onClick={() => setShowRuleForm(false)}>Cancel</Button>
                <Button size="sm" className="flex-1" onClick={handleCreateRule}
                  disabled={createRule.isPending || !ruleName || !threshold || !actionVal}>
                  {createRule.isPending ? 'Saving…' : 'Save rule'}
                </Button>
              </div>
            </div>
          )}

          {/* Rules list */}
          {rules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Zap className="h-8 w-8 text-[#1B2B4B]" />
              <p className="text-sm text-[#64748B]">No rules yet</p>
              <p className="text-xs text-[#64748B]">
                Create a rule to be alerted when your balance crosses a threshold
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {rules.map(rule => {
                const amt = getConversionAmount(rule)
                return (
                  <div key={rule.id}
                    className="rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-[#E2E8F0] truncate">{rule.name}</p>
                          <Badge variant={
                            rule.status === 'triggered' ? 'warning' :
                            rule.status === 'active'    ? 'success'  : 'default'
                          }>
                            {rule.status}
                          </Badge>
                        </div>
                        <p className="mt-0.5 text-xs text-[#64748B]">
                          When USDC &gt; {rule.trigger_threshold.toLocaleString()} →{' '}
                          convert {rule.action_percent ? `${rule.action_percent}%` : `${rule.action_amount} USDC`} to{' '}
                          {CURRENCY_FLAG[rule.target_currency]} {rule.target_currency}
                        </p>
                        {rule.last_triggered && (
                          <p className="mt-0.5 text-[10px] text-amber-500">
                            Last triggered: {new Date(rule.last_triggered * 1000).toLocaleDateString()}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          onClick={() => toggleRule.mutate({
                            id: rule.id,
                            status: rule.status === 'active' ? 'paused' : 'active',
                          })}
                          className="rounded p-1.5 text-[#64748B] hover:text-[#E2E8F0] transition-colors"
                          title={rule.status === 'active' ? 'Pause' : 'Activate'}
                        >
                          {rule.status === 'active'
                            ? <Pause className="h-3.5 w-3.5" />
                            : <Play  className="h-3.5 w-3.5" />
                          }
                        </button>
                        <button
                          onClick={() => deleteRule.mutate(rule.id)}
                          className="rounded p-1.5 text-[#64748B] hover:text-red-400 transition-colors"
                          title="Delete rule"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent payrolls */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-[#E2E8F0]">Recent payrolls</p>
              <p className="text-xs text-[#64748B]">Batch USDC payments with Memo references</p>
            </div>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline">
                <Plus className="h-3.5 w-3.5" /> New batch
              </Button>
            </Link>
          </div>

          {batches.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Building2 className="h-8 w-8 text-[#1B2B4B]" />
              <p className="text-sm text-[#64748B]">No payrolls yet</p>
              <p className="text-xs text-[#64748B]">
                Send USDC to multiple wallets in one batch with unique Memo references
              </p>
              <Link href="/treasury/payroll">
                <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-2">
              {batches.slice(0, 6).map(batch => (
                <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                  <div className="flex items-center justify-between rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-3 hover:border-[#378ADD]/40 transition-colors cursor-pointer">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <p className="text-sm font-medium text-[#E2E8F0] truncate">{batch.name}</p>
                        <Badge variant={
                          batch.status === 'completed'  ? 'success' :
                          batch.status === 'processing' ? 'arc'     :
                          batch.status === 'failed'     ? 'danger'  : 'warning'
                        }>
                          {batch.status}
                        </Badge>
                      </div>
                      <p className="text-xs text-[#64748B]">
                        {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                        · {new Date(batch.created_at * 1000).toLocaleDateString()}
                      </p>
                    </div>
                    <ArrowRight className="h-4 w-4 shrink-0 text-[#64748B]" />
                  </div>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/treasury/ — page + TreasuryContent"

# ============================================================
# 8 — Frontend: Payroll page (create batch)
# ============================================================
mkdir -p "afrifx-web/app/(app)/treasury/payroll"
mkdir -p "afrifx-web/app/(app)/treasury/payroll/[id]"

cat > "afrifx-web/app/(app)/treasury/payroll/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { PayrollCreateContent } from './PayrollCreateContent'

export default function PayrollPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-96 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <PayrollCreateContent />
    </ClientOnly>
  )
}
__EOF__

cat > "afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx" << '__EOF__'
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
      const updated = { ...r, [field]: value, error: undefined }
      if (field === 'walletAddress' && value && !isValidAddress(value)) {
        updated.error = 'Invalid address'
      }
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

      <div className="grid gap-6 lg:grid-cols-3">
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
                <div className="grid grid-cols-12 gap-2 px-1 text-[10px] uppercase tracking-wider text-[#64748B]">
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
__EOF__
echo "✅  treasury/payroll/page.tsx + PayrollCreateContent.tsx"

# ============================================================
# 9 — Frontend: Payroll batch execution page
# ============================================================
cat > "afrifx-web/app/(app)/treasury/payroll/[id]/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { PayrollExecuteContent } from './PayrollExecuteContent'

export default function PayrollBatchPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-96 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <PayrollExecuteContent />
    </ClientOnly>
  )
}
__EOF__

cat > "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract } from 'wagmi'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch, useUpdateRecipient } from '@/hooks/usePayroll'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs } from '@/lib/memo'
import { MEMO_ADDRESS, MEMO_ABI } from '@/lib/memo'
import { formatAmount } from '@/lib/utils'
import { parseUnits } from 'viem'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle, Clock,
} from 'lucide-react'

export function PayrollExecuteContent() {
  const { id }           = useParams()
  const { address }      = useAccount()
  const { data: batch }  = usePayrollBatch(id as string)
  const updateRecipient  = useUpdateRecipient()
  const { writeContractAsync } = useWriteContract()

  const [executing,    setExecuting]    = useState(false)
  const [currentIdx,   setCurrentIdx]   = useState(0)
  const [errorMsg,     setErrorMsg]     = useState<string | null>(null)
  const [done,         setDone]         = useState(false)

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-[#64748B]" />
    </div>
  )

  const recipients = batch.recipients ?? []
  const sentCount  = recipients.filter(r => r.status === 'sent').length
  const pct        = recipients.length > 0 ? Math.round((sentCount / recipients.length) * 100) : 0

  async function executePayroll() {
    if (!address || executing) return
    setExecuting(true)
    setErrorMsg(null)

    const pending = recipients.filter(r => r.status === 'pending')

    for (let i = 0; i < pending.length; i++) {
      const recipient = pending[i]
      setCurrentIdx(i)
      try {
        const usdcRaw = parseUnits(recipient.amount.toFixed(6), USDC_DECIMALS)
        const memoId  = buildMemoId(`payroll-${batch.id}-${recipient.id}`)

        // Check if Memo is available
        let hash: `0x${string}`
        try {
          const args = buildMemoTransferArgs(
            CONTRACTS.USDC,
            recipient.wallet_address as `0x${string}`,
            recipient.amount,
            USDC_DECIMALS,
            memoId,
            {
              app:  'afrifx',
              type: 'p2p-create', // reuse as generic transfer
              ref:  recipient.memo_ref ?? undefined,
            },
          )
          hash = await writeContractAsync(args)
        } catch {
          // Fallback to direct transfer
          hash = await writeContractAsync({
            address:      CONTRACTS.USDC,
            abi:          USDC_ABI,
            functionName: 'transfer',
            args:         [recipient.wallet_address as `0x${string}`, usdcRaw],
          })
        }

        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch.id,
          status:  'sent',
          txHash:  hash,
        })
      } catch (err: any) {
        const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch.id,
          status:  'failed',
        })
        setErrorMsg(`Payment to ${recipient.name ?? recipient.wallet_address.slice(0,10)} failed: ${msg}`)
        // Continue with next recipients
      }
    }

    setExecuting(false)
    setDone(true)
  }

  const statusBadge = {
    draft:      'warning',
    processing: 'arc',
    completed:  'success',
    failed:     'danger',
  }[batch.status] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">{batch.name}</h1>
            <Badge variant={statusBadge}>{batch.status}</Badge>
          </div>
          <p className="text-xs text-[#64748B]">
            {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
            · Created {new Date(batch.created_at * 1000).toLocaleDateString()}
          </p>
        </div>
      </div>

      {/* Progress bar */}
      {(executing || batch.status === 'completed') && (
        <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-2 flex items-center justify-between text-xs">
            <span className="text-[#64748B]">
              {executing ? `Sending payment ${currentIdx + 1} of ${recipients.filter(r => r.status === 'pending').length}…` : 'All payments sent'}
            </span>
            <span className={`font-medium ${pct === 100 ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>
              {sentCount}/{recipients.length} · {pct}%
            </span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-full bg-[#1B2B4B]">
            <div
              className="h-full rounded-full bg-emerald-500 transition-all duration-500"
              style={{ width: `${pct}%` }}
            />
          </div>
          {executing && (
            <p className="mt-1.5 text-center text-xs text-[#64748B]">
              Do not close this tab until all payments are sent.
            </p>
          )}
        </div>
      )}

      {done && sentCount === recipients.length && (
        <div className="mb-4 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">All payments sent successfully!</p>
          <p className="mt-1 text-xs text-emerald-600">
            ${formatAmount(batch.total_amount)} USDC distributed to {sentCount} recipients
          </p>
        </div>
      )}

      {errorMsg && (
        <div className="mb-4 flex items-start gap-2 rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-medium">Payment failed</p>
            <p className="mt-0.5">{errorMsg}</p>
            <p className="mt-1 text-red-600">The remaining payments will continue. You can retry failed ones separately.</p>
          </div>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-3">

        {/* Recipients table */}
        <div className="lg:col-span-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Recipients</p>
          <div className="space-y-2">
            {recipients.map((r, i) => (
              <div key={r.id}
                className={`flex items-center gap-3 rounded-xl p-3 transition-colors
                  ${executing && i === currentIdx && r.status === 'pending'
                    ? 'border border-[#378ADD]/40 bg-[#378ADD]/5'
                    : 'border border-[#1B2B4B] bg-[#080D1B]'}`}>

                {/* Status icon */}
                <div className="shrink-0">
                  {r.status === 'sent'    ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                  : r.status === 'failed' ? <XCircle     className="h-4 w-4 text-red-400" />
                  : executing && i === currentIdx
                  ? <Loader2 className="h-4 w-4 animate-spin text-[#378ADD]" />
                  : <Clock   className="h-4 w-4 text-[#64748B]" />}
                </div>

                {/* Info */}
                <div className="flex-1 min-w-0">
                  {r.name && (
                    <p className="text-xs font-medium text-[#E2E8F0]">{r.name}</p>
                  )}
                  <p className="font-mono text-[11px] text-[#64748B] truncate">{r.wallet_address}</p>
                  {r.memo_ref && (
                    <p className="text-[10px] text-[#64748B]">{r.memo_ref}</p>
                  )}
                </div>

                {/* Amount */}
                <div className="shrink-0 text-right">
                  <p className="font-mono text-sm font-medium text-[#E2E8F0]">
                    {formatAmount(r.amount)} USDC
                  </p>
                  {r.tx_hash && (
                    <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                      target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-[10px] text-[#378ADD] hover:underline">
                      View tx <ExternalLink className="h-2.5 w-2.5" />
                    </a>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Action panel */}
        <div className="space-y-4">
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Execute</p>
            <div className="space-y-2 text-xs">
              {[
                ['Recipients', String(batch.recipient_count)],
                ['Total',      `${formatAmount(batch.total_amount)} USDC`],
                ['Sent',       `${sentCount} / ${batch.recipient_count}`],
              ].map(([l,v]) => (
                <div key={l} className="flex justify-between">
                  <span className="text-[#64748B]">{l}</span>
                  <span className="font-mono text-[#E2E8F0]">{v}</span>
                </div>
              ))}
            </div>

            {batch.status !== 'completed' && (
              <Button className="mt-4 w-full" size="lg"
                onClick={executePayroll}
                disabled={executing || done || sentCount === recipients.length}>
                {executing
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
                  : sentCount > 0
                  ? `Resume (${recipients.length - sentCount} remaining)`
                  : <><Play className="h-4 w-4" /> Start payroll</>
                }
              </Button>
            )}

            {batch.status === 'completed' && (
              <div className="mt-4 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                <CheckCircle className="h-3.5 w-3.5" />
                Payroll complete
              </div>
            )}

            <p className="mt-2 text-center text-[10px] text-[#64748B]">
              Each payment is sent individually on Arc with a unique Memo reference
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  treasury/payroll/[id]/ — execution page"

# ============================================================
# 10 — Update sidebar
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User,
  Wallet, Building2,
} from 'lucide-react'
import { cn } from '@/lib/utils'

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
  { label: 'Treasury', items: [
    { href: '/treasury',         icon: Building2, label: 'Treasury'  },
    { href: '/treasury/payroll', icon: Send,      label: 'Payroll'   },
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
  const pathname = usePathname()
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
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Treasury section added"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Business Treasury + Payroll complete!"
echo ""
echo "  New pages:"
echo "  /treasury         — Overview, auto-conversion rules,"
echo "                      triggered alerts, recent payrolls"
echo "  /treasury/payroll — Create batch (manual + CSV upload)"
echo "  /treasury/payroll/:id — Execute + live progress tracker"
echo ""
echo "  Auto-conversion rules:"
echo "  • Create: when USDC > X, convert Y% (or fixed) to NGN/GHS/etc"
echo "  • Backend checks every hour on Arc chain"
echo "  • Triggered rules show alert with one-click 'Convert now'"
echo "  • Pause / activate / delete rules"
echo ""
echo "  Payroll:"
echo "  • Manual: add recipients row by row"
echo "  • CSV: upload name,wallet_address,amount"
echo "  • Preview batch before executing"
echo "  • Execute: sends USDC to each wallet with unique Memo ref"
echo "  • Live progress bar (3/10 sent…)"
echo "  • Each payment: PAY-YYYYMMDD-XXXX reference"
echo "  • ArcScan link per payment"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
