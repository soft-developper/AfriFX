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
