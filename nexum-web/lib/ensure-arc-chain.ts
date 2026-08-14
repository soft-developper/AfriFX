'use client'
// Ensure an external (wagmi/injected) wallet is on Arc before an on-chain action.
// Circle wallets don't need this — the backend runs each call on the named chain —
// so this is only for the MetaMask/injected path.
import type { Config } from 'wagmi'
import { switchChain } from 'wagmi/actions'
import { arcTestnet } from '@/lib/arc-chain'

// wagmi's switchChain asks the wallet to switch; when the chain is unknown to
// the wallet, wagmi issues wallet_addEthereumChain using the chain definition
// registered in wagmiConfig (arcTestnet). So a single call both ADDS and
// SWITCHES — the payer no longer has to add Arc manually.
export async function ensureArcChain(config: Config, currentChainId?: number): Promise<void> {
  if (currentChainId === arcTestnet.id) return
  await switchChain(config, { chainId: arcTestnet.id })
}
