// ============================================================
// Mock fiat ramp provider a fully working fake for testing the orchestrator
// state machine end-to-end with NO real API keys. Mirrors the SHAPES HoneyCoin
// returns (see HONEYCOIN_INTEGRATION_NOTES.md) so swapping in the real one
// later changes nothing in the core.
//
// Behaviour is deterministic + controllable via the idempotency key suffix so
// tests can force outcomes:
//   key ending in ':fail_onramp'  -> onramp reports failed
//   key ending in ':fail_payout'  -> payout reports failed
// Otherwise everything succeeds.
// ============================================================

import type {
  FiatRampProvider, ChainKey, RampQuote, PayoutRecipient,
  OnrampResult, PayoutResult, NormalizedWebhook,
} from '../types'
import { randomUUID } from 'crypto'

export class MockProvider implements FiatRampProvider {
  readonly key = 'mock'

  // Declared so the comparison layer can be exercised end to end before a
  // second real provider is signed up.
  async capabilities() {
    return {
      key: this.key,
      displayName: 'Test provider',
      countries:  ['NG', 'GH', 'KE', 'ZA', 'UG'],
      currencies: ['NGN', 'GHS', 'KES', 'ZAR', 'UGX'],
      methods:    ['bank', 'mobile_money'] as ('bank' | 'mobile_money')[],
      configured: true,
      note: 'Sandbox provider for testing. Not a real payout route.',
    }
  }

  async supportedChains(): Promise<ChainKey[]> {
    // Mirror HoneyCoin: no Arc, settles on major EVM chains.
    return ['eth', 'arb', 'base', 'matic', 'bsc', 'optimism']
  }

  async createOnramp(params: {
    idempotencyKey: string; senderAmount: number; senderCurrency: string
    receiverChain: ChainKey; receiverAddress: string
    method: 'bank' | 'mobile_money'; charge: Record<string, string>; email?: string
  }): Promise<OnrampResult> {
    return {
      providerRef: `mock_on_${randomUUID().slice(0, 8)}`,
      payInstructions: { note: 'MOCK: pretend the customer paid via ' + params.method },
    }
  }

  async getPayoutQuote(params: {
    usdcAmount: number; destCurrency: string; country: string
  }): Promise<RampQuote> {
    // A plausible fake rate; e.g. 1 USDC ~ 130 KES / 1600 NGN, else 1.
    const table: Record<string, number> = { KES: 130, NGN: 1600, GHS: 15, ZAR: 18, UGX: 3700 }
    const rate = table[params.destCurrency] ?? 1
    const destAmount = +(params.usdcAmount * rate).toFixed(2)
    // A flat-ish fee so the comparison UI has something realistic to display,
    // and so "best rate" and "best net amount" can visibly diverge.
    const feeDest = +(destAmount * 0.005).toFixed(2)
    return {
      quoteId:   `mock_q_${randomUUID().slice(0, 8)}`,
      rate,
      expiresAt: Math.floor(Date.now() / 1000) + 3600, // 1h window, like HoneyCoin
      usdcAmount: params.usdcAmount,
      destAmount,
      feeDest,
      netDest: +(destAmount - feeDest).toFixed(2),
      etaSeconds: 120,
      etaLabel: 'about 2 minutes',
    }
  }

  async createPayout(params: {
    idempotencyKey: string; usdcAmount: number; destCurrency: string
    chain: ChainKey; recipient: PayoutRecipient
  }): Promise<PayoutResult> {
    return {
      providerRef:    `mock_off_${randomUUID().slice(0, 8)}`,
      depositAddress: '0x000000000000000000000000000000000000dEaD',
      depositChain:   params.chain,
      expectedAmount: params.usdcAmount, // exact-amount, like HoneyCoin
    }
  }

  parseWebhook(body: unknown, _headers: Record<string, string>): NormalizedWebhook {
    const b = (body ?? {}) as any
    const data = b.data ?? {}
    const legMap: Record<string, 'onramp' | 'offramp' | 'payout'> = {
      onramp: 'onramp', offramp: 'offramp', withdrawal: 'payout',
    }
    return {
      providerRef:       data.transactionId,
      externalReference: data.externalReference,
      leg:    legMap[data.type] ?? 'payout',
      status: data.status === 'successful' ? 'done'
            : data.status === 'failed'     ? 'failed' : 'pending',
      detail: data,
    }
  }

  async getStatus(ref: { idempotencyKey?: string; providerRef?: string }):
    Promise<{ status: 'pending' | 'done' | 'failed'; detail?: unknown }> {
    const key = ref.idempotencyKey ?? ''
    if (key.endsWith(':fail_onramp') || key.endsWith(':fail_payout')) {
      return { status: 'failed', detail: { mock: true } }
    }
    return { status: 'done', detail: { mock: true } }
  }
}
