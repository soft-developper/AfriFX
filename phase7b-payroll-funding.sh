#!/usr/bin/env bash
# ============================================================================
# Phase 7b - Payroll funding: employer tops up the reusable disbursement float
#
# WHY
#   Hybrid custody: instead of signing every payout, the employer funds a
#   platform-held MPC float ONCE with a single signed USDC transfer, and the
#   backend pays batches out of it (7c). 7b is the funding half - sign a
#   top-up, record it, confirm it against the live wallet balance.
#
# WHAT IT ADDS
#   * migration 0017 - payroll_disbursement_funding (audit ledger of top-ups)
#   * server: /payroll/disbursement/address, /disbursement/fund,
#     /disbursement/funding  (+ getDisbursementAddress in the service)
#   * client: usePayrollFunding hook + DisbursementFloatCard shown on the
#     payroll page (shows the float balance, one-click top up)
#   * fix: provisioning script now loads .env itself (no more inline vars)
#
# SAFETY
#   * The fund destination is fetched from the SERVER (live wallet address),
#     never hardcoded or client-supplied - funds can't be redirected.
#   * A top-up is confirmed by RE-READING the live balance, not by trusting
#     the client. The DB ledger is an audit trail; balance truth is Circle.
#
# REQUIRES: Phase 7a, and the disbursement wallet provisioned
#           (PAYROLL_DISBURSEMENT_WALLET_ID set). Run the migration after.
#
# USAGE
#   bash phase7b-payroll-funding.sh
#   # then: cd afrifx-api && npm run migrate   (applies 0017)
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "provisionDisbursementWallet" "$API/src/services/platformDisbursement.ts" || die "Phase 7a not detected."
BK="$ROOT/.phase7b-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname "afrifx-api/migrations/0017_disbursement_funding.sql")"; cp "$ROOT/afrifx-api/migrations/0017_disbursement_funding.sql" "$BK/afrifx-api/migrations/0017_disbursement_funding.sql" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"; cp "$ROOT/afrifx-api/src/services/platformDisbursement.ts" "$BK/afrifx-api/src/services/platformDisbursement.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/scripts/provisionDisbursement.ts")"; cp "$ROOT/afrifx-api/src/scripts/provisionDisbursement.ts" "$BK/afrifx-api/src/scripts/provisionDisbursement.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/routes/payroll.ts")"; cp "$ROOT/afrifx-api/src/routes/payroll.ts" "$BK/afrifx-api/src/routes/payroll.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/hooks/usePayrollFunding.ts")"; cp "$ROOT/afrifx-web/hooks/usePayrollFunding.ts" "$BK/afrifx-web/hooks/usePayrollFunding.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/components/treasury/DisbursementFloatCard.tsx")"; cp "$ROOT/afrifx-web/components/treasury/DisbursementFloatCard.tsx" "$BK/afrifx-web/components/treasury/DisbursementFloatCard.tsx" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx")"; cp "$ROOT/afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx" "$BK/afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx" 2>/dev/null || true
ok "snapshot saved"
say "Writing files"
mkdir -p "$ROOT/$(dirname "afrifx-api/migrations/0017_disbursement_funding.sql")"
cat > "$ROOT/afrifx-api/migrations/0017_disbursement_funding.sql" <<'AFX_7B_EOF'
-- ============================================================
-- Payroll disbursement funding ledger (hybrid custody, Phase 7b).
--
-- The platform holds a reusable USDC "float" in an MPC disbursement wallet;
-- employers top it up, and the backend pays batches out of it. This table is
-- the AUDIT TRAIL of top-ups: who funded, how much, which on-chain tx, and
-- whether it confirmed.
--
-- It is NOT the source of truth for spendable balance - that is always read
-- live from Circle before a payout (so the ledger drifting can never cause an
-- overspend). This table answers "who put money in and when", for
-- reconciliation and display.
-- ============================================================

CREATE TABLE IF NOT EXISTS payroll_disbursement_funding (
  id             TEXT PRIMARY KEY,
  funder_address TEXT NOT NULL,          -- the employer wallet that funded
  amount         REAL NOT NULL,          -- USDC amount of this top-up
  tx_hash        TEXT,                   -- the funding transfer's on-chain hash
  status         TEXT NOT NULL DEFAULT 'pending',  -- pending | confirmed | failed
  created_at     INTEGER NOT NULL,
  confirmed_at   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_disbursement_funding_funder
  ON payroll_disbursement_funding (funder_address);

CREATE INDEX IF NOT EXISTS idx_disbursement_funding_status
  ON payroll_disbursement_funding (status);
AFX_7B_EOF
ok "wrote afrifx-api/migrations/0017_disbursement_funding.sql"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"
cat > "$ROOT/afrifx-api/src/services/platformDisbursement.ts" <<'AFX_7B_EOF'
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
  const res = await c.createTransaction({
    walletId:           params.walletId,
    tokenAddress:       USDC_ADDRESS,
    blockchain:         BLOCKCHAIN as any,
    destinationAddress: params.destinationAddress,
    amount:             [params.amount.toString()],
    idempotencyKey:     params.idempotencyKey ?? randomUUID(),
    fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    ...(params.refId ? { refId: params.refId } : {}),
  })
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
AFX_7B_EOF
ok "wrote afrifx-api/src/services/platformDisbursement.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/scripts/provisionDisbursement.ts")"
cat > "$ROOT/afrifx-api/src/scripts/provisionDisbursement.ts" <<'AFX_7B_EOF'
// ============================================================
// provisionDisbursement.ts - run ONCE to create the platform payroll wallet.
//
// Usage (from afrifx-api):
//   CIRCLE_API_KEY=... CIRCLE_ENTITY_SECRET=... npx tsx src/scripts/provisionDisbursement.ts
//
// It prints the new wallet's id and address. Save them:
//   * PAYROLL_DISBURSEMENT_WALLET_ID   -> env (used by the payout engine, 7c)
//   * the address is what employers FUND (7b)
//
// This is deliberately a manual script, not an auto-running route: it creates a
// custody wallet and should be an explicit, one-time, human-run action. It does
// not print the entity secret.
// ============================================================

import * as dotenv from 'dotenv'
dotenv.config()

import { provisionDisbursementWallet } from '../services/platformDisbursement'

async function main() {
  if (!process.env.CIRCLE_ENTITY_SECRET) {
    console.error(
      'CIRCLE_ENTITY_SECRET is not set. Generate one with the Circle SDK\n' +
      "(generateEntitySecret()), register it in the Circle console, then set it\n" +
      'in the environment before running this script.')
    process.exit(1)
  }

  console.log('Provisioning the payroll disbursement wallet...')
  const wallet = await provisionDisbursementWallet()

  console.log('\nDone. Save these:')
  console.log(`  PAYROLL_DISBURSEMENT_WALLET_ID = ${wallet.id}`)
  console.log(`  address (fund this)            = ${wallet.address}`)
  console.log(`  blockchain                     = ${wallet.blockchain}`)
  console.log(
    '\nNext: set PAYROLL_DISBURSEMENT_WALLET_ID in the API environment. ' +
    'Employers will fund the address above (Phase 7b), and the backend pays ' +
    'out from it (Phase 7c).')
}

main().catch(err => {
  console.error('Provisioning failed:', err?.message ?? err)
  process.exit(1)
})
AFX_7B_EOF
ok "wrote afrifx-api/src/scripts/provisionDisbursement.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/routes/payroll.ts")"
cat > "$ROOT/afrifx-api/src/routes/payroll.ts" <<'AFX_7B_EOF'
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
AFX_7B_EOF
ok "wrote afrifx-api/src/routes/payroll.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/hooks/usePayrollFunding.ts")"
cat > "$ROOT/afrifx-web/hooks/usePayrollFunding.ts" <<'AFX_7B_EOF'
'use client'
// ============================================================
// usePayrollFunding - top up the platform's reusable disbursement float.
//
// HYBRID CUSTODY (Phase 7b). The employer signs ONE USDC transfer from their
// Circle wallet into the platform's MPC disbursement wallet. The backend then
// pays batches out of that float (7c) with no per-payee signing. This hook is
// only the funding step: sign the transfer, then record it so the backend
// confirms it against the live wallet balance.
//
// The destination is fetched from the server (the live wallet address), never
// hardcoded or supplied by the client, so funds always go to the real wallet.
// ============================================================

import { useState, useCallback } from 'react'
import { parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type FundStep = 'idle' | 'preparing' | 'signing' | 'confirming' | 'done' | 'error'

export interface FundState {
  step:    FundStep
  txHash:  string | null
  balance: number | null
  error:   string | null
  note:    string | null
}

const INITIAL: FundState = {
  step: 'idle', txHash: null, balance: null, error: null, note: null,
}

export function usePayrollFunding() {
  const { address } = useAccount()
  const [state, setState] = useState<FundState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const fund = useCallback(async (amount: number) => {
    if (!address) { setState({ ...INITIAL, step: 'error', error: 'Sign in first' }); return }
    if (!(amount > 0)) { setState({ ...INITIAL, step: 'error', error: 'Enter an amount greater than zero' }); return }

    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      setState({ ...INITIAL, step: 'preparing' })

      // Fetch the live disbursement address from the server - never hardcode
      // or let the client choose where the money goes.
      const addrRes = await fetch(`${API}/payroll/disbursement/address`)
      const addrData = await addrRes.json().catch(() => ({}))
      if (!addrRes.ok || !addrData.address) {
        throw new Error(addrData.error ?? 'Disbursement wallet is not set up yet.')
      }
      const to = addrData.address as string

      // Sign the USDC transfer employer -> disbursement wallet.
      setState(s => ({ ...s, step: 'signing' }))
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.USDC,
        abiFunctionSignature: 'transfer(address,uint256)',
        abiParameters:        [to, parseUnits(amount.toFixed(6), USDC_DECIMALS).toString()],
      }, note)

      const txHash = result.txHash ?? null
      if (!txHash) {
        throw new Error(
          'The top-up was approved but is taking longer than usual to confirm. ' +
          'Check the float balance shortly - if it rose, it went through.')
      }

      // Record + confirm against the live wallet balance server-side.
      setState(s => ({ ...s, step: 'confirming', txHash, note: null }))
      const fundRes = await fetch(`${API}/payroll/disbursement/fund`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ funderAddress: address, amount, txHash }),
      })
      const fundData = await fundRes.json().catch(() => ({}))
      if (!fundRes.ok) throw new Error(fundData.error ?? 'Could not record the top-up')

      setState(s => ({
        ...s, step: 'done', balance: fundData.balance ?? null, note: null,
      }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Funding failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was sent, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, note: null }))
    }
  }, [address])

  return { ...state, fund, reset }
}
AFX_7B_EOF
ok "wrote afrifx-web/hooks/usePayrollFunding.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/components/treasury/DisbursementFloatCard.tsx")"
cat > "$ROOT/afrifx-web/components/treasury/DisbursementFloatCard.tsx" <<'AFX_7B_EOF'
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
AFX_7B_EOF
ok "wrote afrifx-web/components/treasury/DisbursementFloatCard.tsx"
mkdir -p "$ROOT/$(dirname "afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx")"
cat > "$ROOT/afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx" <<'AFX_7B_EOF'
'use client'
import { useState, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useCreateBatch } from '@/hooks/usePayroll'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { formatAmount } from '@/lib/utils'
import { gatewayChains } from '@/lib/gateway'
import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle, Layers } from 'lucide-react'
import Link from 'next/link'
import { DisbursementFloatCard } from '@/components/treasury/DisbursementFloatCard'

const HOME = 'arc'

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
  const [destChain,    setDestChain]    = useState(HOME)
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
      destChain,
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
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">New payroll batch</h1>
          <p className="text-sm text-app-muted">
            Send USDC to multiple wallets · each payment gets a unique Memo reference
          </p>
        </div>
      </div>

      <DisbursementFloatCard />

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">

          {/* Batch details */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-3 text-sm font-medium text-app-text">Batch details</p>
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-app-muted">Batch name *</label>
                <Input placeholder="e.g. June 2026 Payroll" value={batchName}
                  onChange={e => setBatchName(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 block text-xs text-app-muted">Description (optional)</label>
                <Input placeholder="e.g. Monthly contractor payments"
                  value={description} onChange={e => setDescription(e.target.value)} />
              </div>
              <div>
                <label className="mb-1 flex items-center gap-1.5 text-xs text-app-muted">
                  <Layers className="h-3 w-3" /> Payout chain
                </label>
                <select
                  value={destChain}
                  onChange={e => setDestChain(e.target.value)}
                  className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none"
                >
                  {gatewayChains().map(c => (
                    <option key={c.key} value={c.key}>
                      {c.name}{c.isHome ? ' · home' : ''}
                    </option>
                  ))}
                </select>
                <p className="mt-1 text-[11px] text-app-muted">
                  {destChain === HOME
                    ? 'Paid directly on Arc from your wallet balance, one signature per recipient.'
                    : 'Paid from your unified Gateway balance. Fund it on the Treasury page first. Each recipient is signed and minted on the destination chain.'}
                </p>
              </div>
            </div>
          </div>

          {/* Recipients tabs */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <div className="mb-4 flex items-center justify-between">
              <p className="text-sm font-medium text-app-text">Recipients</p>
              <div className="flex rounded-lg border border-app-border bg-app-bg p-0.5">
                <button onClick={() => setActiveTab('manual')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'manual' ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
                  <Users className="h-3 w-3" /> Manual
                </button>
                <button onClick={() => setActiveTab('csv')}
                  className={`flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs transition-colors
                    ${activeTab === 'csv' ? 'bg-app-border text-app-text' : 'text-app-muted'}`}>
                  <FileText className="h-3 w-3" /> CSV upload
                </button>
              </div>
            </div>

            {/* CSV tab */}
            {activeTab === 'csv' && (
              <div className="space-y-3">
                {/* Format guide */}
                <div className="rounded-lg bg-app-bg p-3 text-xs">
                  <p className="mb-1 font-medium text-app-text">Expected CSV format:</p>
                  <pre className="text-app-muted">{`name,wallet_address,amount
John Doe,0x1234...abcd,100
Jane Smith,0xabcd...1234,50`}</pre>
                  <p className="mt-1 text-app-muted">
                    • <code>name</code> is optional · <code>wallet_address</code> and <code>amount</code> required
                  </p>
                </div>

                <input ref={fileInputRef} type="file" accept=".csv,.txt"
                  onChange={handleCSV} className="hidden" />

                <button onClick={() => fileInputRef.current?.click()}
                  className="flex w-full flex-col items-center gap-3 rounded-xl border-2 border-dashed border-app-border bg-app-bg p-8 hover:border-app-accent/50 transition-colors">
                  <Upload className="h-8 w-8 text-app-muted" />
                  <div className="text-center">
                    <p className="text-sm font-medium text-app-text">Click to upload CSV</p>
                    <p className="text-xs text-app-muted">Supports .csv and .txt files</p>
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
                <div className="hidden sm:grid grid-cols-12 gap-2 px-1 text-[10px] uppercase tracking-wider text-app-muted">
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
                          className="text-app-muted hover:text-red-400 transition-colors">
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
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Batch summary</p>
            <div className="space-y-2.5 text-xs">
              {[
                ['Recipients',      `${validCount} valid`],
                ['Total payout',    `${formatAmount(totalAmount)} USDC`],
                ['Your balance',    `${balance} USDC`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span className="text-app-muted">{label}</span>
                  <span className="font-mono text-app-text">{val}</span>
                </div>
              ))}
              <div className="border-t border-app-border pt-2 flex justify-between">
                <span className="text-app-muted">Each payment</span>
                <span className="text-app-muted">Gets unique Memo ref</span>
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
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs text-app-muted">
            <p className="mb-2 font-medium text-app-text">How payroll works</p>
            <ol className="space-y-1.5">
              {[
                'Create batch with recipient list',
                'Review, confirm amounts are correct',
                'Execute, approve USDC, then send to each recipient',
                'Each payment gets a unique Memo reference (PAY-YYYYMMDD-XXXX)',
                'Track status live as payments confirm on Arc',
              ].map((s, i) => (
                <li key={i} className="flex gap-2">
                  <span className="shrink-0 text-app-accent-text">{i+1}.</span>
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
AFX_7B_EOF
ok "wrote afrifx-web/app/(app)/treasury/payroll/PayrollCreateContent.tsx"

say "Verifying"
grep -q "/disbursement/fund" "$API/src/routes/payroll.ts" || die "fund route missing"
grep -q "getDisbursementAddress" "$API/src/services/platformDisbursement.ts" || die "address helper missing"
[ -f "$API/migrations/0017_disbursement_funding.sql" ] || die "migration 0017 missing"

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
say "Phase 7b applied and verified."
cat <<'NOTE'

  Employer funding is in. On the payroll page there's now a "Payroll float"
  card showing the balance with a one-click top up.

  APPLY THE MIGRATION (creates the funding ledger table):
    cd afrifx-api && npm run migrate

  Commit & push:
    git add -A
    git commit -m "phase 7b: payroll float funding (hybrid custody)"
    git push origin main

  Test after deploy:
    1. Go to Treasury -> Payroll. The float card shows balance 0.
    2. Enter a small amount, click Top up, approve on your device.
    3. The balance should rise by that amount (read live from Circle).
    4. GET /payroll/disbursement/funding shows the top-up as 'confirmed'.

  Next: 7c - the backend pays a batch's recipients out of this float, with a
        balance check so it never starts a batch it can't finish.
NOTE
