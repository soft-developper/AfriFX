'use client'
// ============================================================
// useChainUsdcBalance — read a wallet's USDC balance on ANY supported chain.
//
// The app's existing useUSDCBalance is pinned to Arc, which is right for Send's
// same-chain path but useless for the bridge, where the source chain changes.
// This reads balanceOf on whichever chain is selected.
//
// NOTE: a failed RPC read no longer silently shows 0. A dead/rate-limited RPC
// used to be indistinguishable from a genuinely empty wallet — that masked the
// real Amoy/Sepolia balances behind a fake "0" and set Max to 0. We now keep
// the last known balance and expose `error` so the UI can tell the difference.
// ============================================================

import { useState, useEffect, useCallback, useRef } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
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
  const [error, setError] = useState<string | null>(null)
  // Track which (address, chain) the current balance belongs to, so a switch
  // resets to 0 rather than showing a stale balance from the previous chain.
  const scopeRef = useRef<string>('')

  const load = useCallback(async () => {
    const scope = `${address ?? ''}:${chainKey}`
    if (!address) { scopeRef.current = scope; setBalance(0); setError(null); return }
    const chain   = chainByKey(chainKey)
    const chainId = evmChainId(chainKey)
    if (!chain?.usdc || !chainId) {
      scopeRef.current = scope; setBalance(0)
      setError('Chain not configured'); return
    }

    // New scope (address or chain changed): clear stale balance first.
    if (scopeRef.current !== scope) { setBalance(0); scopeRef.current = scope }

    setLoading(true)
    setError(null)
    try {
      const client = getPublicClient(config, { chainId })
      if (!client) { setError('No RPC client for this chain'); return }
      const raw = await client.readContract({
        address: chain.usdc as `0x${string}`,
        abi: ERC20_BALANCE_ABI,
        functionName: 'balanceOf',
        args: [address],
      })
      // USDC is 6 decimals on every supported chain, including Arc's ERC-20
      // interface (the NATIVE token is 18 — mixing them is a known trap).
      setBalance(Number(raw as bigint) / 1_000_000)
      setError(null)
    } catch (e) {
      // Do NOT fake a 0 here — that hid real balances behind dead RPCs. Surface
      // the failure and keep whatever balance we last had for this scope.
      const msg = e instanceof Error ? e.message : 'Balance read failed'
      setError(msg)
    } finally {
      setLoading(false)
    }
  }, [address, chainKey, config])

  useEffect(() => { load() }, [load])

  return { balance, loading, error, refresh: load }
}
