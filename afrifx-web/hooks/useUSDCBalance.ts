'use client'
import { useReadContract } from 'wagmi'
import { useAccount } from 'wagmi'
import { CONTRACTS } from '@/lib/contracts'
import { USDC_ABI, formatUSDC } from '@/lib/usdc'

export function useUSDCBalance() {
  const { address, isConnected } = useAccount()

  const { data: rawBalance, isLoading, refetch } = useReadContract({
    address: CONTRACTS.USDC,
    abi: USDC_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: isConnected && !!address, refetchInterval: 10_000 },
  })

  const formatted = rawBalance !== undefined ? formatUSDC(rawBalance) : '0.00'

  return { rawBalance, formatted, isLoading, refetch }
}
