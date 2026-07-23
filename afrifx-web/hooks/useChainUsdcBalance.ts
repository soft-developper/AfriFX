'use client'
// ============================================================
// useChainUsdcBalance read a wallet's USDC balance on ANY supported chain.
//
// The app's existing useUSDCBalance is pinned to Arc, which is right for Send's
// same-chain path but useless for the bridge, where the source chain changes.
// This reads balanceOf on whichever chain is selected.
// ============================================================

import { useState, useEffect, useCallback } from 'react'
import { useAccount, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export function useChainUsdcBalance(chainKey: string) {
  const { address } = useAccount()
  const config = useConfig()
  const [balance, setBalance] = useState<number>(0)
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    if (!address) { setBalance(0); return }
    const chain   = chainByKey(chainKey)
    const chainId = evmChainId(chainKey)
    if (!chain?.usdc || !chainId) { setBalance(0); return }

    setLoading(true)
    try {
      const client = getPublicClient(config, { chainId })
      if (!client) { setBalance(0); return }
      const raw = await client.readContract({
        address: chain.usdc as `0x${string}`,
        abi: ERC20_BALANCE_ABI,
        functionName: 'balanceOf',
        args: [address],
      })
      // USDC is 6 decimals on every supported chain, including Arc's ERC-20
      // interface (the NATIVE token is 18 mixing them is a known trap).
      setBalance(Number(raw as bigint) / 1_000_000)
    } catch {
      // A failed read shouldn't break the form; just show zero and let the user
      // type an amount manually.
      setBalance(0)
    } finally {
      setLoading(false)
    }
  }, [address, chainKey, config])

  useEffect(() => { load() }, [load])

  return { balance, loading, refresh: load }
}
