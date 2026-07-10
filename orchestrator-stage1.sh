#!/bin/bash
# ============================================================
# AfriFX -- Payout Orchestrator, STAGE 1: provider-agnostic foundation
#
# Backend-only, fully ADDITIVE (no existing files touched -> zero risk to the
# running app). Nothing here is wired into routes yet; it's the foundation the
# state machine (stage 2) builds on. Everything is testable with the included
# mock provider -- no HoneyCoin/Yellow Card keys needed.
#
# Files:
#   orchestrator-schema.sql            -- transfers + transfer_legs tables (run vs DB)
#   src/services/ramp/types.ts         -- the FiatRampProvider interface + shared types
#   src/services/ramp/repository.ts    -- data access for transfers/legs
#   src/services/ramp/providers/mock.ts-- a working fake provider for testing
#   src/services/ramp/registry.ts      -- resolves a provider by key (mock registered)
#
# Run from ~/AfriFX:  bash orchestrator-stage1.sh
# ============================================================
set -e
echo ""
echo "Installing payout orchestrator stage 1 (provider-agnostic core)..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/orchestrator-schema.sql" << 'AFX_EOF'
-- ============================================================
-- Payout orchestrator schema — cross-border transfers
--
-- Two tables:
--   transfers      — one row per end-to-end transfer (user-facing summary)
--   transfer_legs  — one row per leg (the audit trail the orchestrator walks)
--
-- Provider-agnostic: no HoneyCoin/Yellow Card specifics live here.
-- Safe to run more than once (IF NOT EXISTS).
-- Run:  turso db shell <your-db-name> < afrifx-api/orchestrator-schema.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS transfers (
  id                TEXT PRIMARY KEY,           -- 'tr-<uuid>'
  sender_address    TEXT NOT NULL,              -- AfriFX wallet initiating
  sender_mode       TEXT NOT NULL,              -- 'fiat_in' | 'usdc_in'

  -- What the sender is sending
  source_currency   TEXT NOT NULL,              -- 'NGN' (fiat_in) or 'USDC' (usdc_in)
  source_amount     REAL NOT NULL,

  -- What the recipient receives
  dest_currency     TEXT NOT NULL,              -- 'KES'
  dest_amount       REAL,                        -- quoted; may firm up after quote
  usdc_amount       REAL,                        -- settlement amount in USDC (the middle)

  -- Recipient payout details (who gets the money)
  recipient_name    TEXT NOT NULL,
  recipient_method  TEXT NOT NULL,              -- 'bank' | 'mobile_money'
  recipient_account TEXT NOT NULL,              -- account no. OR phone
  recipient_bank    TEXT NOT NULL,              -- bank name/code OR provider
  recipient_country TEXT NOT NULL,              -- ISO-2 'KE'
  recipient_note    TEXT,

  -- Routing
  provider          TEXT NOT NULL,              -- 'honeycoin' | 'yellowcard' | 'mock'
  payout_chain      TEXT,                        -- chain provider wants USDC on, e.g. 'base'
  needs_bridge      INTEGER DEFAULT 0,          -- 1 if source USDC is on Arc and must be bridged

  -- FX quote lock
  quote_id          TEXT,
  quote_rate        REAL,
  quote_expires_at  INTEGER,

  -- Lifecycle
  status            TEXT NOT NULL DEFAULT 'created',
                    -- created | in_progress | completed | failed | refunding | refunded
  current_leg       TEXT,
  failure_reason    TEXT,

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS transfer_legs (
  id              TEXT PRIMARY KEY,             -- 'lg-<uuid>'
  transfer_id     TEXT NOT NULL,               -- -> transfers.id
  leg_type        TEXT NOT NULL,               -- 'onramp'|'collect'|'bridge'|'offramp'|'payout'|'reconcile'
  leg_index       INTEGER NOT NULL,            -- ordering (0,1,2,...)

  status          TEXT NOT NULL DEFAULT 'pending',
                  -- pending | in_flight | done | failed | skipped
  idempotency_key TEXT NOT NULL,               -- prevents double-submits (== provider externalReference)

  -- Evidence, whichever apply to the leg
  provider_ref    TEXT,                         -- provider transaction id
  tx_hash         TEXT,                         -- on-chain hash (collect/bridge)
  attestation     TEXT,                         -- CCTP attestation (bridge)
  amount          REAL,
  currency        TEXT,

  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

-- Helpful indexes for the tick loop and lookups
CREATE INDEX IF NOT EXISTS idx_transfers_status      ON transfers (status);
CREATE INDEX IF NOT EXISTS idx_transfers_sender      ON transfers (sender_address);
CREATE INDEX IF NOT EXISTS idx_legs_transfer         ON transfer_legs (transfer_id);
CREATE INDEX IF NOT EXISTS idx_legs_status           ON transfer_legs (status);
CREATE INDEX IF NOT EXISTS idx_legs_idem             ON transfer_legs (idempotency_key);
AFX_EOF
echo "  afrifx-api/orchestrator-schema.sql"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/types.ts" << 'AFX_EOF'
// ============================================================
// Provider-agnostic fiat on/off-ramp interface.
//
// The orchestrator talks ONLY to this interface. HoneyCoin, Yellow Card, or a
// mock are each an implementation. No core logic references any provider by name.
// See PAYOUT_ORCHESTRATOR_DESIGN.md §8 and HONEYCOIN_INTEGRATION_NOTES.md.
// ============================================================

export type LegType =
  | 'onramp' | 'collect' | 'bridge' | 'offramp' | 'payout' | 'reconcile'

export type LegStatus =
  | 'pending' | 'in_flight' | 'done' | 'failed' | 'skipped'

export type TransferStatus =
  | 'created' | 'in_progress' | 'completed' | 'failed' | 'refunding' | 'refunded'

export type SenderMode = 'fiat_in' | 'usdc_in'
export type PayoutMethod = 'bank' | 'mobile_money'

// A chain key as providers name them. Arc is ours; the rest are provider-side.
export type ChainKey =
  | 'arc' | 'eth' | 'arb' | 'base' | 'matic' | 'bsc' | 'optimism'

export interface RampQuote {
  quoteId:    string
  rate:       number      // dest per USDC (or provider's convention)
  expiresAt:  number      // unix seconds
  usdcAmount: number
  destAmount: number
}

export interface PayoutRecipient {
  name:    string
  method:  PayoutMethod
  account: string         // account number OR phone
  bank:    string         // bank name/code OR mobile-money provider code
  country: string         // ISO-2, e.g. 'KE'
  note?:   string
}

export interface OnrampResult {
  providerRef:     string
  // Whatever the customer must do to pay (STK push id, virtual account, link…)
  payInstructions?: unknown
}

export interface PayoutResult {
  providerRef:   string
  depositAddress: string     // where WE send USDC
  depositChain:  ChainKey     // chain that address expects
  expectedAmount: number      // EXACT USDC to send (providers may auto-refund otherwise)
}

// Normalized shape a provider's webhook is translated into.
export interface NormalizedWebhook {
  providerRef?:      string
  externalReference?: string   // our idempotency key — how we find the transfer/leg
  leg:    'onramp' | 'offramp' | 'payout'
  status: 'done' | 'failed' | 'pending'
  detail?: unknown
}

export interface FiatRampProvider {
  readonly key: string        // 'honeycoin' | 'yellowcard' | 'mock'

  // Which chains this provider settles USDC on (drives bridge/no-bridge).
  supportedChains(): Promise<ChainKey[]>

  // Case A: collect local fiat, settle USDC to an address WE control.
  createOnramp(params: {
    idempotencyKey: string
    senderAmount:   number
    senderCurrency: string
    receiverChain:  ChainKey
    receiverAddress: string
    method:  PayoutMethod
    charge:  Record<string, string>   // phone+operator OR account+bankCode
    email?:  string
  }): Promise<OnrampResult>

  // Quote for the off-ramp conversion (USDC -> dest fiat).
  getPayoutQuote(params: {
    usdcAmount:   number
    destCurrency: string
    country:      string
  }): Promise<RampQuote>

  // Off-ramp + payout: receive USDC at a deposit address, pay out to recipient.
  createPayout(params: {
    idempotencyKey: string
    usdcAmount:     number
    chain:          ChainKey
    recipient:      PayoutRecipient
  }): Promise<PayoutResult>

  // Translate a raw provider webhook into our normalized shape.
  parseWebhook(body: unknown, headers: Record<string, string>): NormalizedWebhook

  // Backstop: query real status by our idempotency key / provider ref.
  getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }>
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/types.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/repository.ts" << 'AFX_EOF'
// ============================================================
// Data access for transfers + transfer_legs.
// Thin wrapper over db.run(sql`...`), matching the codebase's raw-SQL style
// (same parseRows pattern used in txSettler / routes).
// ============================================================

import { db } from '../../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import type { LegType, LegStatus, TransferStatus, SenderMode, PayoutMethod, ChainKey } from './types'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const now = () => Math.floor(Date.now() / 1000)

export interface NewTransfer {
  senderAddress:    string
  senderMode:       SenderMode
  sourceCurrency:   string
  sourceAmount:     number
  destCurrency:     string
  destAmount?:      number
  usdcAmount?:      number
  recipientName:    string
  recipientMethod:  PayoutMethod
  recipientAccount: string
  recipientBank:    string
  recipientCountry: string
  recipientNote?:   string
  provider:         string
  payoutChain?:     ChainKey
  needsBridge?:     boolean
}

export async function createTransfer(t: NewTransfer): Promise<string> {
  const id = `tr-${randomUUID()}`
  const ts = now()
  await db.run(sql`
    INSERT INTO transfers
      (id, sender_address, sender_mode, source_currency, source_amount,
       dest_currency, dest_amount, usdc_amount,
       recipient_name, recipient_method, recipient_account, recipient_bank,
       recipient_country, recipient_note, provider, payout_chain, needs_bridge,
       status, created_at, updated_at)
    VALUES
      (${id}, ${t.senderAddress.toLowerCase()}, ${t.senderMode},
       ${t.sourceCurrency}, ${t.sourceAmount}, ${t.destCurrency},
       ${t.destAmount ?? null}, ${t.usdcAmount ?? null},
       ${t.recipientName}, ${t.recipientMethod}, ${t.recipientAccount},
       ${t.recipientBank}, ${t.recipientCountry}, ${t.recipientNote ?? null},
       ${t.provider}, ${t.payoutChain ?? null}, ${t.needsBridge ? 1 : 0},
       'created', ${ts}, ${ts})`)
  return id
}

export async function getTransfer(id: string): Promise<any | null> {
  const rows = parseRows(await db.run(
    sql`SELECT * FROM transfers WHERE id = ${id} LIMIT 1`))
  return rows[0] ?? null
}

export async function listTransfersBySender(addr: string): Promise<any[]> {
  return parseRows(await db.run(
    sql`SELECT * FROM transfers WHERE LOWER(sender_address) = ${addr.toLowerCase()}
        ORDER BY created_at DESC LIMIT 50`))
}

export async function updateTransfer(
  id: string,
  fields: Partial<{ status: TransferStatus; current_leg: LegType | null;
                    failure_reason: string | null; dest_amount: number;
                    usdc_amount: number; quote_id: string; quote_rate: number;
                    quote_expires_at: number }>,
): Promise<void> {
  const ts = now()
  // Build a small dynamic SET; each field guarded so we only touch what's passed.
  const sets: any[] = []
  if (fields.status !== undefined)          sets.push(sql`status = ${fields.status}`)
  if (fields.current_leg !== undefined)     sets.push(sql`current_leg = ${fields.current_leg}`)
  if (fields.failure_reason !== undefined)  sets.push(sql`failure_reason = ${fields.failure_reason}`)
  if (fields.dest_amount !== undefined)     sets.push(sql`dest_amount = ${fields.dest_amount}`)
  if (fields.usdc_amount !== undefined)     sets.push(sql`usdc_amount = ${fields.usdc_amount}`)
  if (fields.quote_id !== undefined)        sets.push(sql`quote_id = ${fields.quote_id}`)
  if (fields.quote_rate !== undefined)      sets.push(sql`quote_rate = ${fields.quote_rate}`)
  if (fields.quote_expires_at !== undefined) sets.push(sql`quote_expires_at = ${fields.quote_expires_at}`)
  if (!sets.length) return
  const setClause = sql.join(sets, sql`, `)
  await db.run(sql`UPDATE transfers SET ${setClause}, updated_at = ${ts} WHERE id = ${id}`)
}

export async function createLeg(params: {
  transferId: string; legType: LegType; legIndex: number; idempotencyKey: string;
  status?: LegStatus; amount?: number; currency?: string
}): Promise<string> {
  const id = `lg-${randomUUID()}`
  const ts = now()
  await db.run(sql`
    INSERT INTO transfer_legs
      (id, transfer_id, leg_type, leg_index, status, idempotency_key,
       amount, currency, created_at, updated_at)
    VALUES
      (${id}, ${params.transferId}, ${params.legType}, ${params.legIndex},
       ${params.status ?? 'pending'}, ${params.idempotencyKey},
       ${params.amount ?? null}, ${params.currency ?? null}, ${ts}, ${ts})`)
  return id
}

export async function getLegs(transferId: string): Promise<any[]> {
  return parseRows(await db.run(
    sql`SELECT * FROM transfer_legs WHERE transfer_id = ${transferId}
        ORDER BY leg_index ASC`))
}

export async function updateLeg(
  id: string,
  fields: Partial<{ status: LegStatus; provider_ref: string; tx_hash: string;
                    attestation: string; error: string | null; amount: number }>,
): Promise<void> {
  const ts = now()
  const sets: any[] = []
  if (fields.status !== undefined)       sets.push(sql`status = ${fields.status}`)
  if (fields.provider_ref !== undefined) sets.push(sql`provider_ref = ${fields.provider_ref}`)
  if (fields.tx_hash !== undefined)      sets.push(sql`tx_hash = ${fields.tx_hash}`)
  if (fields.attestation !== undefined)  sets.push(sql`attestation = ${fields.attestation}`)
  if (fields.error !== undefined)        sets.push(sql`error = ${fields.error}`)
  if (fields.amount !== undefined)       sets.push(sql`amount = ${fields.amount}`)
  if (!sets.length) return
  const setClause = sql.join(sets, sql`, `)
  await db.run(sql`UPDATE transfer_legs SET ${setClause}, updated_at = ${ts} WHERE id = ${id}`)
}

export async function findLegByIdempotencyKey(key: string): Promise<any | null> {
  const rows = parseRows(await db.run(
    sql`SELECT * FROM transfer_legs WHERE idempotency_key = ${key} LIMIT 1`))
  return rows[0] ?? null
}

export { parseRows }
AFX_EOF
echo "  afrifx-api/src/services/ramp/repository.ts"

mkdir -p "afrifx-api/src/services/ramp/providers"
cat > "afrifx-api/src/services/ramp/providers/mock.ts" << 'AFX_EOF'
// ============================================================
// Mock fiat ramp provider — a fully working fake for testing the orchestrator
// state machine end-to-end with NO real API keys. Mirrors the SHAPES HoneyCoin
// returns (see HONEYCOIN_INTEGRATION_NOTES.md) so swapping in the real one
// later changes nothing in the core.
//
// Behaviour is deterministic + controllable via the idempotency key suffix so
// tests can force outcomes:
//   key ending in ':fail_onramp'  -> onramp reports failed
//   key ending in ':fail_payout'  -> payout reports failed
// Otherwise everything succeeds.
// ============================================================

import type {
  FiatRampProvider, ChainKey, RampQuote, PayoutRecipient,
  OnrampResult, PayoutResult, NormalizedWebhook,
} from '../types'
import { randomUUID } from 'crypto'

export class MockProvider implements FiatRampProvider {
  readonly key = 'mock'

  async supportedChains(): Promise<ChainKey[]> {
    // Mirror HoneyCoin: no Arc, settles on major EVM chains.
    return ['eth', 'arb', 'base', 'matic', 'bsc', 'optimism']
  }

  async createOnramp(params: {
    idempotencyKey: string; senderAmount: number; senderCurrency: string
    receiverChain: ChainKey; receiverAddress: string
    method: 'bank' | 'mobile_money'; charge: Record<string, string>; email?: string
  }): Promise<OnrampResult> {
    return {
      providerRef: `mock_on_${randomUUID().slice(0, 8)}`,
      payInstructions: { note: 'MOCK: pretend the customer paid via ' + params.method },
    }
  }

  async getPayoutQuote(params: {
    usdcAmount: number; destCurrency: string; country: string
  }): Promise<RampQuote> {
    // A plausible fake rate; e.g. 1 USDC ~ 130 KES / 1600 NGN, else 1.
    const table: Record<string, number> = { KES: 130, NGN: 1600, GHS: 15, ZAR: 18, UGX: 3700 }
    const rate = table[params.destCurrency] ?? 1
    return {
      quoteId:   `mock_q_${randomUUID().slice(0, 8)}`,
      rate,
      expiresAt: Math.floor(Date.now() / 1000) + 3600, // 1h window, like HoneyCoin
      usdcAmount: params.usdcAmount,
      destAmount: +(params.usdcAmount * rate).toFixed(2),
    }
  }

  async createPayout(params: {
    idempotencyKey: string; usdcAmount: number; chain: ChainKey; recipient: PayoutRecipient
  }): Promise<PayoutResult> {
    return {
      providerRef:    `mock_off_${randomUUID().slice(0, 8)}`,
      depositAddress: '0x000000000000000000000000000000000000dEaD',
      depositChain:   params.chain,
      expectedAmount: params.usdcAmount, // exact-amount, like HoneyCoin
    }
  }

  parseWebhook(body: unknown, _headers: Record<string, string>): NormalizedWebhook {
    const b = (body ?? {}) as any
    const data = b.data ?? {}
    const legMap: Record<string, 'onramp' | 'offramp' | 'payout'> = {
      onramp: 'onramp', offramp: 'offramp', withdrawal: 'payout',
    }
    return {
      providerRef:       data.transactionId,
      externalReference: data.externalReference,
      leg:    legMap[data.type] ?? 'payout',
      status: data.status === 'successful' ? 'done'
            : data.status === 'failed'     ? 'failed' : 'pending',
      detail: data,
    }
  }

  async getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }> {
    const key = ref.idempotencyKey ?? ''
    if (key.endsWith(':fail_onramp') || key.endsWith(':fail_payout')) {
      return { status: 'failed', detail: { mock: true } }
    }
    return { status: 'done', detail: { mock: true } }
  }
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/providers/mock.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/registry.ts" << 'AFX_EOF'
// ============================================================
// Provider registry. The orchestrator asks for a provider by key; whichever
// implementations are registered are available. This is where HoneyCoin /
// Yellow Card get plugged in later — the core never imports them directly.
// ============================================================

import type { FiatRampProvider } from './types'
import { MockProvider } from './providers/mock'

const registry = new Map<string, FiatRampProvider>()

export function registerProvider(p: FiatRampProvider) {
  registry.set(p.key, p)
}

export function getProvider(key: string): FiatRampProvider {
  const p = registry.get(key)
  if (!p) throw new Error(`No fiat ramp provider registered for key '${key}'`)
  return p
}

export function listProviders(): string[] {
  return [...registry.keys()]
}

// Register the mock by default so the state machine is testable with no keys.
// Real providers (honeycoin, yellowcard) are registered from here once built.
registerProvider(new MockProvider())
AFX_EOF
echo "  afrifx-api/src/services/ramp/registry.ts"

echo ""
echo "Done. NEXT STEPS:"
echo ""
echo "  1) Create the DB tables (run ONCE against your Turso database):"
echo "       turso db shell <your-db-name> < afrifx-api/orchestrator-schema.sql"
echo ""
echo "  2) Typecheck (nothing is wired into routes yet, so the app is unchanged):"
echo "       cd afrifx-api && npx tsc --noEmit"
echo ""
echo "  Note: this stage adds NO new routes and touches NO existing files, so it"
echo "  is safe to commit and deploy with no behavioural change. It's the"
echo "  foundation for stage 2 (the state machine + CCTP bridge + mock end-to-end)."
echo ""
echo "  Commit when ready:"
echo "     git add -A && git commit -m 'Orchestrator stage 1: provider-agnostic core + mock'"
echo "     git push"
