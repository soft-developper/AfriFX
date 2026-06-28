#!/bin/bash
# ============================================================
# AfriFX — Admin System Part 1: Backend (auth, roles, audit)
# Run from ~/AfriFX:  bash admin-system-part1.sh
# ============================================================
set -e
echo ""
echo "🔐  Building Admin System — Part 1 (Backend)..."
echo ""

# ============================================================
# 1 — Install dependencies
# ============================================================
cd afrifx-api
npm install bcryptjs jsonwebtoken
npm install --save-dev @types/bcryptjs @types/jsonwebtoken
cd ..
echo "✅  bcryptjs + jsonwebtoken installed"

# ============================================================
# 2 — Add admin env vars to .env.example
# ============================================================
cat >> afrifx-api/.env.example << '__EOF__'

# ── Admin System ──────────────────────────────────────────
# Super-admin wallet — MUST match the connected wallet to access /admin
ADMIN_WALLET=0xYourAdminWalletAddressHere

# Seed super-admin credentials (change password after first login)
ADMIN_USERNAME=superadmin
ADMIN_EMAIL=admin@afrifx.com
ADMIN_PASSWORD=ChangeMe123!

# JWT secret for admin session tokens — use a long random string
ADMIN_JWT_SECRET=your-super-secret-jwt-key-min-32-chars-long-change-this
__EOF__
echo "✅  .env.example — admin vars added (fill in your .env)"

# ============================================================
# 3 — Turso: admin tables
# ============================================================
echo "  Creating admin tables..."

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS admins (
  id              TEXT PRIMARY KEY,
  username        TEXT UNIQUE NOT NULL,
  email           TEXT UNIQUE NOT NULL,
  password_hash   TEXT NOT NULL,
  wallet_address  TEXT,
  role            TEXT NOT NULL DEFAULT 'sub_admin',
  permissions     TEXT NOT NULL DEFAULT '[]',
  status          TEXT NOT NULL DEFAULT 'active',
  suspended_until INTEGER,
  created_by      TEXT,
  last_login      INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);" && echo "  ✅  admins"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          TEXT PRIMARY KEY,
  admin_id    TEXT NOT NULL,
  admin_name  TEXT NOT NULL,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  details     TEXT,
  ip_address  TEXT,
  created_at  INTEGER NOT NULL
);" && echo "  ✅  admin_audit_log"

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_audit_admin ON admin_audit_log (admin_id, created_at DESC);" && echo "  ✅  audit index"

echo "✅  Admin tables created"

# ============================================================
# 4 — Permissions constant
# ============================================================
mkdir -p afrifx-api/src/lib
cat > afrifx-api/src/lib/permissions.ts << '__EOF__'
// All available admin permissions
export const PERMISSIONS = {
  VIEW_DASHBOARD:    'view_dashboard',
  MANAGE_OFFERS:     'manage_offers',     // force release / cancel offers
  RESOLVE_DISPUTES:  'resolve_disputes',  // settle disputes
  MANAGE_USERS:      'manage_users',      // edit user profiles, warnings
  SUSPEND_USERS:     'suspend_users',     // suspend user accounts
  VIEW_ANALYTICS:    'view_analytics',    // platform analytics
  MANAGE_TREASURY:   'manage_treasury',   // platform treasury / fees
  MANAGE_ADMINS:     'manage_admins',     // add/remove/edit sub-admins
  VIEW_AUDIT_LOG:    'view_audit_log',    // see audit trail
} as const

export type Permission = typeof PERMISSIONS[keyof typeof PERMISSIONS]

export const ALL_PERMISSIONS = Object.values(PERMISSIONS)

// Human-readable labels + descriptions for the UI
export const PERMISSION_META: Record<string, { label: string; description: string }> = {
  view_dashboard:   { label: 'View Dashboard',    description: 'Access the admin overview and stats' },
  manage_offers:    { label: 'Manage Offers',     description: 'Force release or cancel P2P offers' },
  resolve_disputes: { label: 'Resolve Disputes',  description: 'Settle disputes — release or refund USDC' },
  manage_users:     { label: 'Manage Users',      description: 'Edit profiles, issue warnings' },
  suspend_users:    { label: 'Suspend Users',     description: 'Suspend or ban user accounts' },
  view_analytics:   { label: 'View Analytics',    description: 'See platform-wide analytics and charts' },
  manage_treasury:  { label: 'Manage Treasury',   description: 'View and manage platform fees' },
  manage_admins:    { label: 'Manage Admins',     description: 'Add, edit, suspend sub-admins' },
  view_audit_log:   { label: 'View Audit Log',    description: 'Review all admin activity' },
}
__EOF__
echo "✅  lib/permissions.ts"

# ============================================================
# 5 — Admin auth middleware + helpers
# ============================================================
cat > afrifx-api/src/lib/adminAuth.ts << '__EOF__'
import jwt from 'jsonwebtoken'
import bcrypt from 'bcryptjs'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import type { Request, Response, NextFunction } from 'express'

const JWT_SECRET = process.env.ADMIN_JWT_SECRET ?? 'fallback-secret-change-me'
const JWT_EXPIRY = '8h'

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

export function signToken(payload: AdminPayload): string {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRY })
}

export function verifyToken(token: string): AdminPayload | null {
  try {
    return jwt.verify(token, JWT_SECRET) as AdminPayload
  } catch {
    return null
  }
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
    permissions: typeof a.permissions === 'string'
      ? JSON.parse(a.permissions || '[]')
      : (a.permissions ?? []),
  }
}

// Middleware: require valid admin token
export async function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const auth  = req.headers.authorization
  const token = auth?.startsWith('Bearer ') ? auth.slice(7) : null
  if (!token) return res.status(401).json({ error: 'No token provided' })

  const payload = verifyToken(token)
  if (!payload) return res.status(401).json({ error: 'Invalid or expired token' })

  // Re-check admin still exists and is active (not suspended)
  try {
    const rows = await db.run(sql`SELECT * FROM admins WHERE id = ${payload.id} LIMIT 1`)
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
__EOF__
echo "✅  lib/adminAuth.ts"

# ============================================================
# 6 — Seed super-admin on boot
# ============================================================
cat > afrifx-api/src/lib/seedAdmin.ts << '__EOF__'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'
import { hashPassword } from './adminAuth'
import { ALL_PERMISSIONS } from './permissions'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export async function seedSuperAdmin() {
  const username = process.env.ADMIN_USERNAME
  const email    = process.env.ADMIN_EMAIL
  const password = process.env.ADMIN_PASSWORD
  const wallet   = process.env.ADMIN_WALLET

  if (!username || !email || !password) {
    console.warn('[SeedAdmin] ADMIN_USERNAME / ADMIN_EMAIL / ADMIN_PASSWORD not set — skipping seed')
    return
  }

  try {
    // Check if super admin already exists
    const existing = await db.run(
      sql`SELECT id FROM admins WHERE role = 'super_admin' LIMIT 1`
    )
    if (parseRows(existing).length) {
      console.log('[SeedAdmin] Super admin already exists — skipping seed')
      return
    }

    const now  = Math.floor(Date.now() / 1000)
    const hash = await hashPassword(password)

    await db.run(
      sql`INSERT INTO admins
          (id, username, email, password_hash, wallet_address,
           role, permissions, status, created_at, updated_at)
          VALUES
          (${randomUUID()}, ${username.toLowerCase()}, ${email.toLowerCase()},
           ${hash}, ${wallet?.toLowerCase() ?? null},
           'super_admin', ${JSON.stringify(ALL_PERMISSIONS)},
           'active', ${now}, ${now})`
    )
    console.log(`[SeedAdmin] ✅ Super admin '${username}' seeded successfully`)
    console.log(`[SeedAdmin]    Login at /admin with these credentials`)
  } catch (err: any) {
    console.error('[SeedAdmin] Failed:', err.message)
  }
}
__EOF__
echo "✅  lib/seedAdmin.ts"

# ============================================================
# 7 — Admin auth routes (login, verify wallet, session)
# ============================================================
cat > afrifx-api/src/routes/adminAuth.ts << '__EOF__'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import {
  verifyPassword, signToken, normalizeAdmin,
  requireAdmin, logAction,
} from '../lib/adminAuth'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// POST /admin/auth/verify-wallet — step 1: check wallet is admin
router.post('/verify-wallet', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  const adminWallet = process.env.ADMIN_WALLET?.toLowerCase()
  const w           = wallet.toLowerCase()

  // Check against .env super-admin wallet OR any admin's registered wallet
  if (adminWallet && w === adminWallet) {
    return res.json({ valid: true, role: 'super_admin' })
  }

  // Check sub-admin wallets
  try {
    const rows = await db.run(
      sql`SELECT id, role FROM admins
          WHERE LOWER(wallet_address) = ${w}
            AND status = 'active' LIMIT 1`
    )
    const r = parseRows(rows)
    if (r.length) {
      return res.json({ valid: true, role: r[0].role ?? r[0][1] })
    }
    res.json({ valid: false, error: 'This wallet is not authorised for admin access' })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// POST /admin/auth/login — step 2: username/email + password
router.post('/login', async (req, res) => {
  const { identifier, password, wallet } = req.body
  if (!identifier || !password) {
    return res.status(400).json({ error: 'identifier and password required' })
  }

  try {
    // Find admin by username or email
    const rows = await db.run(
      sql`SELECT * FROM admins
          WHERE (LOWER(username) = ${identifier.toLowerCase()}
              OR LOWER(email) = ${identifier.toLowerCase()})
          LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(401).json({ error: 'Invalid credentials' })

    const admin = normalizeAdmin(r[0])

    // Verify password
    const valid = await verifyPassword(password, admin.password_hash)
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' })

    // Check status
    const now = Math.floor(Date.now() / 1000)
    if (admin.status === 'suspended') {
      if (!admin.suspended_until || admin.suspended_until > now) {
        return res.status(403).json({
          error: 'Account suspended',
          until: admin.suspended_until,
        })
      }
    }

    // Optional: verify wallet matches (defense in depth)
    if (wallet && admin.wallet_address &&
        wallet.toLowerCase() !== admin.wallet_address.toLowerCase() &&
        admin.role !== 'super_admin') {
      return res.status(403).json({ error: 'Wallet does not match this admin account' })
    }

    // Issue token
    const token = signToken({
      id:          admin.id,
      username:    admin.username,
      role:        admin.role,
      permissions: admin.permissions,
    })

    // Update last login
    await db.run(sql`UPDATE admins SET last_login = ${now} WHERE id = ${admin.id}`)

    // Audit
    await logAction(admin.id, admin.username, 'login', undefined, undefined,
      'Admin logged in', req.ip)

    res.json({
      token,
      admin: {
        id:          admin.id,
        username:    admin.username,
        email:       admin.email,
        role:        admin.role,
        permissions: admin.permissions,
      },
    })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /admin/auth/me — verify session + return admin info
router.get('/me', requireAdmin, async (req, res) => {
  const admin = (req as any).admin
  res.json({ admin })
})

// POST /admin/auth/logout — audit only (token is stateless)
router.post('/logout', requireAdmin, async (req, res) => {
  const admin = (req as any).admin
  await logAction(admin.id, admin.username, 'logout', undefined, undefined,
    'Admin logged out', req.ip)
  res.json({ success: true })
})

export default router
__EOF__
echo "✅  routes/adminAuth.ts"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Admin System Part 1 (Backend Auth) complete!"
echo ""
echo "  IMPORTANT — Add to afrifx-api/.env:"
echo "  ADMIN_WALLET=0xYourWalletAddress"
echo "  ADMIN_USERNAME=superadmin"
echo "  ADMIN_EMAIL=admin@afrifx.com"
echo "  ADMIN_PASSWORD=YourStrongPassword"
echo "  ADMIN_JWT_SECRET=long-random-string-min-32-chars"
echo ""
echo "  Created:"
echo "  • admins table + admin_audit_log table"
echo "  • bcrypt password hashing"
echo "  • JWT session tokens (8h expiry)"
echo "  • Two-step auth: wallet check → credential login"
echo "  • Permission system (9 granular permissions)"
echo "  • requireAdmin + requirePermission middleware"
echo "  • Audit logging helper"
echo "  • Super-admin auto-seed on boot"
echo ""
echo "  Next: run admin-system-part2.sh for management routes"
echo "══════════════════════════════════════════════════════"
