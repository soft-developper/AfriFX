'use client'
import { useAccount } from 'wagmi'

/*
  Signing readiness for both injected wallets and the Web3Auth embedded wallet.

  For MetaMask/WalletConnect, isConnected is sufficient. For the embedded
  (social-login) wallet there can be a brief moment right after login where the
  account is present but the provider isn't ready to sign yet; wagmi models this
  through the connection status, so we treat 'connected' as ready and anything
  else as not-ready. Signing paths should check `ready` before calling
  writeContract to avoid an occasional "provider not ready" failure.
*/
export function useWalletReady() {
  const { isConnected, status, connector } = useAccount()

  const ready = isConnected && status === 'connected'
  // Identify the embedded wallet so the UI can, e.g., show a recovery nudge.
  const isEmbedded = connector?.id === 'web3auth' || connector?.name?.toLowerCase().includes('web3auth')

  return { ready, isEmbedded, status }
}
