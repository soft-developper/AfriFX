// ============================================================
// /ramp — Bridge.xyz fiat on/off-ramp routes.
//
// User-facing name is "On/Off-ramp"; the route is /ramp (NOT /bridge, which is
// the CCTP cross-chain bridge). Phase 0 exposes only read-only endpoints:
//   GET /ramp/health    — config + live reachability (the sandbox smoke test)
//   GET /ramp/corridors — the data-driven supported-corridor list
// No customer creation, no DB, no money movement yet.
// ============================================================

import { Router } from 'express'
import { bridgeXyzConfigured, bridgePing, BRIDGE_IS_SANDBOX } from '../services/bridgexyz/client'
import { onrampCorridors, BRIDGE_LANDING_CHAIN } from '../services/bridgexyz/config'

const router = Router()

// GET /ramp/health
// Reports whether Bridge is configured and, if so, whether the key actually
// authenticates against the live API. Safe to call from anywhere — read-only.
router.get('/health', async (_req, res) => {
  const configured = bridgeXyzConfigured()
  const base = {
    provider:    'bridgexyz',
    configured,
    env:         BRIDGE_IS_SANDBOX ? 'sandbox' : 'production',
    landingChain: BRIDGE_LANDING_CHAIN,
  }

  if (!configured) {
    // Not an error: the app runs fine without Bridge keys.
    return res.json({ ...base, reachable: false, note: 'BRIDGE_API_KEY not set' })
  }

  try {
    await bridgePing()
    res.json({ ...base, reachable: true })
  } catch (err: any) {
    res.status(502).json({
      ...base,
      reachable: false,
      error: err?.message ?? 'Bridge ping failed',
      status: err?.status,
    })
  }
})

// GET /ramp/corridors — the supported on-ramp corridors (data-driven).
router.get('/corridors', (_req, res) => {
  res.json({ onramp: onrampCorridors() })
})

export default router
