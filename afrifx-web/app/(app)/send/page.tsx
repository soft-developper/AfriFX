'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { Loader2, CheckCircle, Zap } from 'lucide-react'

export default function SendPage() {
  const { isConnected } = useAccount()
  const [to, setTo]         = useState('')
  const [amount, setAmount] = useState('')
  const { formatted: balance } = useUSDCBalance()

  const { writeContractAsync, isPending } = useWriteContract()
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  const valid = isAddress(to) && parseFloat(amount) > 0

  async function handleSend() {
    if (!valid) return
    const hash = await writeContractAsync({
      address: CONTRACTS.USDC,
      abi: USDC_ABI,
      functionName: 'transfer',
      args: [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    // Reset form after successful send
    setTo('')
    setAmount('')
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Send</h1>
        <p className="text-sm text-[#64748B]">Send USDC to any Arc address instantly.</p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-5">
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="text-[#64748B]">Available</span>
          <span className="font-mono text-[#E2E8F0]">{balance} USDC</span>
        </div>

        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">Recipient (Arc address)</label>
          <Input
            placeholder="0x…"
            value={to}
            onChange={(e) => setTo(e.target.value)}
            className="font-mono"
          />
        </div>

        <div className="mb-4 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">Amount (USDC)</label>
          <Input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="font-mono text-lg"
          />
        </div>

        <div className="mb-4 space-y-1.5 border-t border-[#1B2B4B] pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-[#64748B]">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-[#64748B]">Chain</span>
            <span className="text-[#E2E8F0]">Arc Testnet · ID 5042002</span>
          </div>
        </div>

        <Button className="w-full" size="lg" onClick={handleSend} disabled={!isConnected || !valid || isPending}>
          {isPending ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : 'Send USDC'}
        </Button>

        {isSuccess && txHash && (
          <a
            href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline"
          >
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}
      </div>
    </div>
  )
}
