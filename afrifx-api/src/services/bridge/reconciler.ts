// ============================================================
// Bridge reconciler.
//
// The backstop behind the browser. A CCTP bridge needs the user's wallet to
// SIGN the burn, but the mint afterwards is permissionless -- anyone can submit
// it. So if a user closes the tab after burning, their funds are NOT lost; the
// mint just hasn't happened yet.
//
// This cron finds those and (in stage 3) finishes them. Right now it only
// REPORTS, because execution doesn't exist yet -- but it's wired in early so
// stranded transfers are visible from day one rather than discovered by an
// angry user.
// ============================================================

import { listUnresolved, nextAction, isInFlight } from './repository'

const INTERVAL_MS = Number(process.env.BRIDGE_RECONCILE_MS ?? 120_000) // 2 min

let timer: NodeJS.Timeout | null = null

export async function reconcileOnce(): Promise<{
  checked: number; inFlight: number; needsMint: number
}> {
  const pending = await listUnresolved()
  let inFlight = 0, needsMint = 0

  for (const rec of pending) {
    if (isInFlight(rec)) inFlight++
    const action = nextAction(rec)
    if (action === 'mint') needsMint++

    // Age matters: a bridge stuck for hours is a support issue, not a blip.
    const ageMin = Math.floor((Date.now() / 1000 - rec.updated_at) / 60)
    if (ageMin > 30) {
      console.warn(
        `[Bridge] STUCK ${rec.id} ${rec.from_chain}->${rec.to_chain} ` +
        `${rec.amount} USDC status=${rec.status} age=${ageMin}m ` +
        `burn=${rec.burn_tx ?? 'none'} action=${action}`)
    }
  }

  if (pending.length) {
    console.log(`[Bridge] reconcile: ${pending.length} unresolved, ` +
                `${inFlight} in flight, ${needsMint} ready to mint`)
  }
  return { checked: pending.length, inFlight, needsMint }
}

export function startBridgeReconciler() {
  if (timer) return
  timer = setInterval(() => {
    reconcileOnce().catch(err =>
      console.error('[Bridge] reconcile failed:', err?.message))
  }, INTERVAL_MS)
  console.log(`[Bridge] reconciler started (every ${INTERVAL_MS / 1000}s)`)
}

export function stopBridgeReconciler() {
  if (timer) { clearInterval(timer); timer = null }
}
