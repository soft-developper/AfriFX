// ============================================================
// /ramp — Bridge.xyz fiat on/off-ramp routes.
//
// User-facing name is "On/Off-ramp"; the route is /ramp (NOT /bridge, which is
// the CCTP cross-chain bridge).
//
// Phase 0 (read-only):
//   GET  /ramp/health    — config + live reachability (the sandbox smoke test)
//   GET  /ramp/corridors — the data-driven supported-corridor list
// Phase 1 (customer + hosted KYC):
//   GET  /ramp/customer         — this account's ramp/KYC record (or null)
//   POST /ramp/customer         — lazily create a hosted KYC link (individual|business)
//   GET  /ramp/customer/refresh — poll Bridge for latest KYC/ToS status, mirror + return
//   POST /ramp/customer/simulate-approve — SANDBOX ONLY: force KYC approved for testing
// ============================================================

import { Router } from 'express'
import { requireAccount } from '../lib/accountAuth'
import { bridgeXyzConfigured, bridgePing, BRIDGE_IS_SANDBOX } from '../services/bridgexyz/client'
import { onrampCorridors, BRIDGE_LANDING_CHAIN } from '../services/bridgexyz/config'
import {
  createKycLink, getKycLink, simulateKycApproval,
  type BridgeCustomerType,
} from '../services/bridgexyz/customers'
import {
  getRampCustomerByAccount, createRampCustomer, updateRampCustomerStatus,
  type RampCustomerRow,
} from '../services/bridgexyz/repository'

const router = Router()

// ---- Phase 0: health + corridors -------------------------------------------

// GET /ramp/health
router.get('/health', async (_req, res) => {
  const configured = bridgeXyzConfigured()
  const base = {
    provider:     'bridgexyz',
    configured,
    env:          BRIDGE_IS_SANDBOX ? 'sandbox' : 'production',
    landingChain: BRIDGE_LANDING_CHAIN,
  }
  if (!configured) {
    return res.json({ ...base, reachable: false, note: 'BRIDGE_API_KEY not set' })
  }
  try {
    await bridgePing()
    res.json({ ...base, reachable: true })
  } catch (err: any) {
    res.status(502).json({
      ...base, reachable: false,
      error: err?.message ?? 'Bridge ping failed', status: err?.status,
    })
  }
})

// GET /ramp/corridors
router.get('/corridors', (_req, res) => {
  res.json({ onramp: onrampCorridors() })
})

// ---- Phase 1: customer + hosted KYC ----------------------------------------

// Shape returned to the client. We never expose internal ids beyond what the
// UI needs to open the hosted links and render status.
function toClient(row: RampCustomerRow) {
  return {
    customerType: row.customer_type,
    kycStatus:    row.kyc_status,
    tosStatus:    row.tos_status,
    kycLink:      row.kyc_link,
    tosLink:      row.tos_link,
    customerId:   row.customer_id,
    rejectionReasons: row.rejection_reasons ? safeParse(row.rejection_reasons) : [],
    // Convenience flag the gate UI keys off.
    verified:     row.kyc_status === 'approved' && row.tos_status === 'approved',
  }
}

function safeParse(s: string): unknown {
  try { return JSON.parse(s) } catch { return [] }
}

// GET /ramp/customer — the current account's record, or { exists: false }.
router.get('/customer', requireAccount, async (req, res) => {
  const account = (req as any).account
  try {
    const row = await getRampCustomerByAccount(account.id)
    if (!row) return res.json({ exists: false })
    res.json({ exists: true, ...toClient(row) })
  } catch (err: any) {
    res.status(500).json({ error: err?.message ?? 'Failed to load ramp customer' })
  }
})

// POST /ramp/customer — lazily create a hosted KYC link for this account.
// Body: { type?: 'individual' | 'business', fullName: string }
// email is taken from the signed-in account. Idempotent per account: if a
// record already exists we return it rather than creating a second link.
router.post('/customer', requireAccount, async (req, res) => {
  const account = (req as any).account
  if (!bridgeXyzConfigured()) {
    return res.status(503).json({ error: 'On/off-ramp is not available right now' })
  }

  const type = ((req.body?.type as BridgeCustomerType) === 'business')
    ? 'business' : 'individual'
  const fullName = String(req.body?.fullName ?? '').trim()
  if (!fullName) return res.status(400).json({ error: 'Your legal name is required' })
  if (!account.email) return res.status(400).json({ error: 'Your account has no email on file' })

  try {
    // Already onboarded (or mid-flight)? Return the existing record.
    const existing = await getRampCustomerByAccount(account.id)
    if (existing) return res.json({ exists: true, ...toClient(existing) })

    // Stable idempotency key per account so a double-submit can't mint two links.
    const link = await createKycLink({
      fullName, email: account.email, type,
      idempotencyKey: `ramp-kyc-${account.id}`,
    })

    const row = await createRampCustomer({
      accountId:    account.id,
      customerType: type,
      kycLinkId:    link.id,
      customerId:   link.customer_id,
      kycLink:      link.kyc_link,
      tosLink:      link.tos_link,
      kycStatus:    link.kyc_status,
      tosStatus:    link.tos_status,
    })
    res.json({ exists: true, ...toClient(row) })
  } catch (err: any) {
    res.status(err?.status ?? 502).json({ error: err?.message ?? 'Could not start verification' })
  }
})

// GET /ramp/customer/refresh — poll Bridge for latest status, mirror, return.
// Used while the user completes the hosted flow in another tab.
router.get('/customer/refresh', requireAccount, async (req, res) => {
  const account = (req as any).account
  try {
    const row = await getRampCustomerByAccount(account.id)
    if (!row) return res.json({ exists: false })
    if (!row.kyc_link_id) return res.json({ exists: true, ...toClient(row) })

    const link = await getKycLink(row.kyc_link_id)
    await updateRampCustomerStatus({
      accountId:  account.id,
      kycStatus:  link.kyc_status,
      tosStatus:  link.tos_status,
      customerId: link.customer_id,
      rejectionReasons: link.rejection_reasons?.length
        ? JSON.stringify(link.rejection_reasons) : null,
    })
    const updated = await getRampCustomerByAccount(account.id)
    res.json({ exists: true, ...toClient(updated as RampCustomerRow) })
  } catch (err: any) {
    res.status(err?.status ?? 502).json({ error: err?.message ?? 'Could not refresh status' })
  }
})

// POST /ramp/customer/simulate-approve — SANDBOX ONLY.
// Forces the customer to KYC-approved via Bridge's sandbox endpoint so the
// gate can be tested without a real Persona verification. Refused in prod.
router.post('/customer/simulate-approve', requireAccount, async (req, res) => {
  if (!BRIDGE_IS_SANDBOX) {
    return res.status(403).json({ error: 'Not available in production' })
  }
  const account = (req as any).account
  try {
    const row = await getRampCustomerByAccount(account.id)
    if (!row?.customer_id) {
      return res.status(400).json({
        error: 'No Bridge customer id yet — the KYC link must be started first.',
      })
    }
    await simulateKycApproval(row.customer_id, `ramp-sim-${account.id}-${Date.now()}`)
    // Re-poll so our mirror reflects the forced approval.
    if (row.kyc_link_id) {
      const link = await getKycLink(row.kyc_link_id)
      await updateRampCustomerStatus({
        accountId:  account.id,
        kycStatus:  link.kyc_status,
        tosStatus:  link.tos_status,
        customerId: link.customer_id,
      })
    }
    const updated = await getRampCustomerByAccount(account.id)
    res.json({ exists: true, ...toClient(updated as RampCustomerRow) })
  } catch (err: any) {
    res.status(err?.status ?? 502).json({ error: err?.message ?? 'Simulate approval failed' })
  }
})

export default router
