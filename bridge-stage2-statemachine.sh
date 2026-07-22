#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- STAGE 2 of 4: DURABLE STATE MACHINE
#
# The SAFETY LAYER, deliberately built BEFORE any money can move.
#
# WHY IT EXISTS: CCTP is burn-and-mint, and Circle's docs are blunt --
# "Once USDC is burned, complete the mint on destination or lose funds."
# There is no rollback. If the tab closes or the API restarts between the burn
# and the mint, funds are NOT gone but they ARE stranded until someone finishes
# the mint. So every bridge is recorded BEFORE the burn is signed, and each
# stage is persisted as it completes.
#
# *** THE MOST IMPORTANT DISTINCTION IN THIS STAGE ***
#   failed    = died BEFORE the burn  -> no funds moved, user just retries
#   stranded  = died AFTER the burn   -> funds burned, mint still owed
# markFailed() decides which one AUTOMATICALLY by checking whether a burn tx was
# recorded, so a caller (or a buggy client) CANNOT mark burned funds as
# harmlessly "failed" and hide a real problem. Verified by test.
#
# RECOVERY: the moment a burn confirms we persist message_bytes + message_hash.
# Those two fields are what let the mint be completed later BY ANYONE, FROM ANY
# MACHINE (attestations never expire). The /burned endpoint REQUIRES them rather
# than accepting a bare tx hash, because a burn recorded without them is far
# harder to recover.
#
# TESTED against a real database: full happy path, inFlight flipping true at
# exactly the burn, failure-before-burn -> failed, failure-after-burn ->
# stranded with recovery data intact, and the reconciler finding it.
#
# WHAT'S HERE
#   bridge-schema.sql                DB table (run in turso shell)
#   services/bridge/repository.ts    state machine + nextAction() resume logic
#   services/bridge/reconciler.ts    cron that finds stuck bridges (reports for
#                                    now; stage 3 gives it the power to finish)
#   routes/bridge.ts                 create + progress-reporting endpoints
#   index.ts                         wires both in
#
# NON-CUSTODIAL BY DESIGN: the user's own wallet signs; these endpoints only
# RECORD progress. The platform holds no keys, so a compromised API cannot move
# anyone's funds.
#
# NOTHING EXECUTES ON-CHAIN YET -- that's stage 3. Deploying this is safe.
#
# Run from ~/AfriFX:  bash bridge-stage2-statemachine.sh
# ============================================================
set -e
echo ""
echo "Installing bridge state machine (stage 2)..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/bridge-schema.sql" << 'AFX_EOF'
-- ============================================================
-- CCTP bridge transfers.
--
-- WHY THIS TABLE EXISTS AT ALL:
-- CCTP is burn-and-mint. Circle's own docs are blunt about the consequence:
-- "Once USDC is burned, complete the mint on destination or lose funds."
-- There is no rollback. If the browser closes, the user's laptop dies, or our
-- API restarts between the burn and the mint, the money is NOT gone but it IS
-- stranded until someone finishes the mint.
--
-- So every bridge is recorded BEFORE the burn is signed, and each stage is
-- persisted as it completes. That gives us:
--   * a resume path        (user returns, we know exactly where they were)
--   * a reconciler target  (a cron can finish stuck mints)
--   * an audit trail       (what happened, when, on which chain)
--
-- THE TWO FIELDS THAT MAKE RECOVERY POSSIBLE are message_bytes and
-- message_hash. Once we have those from the burn receipt, the mint can be
-- completed by ANYONE at ANY TIME (attestations don't expire) -- so as long as
-- they're saved, funds are recoverable even if everything else fails.
--
-- RUN EACH STATEMENT INDIVIDUALLY in the turso shell (it stops on first error).
-- ============================================================

CREATE TABLE IF NOT EXISTS bridge_transfers (
  id              TEXT PRIMARY KEY,        -- 'br-<uuid>'
  wallet_address  TEXT NOT NULL,           -- who owns this bridge (the signer)

  -- Route
  from_chain      TEXT NOT NULL,           -- our chain key, e.g. 'arc'
  to_chain        TEXT NOT NULL,           -- e.g. 'base'
  from_domain     INTEGER NOT NULL,        -- CCTP domain (NOT the EVM chain id)
  to_domain       INTEGER NOT NULL,
  amount          REAL NOT NULL,           -- USDC, human units
  recipient       TEXT NOT NULL,           -- destination address (usually same wallet)

  -- Stage: created -> approving -> burning -> attesting -> minting -> completed
  --        (or 'failed' at any point; 'stranded' if burned but mint unresolved)
  status          TEXT NOT NULL DEFAULT 'created',

  -- Evidence at each step. These are what make recovery possible.
  approve_tx      TEXT,                    -- ERC-20 approve (not needed on all chains)
  burn_tx         TEXT,                    -- depositForBurn tx hash on source
  message_bytes   TEXT,                    -- the CCTP message emitted by the burn
  message_hash    TEXT,                    -- keccak256(message) -- the attestation key
  attestation     TEXT,                    -- Circle's signature over the message
  mint_tx         TEXT,                    -- receiveMessage tx hash on destination

  error           TEXT,                    -- last error, for support/debugging
  attempts        INTEGER NOT NULL DEFAULT 0,

  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bridge_wallet ON bridge_transfers (wallet_address, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bridge_status ON bridge_transfers (status, updated_at);
AFX_EOF
echo "  afrifx-api/bridge-schema.sql"

mkdir -p "afrifx-api/src/services/bridge"
cat > "afrifx-api/src/services/bridge/repository.ts" << 'AFX_EOF'
// ============================================================
// Bridge state machine (CCTP) -- STAGE 2.
//
// This file owns the DURABLE record of every bridge. It performs NO on-chain
// calls (that's stage 3) -- it only records what happened and decides what
// should happen next. Keeping the state machine separate from execution is what
// makes recovery possible: the record survives even if the executor dies.
//
// THE STAGES
//   created   -> row exists, nothing signed yet. Safe to abandon.
//   burning   -> user is signing / burn submitted. Money may be about to leave.
//   attesting -> BURN CONFIRMED. Funds are burned on source. From here the mint
//                MUST eventually happen or the user is out of pocket.
//   minting   -> attestation obtained, mint submitted on destination.
//   completed -> mint confirmed. Done.
//   failed    -> failed BEFORE the burn landed. No funds moved. Safe.
//   stranded  -> burned, but we couldn't finish. NOT lost: message_bytes +
//                attestation let anyone complete the mint later. This status
//                exists so these are findable and fixable rather than silent.
//
// The distinction between `failed` and `stranded` is the most important thing
// in this file: one is harmless, the other needs a human or the reconciler.
// ============================================================

import { db } from '../../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export type BridgeStatus =
  | 'created' | 'burning' | 'attesting' | 'minting'
  | 'completed' | 'failed' | 'stranded'

export interface BridgeRecord {
  id:             string
  wallet_address: string
  from_chain:     string
  to_chain:       string
  from_domain:    number
  to_domain:      number
  amount:         number
  recipient:      string
  status:         BridgeStatus
  approve_tx?:    string | null
  burn_tx?:       string | null
  message_bytes?: string | null
  message_hash?:  string | null
  attestation?:   string | null
  mint_tx?:       string | null
  error?:         string | null
  attempts:       number
  created_at:     number
  updated_at:     number
}

const now = () => Math.floor(Date.now() / 1000)

// ── Create ─────────────────────────────────────────────────
export async function createBridge(input: {
  walletAddress: string
  fromChain: string
  toChain:   string
  fromDomain: number
  toDomain:   number
  amount:     number
  recipient:  string
}): Promise<string> {
  const id = `br-${randomUUID()}`
  const t  = now()
  await db.run(sql`
    INSERT INTO bridge_transfers
      (id, wallet_address, from_chain, to_chain, from_domain, to_domain,
       amount, recipient, status, attempts, created_at, updated_at)
    VALUES (${id}, ${input.walletAddress.toLowerCase()}, ${input.fromChain},
            ${input.toChain}, ${input.fromDomain}, ${input.toDomain},
            ${input.amount}, ${input.recipient.toLowerCase()},
            'created', 0, ${t}, ${t})`)
  return id
}

// ── Read ───────────────────────────────────────────────────
function normalize(r: any): BridgeRecord | null {
  if (!r) return null
  const g = (k: string, i: number) => (Array.isArray(r) ? r[i] : r[k])
  return {
    id:             g('id', 0),
    wallet_address: g('wallet_address', 1),
    from_chain:     g('from_chain', 2),
    to_chain:       g('to_chain', 3),
    from_domain:    Number(g('from_domain', 4)),
    to_domain:      Number(g('to_domain', 5)),
    amount:         Number(g('amount', 6)),
    recipient:      g('recipient', 7),
    status:         g('status', 8) as BridgeStatus,
    approve_tx:     g('approve_tx', 9),
    burn_tx:        g('burn_tx', 10),
    message_bytes:  g('message_bytes', 11),
    message_hash:   g('message_hash', 12),
    attestation:    g('attestation', 13),
    mint_tx:        g('mint_tx', 14),
    error:          g('error', 15),
    attempts:       Number(g('attempts', 16) ?? 0),
    created_at:     Number(g('created_at', 17)),
    updated_at:     Number(g('updated_at', 18)),
  }
}

export async function getBridge(id: string): Promise<BridgeRecord | null> {
  const rows = parseRows(await db.run(
    sql`SELECT * FROM bridge_transfers WHERE id = ${id} LIMIT 1`))
  return normalize(rows[0])
}

export async function listBridgesByWallet(wallet: string, limit = 25): Promise<BridgeRecord[]> {
  const rows = parseRows(await db.run(sql`
    SELECT * FROM bridge_transfers
    WHERE wallet_address = ${wallet.toLowerCase()}
    ORDER BY created_at DESC LIMIT ${limit}`))
  return rows.map(normalize).filter(Boolean) as BridgeRecord[]
}

/*
  Bridges that need attention: burned but not completed. These are the ones the
  reconciler chases and the ones a human would need to look at. Ordered oldest
  first, because the longest-waiting user is the most urgent.
*/
export async function listUnresolved(limit = 50): Promise<BridgeRecord[]> {
  const rows = parseRows(await db.run(sql`
    SELECT * FROM bridge_transfers
    WHERE status IN ('attesting', 'minting', 'stranded')
    ORDER BY updated_at ASC LIMIT ${limit}`))
  return rows.map(normalize).filter(Boolean) as BridgeRecord[]
}

// ── Stage transitions ──────────────────────────────────────
async function patch(id: string, fields: Record<string, unknown>) {
  const sets: any[] = []
  for (const [k, v] of Object.entries(fields)) {
    sets.push(sql`${sql.raw(k)} = ${v as any}`)
  }
  sets.push(sql`updated_at = ${now()}`)
  const joined = sql.join(sets, sql`, `)
  await db.run(sql`UPDATE bridge_transfers SET ${joined} WHERE id = ${id}`)
}

export async function markBurning(id: string) {
  await patch(id, { status: 'burning' })
}

/*
  THE CRITICAL TRANSITION. Called the moment the burn is confirmed on-chain.
  message_bytes + message_hash MUST be saved here -- they are what allow the
  mint to be completed later by anyone, from any machine. Everything after this
  point is recoverable ONLY because of this write.
*/
export async function markBurned(id: string, opts: {
  burnTx: string
  messageBytes: string
  messageHash:  string
}) {
  await patch(id, {
    status:        'attesting',
    burn_tx:       opts.burnTx,
    message_bytes: opts.messageBytes,
    message_hash:  opts.messageHash,
    error:         null,
  })
}

export async function markAttested(id: string, attestation: string) {
  await patch(id, { status: 'minting', attestation, error: null })
}

export async function markCompleted(id: string, mintTx: string) {
  await patch(id, { status: 'completed', mint_tx: mintTx, error: null })
}

/*
  Failure has two shapes and they are NOT the same:
    * before the burn  -> 'failed'   (no funds moved; user can simply retry)
    * after the burn   -> 'stranded' (funds burned; mint still owed)
  We decide based on whether a burn tx was recorded, so a caller can't
  accidentally mark a burned transfer as harmlessly "failed".
*/
export async function markFailed(id: string, error: string) {
  const rec = await getBridge(id)
  const burned = !!rec?.burn_tx
  await patch(id, {
    status: burned ? 'stranded' : 'failed',
    error:  error.slice(0, 500),
    attempts: (rec?.attempts ?? 0) + 1,
  })
  return burned ? 'stranded' : 'failed'
}

export async function bumpAttempt(id: string) {
  const rec = await getBridge(id)
  await patch(id, { attempts: (rec?.attempts ?? 0) + 1 })
}

/*
  What should happen next for a given record? The executor (stage 3) asks this
  rather than deciding for itself, so resume-after-crash follows exactly the
  same path as a fresh run.
*/
export function nextAction(rec: BridgeRecord):
  | 'burn' | 'await_attestation' | 'mint' | 'done' | 'none' {
  switch (rec.status) {
    case 'created':
    case 'burning':   return 'burn'
    case 'attesting': return rec.attestation ? 'mint' : 'await_attestation'
    case 'minting':   return 'mint'
    case 'stranded':  return rec.attestation ? 'mint' : 'await_attestation'
    case 'completed': return 'done'
    default:          return 'none'   // 'failed' -- nothing owed
  }
}

// True when funds are burned but not yet minted: money is in flight.
export function isInFlight(rec: BridgeRecord): boolean {
  return !!rec.burn_tx && rec.status !== 'completed'
}
AFX_EOF
echo "  afrifx-api/src/services/bridge/repository.ts"

mkdir -p "afrifx-api/src/services/bridge"
cat > "afrifx-api/src/services/bridge/reconciler.ts" << 'AFX_EOF'
// ============================================================
// Bridge reconciler.
//
// The backstop behind the browser. A CCTP bridge needs the user's wallet to
// SIGN the burn, but the mint afterwards is permissionless -- anyone can submit
// it. So if a user closes the tab after burning, their funds are NOT lost; the
// mint just hasn't happened yet.
//
// This cron finds those and (in stage 3) finishes them. Right now it only
// REPORTS, because execution doesn't exist yet -- but it's wired in early so
// stranded transfers are visible from day one rather than discovered by an
// angry user.
// ============================================================

import { listUnresolved, nextAction, isInFlight } from './repository'

const INTERVAL_MS = Number(process.env.BRIDGE_RECONCILE_MS ?? 120_000) // 2 min

let timer: NodeJS.Timeout | null = null

export async function reconcileOnce(): Promise<{
  checked: number; inFlight: number; needsMint: number
}> {
  const pending = await listUnresolved()
  let inFlight = 0, needsMint = 0

  for (const rec of pending) {
    if (isInFlight(rec)) inFlight++
    const action = nextAction(rec)
    if (action === 'mint') needsMint++

    // Age matters: a bridge stuck for hours is a support issue, not a blip.
    const ageMin = Math.floor((Date.now() / 1000 - rec.updated_at) / 60)
    if (ageMin > 30) {
      console.warn(
        `[Bridge] STUCK ${rec.id} ${rec.from_chain}->${rec.to_chain} ` +
        `${rec.amount} USDC status=${rec.status} age=${ageMin}m ` +
        `burn=${rec.burn_tx ?? 'none'} action=${action}`)
    }
  }

  if (pending.length) {
    console.log(`[Bridge] reconcile: ${pending.length} unresolved, ` +
                `${inFlight} in flight, ${needsMint} ready to mint`)
  }
  return { checked: pending.length, inFlight, needsMint }
}

export function startBridgeReconciler() {
  if (timer) return
  timer = setInterval(() => {
    reconcileOnce().catch(err =>
      console.error('[Bridge] reconcile failed:', err?.message))
  }, INTERVAL_MS)
  console.log(`[Bridge] reconciler started (every ${INTERVAL_MS / 1000}s)`)
}

export function stopBridgeReconciler() {
  if (timer) { clearInterval(timer); timer = null }
}
AFX_EOF
echo "  afrifx-api/src/services/bridge/reconciler.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/bridge.ts" << 'AFX_EOF'
// ============================================================
// Bridge routes.
//
//   POST /bridge                  create a bridge record (BEFORE signing)
//   GET  /bridge?wallet=0x…       a wallet's bridge history
//   GET  /bridge/:id              one bridge
//   POST /bridge/:id/burned       record a confirmed burn  <- THE critical one
//   POST /bridge/:id/attested     record Circle's attestation
//   POST /bridge/:id/completed    record the mint
//   POST /bridge/:id/failed       record a failure (auto-classifies stranded)
//   GET  /bridge/meta/unresolved  ops view of anything stuck
//
// The user's wallet signs the transactions client-side (non-custodial), so
// these endpoints RECORD progress rather than perform it. That's deliberate:
// the platform never holds keys, and a compromised API can't move funds.
// ============================================================

import { Router } from 'express'
import {
  createBridge, getBridge, listBridgesByWallet, listUnresolved,
  markBurning, markBurned, markAttested, markCompleted, markFailed,
  nextAction, isInFlight,
} from '../services/bridge/repository'

const router = Router()

// ── Create (called BEFORE the user signs anything) ─────────
router.post('/', async (req, res) => {
  const {
    walletAddress, fromChain, toChain, fromDomain, toDomain, amount, recipient,
  } = req.body

  if (!walletAddress) return res.status(400).json({ error: 'walletAddress required' })
  if (!fromChain || !toChain) return res.status(400).json({ error: 'fromChain and toChain required' })
  if (fromChain === toChain)  return res.status(400).json({ error: 'Source and destination must differ' })
  if (fromDomain == null || toDomain == null) {
    return res.status(400).json({ error: 'fromDomain and toDomain required' })
  }
  if (!amount || Number(amount) <= 0) return res.status(400).json({ error: 'A positive amount is required' })
  if (!recipient) return res.status(400).json({ error: 'recipient required' })

  try {
    const id = await createBridge({
      walletAddress, fromChain, toChain,
      fromDomain: Number(fromDomain), toDomain: Number(toDomain),
      amount: Number(amount), recipient,
    })
    res.status(201).json({ id, status: 'created' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Read ───────────────────────────────────────────────────
router.get('/', async (req, res) => {
  const wallet = req.query.wallet as string | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const list = await listBridgesByWallet(wallet)
    res.json(list.map(b => ({ ...b, nextAction: nextAction(b), inFlight: isInFlight(b) })))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.get('/meta/unresolved', async (_req, res) => {
  try {
    const list = await listUnresolved()
    res.json(list.map(b => ({ ...b, nextAction: nextAction(b), inFlight: isInFlight(b) })))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.get('/:id', async (req, res) => {
  try {
    const rec = await getBridge(req.params.id)
    if (!rec) return res.status(404).json({ error: 'Bridge not found' })
    res.json({ ...rec, nextAction: nextAction(rec), inFlight: isInFlight(rec) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Progress reporting ─────────────────────────────────────
router.post('/:id/burning', async (req, res) => {
  try { await markBurning(req.params.id); res.json({ ok: true }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

/*
  THE CRITICAL ENDPOINT. Once this is stored the funds are burned and the mint
  is owed. messageBytes + messageHash are what make the mint completable later
  by anyone, so we REQUIRE them rather than accepting a bare tx hash — a burn
  recorded without them would be much harder to recover.
*/
router.post('/:id/burned', async (req, res) => {
  const { burnTx, messageBytes, messageHash } = req.body
  if (!burnTx)       return res.status(400).json({ error: 'burnTx required' })
  if (!messageBytes) return res.status(400).json({ error: 'messageBytes required (needed to complete the mint later)' })
  if (!messageHash)  return res.status(400).json({ error: 'messageHash required (needed to fetch the attestation)' })
  try {
    await markBurned(req.params.id, { burnTx, messageBytes, messageHash })
    res.json({ ok: true, status: 'attesting' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/attested', async (req, res) => {
  const { attestation } = req.body
  if (!attestation) return res.status(400).json({ error: 'attestation required' })
  try { await markAttested(req.params.id, attestation); res.json({ ok: true, status: 'minting' }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/completed', async (req, res) => {
  const { mintTx } = req.body
  if (!mintTx) return res.status(400).json({ error: 'mintTx required' })
  try { await markCompleted(req.params.id, mintTx); res.json({ ok: true, status: 'completed' }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/failed', async (req, res) => {
  const { error: reason } = req.body
  try {
    // The repository decides failed-vs-stranded based on whether a burn landed,
    // so a client can't accidentally mark burned funds as harmlessly failed.
    const outcome = await markFailed(req.params.id, String(reason ?? 'unknown'))
    res.json({ ok: true, status: outcome })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/bridge.ts"

mkdir -p "afrifx-api/src"
cat > "afrifx-api/src/index.ts" << 'AFX_EOF'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { securityHeaders }        from './middleware/security'
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
import notificationsRouter         from './routes/notifications'
import disputesRouter              from './routes/disputes'
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import { cleanExpiredSessions } from './services/auth/adminAuth'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import broadcastsRouter           from './routes/broadcasts'
import maintenanceRouter          from './routes/maintenance'
import transfersRouter, { webhookRouter } from './routes/transfers'
import bridgeRouter               from './routes/bridge'
import { startTransferReconciler } from './services/ramp/reconciler'
import { startBridgeReconciler }   from './services/bridge/reconciler'
import { maintenanceGuard }       from './lib/maintenance'
import contentRouter              from './routes/content'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startAdminAuditSummary } from './jobs/adminAuditSummary'
import { startInvoiceReminders }  from './jobs/invoiceReminders'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { startDutyScheduler }     from './jobs/dutyScheduler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

// Security headers first, so they apply to EVERY response (including errors
// and CORS preflight failures).
app.use(securityHeaders)
app.use(corsMiddleware)

// Capture the RAW body so webhook HMAC signatures can be verified against the
// exact bytes the provider signed. Re-stringifying the parsed object is NOT
// safe: key order, spacing and unicode escaping can all differ, which would
// make valid signatures fail to match.
app.use(express.json({
  verify: (req: any, _res, buf) => { req.rawBody = buf.toString('utf8') },
}))
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',          ratesRouter)
app.use('/transactions',   maintenanceGuard('convert'),     transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         maintenanceGuard('marketplace'), offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         maintenanceGuard('send'),        walletRouter)
app.use('/treasury',       maintenanceGuard('treasury'),    treasuryRouter)
app.use('/payroll',        maintenanceGuard('payroll'),     payrollRouter)
app.use('/notifications', notificationsRouter)
app.use('/disputes',       disputesRouter)
app.use('/invoices',       maintenanceGuard('invoices'),    invoicesRouter)
app.use('/payments',       maintenanceGuard('invoices'),    paymentsRouter)
app.use('/content',        contentRouter)
app.use('/admin-auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)
app.use('/admin/broadcasts', broadcastsRouter)
app.use('/maintenance',    maintenanceRouter)
app.use('/transfers',      transfersRouter)
app.use('/bridge',         bridgeRouter)
app.use('/webhooks',       webhookRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
startInvoiceReminders()
startAdminAuditSummary()

  // Clean expired admin sessions every hour
  setInterval(() => cleanExpiredSessions().catch(() => {}), 3600_000)
  startTreasuryChecker()
  startTxSettler()
  startDutyScheduler()
  startTransferReconciler()
  startBridgeReconciler()
})
AFX_EOF
echo "  afrifx-api/src/index.ts"

echo ""
echo "Done. NEXT STEPS:"
echo ""
echo "  1) Run the migration -- ONE statement at a time in the turso shell:"
echo "       turso db shell afrifx"
echo "     then paste each CREATE from afrifx-api/bridge-schema.sql"
echo "     (or, since every statement here is IF NOT EXISTS and independent:"
echo "       turso db shell afrifx < afrifx-api/bridge-schema.sql )"
echo ""
echo "  2) cd afrifx-api && npx tsc --noEmit"
echo "     cd .. && git add -A && git commit -m 'Bridge stage 2: durable state machine'"
echo "     git push"
echo ""
echo "  3) After deploy you should see in the Render logs:"
echo "       [Bridge] reconciler started (every 120s)"
echo ""
echo "  4) Sanity-check the endpoint exists (empty list is correct):"
echo "       curl 'https://afrifx-api.onrender.com/bridge?wallet=0xYourWallet'"
echo "       curl  https://afrifx-api.onrender.com/bridge/meta/unresolved"
echo ""
echo "  Still NO on-chain execution -- stage 3 adds the real burn/attest/mint."
