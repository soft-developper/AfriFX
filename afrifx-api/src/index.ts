import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import walletRouter               from './routes/wallet'
import treasuryRouter             from './routes/treasury'
import payrollRouter              from './routes/payroll'
import notificationsRouter         from './routes/notifications'
import disputesRouter              from './routes/disputes'
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import { cleanExpiredSessions } from './services/auth/adminAuth'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import broadcastsRouter           from './routes/broadcasts'
import maintenanceRouter          from './routes/maintenance'
import transfersRouter, { webhookRouter } from './routes/transfers'
import { startTransferReconciler } from './services/ramp/reconciler'
import { maintenanceGuard }       from './lib/maintenance'
import contentRouter              from './routes/content'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startAdminAuditSummary } from './jobs/adminAuditSummary'
import { startInvoiceReminders }  from './jobs/invoiceReminders'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { startDutyScheduler }     from './jobs/dutyScheduler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)

// Capture the RAW body so webhook HMAC signatures can be verified against the
// exact bytes the provider signed. Re-stringifying the parsed object is NOT
// safe: key order, spacing and unicode escaping can all differ, which would
// make valid signatures fail to match.
app.use(express.json({
  verify: (req: any, _res, buf) => { req.rawBody = buf.toString('utf8') },
}))
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',          ratesRouter)
app.use('/transactions',   maintenanceGuard('convert'),     transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         maintenanceGuard('marketplace'), offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         maintenanceGuard('send'),        walletRouter)
app.use('/treasury',       maintenanceGuard('treasury'),    treasuryRouter)
app.use('/payroll',        maintenanceGuard('payroll'),     payrollRouter)
app.use('/notifications', notificationsRouter)
app.use('/disputes',       disputesRouter)
app.use('/invoices',       maintenanceGuard('invoices'),    invoicesRouter)
app.use('/payments',       maintenanceGuard('invoices'),    paymentsRouter)
app.use('/content',        contentRouter)
app.use('/admin-auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)
app.use('/admin/broadcasts', broadcastsRouter)
app.use('/maintenance',    maintenanceRouter)
app.use('/transfers',      transfersRouter)
app.use('/webhooks',       webhookRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
startInvoiceReminders()
startAdminAuditSummary()

  // Clean expired admin sessions every hour
  setInterval(() => cleanExpiredSessions().catch(() => {}), 3600_000)
  startTreasuryChecker()
  startTxSettler()
  startDutyScheduler()
  startTransferReconciler()
})
