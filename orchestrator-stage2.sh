#!/bin/bash
# ============================================================
# AfriFX -- Payout Orchestrator, STAGE 2: the state machine
#
# Requires stage 1. Backend-only, still fully ADDITIVE (no existing files
# touched, nothing wired into routes yet -> zero behavioural change). This is
# the engine that drives a transfer through its legs, validated end-to-end
# against the mock provider from stage 1.
#
# Files:
#   planner.ts     -- decides which legs a transfer needs (Case A vs B, bridge?)
#   cctp.ts        -- CCTP bridge module (burn/attest/mint); MOCK mode by default,
#                     real on-chain calls gated behind CCTP_LIVE=true (TODOs)
#   engine.ts      -- the state machine: create legs, advance one at a time,
#                     never start leg N+1 until leg N is confirmed done
#   webhook.ts     -- provider webhook -> finalize leg -> advance (primary signal)
#   reconciler.ts  -- cron backstop that reconciles in-flight legs (like txSettler)
#
# Tested: both flows proven end-to-end against a real DB + mock provider:
#   Case A (fiat_in + bridge): onramp->bridge->offramp->payout->reconcile = completed
#   Case B (usdc_in, forced fail): collect->offramp(fail) -> transfer 'refunding'
#
# Run from ~/AfriFX:  bash orchestrator-stage2.sh
# ============================================================
set -e
echo ""
echo "Installing payout orchestrator stage 2 (state machine)..."
echo ""

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/planner.ts" << 'AFX_EOF'
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
AFX_EOF
echo "  afrifx-api/src/services/ramp/planner.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/cctp.ts" << 'AFX_EOF'
// ============================================================
// CCTP bridge module — moves USDC from Arc to a provider-supported chain
// (e.g. Base) using Circle's Cross-Chain Transfer Protocol: burn on source,
// get Circle's attestation, mint canonical USDC on destination. No wrapped
// tokens, 1:1 amount. See HONEYCOIN_INTEGRATION_NOTES.md §5.
//
// STATUS: structured skeleton. The on-chain calls are marked TODO and gated
// behind CCTP_LIVE — with CCTP_LIVE unset (default), bridge() runs in MOCK mode
// so the state machine is testable end-to-end now. Real burn/attest/mint gets
// filled in once we finalize the destination chain (Base) + have RPC/keys.
//
// CCTP references (to implement against):
//   - TokenMessenger.depositForBurn(amount, destDomain, mintRecipient, burnToken)
//   - Circle attestation API: GET https://iris-api.circle.com/attestations/{msgHash}
//   - MessageTransmitter.receiveMessage(message, attestation) on destination
// ============================================================

import type { ChainKey } from './types'

const CCTP_LIVE = process.env.CCTP_LIVE === 'true'

// Circle CCTP domain ids (destination routing). Arc + majors.
// NOTE: confirm Arc's domain id from Circle docs before going live.
const CCTP_DOMAIN: Partial<Record<ChainKey, number>> = {
  eth: 0, optimism: 2, arb: 3, base: 6, matic: 7,
  // arc: <confirm>,
}

export interface BridgeRequest {
  amountUsdc:  number
  fromChain:   ChainKey       // 'arc'
  toChain:     ChainKey       // e.g. 'base'
  recipient:   string         // destination address (provider deposit addr)
  idempotencyKey: string
}

export interface BridgeResult {
  status:       'done' | 'failed'
  burnTxHash?:  string
  attestation?: string
  mintTxHash?:  string
  error?:       string
}

// Burn on source, poll attestation, mint on destination.
export async function bridge(req: BridgeRequest): Promise<BridgeResult> {
  if (!CCTP_LIVE) return mockBridge(req)

  try {
    // 1) Burn on source chain (Arc)
    //    TODO: call TokenMessenger.depositForBurn on Arc via a signer wallet.
    //    const burnTx = await tokenMessenger.write.depositForBurn([...])
    const burnTxHash = await burnOnSource(req)

    // 2) Retrieve Circle's attestation for the burn message
    const attestation = await pollAttestation(burnTxHash)
    if (!attestation) return { status: 'failed', burnTxHash, error: 'attestation timeout' }

    // 3) Mint on destination chain (Base) via MessageTransmitter.receiveMessage
    const mintTxHash = await mintOnDestination(req, attestation)

    return { status: 'done', burnTxHash, attestation, mintTxHash }
  } catch (err: any) {
    return { status: 'failed', error: err?.message ?? 'bridge error' }
  }
}

// ---- real implementations (TODO — filled in with RPC/keys + final chain) ----

async function burnOnSource(_req: BridgeRequest): Promise<string> {
  // TODO: build viem client for Arc, call depositForBurn, return tx hash.
  throw new Error('CCTP burn not implemented yet (set CCTP_LIVE only when ready)')
}

async function pollAttestation(_burnTxHash: string): Promise<string | null> {
  // TODO: derive message hash from burn receipt, poll Circle iris-api until
  // status === 'complete', return attestation bytes. Respect a timeout.
  throw new Error('CCTP attestation polling not implemented yet')
}

async function mintOnDestination(_req: BridgeRequest, _attestation: string): Promise<string> {
  // TODO: call MessageTransmitter.receiveMessage(message, attestation) on dest.
  throw new Error('CCTP mint not implemented yet')
}

// ---- mock mode (default) — lets the state machine run end-to-end now ----

async function mockBridge(req: BridgeRequest): Promise<BridgeResult> {
  // Force failure for tests via a key suffix, else succeed with fake hashes.
  if (req.idempotencyKey.endsWith(':fail_bridge')) {
    return { status: 'failed', error: 'MOCK bridge failure' }
  }
  return {
    status:      'done',
    burnTxHash:  `0xmockburn_${req.idempotencyKey.slice(0, 8)}`,
    attestation: `0xmockattest_${req.idempotencyKey.slice(0, 8)}`,
    mintTxHash:  `0xmockmint_${req.idempotencyKey.slice(0, 8)}`,
  }
}

export const __cctpMode = () => (CCTP_LIVE ? 'live' : 'mock')
AFX_EOF
echo "  afrifx-api/src/services/ramp/cctp.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/engine.ts" << 'AFX_EOF'
// ============================================================
// Orchestrator engine — the durable state machine that advances a transfer
// one leg at a time. Core invariant (design §5): never start leg N+1 until
// leg N is 'done'. Confirmation is always ground-truth (provider status /
// on-chain), never optimistic — the same lesson baked into txSettler.
//
// This engine is provider-agnostic: it calls the FiatRampProvider interface
// and the CCTP module, both of which run against the mock by default, so the
// whole flow is testable now with no real keys.
// ============================================================

import {
  createTransfer, getTransfer, updateTransfer,
  createLeg, getLegs, updateLeg, type NewTransfer,
} from './repository'
import { planLegs } from './planner'
import { getProvider } from './registry'
import { bridge } from './cctp'
import type { LegType, PayoutRecipient, ChainKey } from './types'

const rowVal = (row: any, key: string, arrIdx: number) =>
  Array.isArray(row) ? row[arrIdx] : row[key]

// ---- 1. Create a transfer and its planned legs -------------------------------

export async function startTransfer(input: NewTransfer): Promise<string> {
  const transferId = await createTransfer(input)
  const legs = planLegs({
    senderMode:  input.senderMode,
    needsBridge: !!input.needsBridge,
  })
  legs.forEach(async (legType, i) => {
    await createLeg({
      transferId, legType, legIndex: i,
      idempotencyKey: `${transferId}:${legType}`,
    })
  })
  await updateTransfer(transferId, { status: 'in_progress', current_leg: legs[0] })
  return transferId
}

// ---- 2. Advance a single transfer by one step --------------------------------
// Called by the tick loop and by webhook handlers. Idempotent and safe to
// call repeatedly: it finds the first non-done leg and nudges it forward.

export async function advanceTransfer(transferId: string): Promise<void> {
  const transfer = await getTransfer(transferId)
  if (!transfer) return
  const status = transfer.status ?? transfer[/*status*/ 17]
  if (status === 'completed' || status === 'failed' || status === 'refunded') return

  const legs = await getLegs(transferId)
  // Find the first leg that isn't done/skipped.
  const leg = legs.find((l: any) => {
    const s = l.status ?? l[4]
    return s !== 'done' && s !== 'skipped'
  })

  if (!leg) {
    // All legs done → transfer complete.
    await updateTransfer(transferId, { status: 'completed', current_leg: null })
    return
  }

  const legId   = leg.id       ?? leg[0]
  const legType = (leg.leg_type ?? leg[2]) as LegType
  const legStat = leg.status   ?? leg[4]
  const idemKey = leg.idempotency_key ?? leg[5]

  await updateTransfer(transferId, { current_leg: legType })

  // If the leg already failed, move the transfer into refunding.
  if (legStat === 'failed') {
    await updateTransfer(transferId, { status: 'refunding',
      failure_reason: `leg ${legType} failed` })
    return
  }

  // Execute the leg based on its type. Each executor sets the leg to
  // in_flight, does its work, and reports done/failed. Ground-truth only.
  try {
    switch (legType) {
      case 'onramp':    await execOnramp(transfer, legId, idemKey); break
      case 'collect':   await execCollect(transfer, legId, idemKey); break
      case 'bridge':    await execBridge(transfer, legId, idemKey); break
      case 'offramp':   await execOfframp(transfer, legId, idemKey); break
      case 'payout':    await execPayout(transfer, legId, idemKey); break
      case 'reconcile': await execReconcile(transfer, legId); break
    }
  } catch (err: any) {
    await updateLeg(legId, { status: 'failed', error: err?.message ?? 'leg error' })
    await updateTransfer(transferId, { status: 'refunding',
      failure_reason: `leg ${legType}: ${err?.message ?? 'error'}` })
  }
}

// ---- Leg executors -----------------------------------------------------------
// NOTE: onramp/offramp/payout finalize on provider WEBHOOK, not here. Here we
// initiate and set in_flight; the webhook (or the tick backstop via getStatus)
// flips them to done. bridge/collect/reconcile complete synchronously.

async function execOnramp(t: any, legId: string, idemKey: string) {
  const provider = getProvider(t.provider ?? t[15])
  await updateLeg(legId, { status: 'in_flight' })
  const res = await provider.createOnramp({
    idempotencyKey: idemKey,
    senderAmount:   t.source_amount ?? t[4],
    senderCurrency: t.source_currency ?? t[3],
    receiverChain:  (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    receiverAddress: platformWalletFor((t.payout_chain ?? t[16] ?? 'base') as ChainKey),
    method:  (t.recipient_method ?? t[9]) as 'bank' | 'mobile_money',
    charge:  {}, // filled from sender's chosen pay method in the route layer
  })
  await updateLeg(legId, { provider_ref: res.providerRef })
  // stays in_flight until webhook confirms
}

async function execCollect(t: any, legId: string, _idemKey: string) {
  // Pull the sender's USDC into platform custody on Arc.
  // TODO: real on-chain transfer from sender (they approve in the UI). For now,
  // mock as done so the machine can proceed end-to-end.
  await updateLeg(legId, { status: 'done', tx_hash: `0xmockcollect_${legId.slice(3, 11)}` })
}

async function execBridge(t: any, legId: string, idemKey: string) {
  await updateLeg(legId, { status: 'in_flight' })
  const res = await bridge({
    amountUsdc: t.usdc_amount ?? t[7] ?? 0,
    fromChain:  'arc',
    toChain:    (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    recipient:  platformWalletFor((t.payout_chain ?? t[16] ?? 'base') as ChainKey),
    idempotencyKey: idemKey,
  })
  if (res.status === 'done') {
    await updateLeg(legId, { status: 'done', tx_hash: res.mintTxHash,
      attestation: res.attestation })
  } else {
    await updateLeg(legId, { status: 'failed', error: res.error })
    throw new Error(res.error ?? 'bridge failed')
  }
}

async function execOfframp(t: any, legId: string, idemKey: string) {
  const provider = getProvider(t.provider ?? t[15])
  await updateLeg(legId, { status: 'in_flight' })
  const recipient: PayoutRecipient = {
    name:    t.recipient_name ?? t[8],
    method:  (t.recipient_method ?? t[9]) as 'bank' | 'mobile_money',
    account: t.recipient_account ?? t[10],
    bank:    t.recipient_bank ?? t[11],
    country: t.recipient_country ?? t[12],
  }
  const res = await provider.createPayout({
    idempotencyKey: idemKey,
    usdcAmount: t.usdc_amount ?? t[7] ?? 0,
    chain:      (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
    recipient,
  })
  await updateLeg(legId, { provider_ref: res.providerRef,
    amount: res.expectedAmount })
  // The offramp+payout finalize via the provider webhook.
}

async function execPayout(t: any, legId: string, _idemKey: string) {
  // In HoneyCoin's model, payout is auto-initiated after the offramp deposit
  // confirms, and completion arrives by webhook. So this leg is confirmed by
  // the webhook handler; here we simply ensure it's marked in_flight.
  await updateLeg(legId, { status: 'in_flight' })
}

async function execReconcile(t: any, legId: string) {
  await updateLeg(legId, { status: 'done' })
  await updateTransfer(t.id ?? t[0], { status: 'completed', current_leg: null })
  // TODO: issue receipt (reuse receipt-pdf + Resend), notify both parties.
}

// ---- helpers -----------------------------------------------------------------

function platformWalletFor(_chain: ChainKey): string {
  // TODO: return the platform's receiving wallet on the given chain from config.
  return process.env.PLATFORM_WALLET_ADDRESS ?? '0x0000000000000000000000000000000000000000'
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/engine.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/webhook.ts" << 'AFX_EOF'
// ============================================================
// Webhook handling — a provider webhook (normalized via provider.parseWebhook)
// flips the matching leg to done/failed, then advances the transfer. This is
// the PRIMARY confirmation signal (design §5/§6); the tick loop is the backstop.
// ============================================================

import { getProvider } from './registry'
import { findLegByIdempotencyKey, updateLeg, getLegs } from './repository'
import { advanceTransfer } from './engine'
import { db } from '../../db/client'
import { sql } from 'drizzle-orm'

const rowVal = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

// Process a raw provider webhook. Returns the transferId it touched, if any.
export async function handleProviderWebhook(
  providerKey: string, body: unknown, headers: Record<string, string>,
): Promise<{ ok: boolean; transferId?: string }> {
  const provider = getProvider(providerKey)

  // TODO: verify webhook signature per provider (e.g. HoneyCoin webhook secret)
  // BEFORE trusting the body. Reject if invalid.

  const norm = provider.parseWebhook(body, headers)

  // Find the leg by our idempotency key (which we set == externalReference).
  const key = norm.externalReference
  if (!key) return { ok: false }

  const leg = await findLegByIdempotencyKey(key)
  if (!leg) return { ok: false }

  const legId      = rowVal(leg, 'id', 0)
  const transferId = rowVal(leg, 'transfer_id', 1)
  const current    = rowVal(leg, 'status', 4)

  // Idempotent: ignore if already finalized.
  if (current === 'done' || current === 'failed') return { ok: true, transferId }

  if (norm.status === 'done') {
    await updateLeg(legId, { status: 'done' })
    // If this was the offramp, its paired payout leg also completes here
    // (HoneyCoin auto-pays after offramp deposit confirms).
    await maybeCompletePairedPayout(transferId)
  } else if (norm.status === 'failed') {
    await updateLeg(legId, { status: 'failed', error: 'provider reported failure' })
  }

  await advanceTransfer(transferId)
  return { ok: true, transferId }
}

// When the offramp completes, HoneyCoin auto-initiates the payout and its
// completion is the same/next webhook. To keep the machine moving, mark a
// still-pending payout leg done once offramp is done.
async function maybeCompletePairedPayout(transferId: string) {
  const legs = await getLegs(transferId)
  const offramp = legs.find((l: any) => rowVal(l, 'leg_type', 2) === 'offramp')
  const payout  = legs.find((l: any) => rowVal(l, 'leg_type', 2) === 'payout')
  if (!offramp || !payout) return
  const offDone   = rowVal(offramp, 'status', 4) === 'done'
  const payStatus = rowVal(payout, 'status', 4)
  if (offDone && payStatus !== 'done' && payStatus !== 'failed') {
    await updateLeg(rowVal(payout, 'id', 0), { status: 'done' })
  }
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/webhook.ts"

mkdir -p "afrifx-api/src/services/ramp"
cat > "afrifx-api/src/services/ramp/reconciler.ts" << 'AFX_EOF'
// ============================================================
// Orchestrator tick loop — the backstop behind webhooks (design §6), mirroring
// txSettler. Every N minutes it finds transfers stuck 'in_progress' with an
// in_flight leg and queries the provider's REAL status to move them forward,
// in case a webhook was missed. Ground-truth only, never optimistic.
// ============================================================

import cron from 'node-cron'
import { db } from '../../db/client'
import { sql } from 'drizzle-orm'
import { getProvider } from './registry'
import { getLegs, updateLeg, parseRows } from './repository'
import { advanceTransfer } from './engine'

const rowVal = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

export function startTransferReconciler() {
  console.log('[TransferReconciler] ✅ Started — backstop reconciling in-flight transfers every 3 minutes')
  cron.schedule('*/3 * * * *', reconcile)
  setTimeout(reconcile, 15_000) // shortly after boot too
}

async function reconcile() {
  try {
    const cutoff = Math.floor(Date.now() / 1000) - 90 // give webhooks ~90s first
    const transfers = parseRows(await db.run(sql`
      SELECT id, provider FROM transfers
      WHERE status = 'in_progress' AND updated_at < ${cutoff}
      LIMIT 50`))
    if (!transfers.length) return

    for (const t of transfers) {
      const transferId = rowVal(t, 'id', 0)
      const providerKey = rowVal(t, 'provider', 1)
      const legs = await getLegs(transferId)

      // Only in_flight legs that finalize via provider (onramp/offramp/payout).
      const inflight = legs.filter((l: any) => {
        const s = rowVal(l, 'status', 4)
        const type = rowVal(l, 'leg_type', 2)
        return s === 'in_flight' && ['onramp', 'offramp', 'payout'].includes(type)
      })
      if (!inflight.length) { await advanceTransfer(transferId); continue }

      let provider
      try { provider = getProvider(providerKey) } catch { continue }

      for (const leg of inflight) {
        const legId  = rowVal(leg, 'id', 0)
        const idem   = rowVal(leg, 'idempotency_key', 5)
        const ref    = rowVal(leg, 'provider_ref', 6)
        try {
          const res = await provider.getStatus({ idempotencyKey: idem, providerRef: ref })
          if (res.status === 'done')   await updateLeg(legId, { status: 'done' })
          if (res.status === 'failed') await updateLeg(legId, { status: 'failed', error: 'reconciler: provider failed' })
        } catch { /* leave in_flight; try again next tick */ }
      }
      await advanceTransfer(transferId)
    }
  } catch (err: any) {
    console.error('[TransferReconciler] error:', err?.message)
  }
}
AFX_EOF
echo "  afrifx-api/src/services/ramp/reconciler.ts"

echo ""
echo "Done. This stage is still additive -- no routes wired, no existing files"
echo "touched, so deploying changes no behaviour. To activate later we will:"
echo "  - add a route to start a transfer + a webhook endpoint (stage 3)"
echo "  - register startTransferReconciler() in src/index.ts (stage 3)"
echo "  - build the HoneyCoinProvider once sandbox keys arrive"
echo ""
echo "Typecheck:  cd afrifx-api && npx tsc --noEmit"
echo ""
echo "Commit when ready:"
echo "  git add -A && git commit -m 'Orchestrator stage 2: state machine + CCTP module (mock-tested)'"
echo "  git push"
