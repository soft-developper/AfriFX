// ============================================================
// CCTP bridge module moves USDC from Arc to a provider-supported chain
// (e.g. Base) using Circle's Cross-Chain Transfer Protocol: burn on source,
// get Circle's attestation, mint canonical USDC on destination. No wrapped
// tokens, 1:1 amount. See HONEYCOIN_INTEGRATION_NOTES.md §5.
//
// STATUS: structured skeleton. The on-chain calls are marked TODO and gated
// behind CCTP_LIVE with CCTP_LIVE unset (default), bridge() runs in MOCK mode
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

// ---- real implementations (TODO filled in with RPC/keys + final chain) ----

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

// ---- mock mode (default) lets the state machine run end-to-end now ----

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
