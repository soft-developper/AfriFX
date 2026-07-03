'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  MEMO_ADDRESS,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { Currency, SwapQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export function useSwap() {
  const { address }   = useAccount()
  const publicClient  = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading,  setIsLoading]  = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [txHash,     setTxHash]     = useState<`0x${string}` | null>(null)
  const [txStatus,   setTxStatus]   = useState<'idle'|'pending'|'settled'|'failed'>('idle')
  const [reference,  setReference]  = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  function buildQuote(
    fromCurrency: Currency, toCurrency: Currency,
    fromAmount: number, rate: number,
  ): SwapQuote {
    const usdcAmount = fromCurrency === 'USDC' ? fromAmount : fromAmount / rate
    const spread     = usdcAmount * (SPREAD_BPS / 10_000)
    const networkFee = 0.001
    return {
      fromCurrency, toCurrency, fromAmount,
      toAmount:   usdcAmount - spread - networkFee,
      rate, spreadFee: spread, networkFee,
      deadline:   Math.floor(Date.now() / 1000) + 600,
    }
  }

  async function execute(quote: SwapQuote) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured')
    }

    setIsLoading(true); setError(null); setTxStatus('pending')

    try {
      const ref    = buildReference()
      const memoId = buildMemoId(`convert-${address}`)
      setReference(ref)

      const usdcIn = quote.fromCurrency === 'USDC'
        ? quote.fromAmount
        : quote.toAmount + quote.spreadFee + quote.networkFee

      // Check Memo availability
      const memoCode = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!memoCode && memoCode !== '0x'

      let hash: `0x${string}`

      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, vault, usdcIn, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'convert', ref,
            pair: `${quote.fromCurrency}/${quote.toCurrency}`, rate: quote.rate },
        )
        hash = await writeContractAsync(args)
      } else {
        const { parseUnits } = await import('viem')
        hash = await writeContractAsync({
          address: CONTRACTS.USDC, abi: USDC_ABI,
          functionName: 'transfer',
          args: [vault, parseUnits(usdcIn.toFixed(6), USDC_DECIMALS)],
        })
      }

      setTxHash(hash)

      // Save to DB as pending
      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address, ...quote,
          arcTxHash: hash, memoId, reference: ref,
        }),
      }).catch(console.error)

      // Wait for on-chain confirmation, then mark settled or failed
      // based on the actual receipt status (a tx can broadcast then revert).
      if (publicClient) {
        publicClient.waitForTransactionReceipt({ hash }).then(receipt => {
          const settled = receipt.status === 'success'
          fetch(`${API_BASE}/transactions/${hash}`, {
            method:  'PATCH',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ status: settled ? 'settled' : 'failed' }),
          }).catch(console.error)
          setTxStatus(settled ? 'settled' : 'failed')
          if (!settled) setError('Transaction reverted on-chain')
        }).catch(() => {
          // Receipt lookup failed (e.g. timeout) — leave as pending; the
          // txSettler job will reconcile it against the chain shortly.
        })
      }

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg); setTxStatus('failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    buildQuote, execute,
    isLoading, error, txHash, txStatus, reference,
  }
}
