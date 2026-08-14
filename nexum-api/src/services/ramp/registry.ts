// ============================================================
// Provider registry. The orchestrator asks for a provider by key; whichever
// implementations are registered are available. This is where HoneyCoin /
// Yellow Card get plugged in later the core never imports them directly.
// ============================================================

import type { FiatRampProvider } from './types'
import { MockProvider } from './providers/mock'
import { FlutterwaveProvider } from './providers/flutterwave'
import { flutterwaveConfigured } from './providers/flutterwave-auth'

const registry = new Map<string, FiatRampProvider>()

export function registerProvider(p: FiatRampProvider) {
  registry.set(p.key, p)
}

export function getProvider(key: string): FiatRampProvider {
  const p = registry.get(key)
  if (!p) throw new Error(`No fiat ramp provider registered for key '${key}'`)
  return p
}

export function listProviders(): string[] {
  return [...registry.keys()]
}

// The mock is always available so the state machine is testable with no keys.
registerProvider(new MockProvider())

// Flutterwave registers only when credentials are present, so a missing .env
// can never take the app down it just means no live provider is available.
if (flutterwaveConfigured()) {
  registerProvider(new FlutterwaveProvider())
  console.log('[Ramp] ✅ Flutterwave provider registered' +
    (process.env.FLUTTERWAVE_ENV === 'production' ? ' (PRODUCTION)' : ' (sandbox)'))
} else {
  console.log('[Ramp] Flutterwave not configured, mock provider only')
}
