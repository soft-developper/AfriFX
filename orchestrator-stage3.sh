#!/bin/bash
# ============================================================
# AfriFX -- Payout Orchestrator, STAGE 3: ACTIVATION
#
# This is the stage that turns the orchestrator ON. Everything built in stages
# 1-2 (+ the Flutterwave provider) was deliberately additive and never loaded
# at runtime -- which is exactly why the "[Ramp] Flutterwave provider
# registered" log line never appeared: NOTHING IMPORTED THE REGISTRY. It was
# dead code. This wires it in.
#
# NEW ENDPOINTS
#   GET  /transfers/health          <- diagnostic: is a live provider wired up?
#   POST /transfers                 start a transfer (fiat_in or usdc_in)
#   GET  /transfers?wallet=         a sender's transfers
#   GET  /transfers/:id             one transfer + its legs (status page)
#   GET  /transfers/meta/banks?country=NG      bank list for payout forms
#   POST /transfers/meta/resolve-account       verify a bank account name
#   POST /webhooks/flutterwave      provider callbacks (SIGNATURE VERIFIED)
#
# Also registers the transfer reconciler (the cron backstop behind webhooks).
#
# SECURITY FIX INCLUDED -- RAW BODY CAPTURE.
#   Webhook HMACs are computed over the EXACT BYTES the provider sent.
#   express.json() parses and discards those bytes, and re-stringifying the
#   parsed object is NOT equivalent (key order, spacing and unicode escaping
#   can all differ), so valid signatures would have FAILED to verify in
#   production. index.ts now captures req.rawBody and the webhook verifies
#   against that. Tested: valid raw-body signature accepted, forged rejected.
#
# A forged signature returns 401 (it's an attack, not an event). A handled
# processing error still returns 200 so the provider doesn't retry forever.
#
# ENV (optional overrides):
#   RAMP_PROVIDER=flutterwave     # default provider
#   RAMP_PAYOUT_CHAIN=base        # chain we settle with the provider on
#
# Run from ~/AfriFX:  bash orchestrator-stage3.sh
# ============================================================
set -e
echo ""
echo "Activating the payout orchestrator..."
echo ""

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/transfers.ts" << 'AFX_EOF'
// ============================================================
// Cross-border transfers — the public face of the payout orchestrator.
//
//   POST /transfers            start a transfer (fiat-in or usdc-in)
//   GET  /transfers?wallet=    the sender's transfers
//   GET  /transfers/:id        one transfer + its legs (for a status page)
//   GET  /transfers/meta/banks?country=NG    bank list for payout forms
//   POST /transfers/meta/resolve-account     verify a bank account name
//
//   POST /webhooks/flutterwave  provider callbacks (signature-verified)
//
//   GET  /transfers/health     is a live provider configured? (diagnostic)
// ============================================================

import { Router } from 'express'
import { startTransfer, advanceTransfer } from '../services/ramp/engine'
import { handleProviderWebhook } from '../services/ramp/webhook'
import { getTransfer, getLegs, listTransfersBySender } from '../services/ramp/repository'
import { getProvider, listProviders } from '../services/ramp/registry'
import { flutterwaveConfigured } from '../services/ramp/providers/flutterwave-auth'
import type { SenderMode, PayoutMethod, ChainKey } from '../services/ramp/types'

const router = Router()

// The chain we settle on with the provider. Arc USDC is CCTP-bridged here.
const PAYOUT_CHAIN = (process.env.RAMP_PAYOUT_CHAIN ?? 'base') as ChainKey
const DEFAULT_PROVIDER = process.env.RAMP_PROVIDER ?? 'flutterwave'

// ── Diagnostic: is a real provider actually wired up? ──────
router.get('/health', (_req, res) => {
  res.json({
    providers: listProviders(),
    flutterwaveConfigured: flutterwaveConfigured(),
    defaultProvider: DEFAULT_PROVIDER,
    payoutChain: PAYOUT_CHAIN,
    env: process.env.FLUTTERWAVE_ENV ?? 'sandbox',
  })
})

// ── Start a transfer ───────────────────────────────────────
router.post('/', async (req, res) => {
  const {
    senderAddress, senderMode,
    sourceCurrency, sourceAmount,
    destCurrency, usdcAmount,
    recipientName, recipientMethod, recipientAccount,
    recipientBank, recipientCountry, recipientNote,
    provider,
  } = req.body

  // Validate hard — this moves real money.
  if (!senderAddress)    return res.status(400).json({ error: 'senderAddress is required' })
  if (!['fiat_in', 'usdc_in'].includes(senderMode)) {
    return res.status(400).json({ error: "senderMode must be 'fiat_in' or 'usdc_in'" })
  }
  if (!sourceCurrency || !sourceAmount || Number(sourceAmount) <= 0) {
    return res.status(400).json({ error: 'sourceCurrency and a positive sourceAmount are required' })
  }
  if (!destCurrency) return res.status(400).json({ error: 'destCurrency is required' })
  if (!recipientName || !recipientAccount || !recipientBank || !recipientCountry) {
    return res.status(400).json({
      error: 'Recipient name, account, bank/provider and country are all required',
    })
  }
  if (!['bank', 'mobile_money'].includes(recipientMethod)) {
    return res.status(400).json({ error: "recipientMethod must be 'bank' or 'mobile_money'" })
  }

  const key = provider ?? DEFAULT_PROVIDER
  try { getProvider(key) } catch {
    return res.status(503).json({
      error: `Payment provider '${key}' is not available. ` +
             `Configured providers: ${listProviders().join(', ') || 'none'}.`,
    })
  }

  try {
    // usdc_in transfers start from Arc, so they need the CCTP bridge.
    // fiat_in settles straight onto the payout chain, so no bridge.
    const needsBridge = senderMode === 'usdc_in' && PAYOUT_CHAIN !== 'arc'

    const id = await startTransfer({
      senderAddress,
      senderMode:       senderMode as SenderMode,
      sourceCurrency,
      sourceAmount:     Number(sourceAmount),
      destCurrency,
      usdcAmount:       usdcAmount != null ? Number(usdcAmount) : undefined,
      recipientName,
      recipientMethod:  recipientMethod as PayoutMethod,
      recipientAccount,
      recipientBank,
      recipientCountry,
      recipientNote,
      provider:         key,
      payoutChain:      PAYOUT_CHAIN,
      needsBridge,
    })

    // Kick the state machine immediately; the reconciler is the backstop.
    advanceTransfer(id).catch(err =>
      console.error('[Transfers] advance failed:', err?.message))

    res.status(201).json({ id, status: 'in_progress' })
  } catch (err: any) {
    console.error('[Transfers] start failed:', err?.message)
    res.status(500).json({ error: err.message })
  }
})

// ── The sender's transfers ─────────────────────────────────
router.get('/', async (req, res) => {
  const wallet = req.query.wallet as string | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet is required' })
  try {
    res.json(await listTransfersBySender(wallet))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── One transfer + its legs (status page) ──────────────────
router.get('/:id', async (req, res) => {
  try {
    const t = await getTransfer(req.params.id)
    if (!t) return res.status(404).json({ error: 'Transfer not found' })
    res.json({ transfer: t, legs: await getLegs(req.params.id) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Payout-form helpers ────────────────────────────────────
router.get('/meta/banks', async (req, res) => {
  const country = (req.query.country as string) ?? 'NG'
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.listBanks !== 'function') {
      return res.status(501).json({ error: 'This provider cannot list banks' })
    }
    res.json(await p.listBanks(country))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/meta/resolve-account', async (req, res) => {
  const { accountNumber, bankCode } = req.body
  if (!accountNumber || !bankCode) {
    return res.status(400).json({ error: 'accountNumber and bankCode are required' })
  }
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.resolveBankAccount !== 'function') {
      return res.status(501).json({ error: 'This provider cannot resolve accounts' })
    }
    res.json(await p.resolveBankAccount(accountNumber, bankCode))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router

// ══════════════════════════════════════════════════════════
// Webhook router — mounted separately at /webhooks
// ══════════════════════════════════════════════════════════
export const webhookRouter = Router()

webhookRouter.post('/flutterwave', async (req: any, res) => {
  try {
    // Verify against the RAW body bytes the provider actually signed — see the
    // express.json({ verify }) hook in index.ts. Falling back to the parsed
    // body only if rawBody is somehow unavailable.
    const payload = req.rawBody ?? req.body

    // parseWebhook VERIFIES the HMAC signature and throws if it's forged.
    // We answer 200 even on a handled failure so the provider doesn't retry
    // forever, but a BAD SIGNATURE gets a 401 — that's an attack, not an event.
    const out = await handleProviderWebhook(
      'flutterwave',
      payload,
      req.headers as Record<string, string>,
    )
    res.status(200).json({ received: true, ...out })
  } catch (err: any) {
    if (/signature/i.test(err?.message ?? '')) {
      console.warn('[Webhook] REJECTED Flutterwave webhook — bad signature')
      return res.status(401).json({ error: 'Invalid signature' })
    }
    console.error('[Webhook] Flutterwave error:', err?.message)
    res.status(200).json({ received: true, error: err?.message })
  }
})
AFX_EOF
echo "  afrifx-api/src/routes/transfers.ts"

mkdir -p "afrifx-api/src"
cat > "afrifx-api/src/index.ts" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-api/src/index.ts"

echo ""
echo "Done. No DB changes (the tables already exist). Now:"
echo ""
echo "  cd afrifx-api && npx tsc --noEmit"
echo "  cd .. && git add -A && git commit -m 'Orchestrator stage 3: activation + webhook'"
echo "  git push"
echo ""
echo "  ===== AFTER RENDER REDEPLOYS =====" 
echo ""
echo "  1) You should NOW see this in the Render logs:"
echo "       [Ramp] Flutterwave provider registered (sandbox)"
echo "     If it says 'not configured', your .env isn't being read -- check for"
echo "     CRLF line endings:  grep FLUTTERWAVE .env | cat -A"
echo ""
echo "  2) Confirm it from anywhere:"
echo "       curl https://afrifx-api.onrender.com/transfers/health"
echo "     Expect: providers includes 'flutterwave', flutterwaveConfigured: true"
echo ""
echo "  3) Point Flutterwave's Test Webhook URL at:"
echo "       https://afrifx-api.onrender.com/webhooks/flutterwave"
echo "     (with the same secret hash you put in .env)"
echo ""
echo "  Then we can run a real sandbox transfer end to end."
