'use client'
import { useAccountAddress } from '@/hooks/useAccountAddress'

/*
  Whether the user's wallet is usable.

  Previously this modelled wagmi connection state, because the wallet was
  something the user connected and the provider could be briefly unready
  right after login. That no longer applies: the wallet is provisioned by
  Circle at sign-up, so "ready" simply means the account has an address.

  `isEmbedded` is always true now - every wallet is a Circle
  user-controlled wallet - and is kept so callers that show recovery
  nudges keep working without a change.
*/
export function useWalletReady() {
  const { address, isLoading } = useAccountAddress()

  const ready = Boolean(address) && !isLoading

  return {
    ready,
    isEmbedded: true,
    status: isLoading ? 'connecting' : ready ? 'connected' : 'disconnected',
  }
}
