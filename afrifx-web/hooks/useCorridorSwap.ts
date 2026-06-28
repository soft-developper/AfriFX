'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  MEMO_ADDRESS,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { CorridorQuote, Currency } from '@/types'

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

  const { writeContractAsync } = useWriteContract()

  // Check if Memo contract is deployed (once per session)
  async function isMemoAvailable(): Promise<boolean> {
    if (!publicClient) return false
    try {
      const code = await publicClient.getCode({ address: MEMO_ADDRESS })
      return !!code && code !== '0x'
    } catch { return false }
  }

  async function sendWithMemo(
    toAddress:  `0x${string}`,
    usdcAmount: number,
    memoId:     `0x${string}`,
    payload:    Parameters<typeof buildMemoTransferArgs>[5],
    useMemo:    boolean,
  ): Promise<`0x${string}`> {
    if (useMemo) {
      const args = buildMemoTransferArgs(
        CONTRACTS.USDC, toAddress, usdcAmount, USDC_DECIMALS, memoId, payload,
      )
      return writeContractAsync(args)
    }
    // Fallback: direct USDC transfer
    return writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [toAddress, parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)],
    })
  }

  async function execute(quote: CorridorQuote) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setError(null)
    setCorridorId(quote.corridorId)

    const useMemo = await isMemoAvailable()
    if (useMemo) console.log('[Memo] Corridor: using Memo contract for both steps')
    else console.warn('[Memo] Corridor: Memo not available, using direct transfers')

    try {
      // ── STEP 1: from → USDC ───────────────────────────────
      setStep('step1-pending')
      const ref1    = buildReference()
      const memo1Id = buildMemoId(`corridor-${quote.corridorId}-step1`)
      const usdcIn1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      const hash1 = await sendWithMemo(vault, usdcIn1, memo1Id, {
        app:  'afrifx',
        type: 'corridor-step1',
        ref:  ref1,
        pair: `${quote.from}/USDC`,
        rate: quote.step1.rate,
        corridorId: quote.corridorId,
        step: 1,
      }, useMemo)

      setStep1Hash(hash1)
      setStep('step1-waiting')
      console.log(`[Memo] Corridor Step 1 tx: ${hash1.slice(0,14)}…`)

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step1, walletAddress: address,
          arcTxHash: hash1, memoId: memo1Id, reference: ref1,
          corridorId: quote.corridorId, corridorStep: 1,
        }),
      }).catch(console.error)

      await sleep(1500)
      setStep('step1-done')

      // ── STEP 2: USDC → to ─────────────────────────────────
      setStep('step2-pending')
      const ref2    = buildReference()
      const memo2Id = buildMemoId(`corridor-${quote.corridorId}-step2`)
      const usdcIn2 = quote.step2.fromAmount

      const hash2 = await sendWithMemo(vault, usdcIn2, memo2Id, {
        app:  'afrifx',
        type: 'corridor-step2',
        ref:  ref2,
        pair: `USDC/${quote.to}`,
        rate: quote.step2.rate,
        corridorId: quote.corridorId,
        step: 2,
      }, useMemo)

      setStep2Hash(hash2)
      setStep('step2-waiting')
      console.log(`[Memo] Corridor Step 2 tx: ${hash2.slice(0,14)}…`)

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step2, walletAddress: address,
          arcTxHash: hash2, memoId: memo2Id, reference: ref2,
          corridorId: quote.corridorId, corridorStep: 2,
        }),
      }).catch(console.error)

      await sleep(1500)
      setStep('complete')
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      setStep('error')
      throw err
    }
  }

  function reset() {
    setStep('idle'); setError(null)
    setStep1Hash(null); setStep2Hash(null); setCorridorId(null)
  }

  return {
    execute, reset, step, error,
    step1Hash, step2Hash, corridorId,
    isLoading:  ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)) }
