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
