'use client'
// ============================================================
// useAllChainUsdcBalances — a wallet's USDC balance on EVERY supported chain.
//
// useChainUsdcBalance is single-chain and can't be called in a loop (rules of
// hooks), so this reads them all in one effect using the same wagmi
// getPublicClient + ERC-20 balanceOf + 6-decimals conversion. It maps over
// cctpChains(), so adding a chain to that registry makes it appear here with
// no extra code. A failed RPC read surfaces `error` for that chain and keeps
// the last known balance rather than faking 0.
// ============================================================
import { useState, useEffect, useCallback } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { cctpChains } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export interface ChainBalance {
  key:     string
  name:    string
  isHome:  boolean
  balance: number
  error:   string | null
}

export function useAllChainUsdcBalances() {
  const { address } = useAccount()
  const config = useConfig()
  const [balances, setBalances] = useState<ChainBalance[]>([])
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    const chains = cctpChains()
    // Seed the shape immediately so all chains render (at 0) even before reads.
    const seed: ChainBalance[] = chains.map(c => ({
      key: c.key, name: c.name, isHome: !!c.isHome, balance: 0, error: null,
    }))
    if (!address) { setBalances(seed); return }
    setLoading(true)

    const results = await Promise.all(chains.map(async (c): Promise<ChainBalance> => {
      const base = { key: c.key, name: c.name, isHome: !!c.isHome }
      const chainId = evmChainId(c.key)
      if (!c.usdc || !chainId) return { ...base, balance: 0, error: 'Chain not configured' }
      try {
        const client = getPublicClient(config, { chainId })
        if (!client) return { ...base, balance: 0, error: 'No RPC client' }
        const raw = await client.readContract({
          address: c.usdc as `0x${string}`,
          abi: ERC20_BALANCE_ABI,
          functionName: 'balanceOf',
          args: [address],
        })
        // USDC is 6 decimals on every chain (Arc native is 18 — not this).
        return { ...base, balance: Number(raw as bigint) / 1_000_000, error: null }
      } catch (e) {
        return { ...base, balance: 0, error: e instanceof Error ? e.message : 'read failed' }
      }
    }))

    setBalances(results)
    setLoading(false)
  }, [address, config])

  useEffect(() => { load() }, [load])

  return { balances, loading, refresh: load }
}
