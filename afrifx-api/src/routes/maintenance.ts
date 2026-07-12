// ============================================================
// Maintenance mode — admin toggles + a public status endpoint.
//
// GET  /maintenance/status   PUBLIC — the app reads this to show banners /
//                            disable sections. No auth (needed before login).
// GET  /maintenance          SUPER ADMIN ONLY — full state for the dashboard
// PUT  /maintenance/:section SUPER ADMIN ONLY — take a section down / up
//
// Maintenance is deliberately NOT a grantable permission: taking the platform
// offline is too dangerous to delegate. Only the super admin can do it.
// ============================================================

import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { requireAdmin, requireSuperAdmin, logAction } from '../lib/adminAuth'
import {
  SECTIONS, getMaintenance, invalidateMaintenanceCache,
  DEFAULT_MESSAGE, type Section,
} from '../lib/maintenance'

const router = Router()

// ── PUBLIC: what's currently down ──────────────────────────
// The frontend polls this to show banners and disable sections.
router.get('/status', async (_req, res) => {
  try {
    const rows = await getMaintenance()
    const down = rows.filter(r => r.enabled)
    const platform = down.find(r => r.section === 'platform') ?? null
    res.json({
      platformDown: !!platform,
      platform,
      sections: down.filter(r => r.section !== 'platform'),
      defaultMessage: DEFAULT_MESSAGE,
    })
  } catch (err: any) {
    // Never let a maintenance lookup break the app — fail open.
    res.json({ platformDown: false, platform: null, sections: [], defaultMessage: DEFAULT_MESSAGE })
  }
})

// ── ADMIN ──────────────────────────────────────────────────
router.use(requireAdmin)

// Full state (including sections that are UP), for the dashboard toggles.
router.get('/', requireSuperAdmin, async (_req, res) => {
  try {
    const rows = await getMaintenance(true)
    const bySection = new Map(rows.map(r => [r.section, r]))
    res.json({
      sections: SECTIONS.map(s => {
        const r = bySection.get(s)
        return {
          section:    s,
          enabled:    r?.enabled ?? false,
          message:    r?.message ?? null,
          eta:        r?.eta ?? null,
          enabled_by: r?.enabled_by ?? null,
          enabled_at: r?.enabled_at ?? null,
        }
      }),
      defaultMessage: DEFAULT_MESSAGE,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// Toggle a section (or 'platform') offline / back online.
router.put('/:section', requireSuperAdmin, async (req: any, res) => {
  const admin   = req.admin
  const section = req.params.section as Section
  const { enabled, message, eta } = req.body

  if (!SECTIONS.includes(section)) {
    return res.status(400).json({ error: `Unknown section '${section}'` })
  }
  if (typeof enabled !== 'boolean') {
    return res.status(400).json({ error: 'enabled (boolean) is required' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(sql`
      INSERT INTO maintenance_state
        (section, enabled, message, eta, enabled_by, enabled_at, updated_at)
      VALUES
        (${section}, ${enabled ? 1 : 0}, ${message ?? null}, ${eta ?? null},
         ${enabled ? admin.username : null}, ${enabled ? now : null}, ${now})
      ON CONFLICT(section) DO UPDATE SET
        enabled    = ${enabled ? 1 : 0},
        message    = ${message ?? null},
        eta        = ${eta ?? null},
        enabled_by = ${enabled ? admin.username : null},
        enabled_at = ${enabled ? now : null},
        updated_at = ${now}`)

    invalidateMaintenanceCache()

    await logAction(admin.id, admin.username,
      enabled ? 'maintenance_on' : 'maintenance_off', 'maintenance', section,
      enabled
        ? `Took '${section}' offline${eta ? ` (ETA: ${eta})` : ''}`
        : `Restored '${section}' to full service`,
      req.ip)

    res.json({ success: true, section, enabled })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
