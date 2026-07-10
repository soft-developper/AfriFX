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
