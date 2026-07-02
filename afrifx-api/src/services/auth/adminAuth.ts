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

// ── Setup check ─────────────────────────────────────────────
export async function isFirstTimeSetup(): Promise<boolean> {
  const rows = await db.run(sql`
    SELECT COUNT(*) as cnt FROM admins WHERE role = 'super_admin' AND setup_completed = 1
  `)
  const r = parseRows(rows)
  return Number(r[0]?.cnt ?? 0) === 0
}
