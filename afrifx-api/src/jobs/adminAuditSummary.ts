import { db }  from '../db/client'
import { sql } from 'drizzle-orm'
import { sendEmail } from '../services/email/client'
import { adminAuditSummaryEmail } from '../services/email/templates'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startAdminAuditSummary() {
  console.log('[AuditSummary] Started — sends weekly to super admins')

  const sendSummary = async () => {
    const now     = Math.floor(Date.now() / 1000)
    const weekAgo = now - (7 * 86400)

    try {
      // Get super admins with email
      const adminRows = await db.run(sql`
        SELECT id, username, email FROM admins
        WHERE role = 'super_admin' AND email IS NOT NULL
      `)
      const superAdmins = parseRows(adminRows)
      if (superAdmins.length === 0) return

      // Disputes opened this week
      const openedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes WHERE created_at >= ${weekAgo}
      `)
      const disputesOpened = Number(parseRows(openedRows)[0]?.cnt ?? 0)

      // Disputes resolved this week
      const resolvedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
      `)
      const disputesResolved = Number(parseRows(resolvedRows)[0]?.cnt ?? 0)

      // Avg resolution time (hours)
      const avgRows = await db.run(sql`
        SELECT AVG(admin_resolved_at - created_at) as avg_seconds FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
          AND admin_resolved_at IS NOT NULL
      `)
      const avgSeconds = Number(parseRows(avgRows)[0]?.avg_seconds ?? 0)
      const avgResolutionHours = avgSeconds / 3600

      // Total trade volume this week
      const volRows = await db.run(sql`
        SELECT COUNT(*) as cnt, COALESCE(SUM(usdc_amount), 0) as vol FROM p2p_offers
        WHERE status = 'released' AND updated_at >= ${weekAgo}
      `)
      const volData = parseRows(volRows)[0]
      const totalTrades      = Number(volData?.cnt ?? 0)
      const totalTradeVolume = Number(volData?.vol ?? 0)

      // Invoices paid this week
      const invRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM invoices
        WHERE status = 'paid' AND paid_at >= ${weekAgo}
      `)
      const totalInvoicesPaid = Number(parseRows(invRows)[0]?.cnt ?? 0)

      // Unclaimed disputes
      const unclaimedRows = await db.run(sql`
        SELECT COUNT(*) as cnt FROM disputes
        WHERE status = 'open'
      `)
      const unclaimedDisputes = Number(parseRows(unclaimedRows)[0]?.cnt ?? 0)

      // Admin leaderboard
      const leaderRows = await db.run(sql`
        SELECT admin_resolved_by as name, COUNT(*) as resolved FROM disputes
        WHERE status = 'resolved' AND admin_resolved_at >= ${weekAgo}
          AND admin_resolved_by IS NOT NULL AND admin_resolved_by != 'system'
        GROUP BY admin_resolved_by ORDER BY resolved DESC LIMIT 10
      `)
      const activeAdmins = parseRows(leaderRows).map(r => ({
        name:     r.name ?? r[0] ?? 'unknown',
        resolved: Number(r.resolved ?? r[1] ?? 0),
      }))

      // Date range
      const startDate = new Date(weekAgo * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
      const endDate   = new Date(now * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })

      // Send to each super admin
      for (const admin of superAdmins) {
        const email = admin.email ?? admin[2]
        const name  = admin.username ?? admin[1]
        if (!email) continue

        const template = adminAuditSummaryEmail({
          adminName:          name,
          periodStart:        startDate,
          periodEnd:          endDate,
          disputesOpened,
          disputesResolved,
          avgResolutionHours,
          totalTradeVolume,
          totalTrades,
          totalInvoicesPaid,
          activeAdmins,
          unclaimedDisputes,
        })

        await sendEmail({ to: email, subject: template.subject, html: template.html })
          .catch(err => console.error('[AuditSummary] send failed:', err.message))

        console.log(`[AuditSummary] Sent to ${name} (${email})`)
      }
    } catch (err: any) {
      console.error('[AuditSummary] error:', err.message)
    }
  }

  // Run every Monday at 8am (check every hour, send if it's Monday and not sent today)
  setInterval(async () => {
    const now = new Date()
    if (now.getUTCDay() === 1 && now.getUTCHours() === 8) {
      // Check if already sent today
      const today = Math.floor(new Date(now.toDateString()).getTime() / 1000)
      const rows = await db.run(sql`
        SELECT last_audit_sent FROM admins WHERE role = 'super_admin' LIMIT 1
      `)
      const r = parseRows(rows)[0]
      const lastSent = Number(r?.last_audit_sent ?? r?.[0] ?? 0)

      if (lastSent < today) {
        await sendSummary()
        const nowTs = Math.floor(Date.now() / 1000)
        await db.run(sql`UPDATE admins SET last_audit_sent = ${nowTs} WHERE role = 'super_admin'`)
      }
    }
  }, 3600_000) // Check every hour
}
