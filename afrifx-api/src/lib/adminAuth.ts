import bcrypt from 'bcryptjs'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import type { Request, Response, NextFunction } from 'express'
import { validateSession, parsePermissions } from '../services/auth/adminAuth'

export interface AdminPayload {
  id:          string
  username:    string
  role:        string
  permissions: string[]
}

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export async function hashPassword(pw: string): Promise<string> {
  return bcrypt.hash(pw, 10)
}

export async function verifyPassword(pw: string, hash: string): Promise<boolean> {
  return bcrypt.compare(pw, hash)
}

// Normalize admin row
export function normalizeAdmin(row: any) {
  const a = Array.isArray(row) ? {
    id: row[0], username: row[1], email: row[2], password_hash: row[3],
    wallet_address: row[4], role: row[5], permissions: row[6],
    status: row[7], suspended_until: row[8], created_by: row[9],
    last_login: row[10], created_at: row[11], updated_at: row[12],
  } : row
  return {
    ...a,
    permissions: parsePermissions(a.role, a.permissions),
  }
}

// Middleware: require a valid admin session (shared with /admin-auth/*
// — issued by services/auth/adminAuth.createSession, backed by admin_sessions)
export async function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const auth  = req.headers.authorization
  const token = auth?.startsWith('Bearer ') ? auth.slice(7) : null
  if (!token) return res.status(401).json({ error: 'No token provided' })

  const session = await validateSession(token)
  if (!session) return res.status(401).json({ error: 'Invalid or expired session' })

  const adminId = session.aid ?? session.admin_id

  // Re-check admin still exists and is active (not suspended)
  try {
    const rows = await db.run(sql`SELECT * FROM admins WHERE id = ${adminId} LIMIT 1`)
    const r = parseRows(rows)
    if (!r.length) return res.status(401).json({ error: 'Admin not found' })

    const admin = normalizeAdmin(r[0])
    const now   = Math.floor(Date.now() / 1000)

    if (admin.status === 'suspended') {
      if (!admin.suspended_until || admin.suspended_until > now) {
        return res.status(403).json({ error: 'Account suspended' })
      }
      // Suspension expired — reactivate
      await db.run(sql`UPDATE admins SET status = 'active', suspended_until = NULL WHERE id = ${admin.id}`)
    }

    // Attach to request — refresh permissions from DB (in case they changed)
    ;(req as any).admin = {
      id:          admin.id,
      username:    admin.username,
      role:        admin.role,
      permissions: admin.permissions,
    }
    next()
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
}

// Middleware factory: require a specific permission
export function requirePermission(permission: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    const admin = (req as any).admin as AdminPayload
    if (!admin) return res.status(401).json({ error: 'Not authenticated' })

    // Super admin has all permissions
    if (admin.role === 'super_admin') return next()

    if (!admin.permissions.includes(permission)) {
      return res.status(403).json({ error: `Missing permission: ${permission}` })
    }
    next()
  }
}

// Audit log helper
export async function logAction(
  adminId:    string,
  adminName:  string,
  action:     string,
  targetType?: string,
  targetId?:   string,
  details?:    string,
  ip?:         string,
) {
  try {
    await db.run(
      sql`INSERT INTO admin_audit_log
          (id, admin_id, admin_name, action, target_type, target_id, details, ip_address, created_at)
          VALUES
          (${randomUUID()}, ${adminId}, ${adminName}, ${action},
           ${targetType ?? null}, ${targetId ?? null}, ${details ?? null},
           ${ip ?? null}, ${Math.floor(Date.now() / 1000)})`
    )
  } catch (err: any) {
    console.error('[Audit] Failed to log:', err.message)
  }
}
