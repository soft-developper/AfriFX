'use client'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useEffect } from 'react'
import { ArrowLeftRight, Zap, Shield, Globe } from 'lucide-react'
import { ConnectButton } from '@/components/wallet/ConnectButton'

const features = [
  { icon: Zap,           title: 'Sub-second settlement', desc: 'Arc finalises transactions in under 1 second.' },
  { icon: Shield,        title: 'USDC-native',           desc: 'Gas fees paid in USDC — no volatile ETH needed.' },
  { icon: Globe,         title: 'Pan-African corridors', desc: 'NGN, GHS, KES, ZAR and more coming soon.' },
]

export default function ConnectPage() {
  const { isConnected } = useAccount()
  const router = useRouter()

  useEffect(() => {
    if (isConnected) router.push('/convert')
  }, [isConnected, router])

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4">
      <div className="mb-8 flex items-center gap-3">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-[#378ADD]/20">
          <ArrowLeftRight className="h-6 w-6 text-[#378ADD]" />
        </div>
        <div>
          <h1 className="text-2xl font-semibold text-[#E2E8F0]">AfriFX</h1>
          <p className="text-xs text-[#64748B]">Stablecoin FX on Arc</p>
        </div>
      </div>

      <div className="mb-8 w-full max-w-sm rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
        <h2 className="mb-1 text-base font-semibold text-[#E2E8F0]">Connect your wallet</h2>
        <p className="mb-5 text-xs text-[#64748B]">
          Connect to Arc Testnet (Chain ID 5042002) to start converting currencies instantly.
        </p>
        <ConnectButton />
      </div>

      <div className="grid w-full max-w-sm gap-3">
        {features.map(({ icon: Icon, title, desc }) => (
          <div key={title} className="flex gap-3 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-[#378ADD]/10">
              <Icon className="h-3.5 w-3.5 text-[#378ADD]" />
            </div>
            <div>
              <p className="text-sm font-medium text-[#E2E8F0]">{title}</p>
              <p className="text-xs text-[#64748B]">{desc}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
