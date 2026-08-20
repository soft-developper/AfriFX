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
