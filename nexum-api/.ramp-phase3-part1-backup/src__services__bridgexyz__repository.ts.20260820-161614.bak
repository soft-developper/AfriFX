// ============================================================
// ramp_customers repository — DB access for Bridge.xyz customer/KYC records.
// One row per Nexum account. Mirrors the db.run(sql`…`) + parseRows pattern
// used across the API.
// ============================================================

import { db }  from '../../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import type { BridgeCustomerType, BridgeKycStatus, BridgeTosStatus } from './customers'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export interface RampCustomerRow {
  id:                string
  account_id:        string
  provider:          string
  customer_type:     BridgeCustomerType
  kyc_link_id:       string | null
  customer_id:       string | null
  kyc_link:          string | null
  tos_link:          string | null
  kyc_status:        BridgeKycStatus
  tos_status:        BridgeTosStatus
  rejection_reasons: string | null
  created_at:        number
  updated_at:        number
}

export async function getRampCustomerByAccount(accountId: string): Promise<RampCustomerRow | null> {
  const rows = await db.run(
    sql`SELECT * FROM ramp_customers WHERE account_id = ${accountId} LIMIT 1`)
  return (parseRows(rows)[0] as RampCustomerRow) ?? null
}

export async function getRampCustomerByKycLink(kycLinkId: string): Promise<RampCustomerRow | null> {
  const rows = await db.run(
    sql`SELECT * FROM ramp_customers WHERE kyc_link_id = ${kycLinkId} LIMIT 1`)
  return (parseRows(rows)[0] as RampCustomerRow) ?? null
}

export async function createRampCustomer(params: {
  accountId:     string
  customerType:  BridgeCustomerType
  kycLinkId:     string
  customerId:    string | null
  kycLink:       string
  tosLink:       string
  kycStatus:     BridgeKycStatus
  tosStatus:     BridgeTosStatus
}): Promise<RampCustomerRow> {
  const now = Math.floor(Date.now() / 1000)
  const id  = randomUUID()
  await db.run(sql`
    INSERT INTO ramp_customers
      (id, account_id, provider, customer_type, kyc_link_id, customer_id,
       kyc_link, tos_link, kyc_status, tos_status, rejection_reasons,
       created_at, updated_at)
    VALUES
      (${id}, ${params.accountId}, 'bridgexyz', ${params.customerType},
       ${params.kycLinkId}, ${params.customerId}, ${params.kycLink},
       ${params.tosLink}, ${params.kycStatus}, ${params.tosStatus}, NULL,
       ${now}, ${now})`)
  const created = await getRampCustomerByAccount(params.accountId)
  if (!created) throw new Error('Failed to create ramp customer')
  return created
}

export async function updateRampCustomerStatus(params: {
  accountId:        string
  kycStatus:        BridgeKycStatus
  tosStatus:        BridgeTosStatus
  customerId?:      string | null
  rejectionReasons?: string | null
}): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`
    UPDATE ramp_customers
       SET kyc_status = ${params.kycStatus},
           tos_status = ${params.tosStatus},
           customer_id = COALESCE(${params.customerId ?? null}, customer_id),
           rejection_reasons = ${params.rejectionReasons ?? null},
           updated_at = ${now}
     WHERE account_id = ${params.accountId}`)
}

// ══════════════════════════════════════════════════════════
// Phase 2 — corridors + virtual accounts
// ══════════════════════════════════════════════════════════

export interface RampCorridorRow {
  id:          string
  direction:   string
  currency:    string
  label:       string
  min_amount:  number | null
  enabled:     number
  sort_order:  number
  created_at:  number
  updated_at:  number
}

/** Enabled on-ramp corridors, in display order. Reads replace the old static array. */
export async function listEnabledOnrampCorridors(): Promise<RampCorridorRow[]> {
  const rows = await db.run(sql`
    SELECT * FROM ramp_corridors
     WHERE direction = 'onramp' AND enabled = 1
     ORDER BY sort_order ASC, currency ASC`)
  return parseRows(rows) as RampCorridorRow[]
}

/** A single enabled on-ramp corridor by currency, or null. */
export async function getEnabledOnrampCorridor(currency: string): Promise<RampCorridorRow | null> {
  const rows = await db.run(sql`
    SELECT * FROM ramp_corridors
     WHERE direction = 'onramp' AND enabled = 1 AND currency = ${currency}
     LIMIT 1`)
  return (parseRows(rows)[0] as RampCorridorRow) ?? null
}

export interface RampVirtualAccountRow {
  id:                   string
  account_id:           string
  provider:             string
  currency:             string
  bridge_customer_id:   string
  virtual_account_id:   string
  destination_address:  string
  destination_chain:    string
  deposit_instructions: string | null
  status:               string
  created_at:           number
  updated_at:           number
}

export async function getVirtualAccountsByAccount(accountId: string): Promise<RampVirtualAccountRow[]> {
  const rows = await db.run(sql`
    SELECT * FROM ramp_virtual_accounts
     WHERE account_id = ${accountId}
     ORDER BY created_at ASC`)
  return parseRows(rows) as RampVirtualAccountRow[]
}

export async function getVirtualAccountByAccountCurrency(
  accountId: string, currency: string,
): Promise<RampVirtualAccountRow | null> {
  const rows = await db.run(sql`
    SELECT * FROM ramp_virtual_accounts
     WHERE account_id = ${accountId} AND currency = ${currency}
     LIMIT 1`)
  return (parseRows(rows)[0] as RampVirtualAccountRow) ?? null
}

export async function createVirtualAccountRow(params: {
  accountId:           string
  currency:            string
  bridgeCustomerId:    string
  virtualAccountId:    string
  destinationAddress:  string
  destinationChain:    string
  depositInstructions: string | null
  status:              string
}): Promise<RampVirtualAccountRow> {
  const now = Math.floor(Date.now() / 1000)
  const id  = randomUUID()
  await db.run(sql`
    INSERT INTO ramp_virtual_accounts
      (id, account_id, provider, currency, bridge_customer_id, virtual_account_id,
       destination_address, destination_chain, deposit_instructions, status,
       created_at, updated_at)
    VALUES
      (${id}, ${params.accountId}, 'bridgexyz', ${params.currency},
       ${params.bridgeCustomerId}, ${params.virtualAccountId},
       ${params.destinationAddress}, ${params.destinationChain},
       ${params.depositInstructions}, ${params.status}, ${now}, ${now})`)
  const created = await getVirtualAccountByAccountCurrency(params.accountId, params.currency)
  if (!created) throw new Error('Failed to create ramp virtual account')
  return created
}

/** Refresh the mirrored deposit instructions + status for a VA (e.g. after re-fetch). */
export async function updateVirtualAccountRow(params: {
  accountId:            string
  currency:             string
  depositInstructions?: string | null
  status?:              string
}): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`
    UPDATE ramp_virtual_accounts
       SET deposit_instructions = COALESCE(${params.depositInstructions ?? null}, deposit_instructions),
           status = COALESCE(${params.status ?? null}, status),
           updated_at = ${now}
     WHERE account_id = ${params.accountId} AND currency = ${params.currency}`)
}
