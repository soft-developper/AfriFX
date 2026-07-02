#!/bin/bash
# ============================================================
# AfriFX -- Phase 13: Admin Frontend (session-based auth)
# Rewrites /admin login+setup, adds invite/reset-password pages,
# adds /admin/settings (password + 2FA), updates useAdminAuth.
#
# Also includes two backend fixes found while wiring the frontend
# to Phase 12 -- see the summary printed at the end of this script.
#
# Run from ~/AfriFX:  bash phase13-admin-frontend.sh
# ============================================================
set -e
echo ""
echo "Building Phase 13 -- Admin Frontend..."
echo ""

# ============================================================
# 1 -- Backend fix: mount adminAuthRouter at /admin-auth
# ============================================================
PYEOF_MARK=PYFIX1
python3 - << 'PYFIX1'
path = "afrifx-api/src/index.ts"
with open(path) as f:
    content = f.read()
old = "app.use('/admin/auth',     adminAuthRouter)"
new = "app.use('/admin-auth',     adminAuthRouter)"
if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("  fixed: mounted /admin-auth (was /admin/auth)")
elif "app.use('/admin-auth'" in content:
    print("  already mounted at /admin-auth")
else:
    print("  WARNING: could not find adminAuthRouter mount line -- check index.ts manually")
PYFIX1

# ============================================================
# 2 -- Backend fix: services/auth/adminAuth.ts (adds parsePermissions)
# ============================================================
cat > afrifx-api/src/services/auth/adminAuth.ts << 'ADMINSVC_EOF'
import bcrypt from 'bcryptjs'
import { randomUUID, randomBytes } from 'crypto'
import * as OTPAuth from 'otpauth'
import { db }  from '../../db/client'
import { sql } from 'drizzle-orm'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

const SALT_ROUNDS     = 12
const SESSION_TTL     = 24 * 3600  // 24 hours
const LOCKOUT_MINUTES = 15
const MAX_ATTEMPTS    = 5

// ── Password ────────────────────────────────────────────────
export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, SALT_ROUNDS)
}

export async function verifyPassword(password: string, hash: string): Promise<boolean> {
  return bcrypt.compare(password, hash)
}

export function validatePassword(password: string): string | null {
  if (password.length < 12) return 'Password must be at least 12 characters'
  if (!/[A-Z]/.test(password)) return 'Password must contain an uppercase letter'
  if (!/[a-z]/.test(password)) return 'Password must contain a lowercase letter'
  if (!/[0-9]/.test(password)) return 'Password must contain a number'
  if (!/[^A-Za-z0-9]/.test(password)) return 'Password must contain a special character'
  return null
}

// ── Sessions ────────────────────────────────────────────────
export async function createSession(adminId: string, ip?: string, ua?: string): Promise<string> {
  const id    = randomUUID()
  const token = randomBytes(48).toString('hex')
  const now   = Math.floor(Date.now() / 1000)

  await db.run(sql`
    INSERT INTO admin_sessions (id, admin_id, token, ip_address, user_agent, created_at, expires_at, last_active_at)
    VALUES (${id}, ${adminId}, ${token}, ${ip ?? null}, ${ua ?? null}, ${now}, ${now + SESSION_TTL}, ${now})
  `)

  return token
}

export async function validateSession(token: string): Promise<any | null> {
  const now = Math.floor(Date.now() / 1000)
  const rows = await db.run(sql`
    SELECT s.*, a.id as aid, a.username, a.email, a.role, a.permissions,
           a.is_active, a.totp_enabled
    FROM admin_sessions s
    JOIN admins a ON a.id = s.admin_id
    WHERE s.token = ${token} AND s.expires_at > ${now} AND a.is_active = 1
    LIMIT 1
  `)
  const r = parseRows(rows)
  if (!r.length) return null

  // Extend session on activity
  await db.run(sql`
    UPDATE admin_sessions SET last_active_at = ${now}, expires_at = ${now + SESSION_TTL}
    WHERE token = ${token}
  `)

  return r[0]
}

export async function destroySession(token: string): Promise<void> {
  await db.run(sql`DELETE FROM admin_sessions WHERE token = ${token}`)
}

// Clean expired sessions
export async function cleanExpiredSessions(): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  await db.run(sql`DELETE FROM admin_sessions WHERE expires_at < ${now}`)
}

// ── Rate limiting ───────────────────────────────────────────
export async function checkLockout(adminId: string): Promise<{ locked: boolean, minutesLeft?: number }> {
  const rows = await db.run(sql`
    SELECT locked_until, login_attempts FROM admins WHERE id = ${adminId} LIMIT 1
  `)
  const r = parseRows(rows)[0]
  if (!r) return { locked: false }

  const lockedUntil = Number(r.locked_until ?? 0)
  const now = Math.floor(Date.now() / 1000)

  if (lockedUntil > now) {
    return { locked: true, minutesLeft: Math.ceil((lockedUntil - now) / 60) }
  }

  // Reset if lockout expired
  if (lockedUntil > 0 && lockedUntil <= now) {
    await db.run(sql`UPDATE admins SET login_attempts = 0, locked_until = NULL WHERE id = ${adminId}`)
  }

  return { locked: false }
}

export async function recordLoginAttempt(adminId: string, success: boolean, email: string, ip?: string): Promise<void> {
  const now = Math.floor(Date.now() / 1000)
  const id  = randomUUID()

  // Log attempt
  await db.run(sql`
    INSERT INTO admin_login_log (id, admin_id, email, success, ip_address, created_at)
    VALUES (${id}, ${adminId}, ${email}, ${success ? 1 : 0}, ${ip ?? null}, ${now})
  `)

  if (success) {
    await db.run(sql`UPDATE admins SET login_attempts = 0, locked_until = NULL WHERE id = ${adminId}`)
  } else {
    const rows = await db.run(sql`SELECT login_attempts FROM admins WHERE id = ${adminId} LIMIT 1`)
    const r = parseRows(rows)[0]
    const attempts = Number(r?.login_attempts ?? 0) + 1

    if (attempts >= MAX_ATTEMPTS) {
      const lockUntil = now + (LOCKOUT_MINUTES * 60)
      await db.run(sql`UPDATE admins SET login_attempts = ${attempts}, locked_until = ${lockUntil} WHERE id = ${adminId}`)
    } else {
      await db.run(sql`UPDATE admins SET login_attempts = ${attempts} WHERE id = ${adminId}`)
    }
  }
}

// ── 2FA (TOTP) ──────────────────────────────────────────────
export function generateTOTPSecret(email: string): { secret: string, uri: string } {
  const totp = new OTPAuth.TOTP({
    issuer: 'AfriFX',
    label:  email,
    algorithm: 'SHA1',
    digits: 6,
    period: 30,
    secret: new OTPAuth.Secret(),
  })

  return {
    secret: totp.secret.base32,
    uri:    totp.toString(),
  }
}

export function verifyTOTP(secret: string, code: string): boolean {
  const totp = new OTPAuth.TOTP({
    issuer: 'AfriFX',
    algorithm: 'SHA1',
    digits: 6,
    period: 30,
    secret: OTPAuth.Secret.fromBase32(secret),
  })

  const delta = totp.validate({ token: code, window: 1 })
  return delta !== null
}

export function generateRecoveryCodes(): string[] {
  const codes: string[] = []
  for (let i = 0; i < 10; i++) {
    codes.push(randomBytes(4).toString('hex') + '-' + randomBytes(4).toString('hex'))
  }
  return codes
}

// ── Invitations ─────────────────────────────────────────────
export async function createInvitation(email: string, invitedBy: string, permissions: string): Promise<string> {
  const id    = randomUUID()
  const token = randomBytes(32).toString('hex')
  const now   = Math.floor(Date.now() / 1000)
  const expiresAt = now + (48 * 3600) // 48 hours

  await db.run(sql`
    INSERT INTO admin_invitations (id, email, invited_by, permissions, token, expires_at, created_at)
    VALUES (${id}, ${email}, ${invitedBy}, ${permissions}, ${token}, ${expiresAt}, ${now})
  `)

  return token
}

// ── Password reset ──────────────────────────────────────────
export async function createPasswordReset(adminId: string): Promise<string> {
  const id    = randomUUID()
  const token = randomBytes(32).toString('hex')
  const now   = Math.floor(Date.now() / 1000)

  await db.run(sql`
    INSERT INTO admin_password_resets (id, admin_id, token, expires_at, created_at)
    VALUES (${id}, ${adminId}, ${token}, ${now + 3600}, ${now})
  `)

  return token
}

// ── Permissions ─────────────────────────────────────────────
// admins.permissions stores either the literal 'all' (super_admin)
// or a JSON-encoded string array (sub_admin). Normalize to string[].
export function parsePermissions(role: string, raw: any): string[] {
  if (role === 'super_admin') return ['all']
  if (Array.isArray(raw)) return raw
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }
  return []
}

// ── Setup check ─────────────────────────────────────────────
export async function isFirstTimeSetup(): Promise<boolean> {
  const rows = await db.run(sql`
    SELECT COUNT(*) as cnt FROM admins WHERE role = 'super_admin' AND setup_completed = 1
  `)
  const r = parseRows(rows)
  return Number(r[0]?.cnt ?? 0) === 0
}
ADMINSVC_EOF
echo "  services/auth/adminAuth.ts rewritten (+ parsePermissions)"

# ============================================================
# 3 -- Backend fix: routes/adminAuth.ts (normalizes permissions in responses)
# ============================================================
cat > afrifx-api/src/routes/adminAuth.ts << 'ADMINROUTES_EOF'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import { randomUUID } from 'crypto'
import QRCode from 'qrcode'
import {
  hashPassword, verifyPassword, validatePassword,
  createSession, validateSession, destroySession,
  checkLockout, recordLoginAttempt,
  generateTOTPSecret, verifyTOTP, generateRecoveryCodes,
  createInvitation, createPasswordReset,
  isFirstTimeSetup, parsePermissions,
} from '../services/auth/adminAuth'
import { sendEmail } from '../services/email/client'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Auth middleware — validates session token from Authorization header
export async function requireAdmin(req: any, res: any, next: any) {
  const token = req.headers.authorization?.replace('Bearer ', '')
  if (!token) return res.status(401).json({ error: 'No session token' })

  const session = await validateSession(token)
  if (!session) return res.status(401).json({ error: 'Invalid or expired session' })

  req.admin = {
    id:          session.aid ?? session.admin_id,
    username:    session.username,
    email:       session.email,
    role:        session.role,
    permissions: parsePermissions(session.role, session.permissions),
    totpEnabled: Number(session.totp_enabled ?? 0) === 1,
  }
  next()
}

// ── Setup check ─────────────────────────────────────────────
// GET /admin-auth/setup-status
router.get('/setup-status', async (_req, res) => {
  try {
    const isFirstTime = await isFirstTimeSetup()
    res.json({ needsSetup: isFirstTime })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── First-time super admin setup ────────────────────────────
// POST /admin-auth/setup
router.post('/setup', async (req, res) => {
  const { email, password, username } = req.body
  const ip = req.ip

  try {
    const isFirstTime = await isFirstTimeSetup()
    if (!isFirstTime) {
      return res.status(400).json({ error: 'Setup already completed' })
    }

    // Validate
    if (!email || !password || !username) {
      return res.status(400).json({ error: 'email, password, and username required' })
    }
    const pwError = validatePassword(password)
    if (pwError) return res.status(400).json({ error: pwError })

    const hash = await hashPassword(password)
    const now  = Math.floor(Date.now() / 1000)

    // Check if super admin row already exists (from seed)
    const existing = await db.run(sql`SELECT id FROM admins WHERE role = 'super_admin' LIMIT 1`)
    const ex = parseRows(existing)

    if (ex.length) {
      // Update existing super admin
      await db.run(sql`
        UPDATE admins SET
          username = ${username}, email = ${email},
          password_hash = ${hash}, setup_completed = 1,
          updated_at = ${now}
        WHERE id = ${ex[0].id ?? ex[0][0]}
      `)
    } else {
      // Create new super admin
      const id = randomUUID()
      await db.run(sql`
        INSERT INTO admins (id, username, email, password_hash, role, permissions, setup_completed, is_active, created_at, updated_at)
        VALUES (${id}, ${username}, ${email}, ${hash}, 'super_admin', 'all', 1, 1, ${now}, ${now})
      `)
    }

    // Create session
    const adminRows = await db.run(sql`SELECT id FROM admins WHERE role = 'super_admin' LIMIT 1`)
    const adminId = parseRows(adminRows)[0]?.id ?? parseRows(adminRows)[0]?.[0]
    const token = await createSession(adminId, ip)

    res.json({ success: true, token, needsTOTP: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Login ───────────────────────────────────────────────────
// POST /admin-auth/login
router.post('/login', async (req, res) => {
  const { email, password, totpCode } = req.body
  const ip = req.ip

  try {
    if (!email || !password) {
      return res.status(400).json({ error: 'email and password required' })
    }

    // Find admin by email
    const rows = await db.run(sql`
      SELECT id, username, email, password_hash, role, permissions,
             is_active, totp_enabled, totp_secret, setup_completed
      FROM admins WHERE LOWER(email) = LOWER(${email}) LIMIT 1
    `)
    const admin = parseRows(rows)[0]

    if (!admin) {
      return res.status(401).json({ error: 'Invalid email or password' })
    }

    const adminId = admin.id ?? admin[0]

    // Check lockout
    const lockout = await checkLockout(adminId)
    if (lockout.locked) {
      return res.status(429).json({
        error: `Account locked. Try again in ${lockout.minutesLeft} minutes.`,
      })
    }

    // Check active
    if (!Number(admin.is_active ?? 1)) {
      return res.status(403).json({ error: 'Account is deactivated. Contact super admin.' })
    }

    // Verify password
    const passwordHash = admin.password_hash
    if (!passwordHash) {
      return res.status(401).json({ error: 'Account not set up. Check your invitation email.' })
    }

    const passwordValid = await verifyPassword(password, passwordHash)
    if (!passwordValid) {
      await recordLoginAttempt(adminId, false, email, ip)
      return res.status(401).json({ error: 'Invalid email or password' })
    }

    // Check 2FA
    const totpEnabled = Number(admin.totp_enabled ?? 0) === 1
    if (totpEnabled) {
      if (!totpCode) {
        return res.status(200).json({ needs2FA: true, message: 'Enter your 2FA code' })
      }

      const totpSecret = admin.totp_secret
      if (!verifyTOTP(totpSecret, totpCode)) {
        await recordLoginAttempt(adminId, false, email, ip)
        return res.status(401).json({ error: 'Invalid 2FA code' })
      }
    }

    // Success
    await recordLoginAttempt(adminId, true, email, ip)
    const token = await createSession(adminId, ip, req.headers['user-agent'])

    res.json({
      success:     true,
      token,
      admin: {
        id:          adminId,
        username:    admin.username,
        email:       admin.email,
        role:        admin.role,
        permissions: parsePermissions(admin.role, admin.permissions),
        totpEnabled,
      },
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Verify session ──────────────────────────────────────────
// GET /admin-auth/verify
router.get('/verify', async (req, res) => {
  const token = req.headers.authorization?.replace('Bearer ', '')
  if (!token) return res.status(401).json({ error: 'No token' })

  const session = await validateSession(token)
  if (!session) return res.status(401).json({ error: 'Invalid session' })

  res.json({
    admin: {
      id:          session.aid ?? session.admin_id,
      username:    session.username,
      email:       session.email,
      role:        session.role,
      permissions: parsePermissions(session.role, session.permissions),
      totpEnabled: Number(session.totp_enabled ?? 0) === 1,
    },
  })
})

// ── Logout ──────────────────────────────────────────────────
// POST /admin-auth/logout
router.post('/logout', async (req, res) => {
  const token = req.headers.authorization?.replace('Bearer ', '')
  if (token) await destroySession(token)
  res.json({ success: true })
})

// ── 2FA Setup ───────────────────────────────────────────────
// POST /admin-auth/2fa/setup — generate secret + QR code
router.post('/2fa/setup', requireAdmin, async (req: any, res) => {
  try {
    const { secret, uri } = generateTOTPSecret(req.admin.email)
    const qrCode = await QRCode.toDataURL(uri)

    // Store secret (not yet enabled)
    await db.run(sql`UPDATE admins SET totp_secret = ${secret} WHERE id = ${req.admin.id}`)

    res.json({ secret, qrCode, uri })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin-auth/2fa/verify — verify code and enable 2FA
router.post('/2fa/verify', requireAdmin, async (req: any, res) => {
  const { code } = req.body
  if (!code) return res.status(400).json({ error: 'code required' })

  try {
    const rows = await db.run(sql`SELECT totp_secret FROM admins WHERE id = ${req.admin.id} LIMIT 1`)
    const admin = parseRows(rows)[0]
    const secret = admin?.totp_secret

    if (!secret) return res.status(400).json({ error: 'Set up 2FA first' })

    if (!verifyTOTP(secret, code)) {
      return res.status(400).json({ error: 'Invalid code. Try again.' })
    }

    // Generate recovery codes
    const recoveryCodes = generateRecoveryCodes()
    const now = Math.floor(Date.now() / 1000)

    await db.run(sql`
      UPDATE admins SET
        totp_enabled = 1,
        recovery_codes = ${JSON.stringify(recoveryCodes)},
        updated_at = ${now}
      WHERE id = ${req.admin.id}
    `)

    res.json({ success: true, recoveryCodes })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Forgot password ─────────────────────────────────────────
// POST /admin-auth/forgot-password
router.post('/forgot-password', async (req, res) => {
  const { email } = req.body
  if (!email) return res.status(400).json({ error: 'email required' })

  try {
    const rows = await db.run(sql`
      SELECT id, username, email FROM admins WHERE LOWER(email) = LOWER(${email}) LIMIT 1
    `)
    const admin = parseRows(rows)[0]

    // Always return success (don't reveal if email exists)
    if (!admin) return res.json({ success: true })

    const adminId = admin.id ?? admin[0]
    const token   = await createPasswordReset(adminId)
    const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

    await sendEmail({
      to:      admin.email,
      subject: 'AfriFX Admin — Password reset',
      html:    '<html><body style="background:#080D1B;color:#E2E8F0;font-family:sans-serif;padding:40px;">'
        + '<div style="max-width:480px;margin:0 auto;background:#0F1729;border:1px solid #1B2B4B;border-radius:12px;padding:32px;">'
        + '<h1 style="color:#378ADD;margin:0 0 16px;font-size:20px;">Password reset</h1>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 16px;">Hi ' + (admin.username ?? 'there') + ',</p>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 24px;">Click the button below to reset your AfriFX admin password. This link expires in 1 hour.</p>'
        + '<table cellpadding="0" cellspacing="0" border="0"><tr><td style="background:#378ADD;border-radius:10px;">'
        + '<a href="' + APP_URL + '/admin/reset-password/' + token + '" style="display:inline-block;padding:14px 32px;color:white;font-weight:500;font-size:14px;text-decoration:none;">Reset password</a>'
        + '</td></tr></table>'
        + '<p style="color:#64748B;font-size:12px;margin:24px 0 0;">If you did not request this, ignore this email.</p>'
        + '</div></body></html>',
    })

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin-auth/reset-password
router.post('/reset-password', async (req, res) => {
  const { token, password } = req.body
  if (!token || !password) return res.status(400).json({ error: 'token and password required' })

  const pwError = validatePassword(password)
  if (pwError) return res.status(400).json({ error: pwError })

  const now = Math.floor(Date.now() / 1000)

  try {
    const rows = await db.run(sql`
      SELECT admin_id FROM admin_password_resets
      WHERE token = ${token} AND expires_at > ${now} AND used_at IS NULL LIMIT 1
    `)
    const r = parseRows(rows)
    if (!r.length) return res.status(400).json({ error: 'Invalid or expired reset link' })

    const adminId = r[0].admin_id ?? r[0][0]
    const hash = await hashPassword(password)

    await db.run(sql`UPDATE admins SET password_hash = ${hash}, updated_at = ${now} WHERE id = ${adminId}`)
    await db.run(sql`UPDATE admin_password_resets SET used_at = ${now} WHERE token = ${token}`)

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Sub-admin invitation ────────────────────────────────────
// POST /admin-auth/invite — super admin invites sub-admin
router.post('/invite', requireAdmin, async (req: any, res) => {
  if (req.admin.role !== 'super_admin') {
    return res.status(403).json({ error: 'Only super admins can invite' })
  }

  const { email, permissions } = req.body
  if (!email || !permissions) return res.status(400).json({ error: 'email and permissions required' })

  try {
    // Check if email already exists
    const existing = await db.run(sql`SELECT id FROM admins WHERE LOWER(email) = LOWER(${email}) LIMIT 1`)
    if (parseRows(existing).length) {
      return res.status(400).json({ error: 'An admin with this email already exists' })
    }

    const token = await createInvitation(email, req.admin.id, JSON.stringify(permissions))
    const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

    await sendEmail({
      to:      email,
      subject: 'You have been invited to AfriFX Admin',
      html:    '<html><body style="background:#080D1B;color:#E2E8F0;font-family:sans-serif;padding:40px;">'
        + '<div style="max-width:480px;margin:0 auto;background:#0F1729;border:1px solid #1B2B4B;border-radius:12px;padding:32px;">'
        + '<h1 style="color:#378ADD;margin:0 0 16px;font-size:20px;">You are invited to AfriFX</h1>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 16px;">' + req.admin.username + ' has invited you to join the AfriFX admin team.</p>'
        + '<p style="color:#64748B;font-size:14px;line-height:1.6;margin:0 0 24px;">Click below to set up your password and access the admin dashboard. This invitation expires in 48 hours.</p>'
        + '<table cellpadding="0" cellspacing="0" border="0"><tr><td style="background:#378ADD;border-radius:10px;">'
        + '<a href="' + APP_URL + '/admin/invite/' + token + '" style="display:inline-block;padding:14px 32px;color:white;font-weight:500;font-size:14px;text-decoration:none;">Accept invitation</a>'
        + '</td></tr></table>'
        + '<p style="color:#64748B;font-size:12px;margin:24px 0 0;">If you did not expect this, ignore this email.</p>'
        + '</div></body></html>',
    })

    res.json({ success: true, message: 'Invitation sent to ' + email })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin-auth/accept-invite — sub-admin accepts invitation
router.post('/accept-invite', async (req, res) => {
  const { token, username, password } = req.body
  if (!token || !username || !password) {
    return res.status(400).json({ error: 'token, username, and password required' })
  }

  const pwError = validatePassword(password)
  if (pwError) return res.status(400).json({ error: pwError })

  const now = Math.floor(Date.now() / 1000)

  try {
    const rows = await db.run(sql`
      SELECT * FROM admin_invitations
      WHERE token = ${token} AND expires_at > ${now} AND accepted_at IS NULL LIMIT 1
    `)
    const inv = parseRows(rows)[0]
    if (!inv) return res.status(400).json({ error: 'Invalid or expired invitation' })

    const email       = inv.email
    const permissions = inv.permissions
    const hash        = await hashPassword(password)
    const id          = randomUUID()

    await db.run(sql`
      INSERT INTO admins (id, username, email, password_hash, role, permissions, is_active, setup_completed, created_at, updated_at)
      VALUES (${id}, ${username}, ${email}, ${hash}, 'sub_admin', ${permissions}, 1, 1, ${now}, ${now})
    `)

    // Mark invitation as accepted
    await db.run(sql`UPDATE admin_invitations SET accepted_at = ${now} WHERE token = ${token}`)

    // Create session
    const sessionToken = await createSession(id, req.ip)

    res.json({ success: true, token: sessionToken })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /admin-auth/change-password
router.post('/change-password', requireAdmin, async (req: any, res) => {
  const { currentPassword, newPassword } = req.body
  if (!currentPassword || !newPassword) {
    return res.status(400).json({ error: 'currentPassword and newPassword required' })
  }

  const pwError = validatePassword(newPassword)
  if (pwError) return res.status(400).json({ error: pwError })

  try {
    const rows = await db.run(sql`SELECT password_hash FROM admins WHERE id = ${req.admin.id} LIMIT 1`)
    const admin = parseRows(rows)[0]

    const valid = await verifyPassword(currentPassword, admin?.password_hash)
    if (!valid) return res.status(401).json({ error: 'Current password is incorrect' })

    const hash = await hashPassword(newPassword)
    const now  = Math.floor(Date.now() / 1000)
    await db.run(sql`UPDATE admins SET password_hash = ${hash}, updated_at = ${now} WHERE id = ${req.admin.id}`)

    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
ADMINROUTES_EOF
echo "  routes/adminAuth.ts rewritten (permissions normalized)"

# ============================================================
# 4 -- Backend fix: lib/adminAuth.ts
#      /admin/manage/* (offers, disputes, users, sub-admins,
#      analytics, audit) used a JWT-based requireAdmin that is
#      incompatible with the opaque session tokens Phase 12's
#      login/setup/accept-invite issue. Without this fix, every
#      other admin page 401s right after a successful login.
#      This makes requireAdmin here share the same admin_sessions
#      table/token as /admin-auth/*.
# ============================================================
cat > afrifx-api/src/lib/adminAuth.ts << 'LIBADMIN_EOF'
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
LIBADMIN_EOF
echo "  lib/adminAuth.ts rewritten (session-based requireAdmin)"

# ============================================================
# 5 -- Frontend files
# ============================================================
mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useAdminAuth.ts" << 'HOOK_EOF'
'use client'
import { useState, useEffect, useRef } from 'react'

const API        = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
export const TOKEN_KEY = 'afrifx_admin_token'
export const ADMIN_KEY = 'afrifx_admin'

export interface AdminSession {
  id:           string
  username:     string
  email:        string
  role:         string
  permissions:  string[]
  totpEnabled:  boolean
}

function persist(token: string, admin: AdminSession) {
  sessionStorage.setItem(TOKEN_KEY, token)
  sessionStorage.setItem(ADMIN_KEY, JSON.stringify(admin))
}

function clearPersisted() {
  sessionStorage.removeItem(TOKEN_KEY)
  sessionStorage.removeItem(ADMIN_KEY)
}

export function useAdminAuth() {
  const [admin,   setAdmin]   = useState<AdminSession | null>(null)
  const [loading, setLoading] = useState(true)
  const fetchedRef            = useRef(false)

  const getToken = () =>
    typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  useEffect(() => {
    if (fetchedRef.current) return
    fetchedRef.current = true
    const token = getToken()
    if (!token) { setLoading(false); return }

    fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(res => { if (res.ok) return res.json(); clearPersisted(); return null })
      .then(data => {
        if (data?.admin) {
          setAdmin(data.admin)
          sessionStorage.setItem(ADMIN_KEY, JSON.stringify(data.admin))
        }
      })
      .catch(() => { clearPersisted() })
      .finally(() => setLoading(false))
  }, [])

  // ── First-time setup ─────────────────────────────────────
  async function checkSetupStatus(): Promise<boolean> {
    const res  = await fetch(`${API}/admin-auth/setup-status`)
    const data = await res.json()
    return data.needsSetup === true
  }

  async function setup(email: string, password: string, username: string) {
    const res  = await fetch(`${API}/admin-auth/setup`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, username }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Setup failed' }

    // Setup doesn't return the admin object — fetch it via /verify
    const meRes = await fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${data.token}` },
    })
    const me = await meRes.json()
    if (meRes.ok && me.admin) {
      persist(data.token, me.admin)
      setAdmin(me.admin)
      return { success: true, admin: me.admin, needsTOTP: !!data.needsTOTP }
    }
    return { success: true, needsTOTP: !!data.needsTOTP }
  }

  // ── Login ─────────────────────────────────────────────────
  async function login(email: string, password: string, totpCode?: string) {
    const res  = await fetch(`${API}/admin-auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, totpCode }),
    })
    const data = await res.json()

    if (!res.ok) return { success: false, error: data.error ?? 'Login failed' }
    if (data.needs2FA) return { success: false, needs2FA: true }

    if (data.token && data.admin) {
      persist(data.token, data.admin)
      setAdmin(data.admin)
      return { success: true, admin: data.admin as AdminSession }
    }
    return { success: false, error: 'Unexpected response from server' }
  }

  async function logout() {
    const token = getToken()
    if (token) {
      await fetch(`${API}/admin-auth/logout`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    clearPersisted()
    fetchedRef.current = false
    setAdmin(null)
  }

  // ── Password reset ───────────────────────────────────────
  async function forgotPassword(email: string) {
    const res  = await fetch(`${API}/admin-auth/forgot-password`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Request failed' }
  }

  async function resetPassword(token: string, password: string) {
    const res  = await fetch(`${API}/admin-auth/reset-password`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, password }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Reset failed' }
  }

  // ── Invitations ───────────────────────────────────────────
  async function invite(email: string, permissions: string[]) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/invite`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ email, permissions }),
    })
    const data = await res.json()
    return res.ok ? { success: true, message: data.message } : { success: false, error: data.error ?? 'Invite failed' }
  }

  async function acceptInvite(token: string, username: string, password: string) {
    const res  = await fetch(`${API}/admin-auth/accept-invite`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, username, password }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Invitation failed' }

    const meRes = await fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${data.token}` },
    })
    const me = await meRes.json()
    if (meRes.ok && me.admin) {
      persist(data.token, me.admin)
      setAdmin(me.admin)
    }
    return { success: true }
  }

  // ── Password / 2FA management ────────────────────────────
  async function changePassword(currentPassword: string, newPassword: string) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/change-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ currentPassword, newPassword }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Change failed' }
  }

  async function setup2FA() {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/2fa/setup`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}` },
    })
    const data = await res.json()
    return res.ok
      ? { success: true, secret: data.secret as string, qrCode: data.qrCode as string }
      : { success: false, error: data.error ?? '2FA setup failed' }
  }

  async function verify2FA(code: string) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/2fa/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ code }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Verification failed' }
    // Reflect the now-enabled 2FA flag locally
    setAdmin(prev => {
      if (!prev) return prev
      const next = { ...prev, totpEnabled: true }
      sessionStorage.setItem(ADMIN_KEY, JSON.stringify(next))
      return next
    })
    return { success: true, recoveryCodes: data.recoveryCodes as string[] }
  }

  function hasPermission(perm: string): boolean {
    if (!admin) return false
    if (admin.role === 'super_admin') return true
    return admin.permissions.includes(perm)
  }

  return {
    admin, loading, getToken,
    checkSetupStatus, setup, login, logout,
    forgotPassword, resetPassword,
    invite, acceptInvite,
    changePassword, setup2FA, verify2FA,
    hasPermission,
  }
}

export function adminFetch(path: string, options: RequestInit = {}) {
  const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
  return fetch(`${API}${path}`, {
    ...options,
    headers: { ...options.headers, 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  })
}
HOOK_EOF
echo "  hooks/useAdminAuth.ts"

mkdir -p "afrifx-web/app/admin"
cat > "afrifx-web/app/admin/page.tsx" << 'LOGIN_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Shield, Lock, Mail, User, Loader2, AlertCircle,
  KeyRound, ArrowLeft,
} from 'lucide-react'

const PERMISSION_PAGES = [
  { perm: 'manage_offers',    path: '/admin/offers'     },
  { perm: 'resolve_disputes', path: '/admin/disputes'   },
  { perm: 'manage_users',     path: '/admin/users'      },
  { perm: 'view_analytics',   path: '/admin/analytics'  },
  { perm: 'manage_admins',    path: '/admin/sub-admins' },
  { perm: 'view_audit_log',   path: '/admin/audit'      },
]

function getRedirectPath(role: string, permissions: string[]): string {
  if (role === 'super_admin' || permissions.includes('view_dashboard') || permissions.includes('all')) {
    return '/admin/dashboard'
  }
  const first = PERMISSION_PAGES.find(p => permissions.includes(p.perm))
  return first ? first.path : '/admin/no-access'
}

type Mode = 'checking' | 'setup' | 'login'

export default function AdminLoginPage() {
  const router = useRouter()
  const { checkSetupStatus, setup, login, forgotPassword } = useAdminAuth()

  const [mode, setMode] = useState<Mode>('checking')

  // Setup fields
  const [setupUsername, setSetupUsername] = useState('')
  const [setupEmail,    setSetupEmail]    = useState('')
  const [setupPassword, setSetupPassword] = useState('')
  const [setupConfirm,  setSetupConfirm]  = useState('')

  // Login fields
  const [email,    setEmail]    = useState('')
  const [password, setPassword] = useState('')
  const [totpCode, setTotpCode] = useState('')
  const [needs2FA, setNeeds2FA] = useState(false)

  // Forgot password
  const [showForgot,   setShowForgot]   = useState(false)
  const [forgotEmail,  setForgotEmail]  = useState('')
  const [forgotSent,   setForgotSent]   = useState(false)

  const [error,   setError]   = useState<string | null>(null)
  const [busy,    setBusy]    = useState(false)

  useEffect(() => {
    checkSetupStatus()
      .then(needsSetup => setMode(needsSetup ? 'setup' : 'login'))
      .catch(() => setMode('login'))
  }, [])

  async function handleSetup() {
    setError(null)
    if (!setupUsername || !setupEmail || !setupPassword) {
      setError('All fields are required'); return
    }
    if (setupPassword !== setupConfirm) {
      setError('Passwords do not match'); return
    }
    setBusy(true)
    try {
      const result = await setup(setupEmail, setupPassword, setupUsername)
      if (result.success) {
        router.push('/admin/settings?onboarding=2fa')
      } else {
        setError((result as any).error ?? 'Setup failed')
      }
    } finally { setBusy(false) }
  }

  async function handleLogin() {
    setError(null)
    if (!email || !password) { setError('Email and password are required'); return }
    if (needs2FA && !totpCode) { setError('Enter your 6-digit authenticator code'); return }

    setBusy(true)
    try {
      const result = await login(email, password, needs2FA ? totpCode : undefined)
      if (result.success && result.admin) {
        router.push(getRedirectPath(result.admin.role, result.admin.permissions))
      } else if ((result as any).needs2FA) {
        setNeeds2FA(true)
      } else {
        setError((result as any).error ?? 'Login failed')
      }
    } finally { setBusy(false) }
  }

  async function handleForgot() {
    setError(null)
    if (!forgotEmail) { setError('Enter your email'); return }
    setBusy(true)
    try {
      const result = await forgotPassword(forgotEmail)
      if (result.success) setForgotSent(true)
      else setError((result as any).error ?? 'Request failed')
    } finally { setBusy(false) }
  }

  if (mode === 'checking') {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#080D1B]">
        <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#378ADD]/10">
            <Shield className="h-7 w-7 text-[#378ADD]" />
          </div>
          <h1 className="text-2xl font-bold text-[#E2E8F0]">AfriFX Admin</h1>
          <p className="text-sm text-[#64748B]">
            {mode === 'setup' ? 'Create the super admin account' : 'Sign in to continue'}
          </p>
        </div>

        <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          {mode === 'setup' && (
            <div className="space-y-3">
              <div className="text-center mb-2">
                <p className="text-sm font-medium text-[#E2E8F0]">First-time setup</p>
                <p className="text-xs text-[#64748B]">No admin account exists yet — create the super admin</p>
              </div>
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" placeholder="Username" autoComplete="off"
                  value={setupUsername} onChange={e => setSetupUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                  value={setupEmail} onChange={e => setSetupEmail(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={setupPassword} onChange={e => setSetupPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={setupConfirm} onChange={e => setSetupConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleSetup()} />
              </div>
              <p className="text-[11px] text-[#64748B] leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleSetup} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating account…</>
                      : <>Create super admin</>}
              </Button>
            </div>
          )}

          {mode === 'login' && !showForgot && (
            <div className="space-y-3">
              {!needs2FA ? (
                <>
                  <div className="text-center mb-2">
                    <Lock className="mx-auto mb-2 h-8 w-8 text-[#378ADD]" />
                    <p className="text-sm font-medium text-[#E2E8F0]">Enter credentials</p>
                  </div>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                    <Input className="pl-9" type="email" placeholder="Email" autoComplete="off"
                      value={email} onChange={e => setEmail(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <div className="relative">
                    <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                    <Input className="pl-9" type="password" placeholder="Password" autoComplete="current-password"
                      value={password} onChange={e => setPassword(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  </div>
                  <Button className="w-full" onClick={handleLogin} disabled={!email || !password || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Signing in…</>
                          : <><Lock className="h-4 w-4" /> Sign in</>}
                  </Button>
                  <button onClick={() => { setShowForgot(true); setError(null) }}
                    className="w-full text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                    Forgot password?
                  </button>
                </>
              ) : (
                <>
                  <div className="text-center mb-2">
                    <KeyRound className="mx-auto mb-2 h-8 w-8 text-[#378ADD]" />
                    <p className="text-sm font-medium text-[#E2E8F0]">Two-factor authentication</p>
                    <p className="text-xs text-[#64748B]">Enter the 6-digit code from your authenticator app</p>
                  </div>
                  <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
                    maxLength={6} inputMode="numeric" autoFocus
                    value={totpCode} onChange={e => setTotpCode(e.target.value.replace(/\D/g, ''))}
                    onKeyDown={e => e.key === 'Enter' && handleLogin()} />
                  <Button className="w-full" onClick={handleLogin} disabled={totpCode.length !== 6 || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & sign in</>}
                  </Button>
                  <button onClick={() => { setNeeds2FA(false); setTotpCode(''); setError(null) }}
                    className="flex w-full items-center justify-center gap-1 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                    <ArrowLeft className="h-3 w-3" /> Back
                  </button>
                </>
              )}
            </div>
          )}

          {mode === 'login' && showForgot && (
            <div className="space-y-3">
              {!forgotSent ? (
                <>
                  <div className="text-center mb-2">
                    <Mail className="mx-auto mb-2 h-8 w-8 text-[#378ADD]" />
                    <p className="text-sm font-medium text-[#E2E8F0]">Reset your password</p>
                    <p className="text-xs text-[#64748B]">We'll email you a reset link</p>
                  </div>
                  <Input type="email" placeholder="Your admin email" autoComplete="off"
                    value={forgotEmail} onChange={e => setForgotEmail(e.target.value)}
                    onKeyDown={e => e.key === 'Enter' && handleForgot()} />
                  <Button className="w-full" onClick={handleForgot} disabled={!forgotEmail || busy}>
                    {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : <>Send reset link</>}
                  </Button>
                </>
              ) : (
                <div className="rounded-lg bg-emerald-900/20 px-3 py-4 text-center text-sm text-emerald-400">
                  If that email is registered, a reset link is on its way. Check your inbox.
                </div>
              )}
              <button onClick={() => { setShowForgot(false); setForgotSent(false); setError(null) }}
                className="flex w-full items-center justify-center gap-1 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                <ArrowLeft className="h-3 w-3" /> Back to sign in
              </button>
            </div>
          )}

          {error && (
            <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
        </div>
        <p className="mt-4 text-center text-xs text-[#64748B]">🔒 Restricted area — all actions are logged</p>
      </div>
    </div>
  )
}
LOGIN_EOF
echo "  app/admin/page.tsx (login + first-time setup + 2FA + forgot password)"

mkdir -p "afrifx-web/app/admin/invite/[token]"
cat > "afrifx-web/app/admin/invite/[token]/page.tsx" << 'INVITE_EOF'
'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, User, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function AcceptInvitePage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { acceptInvite } = useAdminAuth()

  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleAccept() {
    setError(null)
    if (!username || !password) { setError('Username and password are required'); return }
    if (password !== confirm)   { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await acceptInvite(params.token, username, password)
      if (result.success) {
        setDone(true)
        setTimeout(() => router.push('/admin/dashboard'), 1200)
      } else {
        setError((result as any).error ?? 'Could not accept invitation')
      }
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#378ADD]/10">
            <Shield className="h-7 w-7 text-[#378ADD]" />
          </div>
          <h1 className="text-2xl font-bold text-[#E2E8F0]">Accept invitation</h1>
          <p className="text-sm text-[#64748B]">Set up your AfriFX admin account</p>
        </div>

        <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          {done ? (
            <div className="flex flex-col items-center gap-2 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-[#E2E8F0]">Account created — redirecting…</p>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <User className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" placeholder="Choose a username" autoComplete="off"
                  value={username} onChange={e => setUsername(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Confirm password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleAccept()} />
              </div>
              <p className="text-[11px] text-[#64748B] leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleAccept} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Setting up…</> : <>Accept & create account</>}
              </Button>

              {error && (
                <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
INVITE_EOF
echo "  app/admin/invite/[token]/page.tsx"

mkdir -p "afrifx-web/app/admin/reset-password/[token]"
cat > "afrifx-web/app/admin/reset-password/[token]/page.tsx" << 'RESETPW_EOF'
'use client'
import { useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Shield, Lock, Loader2, AlertCircle, CheckCircle } from 'lucide-react'

export default function ResetPasswordPage() {
  const params = useParams<{ token: string }>()
  const router = useRouter()
  const { resetPassword } = useAdminAuth()

  const [password, setPassword] = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [busy,     setBusy]     = useState(false)
  const [done,     setDone]     = useState(false)

  async function handleReset() {
    setError(null)
    if (!password) { setError('Enter a new password'); return }
    if (password !== confirm) { setError('Passwords do not match'); return }

    setBusy(true)
    try {
      const result = await resetPassword(params.token, password)
      if (result.success) setDone(true)
      else setError((result as any).error ?? 'Reset failed — the link may have expired')
    } finally { setBusy(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B] p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#378ADD]/10">
            <Shield className="h-7 w-7 text-[#378ADD]" />
          </div>
          <h1 className="text-2xl font-bold text-[#E2E8F0]">Reset password</h1>
          <p className="text-sm text-[#64748B]">Choose a new password for your admin account</p>
        </div>

        <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          {done ? (
            <div className="flex flex-col items-center gap-3 py-4 text-center">
              <CheckCircle className="h-8 w-8 text-emerald-400" />
              <p className="text-sm text-[#E2E8F0]">Password updated</p>
              <Link href="/admin" className="w-full">
                <Button className="w-full">Go to sign in</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="New password" autoComplete="new-password"
                  value={password} onChange={e => setPassword(e.target.value)} />
              </div>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
                <Input className="pl-9" type="password" placeholder="Confirm new password" autoComplete="new-password"
                  value={confirm} onChange={e => setConfirm(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleReset()} />
              </div>
              <p className="text-[11px] text-[#64748B] leading-relaxed">
                Min 12 characters, with uppercase, lowercase, a number, and a special character.
              </p>
              <Button className="w-full" onClick={handleReset} disabled={busy}>
                {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
              </Button>

              {error && (
                <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
RESETPW_EOF
echo "  app/admin/reset-password/[token]/page.tsx"

mkdir -p "afrifx-web/app/admin/settings"
cat > "afrifx-web/app/admin/settings/page.tsx" << 'SETTINGS_EOF'
'use client'
import { useState, useEffect, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import { AdminShell } from '@/components/admin/AdminShell'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import {
  Lock, ShieldCheck, ShieldOff, Loader2, AlertCircle,
  CheckCircle, KeyRound, Copy, Check,
} from 'lucide-react'

function ChangePasswordCard() {
  const { changePassword } = useAdminAuth()
  const [current,  setCurrent]  = useState('')
  const [next,     setNext]     = useState('')
  const [confirm,  setConfirm]  = useState('')
  const [error,    setError]    = useState<string | null>(null)
  const [success,  setSuccess]  = useState(false)
  const [busy,     setBusy]     = useState(false)

  async function handleSubmit() {
    setError(null); setSuccess(false)
    if (!current || !next) { setError('All fields are required'); return }
    if (next !== confirm)  { setError('New passwords do not match'); return }

    setBusy(true)
    try {
      const result = await changePassword(current, next)
      if (result.success) {
        setSuccess(true)
        setCurrent(''); setNext(''); setConfirm('')
      } else {
        setError((result as any).error ?? 'Could not change password')
      }
    } finally { setBusy(false) }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Lock className="h-4 w-4 text-[#378ADD]" /> Change password</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input type="password" placeholder="Current password" autoComplete="current-password"
          value={current} onChange={e => setCurrent(e.target.value)} />
        <Input type="password" placeholder="New password" autoComplete="new-password"
          value={next} onChange={e => setNext(e.target.value)} />
        <Input type="password" placeholder="Confirm new password" autoComplete="new-password"
          value={confirm} onChange={e => setConfirm(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && handleSubmit()} />
        <p className="text-[11px] text-[#64748B]">
          Min 12 characters, with uppercase, lowercase, a number, and a special character.
        </p>
        <Button onClick={handleSubmit} disabled={busy}>
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Updating…</> : <>Update password</>}
        </Button>
        {success && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
            <CheckCircle className="h-3.5 w-3.5" /> Password updated
          </div>
        )}
        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function TwoFactorCard({ autoStart }: { autoStart: boolean }) {
  const { admin, setup2FA, verify2FA } = useAdminAuth()
  const [stage, setStage]   = useState<'idle' | 'qr' | 'recovery'>('idle')
  const [qrCode, setQrCode] = useState('')
  const [secret, setSecret] = useState('')
  const [code,   setCode]   = useState('')
  const [codes,  setCodes]  = useState<string[]>([])
  const [copied, setCopied] = useState(false)
  const [error,  setError]  = useState<string | null>(null)
  const [busy,   setBusy]   = useState(false)

  useEffect(() => {
    if (autoStart && admin && !admin.totpEnabled) handleStart()
  }, [autoStart, admin?.id])

  async function handleStart() {
    setError(null); setBusy(true)
    try {
      const result = await setup2FA()
      if (result.success) {
        setQrCode(result.qrCode!); setSecret(result.secret!); setStage('qr')
      } else {
        setError((result as any).error ?? 'Could not start 2FA setup')
      }
    } finally { setBusy(false) }
  }

  async function handleVerify() {
    setError(null)
    if (code.length !== 6) { setError('Enter the 6-digit code'); return }
    setBusy(true)
    try {
      const result = await verify2FA(code)
      if (result.success) {
        setCodes(result.recoveryCodes ?? [])
        setStage('recovery')
      } else {
        setError((result as any).error ?? 'Invalid code')
      }
    } finally { setBusy(false) }
  }

  function copyRecoveryCodes() {
    navigator.clipboard.writeText(codes.join('\n')).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  const enabled = admin?.totpEnabled && stage !== 'recovery'

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-[#378ADD]" /> Two-factor authentication
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {enabled && stage === 'idle' && (
          <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
            <ShieldCheck className="h-4 w-4" /> 2FA is enabled on your account
          </div>
        )}

        {!enabled && stage === 'idle' && (
          <>
            <div className="flex items-center gap-2 rounded-lg bg-amber-900/20 px-3 py-2.5 text-xs text-amber-400">
              <ShieldOff className="h-4 w-4" /> 2FA is not enabled — we recommend turning it on
            </div>
            <Button onClick={handleStart} disabled={busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Starting…</> : <>Set up 2FA</>}
            </Button>
          </>
        )}

        {stage === 'qr' && (
          <div className="space-y-3">
            <p className="text-xs text-[#64748B]">
              Scan this QR code with an authenticator app (Google Authenticator, 1Password, Authy).
            </p>
            {qrCode && (
              <div className="flex justify-center rounded-lg bg-white p-3">
                <img src={qrCode} alt="2FA QR code" className="h-40 w-40" />
              </div>
            )}
            <p className="break-all rounded-lg bg-[#080D1B] p-2 text-center font-mono text-[10px] text-[#64748B]">
              {secret}
            </p>
            <Input className="text-center tracking-[0.4em] text-lg" placeholder="000000"
              maxLength={6} inputMode="numeric"
              value={code} onChange={e => setCode(e.target.value.replace(/\D/g, ''))}
              onKeyDown={e => e.key === 'Enter' && handleVerify()} />
            <Button onClick={handleVerify} disabled={code.length !== 6 || busy}>
              {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Verifying…</> : <>Verify & enable</>}
            </Button>
          </div>
        )}

        {stage === 'recovery' && (
          <div className="space-y-3">
            <div className="flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="h-4 w-4" /> 2FA enabled
            </div>
            <p className="text-xs text-[#64748B]">
              Save these recovery codes somewhere safe — each can be used once if you lose access to your authenticator.
            </p>
            <div className="grid grid-cols-2 gap-1.5 rounded-lg bg-[#080D1B] p-3 font-mono text-xs text-[#E2E8F0]">
              {codes.map(c => <span key={c}>{c}</span>)}
            </div>
            <Button variant="outline" onClick={copyRecoveryCodes}>
              {copied ? <><Check className="h-4 w-4" /> Copied</> : <><Copy className="h-4 w-4" /> Copy codes</>}
            </Button>
          </div>
        )}

        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function SettingsBody() {
  const { admin } = useAdminAuth()
  const searchParams = useSearchParams()
  const autoStart2FA = searchParams.get('onboarding') === '2fa'

  return (
    <div className="mx-auto max-w-xl space-y-6">
      <div>
        <h1 className="text-lg font-semibold text-[#E2E8F0]">Account settings</h1>
        {admin && (
          <p className="text-sm text-[#64748B]">
            Signed in as <span className="text-[#378ADD]">{admin.username}</span> · {admin.email}
          </p>
        )}
      </div>
      <ChangePasswordCard />
      <TwoFactorCard autoStart={autoStart2FA} />
    </div>
  )
}

export default function AdminSettingsPage() {
  return (
    <AdminShell>
      <Suspense fallback={
        <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin text-[#378ADD]" /></div>
      }>
        <SettingsBody />
      </Suspense>
    </AdminShell>
  )
}
SETTINGS_EOF
echo "  app/admin/settings/page.tsx (change password + 2FA)"

mkdir -p "afrifx-web/app/admin/no-access"
cat > "afrifx-web/app/admin/no-access/page.tsx" << 'NOACCESS_EOF'
'use client'
import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ShieldOff, LogOut } from 'lucide-react'
import { TOKEN_KEY, ADMIN_KEY } from '@/hooks/useAdminAuth'

// IMPORTANT: This page does NOT use AdminShell
// to avoid infinite redirect loops for sub-admins with no permissions

export default function NoAccessPage() {
  const router             = useRouter()
  const [username, setUsername] = useState('')
  const [checked,  setChecked]  = useState(false)

  useEffect(() => {
    // One-time check — do not loop
    const token    = sessionStorage.getItem(TOKEN_KEY)
    const adminRaw = sessionStorage.getItem(ADMIN_KEY)
    if (!token || !adminRaw) {
      router.replace('/admin')
      return
    }
    try {
      const admin = JSON.parse(adminRaw)
      setUsername(admin.username ?? '')
    } catch {}
    setChecked(true)
  }, []) // Empty deps — run once only, no loop

  function handleLogout() {
    sessionStorage.removeItem(TOKEN_KEY)
    sessionStorage.removeItem(ADMIN_KEY)
    router.replace('/admin')
  }

  if (!checked) return null

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-[#080D1B] px-4">
      <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-8 text-center">
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-amber-900/20 border border-amber-900/40">
          <ShieldOff className="h-8 w-8 text-amber-400" />
        </div>
        <h1 className="mb-2 text-lg font-semibold text-[#E2E8F0]">
          No permissions assigned
        </h1>
        {username && (
          <p className="mb-1 text-sm text-[#378ADD]">@{username}</p>
        )}
        <p className="mb-6 text-sm text-[#64748B]">
          Your admin account has been created but no permissions have been
          assigned yet. Please contact the super admin to grant you access
          to the relevant sections.
        </p>
        <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-4 text-left text-xs text-[#64748B] space-y-1.5">
          <p className="font-medium text-[#E2E8F0]">What the super admin needs to do:</p>
          <p>1. Go to Admin panel → Sub-admins</p>
          <p>2. Find your account and click Edit</p>
          <p>3. Assign the required permissions</p>
          <p>4. You can then log back in</p>
        </div>
        <button onClick={handleLogout}
          className="flex w-full items-center justify-center gap-2 rounded-xl border border-[#1B2B4B] px-4 py-2.5 text-sm text-[#64748B] hover:bg-[#080D1B] hover:text-red-400 transition-colors">
          <LogOut className="h-4 w-4" />
          Sign out
        </button>
      </div>
    </div>
  )
}
NOACCESS_EOF
echo "  app/admin/no-access/page.tsx (storage key fix)"

mkdir -p "afrifx-web/app/admin/sub-admins"
cat > "afrifx-web/app/admin/sub-admins/page.tsx" << 'SUBADMINS_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Loader2, Plus, Shield, Trash2, Pause, Play,
  Key, Check, Mail, CheckCircle, AlertCircle,
} from 'lucide-react'

export default function AdminSubAdmins() {
  const { admin, invite } = useAdminAuth()
  const [admins,  setAdmins]  = useState<any[]>([])
  const [permMeta, setPermMeta] = useState<any>({})
  const [allPerms, setAllPerms] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [busy, setBusy] = useState<string|null>(null)

  // Invite form state
  const [inviteEmail, setInviteEmail] = useState('')
  const [selectedPerms, setSelectedPerms] = useState<string[]>([])
  const [inviteError,   setInviteError]   = useState<string|null>(null)
  const [inviteSuccess, setInviteSuccess] = useState<string|null>(null)

  // Editing
  const [editingId, setEditingId] = useState<string|null>(null)
  const [editPerms, setEditPerms] = useState<string[]>([])

  async function load() {
    setLoading(true)
    const [adminRes, permRes] = await Promise.all([
      adminFetch('/admin/manage/admins'),
      adminFetch('/admin/manage/permissions'),
    ])
    const adminData = await adminRes.json()
    const permData  = await permRes.json()
    setAdmins(Array.isArray(adminData) ? adminData : [])
    setPermMeta(permData.meta ?? {})
    setAllPerms(permData.all ?? [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function sendInvite() {
    if (!inviteEmail || selectedPerms.length === 0) return
    setInviteError(null); setInviteSuccess(null)
    setBusy('create')
    try {
      const result = await invite(inviteEmail, selectedPerms)
      if (result.success) {
        setInviteSuccess(result.message ?? `Invitation sent to ${inviteEmail}`)
        setInviteEmail(''); setSelectedPerms([])
      } else {
        setInviteError((result as any).error ?? 'Could not send invitation')
      }
    } finally { setBusy(null) }
  }

  async function toggleStatus(a: any) {
    setBusy(a.id)
    const newStatus = a.status === 'active' ? 'suspended' : 'active'
    let suspendedUntil = null
    if (newStatus === 'suspended') {
      const days = prompt('Suspend for how many days? (leave blank for indefinite)')
      if (days && !isNaN(Number(days))) {
        suspendedUntil = Math.floor(Date.now() / 1000) + Number(days) * 86400
      }
    }
    try {
      await adminFetch(`/admin/manage/admins/${a.id}`, {
        method: 'PATCH', body: JSON.stringify({ status: newStatus, suspendedUntil }),
      })
      await load()
    } finally { setBusy(null) }
  }

  async function deleteAdmin(id: string) {
    if (!confirm('Remove this sub-admin permanently?')) return
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, { method: 'DELETE' })
      await load()
    } finally { setBusy(null) }
  }

  async function savePerms(id: string) {
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, {
        method: 'PATCH', body: JSON.stringify({ permissions: editPerms }),
      })
      setEditingId(null)
      await load()
    } finally { setBusy(null) }
  }

  async function resetCredentials(a: any) {
    const newPassword = prompt(`Reset password for ${a.username}:\nEnter new password (min 8 chars):`)
    if (!newPassword) return
    setBusy(a.id)
    try {
      const res = await adminFetch(`/admin/manage/admins/${a.id}/credentials`, {
        method: 'PATCH', body: JSON.stringify({ newPassword }),
      })
      if (res.ok) alert('Password reset successfully')
      else alert((await res.json()).error)
    } finally { setBusy(null) }
  }

  function togglePerm(list: string[], setList: (l: string[]) => void, perm: string) {
    setList(list.includes(perm) ? list.filter(p => p !== perm) : [...list, perm])
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Sub-admin management</h1>
        {admin?.role === 'super_admin' && (
          <Button size="sm" onClick={() => { setShowForm(!showForm); setInviteError(null); setInviteSuccess(null) }}>
            <Plus className="h-4 w-4" /> Invite sub-admin
          </Button>
        )}
      </div>

      {admin?.role !== 'super_admin' && (
        <div className="mb-6 flex items-center gap-2 rounded-lg bg-[#0F1729] border border-[#1B2B4B] px-4 py-3 text-xs text-[#64748B]">
          Only the super admin can invite new sub-admins.
        </div>
      )}

      {/* Invite form */}
      {showForm && (
        <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-1 text-sm font-medium text-[#E2E8F0]">Invite a sub-admin</p>
          <p className="mb-4 text-xs text-[#64748B]">
            They'll get an email with a link to set their own password and, optionally, 2FA.
          </p>
          <div className="relative mb-4">
            <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
            <Input className="pl-9" placeholder="Email address" type="email" autoComplete="off"
              value={inviteEmail} onChange={e => setInviteEmail(e.target.value)} />
          </div>

          <p className="mb-2 text-xs font-medium text-[#E2E8F0]">Permissions</p>
          <div className="mb-4 grid grid-cols-2 gap-2 lg:grid-cols-3">
            {allPerms.map(perm => (
              <button key={perm} onClick={() => togglePerm(selectedPerms, setSelectedPerms, perm)}
                className={`flex items-start gap-2 rounded-lg border p-2.5 text-left transition-colors
                  ${selectedPerms.includes(perm)
                    ? 'border-[#378ADD] bg-[#378ADD]/10'
                    : 'border-[#1B2B4B] bg-[#080D1B]'}`}>
                <div className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded
                  ${selectedPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                  {selectedPerms.includes(perm) && <Check className="h-3 w-3 text-white" />}
                </div>
                <div>
                  <p className="text-xs font-medium text-[#E2E8F0]">{permMeta[perm]?.label ?? perm}</p>
                  <p className="text-[10px] text-[#64748B]">{permMeta[perm]?.description}</p>
                </div>
              </button>
            ))}
          </div>

          <div className="flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setShowForm(false)}>Cancel</Button>
            <Button className="flex-1" onClick={sendInvite}
              disabled={!inviteEmail || selectedPerms.length === 0 || busy === 'create'}>
              {busy === 'create' ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Mail className="h-4 w-4" /> Send invite</>}
            </Button>
          </div>

          {inviteSuccess && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
            </div>
          )}
          {inviteError && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
            </div>
          )}
        </div>
      )}

      {/* Admins list */}
      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-3">
          {admins.map(a => (
            <div key={a.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className={`flex h-10 w-10 items-center justify-center rounded-full
                    ${a.role === 'super_admin' ? 'bg-amber-500/20' : 'bg-[#378ADD]/10'}`}>
                    <Shield className={`h-5 w-5 ${a.role === 'super_admin' ? 'text-amber-400' : 'text-[#378ADD]'}`} />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-[#E2E8F0]">{a.username}</p>
                      <Badge variant={a.role === 'super_admin' ? 'warning' : 'arc'}>
                        {a.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
                      </Badge>
                      {a.status === 'suspended' && <Badge variant="danger">Suspended</Badge>}
                    </div>
                    <p className="text-xs text-[#64748B]">{a.email}</p>
                    {a.last_login && (
                      <p className="text-[10px] text-[#64748B]">
                        Last login: {new Date(Number(a.last_login) * 1000).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>

                {a.role !== 'super_admin' && (
                  <div className="flex gap-1">
                    <button onClick={() => resetCredentials(a)} disabled={busy === a.id}
                      title="Reset password"
                      className="rounded p-1.5 text-[#64748B] hover:text-[#378ADD]">
                      <Key className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => toggleStatus(a)} disabled={busy === a.id}
                      title={a.status === 'active' ? 'Suspend' : 'Activate'}
                      className="rounded p-1.5 text-[#64748B] hover:text-amber-400">
                      {a.status === 'active' ? <Pause className="h-3.5 w-3.5" /> : <Play className="h-3.5 w-3.5" />}
                    </button>
                    <button onClick={() => deleteAdmin(a.id)} disabled={busy === a.id}
                      title="Remove"
                      className="rounded p-1.5 text-[#64748B] hover:text-red-400">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                )}
              </div>

              {/* Permissions */}
              {a.role !== 'super_admin' && (
                <div className="mt-3 border-t border-[#1B2B4B] pt-3">
                  {editingId === a.id ? (
                    <div>
                      <div className="mb-2 grid grid-cols-2 gap-2 lg:grid-cols-3">
                        {allPerms.map(perm => (
                          <button key={perm} onClick={() => togglePerm(editPerms, setEditPerms, perm)}
                            className={`flex items-center gap-1.5 rounded-lg border p-2 text-left text-xs transition-colors
                              ${editPerms.includes(perm) ? 'border-[#378ADD] bg-[#378ADD]/10 text-[#E2E8F0]' : 'border-[#1B2B4B] text-[#64748B]'}`}>
                            <div className={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded
                              ${editPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                              {editPerms.includes(perm) && <Check className="h-2.5 w-2.5 text-white" />}
                            </div>
                            {permMeta[perm]?.label ?? perm}
                          </button>
                        ))}
                      </div>
                      <div className="flex gap-2">
                        <Button size="sm" variant="outline" onClick={() => setEditingId(null)}>Cancel</Button>
                        <Button size="sm" onClick={() => savePerms(a.id)} disabled={busy === a.id}>
                          {busy === a.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Save permissions'}
                        </Button>
                      </div>
                    </div>
                  ) : (
                    <div className="flex items-center justify-between">
                      <div className="flex flex-wrap gap-1.5">
                        {(a.permissions ?? []).length === 0 ? (
                          <span className="text-xs text-[#64748B]">No permissions granted</span>
                        ) : (a.permissions ?? []).map((p: string) => (
                          <span key={p} className="rounded-full bg-[#1B2B4B] px-2 py-0.5 text-[10px] text-[#E2E8F0]">
                            {permMeta[p]?.label ?? p}
                          </span>
                        ))}
                      </div>
                      <button onClick={() => { setEditingId(a.id); setEditPerms(a.permissions ?? []) }}
                        className="shrink-0 text-xs text-[#378ADD] hover:underline">
                        Edit permissions
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </AdminShell>
  )
}
SUBADMINS_EOF
echo "  app/admin/sub-admins/page.tsx (wallet-required form -> email invite flow)"

mkdir -p "afrifx-web/components/admin"
cat > "afrifx-web/components/admin/AdminShell.tsx" << 'SHELL_EOF'
'use client'
import { useEffect } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { useAdminAuth } from '@/hooks/useAdminAuth'
import {
  LayoutDashboard, Store, AlertTriangle, Users,
  Shield, ScrollText, BarChart3, LogOut, Loader2, Settings,
} from 'lucide-react'

const NAV = [
  { href: '/admin/dashboard',  icon: LayoutDashboard, label: 'Overview',   perm: 'view_dashboard'   },
  { href: '/admin/offers',     icon: Store,           label: 'Offers',     perm: 'manage_offers'    },
  { href: '/admin/disputes',   icon: AlertTriangle,   label: 'Disputes',   perm: 'resolve_disputes' },
  { href: '/admin/users',      icon: Users,           label: 'Users',      perm: 'manage_users'     },
  { href: '/admin/sub-admins', icon: Shield,          label: 'Sub-admins', perm: 'manage_admins'    },
  { href: '/admin/analytics',  icon: BarChart3,       label: 'Analytics',  perm: 'view_analytics'   },
  { href: '/admin/audit',      icon: ScrollText,      label: 'Audit log',  perm: 'view_audit_log'   },
]

export function AdminShell({ children }: { children: React.ReactNode }) {
  const router   = useRouter()
  const pathname = usePathname()
  const { admin, loading, logout, hasPermission } = useAdminAuth()

  useEffect(() => {
    if (!loading && !admin) router.push('/admin')
  }, [loading, admin, router])

  if (loading) return (
    <div className="flex min-h-screen items-center justify-center bg-[#080D1B]">
      <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
    </div>
  )

  if (!admin) return null

  // Sub-admin landing on dashboard without permission
  // → redirect to their first permitted page
  if (
    typeof window !== 'undefined' &&
    admin.role !== 'super_admin' &&
    !admin.permissions.includes('view_dashboard') &&
    window.location.pathname === '/admin/dashboard'
  ) {
    const PAGES = [
      { perm: 'manage_offers',    path: '/admin/offers'     },
      { perm: 'resolve_disputes', path: '/admin/disputes'   },
      { perm: 'manage_users',     path: '/admin/users'      },
      { perm: 'view_analytics',   path: '/admin/analytics'  },
      { perm: 'manage_admins',    path: '/admin/sub-admins' },
      { perm: 'view_audit_log',   path: '/admin/audit'      },
    ]
    const first = PAGES.find(p => admin.permissions.includes(p.perm))
    if (first) { window.location.replace(first.path); return null }
  }

  const visibleNav = NAV.filter(item => hasPermission(item.perm))

  async function handleLogout() {
    await logout()
    router.push('/admin')
  }

  return (
    <div className="flex min-h-screen bg-[#080D1B]">
      <aside className="flex w-56 shrink-0 flex-col border-r border-[#1B2B4B] bg-[#0F1729]">
        <div className="flex items-center gap-2 border-b border-[#1B2B4B] px-4 py-4">
          <Shield className="h-5 w-5 text-[#378ADD]" />
          <span className="font-semibold text-[#E2E8F0]">AfriFX Admin</span>
        </div>
        <nav className="flex-1 py-3">
          {visibleNav.map(({ href, icon: Icon, label }) => {
            const active = pathname === href
            return (
              <Link key={href} href={href}
                className={`flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors
                  ${active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0]'}`}>
                <Icon className="h-4 w-4" /> {label}
              </Link>
            )
          })}
        </nav>
        <div className="border-t border-[#1B2B4B] p-3 space-y-2">
          <div className="rounded-lg bg-[#080D1B] px-3 py-2">
            <p className="text-xs font-medium text-[#E2E8F0]">{admin.username}</p>
            <p className="text-[10px] text-[#378ADD]">
              {admin.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
            </p>
          </div>
          <Link href="/admin/settings"
            className="flex items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0] transition-colors">
            <Settings className="h-3.5 w-3.5 shrink-0" />
            Settings
          </Link>
          <Link href="/dashboard"
            className="flex items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-[#E2E8F0] transition-colors">
            <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
            Main dashboard
          </Link>
          <button onClick={handleLogout}
            className="flex w-full items-center gap-2 rounded-lg border border-[#1B2B4B] px-3 py-2 text-xs text-[#64748B] hover:bg-[#080D1B] hover:text-red-400 transition-colors">
            <LogOut className="h-3.5 w-3.5 shrink-0" />
            Logout
          </button>
        </div>
      </aside>
      <main className="flex-1 overflow-y-auto p-6">{children}</main>
    </div>
  )
}
SHELL_EOF
echo "  components/admin/AdminShell.tsx (+ Settings link)"

echo ""
echo "======================================================"
echo "Phase 13 -- Admin Frontend complete!"
echo ""
echo "  Pages:"
echo "    /admin                      -- auto-detects first-time setup vs login, 2FA step, forgot password"
echo "    /admin/invite/[token]       -- accept sub-admin invitation"
echo "    /admin/reset-password/[token] -- reset password from email link"
echo "    /admin/settings             -- change password + enable/view 2FA"
echo ""
echo "  Also updated:"
echo "    app/admin/sub-admins/page.tsx -- 'Add sub-admin' used to be a"
echo "       direct-create form with a required wallet-address field (a"
echo "       leftover from the pre-Phase-12 flow). It now sends an email"
echo "       invite via /admin-auth/invite instead, gated to super_admin"
echo "       only (matching what the backend allows)."
echo ""
echo "  Backend fixes bundled in (found while wiring the frontend):"
echo "    1. adminAuthRouter is now mounted at /admin-auth (index.ts had it"
echo "       at the old /admin/auth path, which didn't match what you said"
echo "       is deployed -- double check your live index.ts matches)."
echo "    2. /admin-auth/* responses now return permissions as a real"
echo "       string[] instead of the raw DB column ('all' or a JSON string)."
echo "    3. lib/adminAuth.ts's requireAdmin (guarding /admin/manage/* --"
echo "       offers, disputes, users, sub-admins, analytics, audit) used"
echo "       to verify a JWT. Phase 12's login/setup/accept-invite issue"
echo "       opaque session tokens instead, so every other admin page would"
echo "       have 401'd right after login. It now validates against the"
echo "       same admin_sessions table as /admin-auth/*."
echo ""
echo "  NEXT:"
echo "    cd afrifx-api && npm install && npx tsc --noEmit"
echo "    cd afrifx-web && npm run build"
echo "    Redeploy both, then test: setup -> login -> 2FA -> settings ->"
echo "    invite a sub-admin -> accept-invite -> forgot/reset password."
echo "======================================================"
