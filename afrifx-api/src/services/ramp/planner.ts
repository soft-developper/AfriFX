// ============================================================
// Leg planner — given a transfer, decide the ordered list of legs it needs.
// Pure function, no I/O, so it's trivially testable. See design doc §2/§3.
//
//   Case A (fiat_in):  onramp -> [bridge?] -> offramp -> payout -> reconcile
//   Case B (usdc_in):  collect -> [bridge?] -> offramp -> payout -> reconcile
//
// bridge is included only when needs_bridge = 1 (source USDC is on Arc and the
// provider settles on a different chain, e.g. Base).
// ============================================================

import type { LegType, SenderMode } from './types'

export function planLegs(opts: { senderMode: SenderMode; needsBridge: boolean }): LegType[] {
  const legs: LegType[] = []

  if (opts.senderMode === 'fiat_in') legs.push('onramp')
  else                               legs.push('collect')

  if (opts.needsBridge)              legs.push('bridge')

  legs.push('offramp')
  legs.push('payout')
  legs.push('reconcile')
  return legs
}
