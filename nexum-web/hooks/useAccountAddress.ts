'use client'

/**
 * The signed-in user's wallet address.
 *
 * Replaces `useAccount()` from wagmi as the source of the address. The
 * wallet is now provisioned by Circle at sign-up rather than connected
 * by the user, so the address comes from their account.
 *
 * Deliberately shaped like wagmi's useAccount so feature code can be
 * migrated by changing the import rather than restructuring:
 *
 *   - import { useAccount } from 'wagmi'
 *   + import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
 *
 * SCOPE: reading the address only. Signing still goes through Circle
 * challenges, so anything using useWriteContract, useSignTypedData or
 * useSwitchChain needs a real migration, not this shim (Phase 4).
 *
 * Named useAccountAddress rather than useWallet because useWallet
 * already exists and returns balances.
 */

import { useAuth } from '@/hooks/useAuth'

export interface AccountAddressState {
  /** Lowercase 0x address, or undefined before the wallet is provisioned. */
  address:     `0x${string}` | undefined
  /** True once the account has a wallet. Mirrors wagmi's isConnected. */
  isConnected: boolean
  /** True while the session is still being confirmed on load. */
  isLoading:   boolean
}

export function useAccountAddress(): AccountAddressState {
  const { account, loading } = useAuth()
  const address = account?.walletAddress ?? undefined

  return {
    address:     address as `0x${string}` | undefined,
    isConnected: Boolean(address),
    isLoading:   loading,
  }
}
