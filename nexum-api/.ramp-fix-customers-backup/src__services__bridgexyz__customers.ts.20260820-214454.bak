// ============================================================
// Bridge.xyz customer + KYC-link operations (Phase 1).
//
// We use Bridge's HOSTED onboarding (KYC Links / Persona) — NOT direct API
// customer creation — so Nexum never collects or transmits SSNs or ID-document
// images. We call POST /v0/kyc_links to get a Persona kyc_link + a Bridge
// tos_link, hand those to the user, and poll GET /v0/kyc_links/:id for status.
// ============================================================

import { bridgeFetch } from './client'

export type BridgeKycStatus =
  | 'not_started' | 'under_review' | 'incomplete'
  | 'awaiting_questionnaire' | 'awaiting_ubo'
  | 'approved' | 'rejected' | 'paused' | 'offboarded'

export type BridgeTosStatus = 'pending' | 'approved'

export type BridgeCustomerType = 'individual' | 'business'

export interface BridgeRejectionReason {
  developer_reason?: string
  reason?: string
  created_at?: string
}

export interface KycLinkResponse {
  id:                string
  full_name:         string
  email:             string
  type:              BridgeCustomerType
  kyc_link:          string
  tos_link:          string
  kyc_status:        BridgeKycStatus
  tos_status:        BridgeTosStatus
  rejection_reasons: BridgeRejectionReason[]
  customer_id:       string | null
  created_at?:       string
}

/**
 * Create a hosted KYC link for a new customer. Bridge returns a Persona
 * kyc_link + a ToS link. `idempotencyKey` should be stable per account so a
 * retry doesn't create a second link.
 */
export async function createKycLink(params: {
  fullName: string
  email:    string
  type:     BridgeCustomerType
  idempotencyKey: string
}): Promise<KycLinkResponse> {
  return bridgeFetch<KycLinkResponse>('kyc_links', {
    method: 'POST',
    idempotencyKey: params.idempotencyKey,
    body: {
      full_name: params.fullName,
      email:     params.email,
      type:      params.type,
    },
  })
}

/** Poll the current status of a KYC link. */
export async function getKycLink(kycLinkId: string): Promise<KycLinkResponse> {
  return bridgeFetch<KycLinkResponse>(`kyc_links/${kycLinkId}`, { method: 'GET' })
}

/**
 * SANDBOX ONLY — force a customer to KYC-approved so the flow can be tested
 * end-to-end without doing a real Persona verification. No-op signature in
 * production (Bridge rejects it), so callers must gate on sandbox.
 */
export async function simulateKycApproval(customerId: string, idempotencyKey: string): Promise<unknown> {
  return bridgeFetch(`customers/${customerId}/simulate_kyc_approval`, {
    method: 'POST',
    idempotencyKey,
  })
}
