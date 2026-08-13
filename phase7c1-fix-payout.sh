#!/usr/bin/env bash
# ============================================================================
# Phase 7c.1 - Fix + diagnose payroll payouts (all recipients failed)
#
# SYMPTOM
#   Batch runs, every recipient goes 'failed'. The engine was swallowing
#   Circle's real error into a bare 'failed', so the cause was invisible.
#
# TWO CHANGES
#   1. LIKELY FIX: identify the USDC transfer by tokenId (resolved from the
#      wallet) instead of tokenAddress. On Arc, USDC is the NATIVE asset, and
#      Circle rejects an ERC-20-style tokenAddress for a native token - the
#      most likely reason every send failed. Falls back to tokenAddress if the
#      id can't be resolved.
#   2. DIAGNOSIS: on failure we now capture Circle's ACTUAL message - logged to
#      the server (Render logs) and stored on the recipient (shown in the UI as
#      the red reason). So if it still fails, you can SEE why.
#
# CHANGES (3 files)
#   afrifx-api/src/services/platformDisbursement.ts  tokenId + surface error
#   afrifx-api/src/routes/payroll.ts                 record failure reason
#   afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx  show reason
#
# REQUIRES: Phase 7c.
#
# USAGE
#   bash phase7c1-fix-payout.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "runBatchPayout" "$API/src/routes/payroll.ts" || die "Phase 7c not detected."
BK="$ROOT/.phase7c1-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"; cp "$ROOT/afrifx-api/src/services/platformDisbursement.ts" "$BK/afrifx-api/src/services/platformDisbursement.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/routes/payroll.ts")"; cp "$ROOT/afrifx-api/src/routes/payroll.ts" "$BK/afrifx-api/src/routes/payroll.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx")"; cp "$ROOT/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" "$BK/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" 2>/dev/null || true
ok "snapshot saved"
say "Writing files"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"
cat > "$ROOT/afrifx-api/src/services/platformDisbursement.ts" <<'AFX_7C1_EOF'
// ============================================================
// platformDisbursement.ts - the platform's MPC disbursement wallet.
//
// WHY THIS EXISTS
// Payroll pays many recipients. User-controlled wallets require the user to
// approve every signature on their device, so a 50-person batch is 50 taps and
// can never run unattended. The hybrid-custody answer: the employer funds ONE
// platform-held wallet with a single signed transfer, and the BACKEND pays out
// from there - no user present per payout, and it can be scheduled.
//
// This wallet is a Circle DEVELOPER-CONTROLLED wallet (MPC), NOT the raw
// private-key platform wallet used for escrow. Keys are secured by Circle's
// MPC via an entity secret; we never hold or log a private key. This is the
// more secure custody model and the foundation escrow can later move onto.
//
// SECURITY
//   * CIRCLE_ENTITY_SECRET is the master key to platform funds. It lives ONLY
//     in the server environment, never in code, never in a log line. The SDK
//     encrypts it per-request (unique ciphertext) so it isn't replayable.
//   * This module never prints the secret, a wallet's private material, or
//     full request bodies.
//
// SCOPE (Phase 7a): provision the wallet + ONE tested payout primitive
// (sendUsdc). Funding and the batch payout engine come in 7b / 7c.
// ============================================================

import {
  initiateDeveloperControlledWalletsClient,
} from '@circle-fin/developer-controlled-wallets'
import { randomUUID } from 'crypto'

const BLOCKCHAIN = process.env.CIRCLE_BLOCKCHAIN ?? 'ARC-TESTNET'

// USDC token id differs by environment; on Arc testnet USDC is the native gas
// token. Circle identifies tokens by a tokenId OR by (blockchain + address).
// We pass the address form so there's nothing extra to configure.
const USDC_ADDRESS =
  process.env.CIRCLE_USDC_ADDRESS ?? '0x3600000000000000000000000000000000000000'

/** Lazily-built SDK client. Throws clearly if the env isn't configured. */
let _client: ReturnType<typeof initiateDeveloperControlledWalletsClient> | null = null

function client() {
  if (_client) return _client
  const apiKey       = process.env.CIRCLE_API_KEY
  const entitySecret = process.env.CIRCLE_ENTITY_SECRET
  if (!apiKey)       throw new Error('CIRCLE_API_KEY is not configured')
  if (!entitySecret) throw new Error('CIRCLE_ENTITY_SECRET is not configured')
  _client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret })
  return _client
}

export interface DisbursementWallet {
  id:         string
  address:    string
  blockchain: string
}

/**
 * Provision the platform disbursement wallet set + wallet.
 *
 * Idempotent by intent: run once. It creates a wallet set and a single SCA
 * wallet on the primary chain and returns its id + address. Persist those
 * (env or DB) - subsequent payouts reference the walletId. Safe to call again
 * only if you WANT another wallet; it does not dedupe, so guard the caller.
 *
 * Returns the address to fund. Never logs the entity secret.
 */
export async function provisionDisbursementWallet(
  name = 'AfriFX Payroll Disbursement',
): Promise<DisbursementWallet> {
  const c = client()

  const setRes = await c.createWalletSet({ name })
  const walletSetId = setRes.data?.walletSet?.id
  if (!walletSetId) throw new Error('Circle did not return a wallet set id')

  const walletsRes = await c.createWallets({
    blockchains: [BLOCKCHAIN as any],
    count:       1,
    walletSetId,
    accountType: 'SCA',
  })
  const w = walletsRes.data?.wallets?.[0]
  if (!w?.id || !w?.address) throw new Error('Circle did not return a wallet')

  return { id: w.id, address: w.address, blockchain: String(w.blockchain ?? BLOCKCHAIN) }
}

/** The current USDC balance of a developer-controlled wallet, as a number. */
export async function getDisbursementBalance(walletId: string): Promise<number> {
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  const balances = res.data?.tokenBalances ?? []
  const usdc = balances.find(
    b => String(b.token?.symbol ?? '').toUpperCase() === 'USDC'
      || String(b.token?.tokenAddress ?? '').toLowerCase() === USDC_ADDRESS.toLowerCase())
  return usdc ? Number(usdc.amount) : 0
}

/**
 * Resolve the Circle tokenId for USDC on this wallet's chain.
 *
 * Identifying a transfer by tokenId is the most reliable path - it works
 * whether USDC is a native asset (as on Arc) or an ERC-20, avoiding the
 * "tokenAddress for a native token" rejection. Cached after first lookup.
 */
let _usdcTokenId: string | null = null
async function resolveUsdcTokenId(walletId: string): Promise<string | null> {
  if (_usdcTokenId) return _usdcTokenId
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  const balances = res.data?.tokenBalances ?? []
  const usdc = balances.find(
    b => String(b.token?.symbol ?? '').toUpperCase() === 'USDC'
      || String(b.token?.tokenAddress ?? '').toLowerCase() === USDC_ADDRESS.toLowerCase())
  _usdcTokenId = usdc?.token?.id ? String(usdc.token.id) : null
  return _usdcTokenId
}

/** The on-chain address of the disbursement wallet (what employers fund). */
export async function getDisbursementAddress(walletId: string): Promise<string> {
  const c = client()
  const res = await c.getWallet({ id: walletId })
  const address = res.data?.wallet?.address
  if (!address) throw new Error('Could not read the disbursement wallet address')
  return address
}

export interface PayoutResult {
  id:     string
  state:  string
  txHash?: string
}

/**
 * Send USDC from the platform disbursement wallet to one address.
 *
 * THE payout primitive. Backend-signed via MPC - no user present. Returns the
 * Circle transaction id and state; the tx hash follows once mined (poll with
 * getPayoutStatus). Uses an idempotencyKey so a retried call can't double-pay.
 *
 * `idempotencyKey` SHOULD be stable per (batch, recipient) so a retry of the
 * same payout is exactly-once. The caller supplies it; if omitted we generate
 * one, which is only safe for genuinely one-off sends.
 */
export async function sendUsdc(params: {
  walletId:           string
  destinationAddress: string
  amount:             number
  idempotencyKey?:    string
  refId?:             string
}): Promise<PayoutResult> {
  const c = client()

  // Prefer tokenId (works for native USDC like Arc's). Fall back to
  // tokenAddress+blockchain if the id can't be resolved.
  const tokenId = await resolveUsdcTokenId(params.walletId).catch(() => null)
  const tokenIdent = tokenId
    ? { tokenId }
    : { tokenAddress: USDC_ADDRESS, blockchain: BLOCKCHAIN as any }

  let res
  try {
    res = await c.createTransaction({
      walletId:           params.walletId,
      ...tokenIdent,
      destinationAddress: params.destinationAddress,
      amount:             [params.amount.toString()],
      idempotencyKey:     params.idempotencyKey ?? randomUUID(),
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
      ...(params.refId ? { refId: params.refId } : {}),
    } as any)
  } catch (err: any) {
    // Surface Circle's actual rejection instead of a generic failure.
    const detail = err?.response?.data?.message ?? err?.message ?? 'transfer rejected'
    throw new Error(detail)
  }

  const tx = res.data
  if (!tx?.id) throw new Error('Circle did not return a transaction id')
  return { id: String(tx.id), state: String(tx.state ?? 'INITIATED') }
}

/** Poll a payout's status by transaction id (to learn its on-chain hash). */
export async function getPayoutStatus(txId: string): Promise<PayoutResult> {
  const c = client()
  const res = await c.getTransaction({ id: txId })
  const tx = res.data?.transaction
  return {
    id:     String(tx?.id ?? txId),
    state:  String(tx?.state ?? 'UNKNOWN'),
    txHash: tx?.txHash,
  }
}
AFX_7C1_EOF
ok "wrote afrifx-api/src/services/platformDisbursement.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/routes/payroll.ts")"
cat > "$ROOT/afrifx-api/src/routes/payroll.ts" <<'AFX_7C1_EOF'
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
        // Capture Circle's ACTUAL message so failures are diagnosable: log it
        // (Render logs) and stash a short form in tx_hash (no error column yet)
        // prefixed with "ERR:" so the UI/DB can show why.
        const reason = String(err?.response?.data?.message ?? err?.message ?? 'unknown error').slice(0, 180)
        console.error(`[payout] batch=${batchId} recipient=${recipientId} FAILED:`, reason)
        await db.run(sql`
          UPDATE payroll_recipients SET status = 'failed', tx_hash = ${'ERR: ' + reason}
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
AFX_7C1_EOF
ok "wrote afrifx-api/src/routes/payroll.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx")"
cat > "$ROOT/afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" <<'AFX_7C1_EOF'
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
              {r.tx_hash && r.tx_hash.startsWith('ERR: ')
                ? <span className="max-w-[180px] truncate text-[11px] text-red-400" title={r.tx_hash.slice(5)}>{r.tx_hash.slice(5)}</span>
                : r.tx_hash
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
AFX_7C1_EOF
ok "wrote afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx"

say "Verifying"
grep -q "resolveUsdcTokenId" "$API/src/services/platformDisbursement.ts" || die "tokenId fix missing"
grep -q "ERR: " "$API/src/routes/payroll.ts" || die "error capture missing"

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
say "Phase 7c.1 applied and verified."
cat <<'NOTE'

  Commit & push:
    git add -A
    git commit -m "phase 7c.1: payroll payout uses tokenId + surfaces real errors"
    git push origin main

  Then retry the batch:
    - If it now SUCCEEDS: the native-USDC tokenAddress was the bug. Done.
    - If it still fails: each failed recipient row now shows the REAL reason in
      red (and it's in the Render logs as "[payout] ... FAILED: <reason>").
      Send me that exact reason and I'll target it precisely. Likely candidates:
        * "insufficient funds" -> the float needs extra USDC for gas (on Arc,
          gas is USDC), so fund a little above the payout total.
        * a token/blockchain identifier complaint -> we adjust the identifier.
NOTE
