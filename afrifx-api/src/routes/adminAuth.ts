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

  const { email, permissions, dutyStartMin, dutyEndMin, dutyDays, dutyDates } = req.body
  if (!email || !permissions) return res.status(400).json({ error: 'email and permissions required' })

  // Working hours (the sub-admin's dispute duty session). Required if the
  // sub-admin will handle disputes; validated to max 6 hours.
  const wantsDuty = dutyStartMin != null || dutyEndMin != null ||
                    (dutyDays?.length) || (dutyDates?.length)
  let duty: { startMin: number; endMin: number; days: number[]; dates: string[] } | undefined
  if (wantsDuty) {
    const { validateWindow } = await import('../lib/duty')
    const err = validateWindow({
      startMin: dutyStartMin, endMin: dutyEndMin,
      days: dutyDays ?? [], dates: dutyDates ?? [],
    })
    if (err) return res.status(400).json({ error: err })
    duty = {
      startMin: dutyStartMin, endMin: dutyEndMin,
      days: dutyDays ?? [], dates: dutyDates ?? [],
    }
  }

  try {
    // Check if email already exists
    const existing = await db.run(sql`SELECT id FROM admins WHERE LOWER(email) = LOWER(${email}) LIMIT 1`)
    if (parseRows(existing).length) {
      return res.status(400).json({ error: 'An admin with this email already exists' })
    }

    const token = await createInvitation(email, req.admin.id, JSON.stringify(permissions), duty)
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

    // Carry the working hours chosen by the general admin at invite time.
    const dStart = inv.duty_start_min ?? null
    const dEnd   = inv.duty_end_min   ?? null
    const dDays  = inv.duty_days      ?? null
    const dDates = inv.duty_dates     ?? null

    await db.run(sql`
      INSERT INTO admins (id, username, email, password_hash, role, permissions, is_active, setup_completed, created_at, updated_at,
                          duty_start_min, duty_end_min, duty_days, duty_dates)
      VALUES (${id}, ${username}, ${email}, ${hash}, 'sub_admin', ${permissions}, 1, 1, ${now}, ${now},
              ${dStart}, ${dEnd}, ${dDays}, ${dDates})
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
