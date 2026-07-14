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
router.get('/health', async (_req, res) => {
  const out: any = {
    providers: listProviders(),
    flutterwaveConfigured: flutterwaveConfigured(),
    defaultProvider: DEFAULT_PROVIDER,
    payoutChain: PAYOUT_CHAIN,
    env: process.env.FLUTTERWAVE_ENV ?? 'sandbox',
    // The on-ramp credits USDC into this wallet; the off-ramp spends from it.
    walletIdSet: !!process.env.FLUTTERWAVE_WALLET_ID,
    webhookSecretSet: !!process.env.FLUTTERWAVE_WEBHOOK_SECRET_HASH,
  }

  // Best-effort balance — a dry wallet is the most likely payout failure.
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.walletBalance === 'function') {
      out.usdcBalance = await p.walletBalance('USDC')
    }
  } catch (err: any) {
    out.balanceError = err?.message
  }

  res.json(out)
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
  const { accountNumber, bankCode, currency } = req.body
  if (!accountNumber || !bankCode) {
    return res.status(400).json({ error: 'accountNumber and bankCode are required' })
  }
  try {
    const p: any = getProvider(DEFAULT_PROVIDER)
    if (typeof p.resolveBankAccount !== 'function') {
      return res.status(501).json({ error: 'This provider cannot resolve accounts' })
    }
    // Flutterwave v4 requires the account currency (NGN, GHS, KES…).
    res.json(await p.resolveBankAccount(accountNumber, bankCode, currency ?? 'NGN'))
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
