'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState } from 'react'
import { useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { sendUsdc, NeedsReauthError } from '@/hooks/useCircleTx'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { AlertCircle, CheckCircle, Loader2, Zap } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

/*
  Send is same-chain (Arc -> Arc) only.

  The cross-chain / unified-balance path was removed: it routed through Circle
  Gateway, which never completed a mint on this testnet (the destination
  GatewayMinter rejects the Arc-origin attestation signer), so shipping it as a
  live option would have been dishonest. Same-chain transfer is the proven path
  Send has always used, so that is all this page offers for now. The unified
  balance still exists read-only on the Treasury page; when Gateway cross-chain
  is genuinely working end to end, sending from it can come back here.
*/
function SendPageInner() {
  const { address, isConnected }  = useAccount()
  const publicClient              = usePublicClient()
  const { ready: walletReady }    = useWalletReady()
  const [to,      setTo]          = useState('')
  const [amount,  setAmount]      = useState('')

  // Wallet balance on Arc (what Send has always used).
  const { formatted: balance } = useUSDCBalance()
  const [sending, setSending] = useState(false)
  const [txStep,  setTxStep]  = useState<string | null>(null)
  const [txError, setTxError] = useState<string | null>(null)
  const [txNote,  setTxNote]  = useState<string | null>(null)
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess }       = useWaitForTransactionReceipt({ hash: txHash })

  const availableNum      = parseFloat(balance) || 0
  const amountNum         = parseFloat(amount) || 0
  const insufficientFunds = amountNum > 0 && amountNum > availableNum
  const validAddress      = isAddress(to)
  const validAmount       = amountNum > 0 && !insufficientFunds
  const valid             = validAddress && validAmount

  const busy = sending

  function setMax() { setAmount(availableNum.toFixed(6)) }

  async function handleSend() {
    if (!valid) return

    // A Circle wallet transfer. The user approves it on their device, so there
    // is no connected wallet to sign with.
    setSending(true); setTxError(null); setTxNote(null)
    try {
      const result = await sendUsdc({ to, amount }, setTxStep)
      if (result.txHash) {
        setTxHash(result.txHash as `0x${string}`)
        // Record this send so it appears in History (GET /transactions?wallet=).
        // Same-asset USDC→USDC movement on Arc.
        if (address) {
          const hash = result.txHash as `0x${string}`
          fetch(`${API}/transactions`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              walletAddress: address,
              fromCurrency: 'USDC', toCurrency: 'USDC',
              fromAmount: Number(amount), toAmount: Number(amount),
              arcTxHash: hash,
            }),
          }).catch(() => {})
          // Confirm on-chain, then mark settled/failed.
          if (publicClient) {
            publicClient.waitForTransactionReceipt({ hash }).then(r => {
              const ok = r.status === 'success'
              fetch(`${API}/transactions/${hash}`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ status: ok ? 'settled' : 'failed' }),
              }).catch(() => {})
            }).catch(() => {})
          }
        }
      } else {
        // Approved and broadcast, but Circle hasn't surfaced the hash yet.
        // Say so plainly rather than ending in silence, which reads as a
        // failure even though the money has almost certainly moved.
        setTxNote('Sent. It is confirming on-chain and will appear in your activity shortly.')
      }
      setTo(''); setAmount('')
    } catch (err: any) {
      setTxError(err instanceof NeedsReauthError
        ? err.message
        : (err?.message ?? 'Could not send the transfer'))
    } finally {
      setSending(false); setTxStep(null)
    }
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any address on Arc. Instant, with near-zero fees.
        </p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Balance */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="text-app-muted">Wallet balance</span>
          <span className="font-mono text-app-text">{balance} USDC</span>
        </div>

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient address
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
            <button onClick={setMax} className="text-xs text-app-accent-text hover:underline">
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

          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {balance} USDC
            </div>
          )}

          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(availableNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Route info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Route</span>
            <span className="text-app-text">Arc Testnet · direct</span>
          </div>
        </div>

        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !walletReady || !valid || busy || insufficientFunds}>
          {busy
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : !walletReady && isConnected
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Preparing wallet…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {/* Progress: approving happens on the user's device, so tell them
            what they're waiting for at each step. */}
        {txStep && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {txStep}…
          </p>
        )}

        {txNote && (
          <div className="mt-2 flex items-start gap-1.5 rounded-lg bg-emerald-900/20 px-3 py-2 text-[11px] text-emerald-500">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{txNote}</span>
          </div>
        )}

        {txError && (
          <div className="mt-2 flex items-start gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-[11px] text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{txError}</span>
          </div>
        )}

        {/* Success */}
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

