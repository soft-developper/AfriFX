'use client'
// ============================================================
// useCompleteBridge, finish a mint that was left outstanding.
//
// WHY THIS EXISTS
// A CCTP bridge burns on the source chain, then mints on the destination. The
// mint is a SEPARATE transaction, so anything that interrupts the flow (closing
// the tab, a slow attestation, an RPC failure) leaves the burn done and the
// mint owed.
//
// Our reconciler can SEE those, but it cannot fix them: the platform holds no
// key, by design. So the person who owns the funds needs a way to finish it
// themselves. That is what this does.
//
// The good news is that CCTP makes this safe and permanent:
//   * attestations DO NOT EXPIRE, so there is no deadline
//   * we set destinationCaller to bytes32(0) at burn time, meaning ANY address
//     may submit the mint
// So a stranded transfer is always recoverable, and recovering it needs nothing
// but the original burn transaction hash, which we persisted.
// ============================================================

import { useState, useCallback } from 'react'
import { useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { irisBase, chainByKey } from '@/lib/cctp-chains'
import { MESSAGE_TRANSMITTER_V2_ABI, fetchAttestation } from '@/lib/cctp-client'
import { cctpContracts } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type CompleteStep = 'idle' | 'checking' | 'switching' | 'minting' | 'done' | 'error'

export function useCompleteBridge() {
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const config = useConfig()

  const [step,   setStep]   = useState<CompleteStep>('idle')
  const [error,  setError]  = useState<string | null>(null)
  const [mintTx, setMintTx] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const reset = useCallback(() => {
    setStep('idle'); setError(null); setMintTx(null); setBusyId(null)
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
    setStep('checking'); setError(null)

    try {
      const from = chainByKey(bridge.from_chain)
      const to   = chainByKey(bridge.to_chain)
      const dstChainId = evmChainId(bridge.to_chain)
      if (!from || !to || !dstChainId) throw new Error('Unsupported route')

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

      // 2. Mint on the destination chain.
      setStep('switching')
      try {
        await switchChainAsync({ chainId: dstChainId })
      } catch {
        throw new Error(`Please switch your wallet to ${to.name}, then try again.`)
      }

      setStep('minting')
      const tx = await writeContractAsync({
        address: cctpContracts().messageTransmitter as `0x${string}`,
        abi: MESSAGE_TRANSMITTER_V2_ABI,
        functionName: 'receiveMessage',
        args: [att.message as `0x${string}`, att.attestation as `0x${string}`],
        chainId: dstChainId,
      })
      await getPublicClient(config, { chainId: dstChainId })
        ?.waitForTransactionReceipt({ hash: tx as `0x${string}` })

      await fetch(`${API}/bridge/${bridge.id}/completed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mintTx: tx }),
      }).catch(() => {})

      setMintTx(tx as string)
      setStep('done')
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Could not complete the transfer'
      if (/already been used|nonce already/i.test(message)) {
        // The mint already happened, so this is success, not failure.
        message = 'This transfer was already completed. Refreshing the list.'
        await fetch(`${API}/bridge/${bridge.id}/completed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mintTx: 'already-minted' }),
        }).catch(() => {})
      }
      setStep('error'); setError(message)
    } finally {
      setBusyId(null)
    }
  }, [writeContractAsync, switchChainAsync, config])

  return { step, error, mintTx, busyId, complete, reset }
}
