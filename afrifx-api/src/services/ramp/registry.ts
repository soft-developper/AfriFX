// ============================================================
// Provider registry. The orchestrator asks for a provider by key; whichever
// implementations are registered are available. This is where HoneyCoin /
// Yellow Card get plugged in later — the core never imports them directly.
// ============================================================

import type { FiatRampProvider } from './types'
import { MockProvider } from './providers/mock'

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

// Register the mock by default so the state machine is testable with no keys.
// Real providers (honeycoin, yellowcard) are registered from here once built.
registerProvider(new MockProvider())
