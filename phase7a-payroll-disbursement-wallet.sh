#!/usr/bin/env bash
# ============================================================================
# Phase 7a - Payroll hybrid custody: platform MPC disbursement wallet (backend)
#
# WHY
#   Payroll on user-controlled wallets = one device tap per payee, never
#   unattended. Hybrid custody fixes that: the employer funds ONE platform-held
#   wallet with a single transfer, and the backend pays out from it. 7a builds
#   the foundation - a Circle DEVELOPER-CONTROLLED (MPC) wallet and one tested
#   payout primitive. Funding (7b) and the batch engine (7c) come next.
#
# WHY MPC (not the raw-key platform wallet)
#   Chosen for the stronger custody model: keys are secured by Circle's MPC via
#   an entity secret; the server never holds or logs a private key. This is
#   also the foundation escrow can later migrate onto.
#
# WHAT IT ADDS
#   * dep: @circle-fin/developer-controlled-wallets
#   * src/services/platformDisbursement.ts - client + provision + sendUsdc +
#     balance + status (entity secret only from env, never logged)
#   * src/scripts/provisionDisbursement.ts - run ONCE to create the wallet
#   * GET /payroll/disbursement/status - verify config + balance
#   * guard tests (no network)
#
# SECURITY - YOU MUST DO THIS (one time, before provisioning)
#   1. Generate an entity secret with the Circle SDK (generateEntitySecret()).
#   2. Register it in the Circle console; save the recovery file safely.
#   3. Set CIRCLE_ENTITY_SECRET in the API environment (Render). NEVER commit it.
#   Then run:
#     cd afrifx-api && npx tsx src/scripts/provisionDisbursement.ts
#   Save the printed wallet id as PAYROLL_DISBURSEMENT_WALLET_ID in the env.
#
# REQUIRES: existing Circle API key (CIRCLE_API_KEY) already set.
#
# USAGE
#   bash phase7a-payroll-disbursement-wallet.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
[ -f "$API/src/routes/payroll.ts" ] || die "run from repo root"
BK="$ROOT/.phase7a-backup"; rm -rf "$BK"; mkdir -p "$BK"
mkdir -p "$BK/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"; cp "$ROOT/afrifx-api/src/services/platformDisbursement.ts" "$BK/afrifx-api/src/services/platformDisbursement.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/scripts/provisionDisbursement.ts")"; cp "$ROOT/afrifx-api/src/scripts/provisionDisbursement.ts" "$BK/afrifx-api/src/scripts/provisionDisbursement.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/tests/platformDisbursement.test.ts")"; cp "$ROOT/afrifx-api/tests/platformDisbursement.test.ts" "$BK/afrifx-api/tests/platformDisbursement.test.ts" 2>/dev/null || true
mkdir -p "$BK/$(dirname "afrifx-api/src/routes/payroll.ts")"; cp "$ROOT/afrifx-api/src/routes/payroll.ts" "$BK/afrifx-api/src/routes/payroll.ts" 2>/dev/null || true
ok "snapshot saved"
say "Installing SDK dependency"
( cd "$API" && npm install @circle-fin/developer-controlled-wallets@^10.8.0 --no-audit --no-fund --loglevel=error >/dev/null 2>&1 ) || die "npm install failed"
ok "@circle-fin/developer-controlled-wallets installed"
say "Writing files"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/services/platformDisbursement.ts")"
cat > "$ROOT/afrifx-api/src/services/platformDisbursement.ts" <<'AFX_7A_EOF'
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
AFX_7A_EOF
ok "wrote afrifx-api/src/services/platformDisbursement.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/scripts/provisionDisbursement.ts")"
cat > "$ROOT/afrifx-api/src/scripts/provisionDisbursement.ts" <<'AFX_7A_EOF'
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
AFX_7A_EOF
ok "wrote afrifx-api/src/scripts/provisionDisbursement.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/tests/platformDisbursement.test.ts")"
cat > "$ROOT/afrifx-api/tests/platformDisbursement.test.ts" <<'AFX_7A_EOF'
import { describe, it, expect, beforeEach, afterEach } from 'vitest'

// These tests verify the guard behavior only - that the service refuses to act
// without configuration - WITHOUT making any network calls to Circle. The
// happy path (real provisioning / payout) is exercised manually against the
// Circle sandbox, since it moves testnet funds.

describe('platformDisbursement config guards', () => {
  const saved = { key: process.env.CIRCLE_API_KEY, secret: process.env.CIRCLE_ENTITY_SECRET }

  beforeEach(() => {
    delete process.env.CIRCLE_API_KEY
    delete process.env.CIRCLE_ENTITY_SECRET
  })
  afterEach(() => {
    if (saved.key)    process.env.CIRCLE_API_KEY = saved.key
    else              delete process.env.CIRCLE_API_KEY
    if (saved.secret) process.env.CIRCLE_ENTITY_SECRET = saved.secret
    else              delete process.env.CIRCLE_ENTITY_SECRET
  })

  it('provisioning throws a clear error when the entity secret is missing', async () => {
    process.env.CIRCLE_API_KEY = 'test-key'
    const { provisionDisbursementWallet } = await import('../src/services/platformDisbursement')
    await expect(provisionDisbursementWallet()).rejects.toThrow(/CIRCLE_ENTITY_SECRET/)
  })

  it('a payout throws a clear error when the API key is missing', async () => {
    process.env.CIRCLE_ENTITY_SECRET = 'test-secret'
    const { sendUsdc } = await import('../src/services/platformDisbursement')
    await expect(sendUsdc({
      walletId: 'w', destinationAddress: '0xabc', amount: 1,
    })).rejects.toThrow(/CIRCLE_API_KEY/)
  })
})
AFX_7A_EOF
ok "wrote afrifx-api/tests/platformDisbursement.test.ts"
mkdir -p "$ROOT/$(dirname "afrifx-api/src/routes/payroll.ts")"
cat > "$ROOT/afrifx-api/src/routes/payroll.ts" <<'AFX_7A_EOF'
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

export default router
AFX_7A_EOF
ok "wrote afrifx-api/src/routes/payroll.ts"

say "Verifying"
grep -q "provisionDisbursementWallet" "$API/src/services/platformDisbursement.ts" || die "service missing"
grep -q "/disbursement/status" "$API/src/routes/payroll.ts" || die "status route missing"

say "API: tsc + tests"
( cd "$API" && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "API tsc failed - restored"; }
ok "api typechecks"
( cd "$API" && npx vitest run >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "API tests failed - restored"; }
ok "api tests pass"
rm -rf "$BK"
say "Phase 7a applied and verified."
cat <<'NOTE'

  Foundation for hybrid-custody payroll is in. No behavior changes for users
  yet - this is backend plumbing.

  ONE-TIME SETUP (do this, then provision):
    1. Generate + register an entity secret (Circle SDK generateEntitySecret();
       register in the Circle console; save the recovery file).
    2. Set CIRCLE_ENTITY_SECRET in the API env (Render). Never commit it.
    3. Provision the wallet:
         cd afrifx-api && npx tsx src/scripts/provisionDisbursement.ts
       Save the printed id as PAYROLL_DISBURSEMENT_WALLET_ID in the API env.

  Commit & push:
    git add -A
    git commit -m "phase 7a: payroll MPC disbursement wallet foundation"
    git push origin main

  Verify after deploy:
    GET /payroll/disbursement/status
      -> { configured:false } until PAYROLL_DISBURSEMENT_WALLET_ID is set
      -> { configured:true, balance:0 } once provisioned (fund it in 7b)

  Next: 7b - employer funds the disbursement wallet with one signed transfer.
NOTE
