'use client'
import { useConnect } from 'wagmi'
import { Button } from '@/components/ui/button'
import { X } from 'lucide-react'

interface WalletModalProps {
  isOpen: boolean
  onClose: () => void
}

export function WalletModal({ isOpen, onClose }: WalletModalProps) {
  const { connect, connectors, isPending } = useConnect()

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-full max-w-sm rounded-2xl border border-app-border bg-app-surface p-6 shadow-2xl">
        <div className="mb-6 flex items-center justify-between">
          <h2 className="text-base font-semibold text-app-text">Connect wallet</h2>
          <button onClick={onClose} className="rounded-md p-1 hover:bg-app-border">
            <X className="h-4 w-4 text-app-muted" />
          </button>
        </div>

        <p className="mb-4 text-xs text-app-muted">
          Connect to Arc Testnet (Chain ID: 5042002). USDC is the gas token.
        </p>

        <div className="flex flex-col gap-2">
          {connectors.map((connector) => (
            <Button
              key={connector.id}
              variant="outline"
              className="w-full justify-start gap-3"
              onClick={() => { connect({ connector }); onClose() }}
              disabled={isPending}
            >
              {connector.name}
            </Button>
          ))}
        </div>
      </div>
    </div>
  )
}
