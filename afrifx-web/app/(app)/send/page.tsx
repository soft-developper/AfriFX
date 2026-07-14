'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { Loader2, CheckCircle, Zap, AlertCircle } from 'lucide-react'

function SendPageInner() {
  const { isConnected }        = useAccount()
  const { ready: walletReady } = useWalletReady()
  const [to,     setTo]        = useState('')
  const [amount, setAmount]    = useState('')
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const { writeContractAsync, isPending } = useWriteContract()
  const [txHash, setTxHash]    = useState<`0x${string}` | undefined>()
  const { isSuccess }          = useWaitForTransactionReceipt({ hash: txHash })

  const amountNum     = parseFloat(amount) || 0
  const balanceNum    = parseFloat(balance) || 0
  const insufficientFunds = amountNum > 0 && amountNum > balanceNum
  const validAddress  = isAddress(to)
  const validAmount   = amountNum > 0 && !insufficientFunds
  const valid         = validAddress && validAmount

  // Max button fill in full balance
  function setMax() {
    setAmount(balanceNum.toFixed(6))
  }

  async function handleSend() {
    if (!valid) return
    const hash = await writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    setTo('')
    setAmount('')
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">Send USDC to any Arc address instantly.</p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Balance */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="text-app-muted">Available balance</span>
          <span className="font-mono text-app-text">{balance} USDC</span>
        </div>

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient (Arc address)
          </label>
          <Input
            placeholder="0x…"
            value={to}
            onChange={e => setTo(e.target.value)}
            className={`font-mono ${to && !validAddress ? 'border-red-500/50' : ''}`}
          />
          {to && !validAddress && (
            <p className="text-xs text-red-400">Invalid wallet address</p>
          )}
        </div>

        {/* Amount */}
        <div className="mb-4 space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Amount (USDC)
            </label>
            <button onClick={setMax}
              className="text-xs text-app-accent-text hover:underline">
              Max
            </button>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className={`font-mono text-lg ${insufficientFunds ? 'border-red-500/50' : ''}`}
          />

          {/* Insufficient funds warning */}
          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {balance} USDC
            </div>
          )}

          {/* Valid amount preview */}
          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(balanceNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Fee info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Chain</span>
            <span className="text-app-text">Arc Testnet · ID 5042002</span>
          </div>
        </div>

        {/* Send button disabled when insufficient */}
        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !walletReady || !valid || isPending || insufficientFunds}>
          {isPending
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : !walletReady && isConnected
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Preparing wallet…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}
      </div>
    </div>
  )
}

export default function SendPage() {
  return (
    <SectionGuard section="send">
      <SendPageInner />
    </SectionGuard>
  )
}
