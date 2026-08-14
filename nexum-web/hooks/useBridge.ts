'use client'
// ============================================================
// useBridge — the CCTP flow, signed by the user's CIRCLE wallet.
//
// STAGE 3b (Circle migration). Real money moves here, so the discipline is
// unchanged from the wagmi version:
//   RECORD FIRST, THEN ACT, THEN RECORD THE RESULT.
//
// Every step is reported to the stage-2 state machine, so if the tab closes or
// a request dies, the server record still reflects reality and the transfer
// can be resumed or reconciled.
//
// THE ONE MOMENT THAT MATTERS: the instant the burn confirms, we POST the burn
// tx hash to /bridge/:id/burned BEFORE anything else. After that the funds are
// burned and the mint is owed; losing the hash there makes recovery far harder.
//
// WHAT CHANGED FROM WAGMI
// The wallet is a Circle user-controlled wallet, not a browser wallet, so:
//   * approve/burn/mint are contractExecution challenges the user approves on
//     their device (executeContractCall), not writeContract calls.
//   * there is NO switchChain: Circle runs each call on the chain we name
//     (via the wallet that lives there), so the two old network-switch steps
//     simply vanish. The wallet exists on every bridge chain because we add
//     them at sign-up (see addBridgeChains).
//   * we don't wait for a receipt: executeContractCall returns the on-chain
//     hash once Circle surfaces it.
// The attestation wait (Circle Iris) is byte-for-byte the same as before.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import {
  cctpContracts, irisBase, chainByKey, addressToBytes32, CCTP_ENV,
} from '@/lib/cctp-chains'
import {
  getBurnFee, fetchAttestation, toUnits, FINALITY,
} from '@/lib/cctp-client'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type BridgeStep =
  | 'idle' | 'creating' | 'approving' | 'burning'
  | 'attesting' | 'minting' | 'done' | 'error'

export interface BridgeState {
  step:     BridgeStep
  bridgeId: string | null
  burnTx:   string | null
  mintTx:   string | null
  error:    string | null
  /** Burned but not yet minted funds are in flight and the mint is owed. */
  inFlight: boolean
  /** Seconds spent waiting for Circle, so the UI isn't a black box. */
  waitedSec: number
  /** A human step message while the user approves on their device. */
  note:     string | null
}

const INITIAL: BridgeState = {
  step: 'idle', bridgeId: null, burnTx: null, mintTx: null,
  error: null, inFlight: false, waitedSec: 0, note: null,
}

// Iris allows 40 req/s and blocks for 5 minutes if breached, so poll gently.
const POLL_MS       = 5_000
/*
  Five minutes of ACTIVE waiting, not thirty. Ethereum Sepolia needs ~13-19 min
  to finalise before Circle will even attest, so a spinner that waits the whole
  time makes a working transfer look broken. We wait a sensible while, then hand
  off to the reconciler, which was always the design.
*/
const POLL_MAX_MIN  = 5

async function api(path: string, body?: unknown) {
  const res = await fetch(`${API}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const d = await res.json().catch(() => ({}))
    throw new Error(d.error ?? `API ${res.status}`)
  }
  return res.json()
}

export function useBridge() {
  const { address } = useAccount()
  const [state, setState] = useState<BridgeState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const bridge = useCallback(async (params: {
    fromKey: string
    toKey:   string
    amount:  number
    recipient?: string
  }) => {
    if (!address) { setState(s => ({ ...s, step: 'error', error: 'Sign in first' })); return }

    const from = chainByKey(params.fromKey)
    const to   = chainByKey(params.toKey)
    if (!from || !to) { setState(s => ({ ...s, step: 'error', error: 'Unsupported route' })); return }

    const recipient = params.recipient ?? address
    const amountUnits = toUnits(params.amount)
    let bridgeId: string | null = null
    let burnedYet = false

    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      // ── 1. Record BEFORE anything is signed ──────────────
      setState({ ...INITIAL, step: 'creating' })
      const created = await api('/bridge', {
        walletAddress: address,
        fromChain: from.key, toChain: to.key,
        fromDomain: from.domain, toDomain: to.domain,
        amount: params.amount, recipient,
      })
      bridgeId = created.id
      setState(s => ({ ...s, bridgeId }))

      const contracts = cctpContracts()
      const messenger = contracts.tokenMessenger as `0x${string}`

      /*
        CCTP burns an ERC-20, so burnToken MUST be a real token address. Fail
        HERE with a clear message rather than passing the zero address to
        depositForBurn, which reverts opaquely after the user has approved.
      */
      if (!from.usdc || /^0x0+$/.test(from.usdc)) {
        throw new Error(
          `No USDC token address configured for ${from.name}. ` +
          `Bridging from this chain can't proceed until it's set.`)
      }

      // ── 2. Approve the TokenMessenger to spend USDC ──────
      // (on the SOURCE chain, signed by the wallet that lives there)
      setState(s => ({ ...s, step: 'approving' }))
      await executeContractCall({
        chainKey:             from.key,
        contractAddress:      from.usdc,
        abiFunctionSignature: 'approve(address,uint256)',
        abiParameters:        [messenger, amountUnits.toString()],
      }, note)

      // ── 3. BURN on the source chain ──────────────────────
      setState(s => ({ ...s, step: 'burning' }))
      await api(`/bridge/${bridgeId}/burning`, {})

      const fee = await getBurnFee(irisBase(), from.domain, to.domain, amountUnits)

      /*
        depositForBurn(amount, destinationDomain, mintRecipient, burnToken,
                       destinationCaller, maxFee, minFinalityThreshold)
        Circle's abiParameters wants: uint256 as decimal strings, address as
        hex, bytes32 as hex. destinationCaller = bytes32(0) so ANY address may
        finish the mint (our reconciler, or the user from another device).
      */
      const burnResult = await executeContractCall({
        chainKey:             from.key,
        contractAddress:      messenger,
        abiFunctionSignature:
          'depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)',
        abiParameters: [
          amountUnits.toString(),
          to.domain,
          addressToBytes32(recipient),
          from.usdc,
          `0x${'0'.repeat(64)}`,
          fee.maxFeeUnits.toString(),
          FINALITY.FINALIZED,
        ],
      }, note)

      const burnTx = burnResult.txHash
      if (!burnTx) {
        // Approved but no hash surfaced in time. Not necessarily lost, but we
        // can't record a burn without its hash, so stop and let the user retry
        // or check. The bridge record is still 'burning', which the reconciler
        // will resolve.
        throw new Error(
          'The burn was approved but is taking longer than usual to confirm. ' +
          'Check "Recent bridges" shortly \u2014 if it went through you can ' +
          'finish it there; nothing is lost.')
      }

      /*
        *** THE CRITICAL WRITE ***
        Funds are now burned. Persist the tx hash immediately; everything
        downstream depends on it. We await this and let a failure surface.
      */
      burnedYet = true
      setState(s => ({ ...s, burnTx, inFlight: true }))
      await api(`/bridge/${bridgeId}/burned`, {
        burnTx,
        // Circle looks the message up by tx hash, so store the hash in both
        // fields rather than computing a message hash client-side.
        messageBytes: burnTx,
        messageHash:  burnTx,
      })

      // ── 4. Wait for Circle's attestation ─────────────────
      setState(s => ({ ...s, step: 'attesting', note: null }))
      const startedAt = Date.now()
      const deadline  = startedAt + POLL_MAX_MIN * 60_000

      let att: Awaited<ReturnType<typeof fetchAttestation>> = { status: 'pending' }
      while (Date.now() < deadline) {
        try {
          att = await fetchAttestation(irisBase(), from.domain, burnTx)
          if (att.status === 'complete') break
        } catch {
          // swallow and retry — the burn is safe either way
        }
        setState(s => ({ ...s, waitedSec: Math.floor((Date.now() - startedAt) / 1000) }))
        await new Promise(r => setTimeout(r, POLL_MS))
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        // NOT a loss: the burn is recorded and the reconciler will finish it.
        throw new Error(
          'Circle is still attesting this transfer. Your USDC is burned and ' +
          'safely recorded, so nothing is lost, but the final step needs your ' +
          'signature. You can close this page and finish it any time from ' +
          '"Recent bridges" below.')
      }
      await api(`/bridge/${bridgeId}/attested`, { attestation: att.attestation })

      // ── 5. MINT on the destination chain ─────────────────
      // (signed by the same wallet, on the destination chain)
      setState(s => ({ ...s, step: 'minting' }))
      const mintResult = await executeContractCall({
        chainKey:             to.key,
        contractAddress:      contracts.messageTransmitter,
        abiFunctionSignature: 'receiveMessage(bytes,bytes)',
        abiParameters:        [att.message, att.attestation],
      }, note)

      const mintTx = mintResult.txHash ?? 'pending'
      await api(`/bridge/${bridgeId}/completed`, { mintTx })
      setState(s => ({ ...s, step: 'done', mintTx, inFlight: false, note: null }))
    } catch (err: any) {
      let message = err?.message ?? 'Bridge failed'

      if (err instanceof NeedsReauthError) {
        message = err.message
      } else if (err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch|network request/i.test(message)) {
        message =
          'Could not reach the network. This is usually a busy public endpoint ' +
          'rather than a problem with your transfer; nothing was submitted. ' +
          'Please try again in a moment.'
      }

      // Tell the server. It classifies failed-vs-stranded by whether a burn
      // landed, so burned funds can never be recorded as a harmless failure.
      if (bridgeId) {
        await api(`/bridge/${bridgeId}/failed`, { error: message }).catch(() => {})
      }
      setState(s => ({
        ...s, step: 'error', error: message,
        inFlight: burnedYet, note: null,
      }))
    }
  }, [address])

  return { ...state, bridge, reset, env: CCTP_ENV }
}
