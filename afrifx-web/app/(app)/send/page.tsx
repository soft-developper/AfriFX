'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useGatewaySend } from '@/hooks/useGatewaySend'
import { fetchGatewayBalances, gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { AlertCircle, CheckCircle, Loader2, Zap, Layers, ExternalLink } from 'lucide-react'

const HOME = 'arc'

function SendPageInner() {
  const { address, isConnected }  = useAccount()
  const { ready: walletReady }    = useWalletReady()
  const [to,      setTo]          = useState('')
  const [amount,  setAmount]      = useState('')
  const [destKey, setDestKey]     = useState(HOME)

  // Wallet balance on Arc (what Send has always used).
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const { writeContractAsync, isPending }  = useWriteContract()
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess }       = useWaitForTransactionReceipt({ hash: txHash })

  // Unified Gateway balance, for cross-chain sends.
  const gw = useGatewaySend()
  const [gwTotal,  setGwTotal]  = useState(0)
  const [gwByChain, setGwByChain] = useState<any[]>([])

  useEffect(() => {
    if (!address) return
    fetchGatewayBalances(address).then(res => {
      if ('error' in res) return
      setGwTotal(res.total)
      setGwByChain(res.perChain)
    })
  }, [address, gw.step])

  /*
    SMART ROUTING — the user picks a destination, not a mechanism.
      same chain (Arc -> Arc)  : plain wallet transfer. Instant, no Gateway
                                 balance consumed, and it's what Send always did.
      cross-chain              : spend the unified Gateway balance.
    This keeps existing behaviour intact while making other chains possible.
  */
  const isCrossChain = destKey !== HOME
  const dest    = gatewayChains().find(c => c.key === destKey)
  const destCctp = chainByKey(destKey)

  // Which balance applies to the current route?
  const availableNum = isCrossChain ? gwTotal : (parseFloat(balance) || 0)
  const availableStr = isCrossChain ? gwTotal.toFixed(2) : balance

  const amountNum        = parseFloat(amount) || 0
  const insufficientFunds = amountNum > 0 && amountNum > availableNum
  const validAddress     = isAddress(to)
  const validAmount      = amountNum > 0 && !insufficientFunds
  const valid            = validAddress && validAmount

  // For a cross-chain send we spend from whichever chain holds the balance.
  const sourceKey = gwByChain.find(c => c.amount >= amountNum)?.key ?? HOME

  const busy = isPending || ['signing','requesting','switching','minting'].includes(gw.step)

  function setMax() { setAmount(availableNum.toFixed(6)) }

  async function handleSend() {
    if (!valid) return

    if (isCrossChain) {
      await gw.send({ fromKey: sourceKey, toKey: destKey, amount: amountNum, recipient: to })
      return
    }

    const hash = await writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    setTo(''); setAmount('')
  }

  const gwLabel: Record<string, string> = {
    signing:    'Sign the transfer in your wallet',
    requesting: 'Getting approval from Circle…',
    switching:  `Switch your wallet to ${dest?.name ?? 'the destination'}`,
    minting:    'Confirm the final step in your wallet',
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any supported chain. Cross-chain sends use your unified balance.
        </p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Destination chain */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Send to chain
          </label>
          <select
            value={destKey}
            onChange={e => setDestKey(e.target.value)}
            disabled={busy}
            className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
          >
            {gatewayChains().map(c => (
              <option key={c.key} value={c.key}>{c.name}</option>
            ))}
          </select>
        </div>

        {/* Balance — which one depends on the route */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="flex items-center gap-1.5 text-app-muted">
            {isCrossChain ? <><Layers className="h-3 w-3" /> Unified balance</> : 'Wallet balance'}
          </span>
          <span className="font-mono text-app-text">{availableStr} USDC</span>
        </div>

        {isCrossChain && gwTotal === 0 && (
          <div className="mb-3 rounded-lg bg-amber-900/20 px-3 py-2 text-[11px] text-amber-300">
            Cross-chain sends spend your unified balance, which is empty. Add funds
            from the Treasury page first.
          </div>
        )}

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
              Insufficient balance, you only have {availableStr} USDC
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
            <span className="text-app-text">
              {isCrossChain ? `Unified balance → ${dest?.name}` : 'Arc Testnet · direct'}
            </span>
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

        {/* Cross-chain progress */}
        {busy && isCrossChain && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {gwLabel[gw.step] ?? 'Working…'}
          </p>
        )}

        {/* Cross-chain errors. The EOA case gets its own explanation because
            "your wallet type isn't supported" is not something a user can
            debug from a generic error. */}
        {gw.step === 'error' && gw.error && (
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertCircle className="h-3.5 w-3.5" /> Transfer not completed
            </p>
            <p className="mt-1 text-[11px] text-red-300/90">{gw.error}</p>
            {gw.needsEoa && (
              <p className="mt-1.5 text-[11px] text-red-300/70">
                Same-chain sends on Arc still work normally.
              </p>
            )}
            <Button size="sm" variant="outline" className="mt-2" onClick={gw.reset}>
              Try again
            </Button>
          </div>
        )}

        {/* Success — same-chain */}
        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}

        {/* Success — cross-chain */}
        {gw.step === 'done' && gw.mintTx && (
          <div className="mt-3 rounded-lg bg-emerald-900/20 px-3 py-2">
            <p className="flex items-center gap-2 text-xs text-emerald-400">
              <CheckCircle className="h-3.5 w-3.5" /> Sent to {dest?.name}
            </p>
            {destCctp && (
              <a href={`${destCctp.explorer}/tx/${gw.mintTx}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-1 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
                View transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
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
