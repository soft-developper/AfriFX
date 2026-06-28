'use client'
// Thin wrapper — kept for backwards compatibility
// TopNav now uses RainbowKit ConnectButton.Custom directly
import { useConnectModal } from '@rainbow-me/rainbowkit'

export function ConnectButton({ label = 'Connect wallet' }: { label?: string }) {
  const { openConnectModal } = useConnectModal()
  return (
    <button
      onClick={openConnectModal}
      className="rounded-xl bg-[#378ADD] px-4 py-2 text-sm font-medium text-white transition-opacity hover:opacity-90">
      {label}
    </button>
  )
}
