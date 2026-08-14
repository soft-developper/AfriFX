'use client'
import { useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { arcTestnet } from '@/lib/arc-chain'

/**
 * Poll for a transaction receipt on Arc.
 * Arc has sub-second finality so this resolves almost immediately.
 */
export function useArcTransaction(hash?: `0x${string}`) {
  const { data, isLoading, isSuccess, isError } = useWaitForTransactionReceipt({
    hash,
    chainId: arcTestnet.id,
  })

  return {
    receipt: data,
    isLoading,
    isSuccess,
    isError,
    explorerUrl: hash
      ? `https://testnet.arcscan.app/tx/${hash}`
      : null,
  }
}
