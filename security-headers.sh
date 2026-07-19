#!/bin/bash
# ============================================================
# AfriFX Production Layer 1/4: SECURITY HEADERS (helmet)
#
# Adds HTTP security headers to every API response. Before this, the API sent
# NONE -- no clickjacking protection, no HSTS, no MIME-sniff protection. For an
# app moving money that's a real gap, and it's the fastest one to close.
#
# WHAT YOU GET (verified live on a booted server, not just compiled):
#   X-Frame-Options: DENY                 -> can't be iframed (clickjacking)
#   Strict-Transport-Security: 2 years    -> browsers pin HTTPS
#   Content-Security-Policy: default 'none'-> response is inert if ever rendered
#   X-Content-Type-Options: nosniff        -> no MIME sniffing
#   Referrer-Policy: no-referrer           -> no referrer leakage
#   X-Powered-By removed                   -> framework fingerprint hidden
#   Cross-Origin-Resource-Policy: cross-origin -> frontend can still call the API
#
# TUNED FOR A JSON API: helmet's HTML-oriented defaults are adjusted so nothing
# breaks -- CSP is locked to 'none' for active content (the API serves no
# scripts), and CORP is relaxed to 'cross-origin' so the Vercel frontend can
# still read responses. Mounted FIRST in the stack, so headers apply even to
# error and CORS-preflight responses.
#
# Installs the `helmet` package (added to package.json), so this script runs
# npm install.
#
# Run from ~/AfriFX:  bash security-headers.sh
# ============================================================
set -e
echo ""
echo "Adding security headers (helmet)..."
echo ""

mkdir -p "afrifx-api/src/middleware"
cat > "afrifx-api/src/middleware/security.ts" << 'AFX_EOF'
// ============================================================
// Security headers (Layer 5).
//
// AfriFX is a JSON API, not an HTML site, so the config is tuned for that:
//   * We DON'T serve a browsable UI from here, so a strict Content-Security-
//     Policy that assumes HTML/script tags would add risk of breakage without
//     protecting anything real — the frontend (Vercel) sets its own CSP. We
//     keep a minimal CSP that just disallows this origin being used to load
//     active content.
//   * HSTS is ON so browsers pin HTTPS (Render terminates TLS in front of us).
//   * We hide the framework fingerprint and turn off client-side MIME sniffing.
//   * crossOriginResourcePolicy is relaxed to 'cross-origin' because the API is
//     legitimately called from the frontend on a different origin — the strict
//     default ('same-origin') would break those reads.
// ============================================================

import helmet from 'helmet'

export const securityHeaders = helmet({
  // Clickjacking: this API should never be framed.
  frameguard: { action: 'deny' },

  // Force HTTPS for two years, including subdomains.
  hsts: {
    maxAge: 63072000,       // 2 years in seconds
    includeSubDomains: true,
    preload: true,
  },

  // Don't leak the referrer to third parties.
  referrerPolicy: { policy: 'no-referrer' },

  // A JSON API doesn't load scripts/styles/images of its own, so lock the CSP
  // right down to 'none' for active content. This makes any response that
  // somehow renders in a browser inert.
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'none'"],
      formAction: ["'none'"],
    },
  },

  // The frontend calls this API cross-origin, so allow that (the default
  // 'same-origin' would block legitimate cross-origin resource reads).
  crossOriginResourcePolicy: { policy: 'cross-origin' },

  // Belt-and-braces: X-Content-Type-Options: nosniff, hide X-Powered-By, etc.
  // (these are on by default in helmet, listed here for clarity of intent).
})
AFX_EOF
echo "  afrifx-api/src/middleware/security.ts"

mkdir -p "afrifx-api/src"
cat > "afrifx-api/src/index.ts" << 'AFX_EOF'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { securityHeaders }        from './middleware/security'
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

// Security headers first, so they apply to EVERY response (including errors
// and CORS preflight failures).
app.use(securityHeaders)
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
AFX_EOF
echo "  afrifx-api/src/index.ts"

mkdir -p "afrifx-api"
cat > "afrifx-api/package.json" << 'AFX_EOF'
{
  "name": "afrifx-api",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "tsx src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "db:push": "drizzle-kit push"
  },
  "dependencies": {
    "@libsql/client": "^0.10.0",
    "bcryptjs": "^3.0.3",
    "cloudinary": "^2.10.0",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "drizzle-orm": "^0.33.0",
    "express": "^4.19.2",
    "express-rate-limit": "^8.5.2",
    "helmet": "^8.3.0",
    "jsonwebtoken": "^9.0.3",
    "multer": "^2.2.0",
    "node-cron": "^3.0.3",
    "otpauth": "^9.5.1",
    "pdfkit": "^0.19.1",
    "qrcode": "^1.5.4",
    "resend": "^6.16.0",
    "viem": "^2.17.7"
  },
  "devDependencies": {
    "@types/bcryptjs": "^2.4.6",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/express-rate-limit": "^5.1.3",
    "@types/jsonwebtoken": "^9.0.10",
    "@types/multer": "^2.1.0",
    "@types/node": "^20",
    "@types/node-cron": "^3.0.11",
    "@types/pdfkit": "^0.17.6",
    "@types/qrcode": "^1.5.6",
    "drizzle-kit": "^0.24.0",
    "tsx": "^4.19.1",
    "typescript": "^5"
  }
}
AFX_EOF
echo "  afrifx-api/package.json"

echo ""
echo "Installing helmet..."
cd afrifx-api && npm install --no-audit --no-fund >/dev/null 2>&1 && cd ..
echo "  helmet installed"
echo ""
echo "Done. Now:"
echo "  cd afrifx-api && npx tsc --noEmit"
echo "  cd .. && git add -A && git commit -m 'Security: add helmet HTTP headers'"
echo "  git push"
echo ""
echo "  ===== AFTER DEPLOY, VERIFY =====" 
echo "  curl -sI https://afrifx-api.onrender.com/health | grep -iE \\"
echo "    'x-frame|strict-transport|content-security|x-content-type|referrer'"
echo "  -> you should see the security headers listed."
echo ""
echo "  Optional: run https://securityheaders.com against your API URL for a"
echo "  graded report."
