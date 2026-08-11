'use client'
// ============================================================
// useCorridorSwap - two-leg corridor (from -> USDC -> to), signed by the
// user's CIRCLE wallet.
//
// CIRCLE MIGRATION. Each leg is a USDC transfer to the vault via a
// contractExecution challenge (executeContractCall). Memo is DROPPED - it needs
// an EOA and the Circle wallet is a smart contract (verified on-chain), so we
// transfer directly; the corridor/step/ref metadata is still recorded to the
// API in recordTx below, so nothing is lost operationally.
//
// TWO-LEG DISCIPLINE (unchanged): leg 2 is only sent after leg 1 is confirmed
// on-chain. A reverted leg 1 stops the corridor; a reverted leg 2 is reported
// with leg 1 already settled.
// ============================================================

import { useState } from 'react'
import { usePublicClient } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { buildMemoId, buildReference } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import type { CorridorQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep =
  | 'idle'
  | 'step1-pending' | 'step1-waiting' | 'step1-done'
  | 'step2-pending' | 'step2-waiting'
  | 'complete' | 'error'

export function useCorridorSwap() {
  const { address }  = useAccount()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)
  const [note,       setNote]       = useState<string | null>(null)

  // A USDC transfer to the vault via a Circle contract-execution challenge.
  async function transferToVault(
    toAddress: `0x${string}`, usdcAmount: number,
  ): Promise<`0x${string}`> {
    const result = await executeContractCall({
      chainKey:             'arc',
      contractAddress:      CONTRACTS.USDC,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [toAddress, parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS).toString()],
    }, setNote)
    if (!result.txHash) throw new Error('The transfer did not confirm in time. Please check and retry.')
    return result.txHash as `0x${string}`
  }

  async function recordTx(body: any) {
    await fetch(`${API_BASE}/transactions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).catch(console.error)
  }

  async function patchTxStatus(hash: string, status: 'settled' | 'failed') {
    await fetch(`${API_BASE}/transactions/${hash}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status }),
    }).catch(console.error)
  }

  // Wait for the on-chain receipt and return whether it actually succeeded.
  // A tx hash existing only means it was broadcast - it can still revert.
  async function confirmedOnChain(hash: `0x${string}`): Promise<boolean> {
    if (!publicClient) return false
    try {
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      return receipt.status === 'success'
    } catch {
      return false
    }
  }

  async function execute(quote: CorridorQuote) {
    if (!address) throw new Error('Sign in first')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setError(null)
    setCorridorId(quote.corridorId)

    try {
      // ── STEP 1: from → USDC ───────────────────────────────
      setStep('step1-pending')
      const ref1    = buildReference()
      const memo1Id = buildMemoId(`corridor-${quote.corridorId}-step1`)
      const usdcIn1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      const hash1 = await transferToVault(vault as `0x${string}`, usdcIn1)

      setStep1Hash(hash1)
      setStep('step1-waiting')

      await recordTx({
        ...quote.step1, walletAddress: address,
        arcTxHash: hash1, memoId: memo1Id, reference: ref1,
        corridorId: quote.corridorId, corridorStep: 1,
      })

      // Only proceed if step 1 actually settled on-chain.
      const step1Ok = await confirmedOnChain(hash1)
      await patchTxStatus(hash1, step1Ok ? 'settled' : 'failed')
      if (!step1Ok) {
        setError('Step 1 reverted on-chain, the corridor was not completed. No further transaction was sent.')
        setStep('error')
        return
      }
      setStep('step1-done')

      // ── STEP 2: USDC → to ─────────────────────────────────
      setStep('step2-pending')
      const ref2    = buildReference()
      const memo2Id = buildMemoId(`corridor-${quote.corridorId}-step2`)
      const usdcIn2 = quote.step2.fromAmount

      const hash2 = await transferToVault(vault as `0x${string}`, usdcIn2)

      setStep2Hash(hash2)
      setStep('step2-waiting')

      await recordTx({
        ...quote.step2, walletAddress: address,
        arcTxHash: hash2, memoId: memo2Id, reference: ref2,
        corridorId: quote.corridorId, corridorStep: 2,
      })

      const step2Ok = await confirmedOnChain(hash2)
      await patchTxStatus(hash2, step2Ok ? 'settled' : 'failed')
      if (!step2Ok) {
        setError('Step 2 reverted on-chain. Step 1 settled, but the second leg did not complete.')
        setStep('error')
        return
      }
      setStep('complete'); setNote(null)
    } catch (err: any) {
      let msg = err?.shortMessage ?? err?.message ?? 'Failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) msg = err.message
      setError(msg)
      setStep('error'); setNote(null)
      throw err
    }
  }

  function reset() {
    setStep('idle'); setError(null)
    setStep1Hash(null); setStep2Hash(null); setCorridorId(null); setNote(null)
  }

  return {
    execute, reset, step, error, note,
    step1Hash, step2Hash, corridorId,
    isLoading:  ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}
