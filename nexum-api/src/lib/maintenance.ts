// ============================================================
// Maintenance mode.
//
// Sections can be taken offline individually, or the whole platform at once.
// Enforced at the API (not just hidden in the UI), so nothing slips through
// but with two deliberate carve-outs:
//
//   1) IN-FLIGHT WORK STILL COMPLETES. We block endpoints that START new work
//      (create an offer, run a conversion, send funds). We do NOT block the
//      endpoints that FINISH work already underway (confirm payment, release
//      escrow, resolve a dispute). Otherwise a user's USDC could sit stranded
//      in escrow for the whole upgrade window.
//
//   2) ADMINS BYPASS. An authenticated admin can still use a section under
//      maintenance, so they can verify the upgrade before reopening it.
//
// Reads (GET) are always allowed people can still see their trades.
// ============================================================

import type { Request, Response, NextFunction } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'

export const SECTIONS = [
  'platform',      // everything
  'convert',
  'corridor',
  'send',
  'marketplace',
  'invoices',
  'treasury',
  'payroll',
] as const
export type Section = typeof SECTIONS[number]

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}
const val = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

export interface MaintenanceRow {
  section: string
  enabled: boolean
  message: string | null
  eta:     string | null
  enabled_by: string | null
  enabled_at: number | null
}

// Small cache so we don't hit the DB on every single request.
let cache: { at: number; rows: MaintenanceRow[] } = { at: 0, rows: [] }
const TTL_MS = 5_000

export async function getMaintenance(force = false): Promise<MaintenanceRow[]> {
  if (!force && Date.now() - cache.at < TTL_MS) return cache.rows
  try {
    const rows = parseRows(await db.run(sql`SELECT * FROM maintenance_state`))
    const parsed: MaintenanceRow[] = rows.map(r => ({
      section:    val(r, 'section', 0),
      enabled:    Number(val(r, 'enabled', 1) ?? 0) === 1,
      message:    val(r, 'message', 2) ?? null,
      eta:        val(r, 'eta', 3) ?? null,
      enabled_by: val(r, 'enabled_by', 4) ?? null,
      enabled_at: val(r, 'enabled_at', 5) ?? null,
    }))
    cache = { at: Date.now(), rows: parsed }
    return parsed
  } catch {
    // If the table doesn't exist yet, treat everything as live rather than
    // accidentally locking the platform.
    return []
  }
}

export function invalidateMaintenanceCache() { cache = { at: 0, rows: [] } }

// Is this section (or the whole platform) currently down?
export async function isDown(section: Section): Promise<MaintenanceRow | null> {
  const rows = await getMaintenance()
  const platform = rows.find(r => r.section === 'platform' && r.enabled)
  if (platform) return platform
  return rows.find(r => r.section === section && r.enabled) ?? null
}

export const DEFAULT_MESSAGE =
  'This section is temporarily unavailable while we perform a scheduled upgrade. Trades already in progress will complete normally.'

/*
  Endpoints that FINISH work already underway. These stay open during
  maintenance so nobody's funds get stranded mid-trade.

  Matched against the path WITHIN the router (req.path), e.g. for
  /offers/:id/confirm the router sees "/abc123/confirm".
*/
const ALLOW_WHEN_DOWN = [
  /\/confirm$/i,          // taker/maker confirming an in-flight trade
  /\/release$/i,          // releasing escrow
  /\/cancel$/i,           // cancelling an in-flight trade (returns funds)
  /\/dispute/i,           // raising or working a dispute on an existing trade
  /\/messages/i,          // chat on an existing trade/dispute
  /\/resolve$/i,          // admin resolving a dispute
]

function completesInFlightWork(path: string): boolean {
  return ALLOW_WHEN_DOWN.some(re => re.test(path))
}

/*
  Guard a router. Blocks WRITES that start new work while the section is down.
  Reads pass. In-flight completion passes. Admins pass.
*/
export function maintenanceGuard(section: Section) {
  return async (req: Request, res: Response, next: NextFunction) => {
    // Reads are always fine users can still see their trades.
    if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') {
      return next()
    }

    const down = await isDown(section)
    if (!down) return next()

    // Admins bypass, so they can verify the upgrade before reopening.
    if ((req as any).admin) return next()

    // Let people finish what they already started.
    if (completesInFlightWork(req.path)) return next()

    return res.status(503).json({
      error:       down.message?.trim() || DEFAULT_MESSAGE,
      maintenance: true,
      section:     down.section,
      eta:         down.eta ?? null,
    })
  }
}
