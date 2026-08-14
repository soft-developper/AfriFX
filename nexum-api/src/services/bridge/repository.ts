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
