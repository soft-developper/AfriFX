'use client'
// ============================================================
// useCompleteBridge — finish a mint that was left outstanding.
//
// WHY THIS EXISTS
// A CCTP bridge burns on the source chain, then mints on the destination. The
// mint is a SEPARATE transaction, so anything that interrupts the flow (closing
// the tab, a slow attestation) leaves the burn done and the mint owed.
//
// Our reconciler can SEE those but cannot fix them: the platform holds no key,
// by design. So the owner of the funds finishes it themselves. That is what
// this does.
//
// CCTP makes this safe and permanent:
//   * attestations DO NOT EXPIRE, so there is no deadline
//   * destinationCaller was bytes32(0) at burn time, so ANY address may mint
// A stranded transfer is always recoverable, needing only the original burn
// transaction hash, which we persisted.
//
// CIRCLE MIGRATION: the mint is a contractExecution challenge the user approves
// on their device (executeContractCall), signed by their Circle wallet on the
// destination chain. No wagmi, no network switch — Circle runs the call on the
// chain we name.
// ============================================================

import { useState, useCallback } from 'react'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import { irisBase, chainByKey, cctpContracts } from '@/lib/cctp-chains'
import { fetchAttestation } from '@/lib/cctp-client'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type CompleteStep = 'idle' | 'checking' | 'minting' | 'done' | 'error'

export function useCompleteBridge() {
  const [step,   setStep]   = useState<CompleteStep>('idle')
  const [error,  setError]  = useState<string | null>(null)
  const [mintTx, setMintTx] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [note,   setNote]   = useState<string | null>(null)

  const reset = useCallback(() => {
    setStep('idle'); setError(null); setMintTx(null); setBusyId(null); setNote(null)
  }, [])

  const complete = useCallback(async (bridge: {
    id: string
    from_chain: string
    to_chain: string
    burn_tx?: string | null
  }) => {
    if (!bridge.burn_tx) {
      setStep('error'); setError('No burn transaction recorded for this transfer.')
      return
    }

    setBusyId(bridge.id)
    setStep('checking'); setError(null); setNote(null)

    try {
      const from = chainByKey(bridge.from_chain)
      const to   = chainByKey(bridge.to_chain)
      if (!from || !to) throw new Error('Unsupported route')

      // 1. Fetch the attestation using the ORIGINAL burn tx. Attestations never
      //    expire, so this works however long ago the burn happened.
      const att = await fetchAttestation(irisBase(), from.domain, bridge.burn_tx)

      if (att.status === 'not_found') {
        throw new Error(
          'Circle has no record of this burn yet. If it was very recent, wait a ' +
          'few minutes and try again.')
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        throw new Error(
          `Circle has not finished attesting this transfer yet. ${from.name} ` +
          'transfers can take 13 to 19 minutes to finalise. Try again shortly.')
      }

      await fetch(`${API}/bridge/${bridge.id}/attested`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ attestation: att.attestation }),
      }).catch(() => {})

      // 2. Mint on the destination chain via a Circle challenge.
      setStep('minting')
      const result = await executeContractCall({
        chainKey:             to.key,
        contractAddress:      cctpContracts().messageTransmitter,
        abiFunctionSignature: 'receiveMessage(bytes,bytes)',
        abiParameters:        [att.message, att.attestation],
      }, setNote)

      const tx = result.txHash ?? 'pending'

      await fetch(`${API}/bridge/${bridge.id}/completed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mintTx: tx }),
      }).catch(() => {})

      setMintTx(tx)
      setStep('done'); setNote(null)
    } catch (err: any) {
      let message = err?.message ?? 'Could not complete the transfer'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/already been used|nonce already|already minted/i.test(message)) {
        // The mint already happened, so this is success, not failure.
        message = 'This transfer was already completed. Refreshing the list.'
        await fetch(`${API}/bridge/${bridge.id}/completed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mintTx: 'already-minted' }),
        }).catch(() => {})
      }
      setStep('error'); setError(message); setNote(null)
    } finally {
      setBusyId(null)
    }
  }, [])

  return { step, error, mintTx, busyId, note, complete, reset }
}
