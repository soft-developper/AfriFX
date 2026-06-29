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
import invoicesRouter              from './routes/invoices'
import paymentsRouter              from './routes/payments'
import adminAuthRouter            from './routes/adminAuth'
import adminManageRouter          from './routes/adminManage'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'
import { startTreasuryChecker }   from './jobs/treasuryChecker'
import { startTxSettler }         from './jobs/txSettler'
import { seedSuperAdmin }         from './lib/seedAdmin'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)

// More lenient rate limit for admin auth (avoids 429 on legitimate use)
import rateLimit from 'express-rate-limit'
const adminRateLimit = rateLimit({
  windowMs: 60 * 1000,     // 1 minute
  max:      60,            // 60 requests per minute per IP
  standardHeaders: true,
  legacyHeaders:   false,
  skip: (req) => req.path.includes('/admin/auth/me'), // never rate-limit /me
})
app.use('/admin/auth', adminRateLimit)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => res.json({ status: 'ok', ts: Date.now() }))

app.use('/rates',          ratesRouter)
app.use('/transactions',   transactionsRouter)
app.use('/user',           userRouter)
app.use('/offers',         offersRouter)
app.use('/profile',        profileRouter)
app.use('/chat',           chatRouter)
app.use('/wallet',         walletRouter)
app.use('/treasury',       treasuryRouter)
app.use('/payroll',        payrollRouter)
app.use('/invoices',       invoicesRouter)
app.use('/payments',       paymentsRouter)
app.use('/admin/auth',     adminAuthRouter)
app.use('/admin/manage',   adminManageRouter)

app.use(errorHandler)

app.listen(PORT, async () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  await seedSuperAdmin()
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
  startTreasuryChecker()
  startTxSettler()
})
