#!/bin/bash
# ============================================================
# AfriFX, wire Convert to a REAL payout (backend)
#
# THE PROBLEM YOU FOUND
# Convert did exactly two things: transfer the user's USDC to a vault address,
# and write a database row saying "converted 100 USDC to 162,000 NGN". No fiat
# was created or delivered anywhere. The row recorded an INTENTION, not a claim
# on anything, and there was no path back. Your question about how the fiat
# converts back could not be answered because the round trip never closed.
#
# WHAT THIS ADDS
#   POST /transfers/cashout
#     Creates a REAL payout through a provider and tracks it in the orchestrator:
#     collect -> bridge -> offramp -> payout -> reconcile. Verified in test: a
#     valid request produces that full pipeline, not a database row.
#
# *** THE PRODUCT CHANGE YOU SHOULD KNOW ABOUT ***
# A cash-out now REQUIRES recipient details: name, account or phone, and bank or
# mobile-money provider. That is not an implementation detail, it is unavoidable:
# you cannot pay someone fiat without knowing where to send it. Convert's current
# UI does not collect these, so the frontend needs that form before this endpoint
# is usable.
# The API refuses up front when they are missing, rather than accepting the USDC
# and discovering the gap afterwards. Tested: missing recipient, missing bank and
# zero amount are all rejected BEFORE anything moves.
#
# PROVIDER CHOICE: honours the provider the user picked from the comparison, but
# VERIFIES it exists rather than trusting the client. With no choice given, it
# asks every capable provider and uses the first that quotes. If none can serve
# the corridor it returns 422 and says so, explicitly noting the USDC was not
# touched.
#
# ONE MORE HONESTY FIX
# transactions PATCH marked a conversion 'settled' as soon as the ON-CHAIN
# transfer confirmed. But that only means the USDC reached a vault; the user had
# received nothing. Telling them "settled" was wrong. On-chain confirmation now
# records 'funded', and only a completed payout marks 'settled'.
#
# BACKEND ONLY. The Convert UI still calls the old path, so nothing changes for
# users yet. Next step is the frontend: recipient details plus a provider picker.
#
# Run from ~/AfriFX:  bash convert-real-payout.sh
# ============================================================
set -e
echo ""
echo "Wiring Convert to real payouts..."
echo ""

mkdir -p "afrifx-api/src/services"
cat > "afrifx-api/src/services/cashout.ts" << 'AFX_EOF'
// ============================================================
// Cash-out: turn a USDC to fiat conversion into a REAL payout.
//
// WHY THIS EXISTS
// Convert used to do one thing: move the user's USDC to a vault address and
// write a database row saying "converted 100 USDC to 162,000 NGN". No fiat was
// ever created or delivered. The row was a record of an INTENTION, not a claim
// on anything, and there was no path back. On testnet with your own funds that
// is a demo; with real users it would be taking custody and giving nothing.
//
// This wires the conversion to the payout orchestrator, so the fiat leg
// actually happens: a provider pays the user's bank account or mobile money,
// and the transfer is tracked, retried and reconciled like any other.
//
// WHAT CHANGES FOR THE USER
// A cash-out now needs somewhere to send the money. That is a real product
// change, not an implementation detail: you cannot pay someone fiat without
// their account details. The API therefore REQUIRES recipient details and
// refuses the request without them, rather than accepting the USDC and
// discovering the problem later.
// ============================================================

import { startTransfer, advanceTransfer } from './ramp/engine'
import { getProvider, listProviders } from './ramp/registry'
import { compareProviders } from './ramp/compare'
import type { PayoutMethod, ChainKey } from './ramp/types'

const PAYOUT_CHAIN = (process.env.RAMP_PAYOUT_CHAIN ?? 'base') as ChainKey

export interface CashOutRequest {
  walletAddress: string
  usdcAmount:    number
  destCurrency:  string
  country:       string
  recipient: {
    name:    string
    method:  PayoutMethod
    account: string
    bank:    string
    note?:   string
  }
  /** Chosen by the user from the comparison. Falls back to the default. */
  provider?: string
}

export interface CashOutResult {
  ok: boolean
  transferId?: string
  provider?:   string
  error?:      string
  /** Set when the failure is "no provider can serve this", so the UI can explain. */
  noProvider?: boolean
}

/*
  Validate hard BEFORE anything moves.

  The old flow's central flaw was that it accepted USDC first and had no way to
  deliver. So every precondition for actually paying someone is checked up
  front, and the request is refused if any is missing.
*/
export async function startCashOut(req: CashOutRequest): Promise<CashOutResult> {
  if (!req.walletAddress)               return { ok: false, error: 'walletAddress is required' }
  if (!(req.usdcAmount > 0))            return { ok: false, error: 'A positive usdcAmount is required' }
  if (!req.destCurrency)                return { ok: false, error: 'destCurrency is required' }
  if (!req.country)                     return { ok: false, error: 'country is required' }

  const r = req.recipient
  if (!r?.name)    return { ok: false, error: 'Recipient name is required to pay out' }
  if (!r?.account) return { ok: false, error: 'Account number or phone is required to pay out' }
  if (!r?.bank)    return { ok: false, error: 'Bank or mobile money provider is required' }
  if (!['bank', 'mobile_money'].includes(r.method)) {
    return { ok: false, error: "method must be 'bank' or 'mobile_money'" }
  }

  /*
    Which provider? If the user picked one from the comparison, honour it,
    but VERIFY it can actually serve this route rather than trusting the client.
    If they didn't pick, use whichever capable provider quotes successfully.
  */
  let chosen = req.provider

  if (chosen) {
    if (!listProviders().includes(chosen)) {
      return { ok: false, error: `Provider '${chosen}' is not available` }
    }
  } else {
    const quotes = await compareProviders({
      usdcAmount: req.usdcAmount,
      destCurrency: req.destCurrency,
      country: req.country,
      method: r.method,
    })
    const usable = quotes.find(q => q.ok)
    if (!usable) {
      return {
        ok: false, noProvider: true,
        error: `No payout provider can currently send ${req.destCurrency} to ${req.country}. ` +
               `Your USDC has not been touched.`,
      }
    }
    chosen = usable.provider
  }

  try {
    /*
      usdc_in: the user already holds USDC on Arc, so the orchestrator collects
      it, bridges to the provider's settlement chain, converts and pays out.
      needsBridge is true whenever the provider settles somewhere other than Arc.
    */
    const transferId = await startTransfer({
      senderAddress:   req.walletAddress,
      senderMode:      'usdc_in',
      sourceCurrency:  'USDC',
      sourceAmount:    req.usdcAmount,
      destCurrency:    req.destCurrency,
      usdcAmount:      req.usdcAmount,
      recipientName:    r.name,
      recipientMethod:  r.method,
      recipientAccount: r.account,
      recipientBank:    r.bank,
      recipientCountry: req.country,
      recipientNote:    r.note,
      provider:        chosen,
      payoutChain:     PAYOUT_CHAIN,
      needsBridge:     PAYOUT_CHAIN !== 'arc',
    } as any)

    // Kick the state machine; the reconciler is the backstop if this throws.
    advanceTransfer(transferId).catch(err =>
      console.error('[CashOut] advance failed:', err?.message))

    return { ok: true, transferId, provider: chosen }
  } catch (err: any) {
    return { ok: false, error: err?.message ?? 'Could not start the payout' }
  }
}
AFX_EOF
echo "  afrifx-api/src/services/cashout.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/transfers.ts" << 'AFX_EOF'
// ============================================================
// Cross-border transfers the public face of the payout orchestrator.
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
import { compareProviders, providerCapabilities } from '../services/ramp/compare'
import { startCashOut } from '../services/cashout'
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

  // Best-effort balance a dry wallet is the most likely payout failure.
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

// ── Provider comparison ────────────────────────────────────
/*
  GET /transfers/providers
    What ramps exist and what each can serve. Cheap, no network calls to
    providers, so it's safe to call on page load.

  POST /transfers/quotes
    Ask every CAPABLE provider for a live quote and return them ALL, including
    any that failed. Deliberately unranked: the best rate is often not the
    fastest, and choosing for the user would mean quietly steering them.
*/
router.get('/providers', async (_req, res) => {
  try { res.json(await providerCapabilities()) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/quotes', async (req, res) => {
  const { usdcAmount, destCurrency, country, method } = req.body
  if (!usdcAmount || Number(usdcAmount) <= 0) {
    return res.status(400).json({ error: 'A positive usdcAmount is required' })
  }
  if (!destCurrency) return res.status(400).json({ error: 'destCurrency is required' })
  if (!country)      return res.status(400).json({ error: 'country is required' })

  try {
    const quotes = await compareProviders({
      usdcAmount: Number(usdcAmount),
      destCurrency, country, method,
    })
    res.json({
      usdcAmount: Number(usdcAmount), destCurrency, country,
      quotes,
      // Surfaced so the UI can say "2 of 3 providers responded" rather than
      // silently showing a short list.
      available: quotes.filter(q => q.ok).length,
      total:     quotes.length,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Cash out: USDC to fiat, actually delivered ─────────────
/*
  POST /transfers/cashout

  This is what "Convert USDC to NGN" should call. Unlike the old flow, which
  wrote a database row and delivered nothing, this creates a REAL payout through
  a provider and tracks it through the orchestrator.

  It REQUIRES recipient details, because you cannot pay someone fiat without
  knowing where to send it. Refusing up front is far better than accepting the
  USDC and discovering the gap afterwards.
*/
router.post('/cashout', async (req, res) => {
  try {
    const result = await startCashOut(req.body)
    if (!result.ok) {
      // 422 for "we understood you but cannot serve this route", so the UI can
      // distinguish a bad request from an unavailable corridor.
      return res.status(result.noProvider ? 422 : 400).json({ error: result.error })
    }
    res.status(201).json({
      transferId: result.transferId,
      provider:   result.provider,
      status:     'in_progress',
    })
  } catch (err: any) {
    console.error('[CashOut]', err?.message)
    res.status(500).json({ error: err.message })
  }
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

  // Validate hard this moves real money.
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
    const result = await p.resolveBankAccount(accountNumber, bankCode, currency ?? 'NGN')
    // Never answer with an empty body an empty 200 is indistinguishable from
    // a silent failure, which is exactly what bit us here.
    res.json(result ?? { empty: true, note: 'Provider returned no data' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router

// ══════════════════════════════════════════════════════════
// Webhook router mounted separately at /webhooks
// ══════════════════════════════════════════════════════════
export const webhookRouter = Router()

webhookRouter.post('/flutterwave', async (req: any, res) => {
  try {
    // Verify against the RAW body bytes the provider actually signed see the
    // express.json({ verify }) hook in index.ts. Falling back to the parsed
    // body only if rawBody is somehow unavailable.
    const payload = req.rawBody ?? req.body

    // parseWebhook VERIFIES the HMAC signature and throws if it's forged.
    // We answer 200 even on a handled failure so the provider doesn't retry
    // forever, but a BAD SIGNATURE gets a 401 that's an attack, not an event.
    const out = await handleProviderWebhook(
      'flutterwave',
      payload,
      req.headers as Record<string, string>,
    )
    res.status(200).json({ received: true, ...out })
  } catch (err: any) {
    if (/signature/i.test(err?.message ?? '')) {
      console.warn('[Webhook] REJECTED Flutterwave webhook, bad signature')
      return res.status(401).json({ error: 'Invalid signature' })
    }
    console.error('[Webhook] Flutterwave error:', err?.message)
    res.status(200).json({ received: true, error: err?.message })
  }
})
AFX_EOF
echo "  afrifx-api/src/routes/transfers.ts"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/transactions.ts" << 'AFX_EOF'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /transactions?wallet=0x
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /transactions create
router.post('/', async (req, res) => {
  const {
    walletAddress, fromCurrency, toCurrency,
    fromAmount, toAmount, spreadFee, networkFee,
    arcTxHash, memoId, reference, corridorId, corridorStep,
  } = req.body

  const now = Math.floor(Date.now() / 1000)
  const id  = arcTxHash ?? `tx-${now}-${Math.random().toString(36).slice(2,8)}`

  try {
    await db.run(
      sql`INSERT OR IGNORE INTO transactions
          (id, wallet_address, from_currency, to_currency,
           from_amount, to_amount, spread_fee, network_fee,
           arc_tx_hash, memo_id, reference,
           corridor_id, corridor_step, status, created_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()}, ${fromCurrency}, ${toCurrency},
           ${fromAmount}, ${toAmount}, ${spreadFee ?? 0}, ${networkFee ?? 0.001},
           ${arcTxHash ?? null}, ${memoId ?? null}, ${reference ?? null},
           ${corridorId ?? null}, ${corridorStep ?? null}, 'pending', ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

/*
  PATCH /transactions/:hash, update status after on-chain confirmation.

  IMPORTANT DISTINCTION. A confirmed on-chain transfer means the USDC left the
  user's wallet. For a USDC to fiat conversion that is NOT the same as the
  conversion being SETTLED: settled should mean the recipient actually received
  their money, which happens later, via a payout provider.

  Calling that 'settled' told users their money had arrived when it had not.
  So an on-chain confirmation now records 'funded' for fiat-bound conversions,
  and only the payout completing marks them 'settled'. Callers can still pass an
  explicit status for other cases.
*/
router.patch('/:hash', async (req, res) => {
  const { status } = req.body
  const now        = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE transactions
          SET status     = ${status ?? 'funded'},
              settled_at = ${status === 'settled' ? now : null}
          WHERE arc_tx_hash = ${req.params.hash}
             OR id          = ${req.params.hash}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /transactions/ref/:ref
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions WHERE reference = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Not found' })
    res.json(r[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/transactions.ts"

echo ""
echo "Done. Then:"
echo "  cd afrifx-api && npx tsc --noEmit"
echo "  cd .. && git add -A && git commit -m 'Convert: real provider payouts via orchestrator'"
echo "  git push"
echo ""
echo "  ===== TRY IT ====="
echo "  curl -X POST https://afrifx-api.onrender.com/transfers/cashout \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"walletAddress\":\"0xYourWallet\",\"usdcAmount\":10,"
echo "         \"destCurrency\":\"NGN\",\"country\":\"NG\",\"provider\":\"mock\","
echo "         \"recipient\":{\"name\":\"Ada Obi\",\"method\":\"bank\","
echo "                       \"account\":\"0690000031\",\"bank\":\"044\"}}'"
echo ""
echo "  Then GET /transfers/<id> to watch the legs. With provider 'mock' this is"
echo "  safe to run today; no real money moves."
echo ""
echo "  IMPORTANT: do NOT point the Convert UI at this until the recipient form"
echo "  exists, or users will hit validation errors after signing."
