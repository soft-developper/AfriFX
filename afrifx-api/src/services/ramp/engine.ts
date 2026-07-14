// ============================================================
// Orchestrator engine the durable state machine that advances a transfer
// one leg at a time. Core invariant (design §5): never start leg N+1 until
// leg N is 'done'. Confirmation is always ground-truth (provider status /
// on-chain), never optimistic the same lesson baked into txSettler.
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
    usdcAmount:   t.usdc_amount ?? t[7] ?? 0,
    destCurrency: t.dest_currency ?? t[5],
    chain:        (t.payout_chain ?? t[16] ?? 'base') as ChainKey,
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
