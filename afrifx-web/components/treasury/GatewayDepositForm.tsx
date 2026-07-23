'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { Loader2, CheckCircle, AlertTriangle, Clock, ExternalLink } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useGatewayDeposit } from '@/hooks/useGatewayDeposit'
import { gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'

/*
  Deposit USDC into Gateway.

  The honest bit this UI has to get right: a deposit is NOT instantly spendable.
  It has to reach block finality first — about half a second on Arc, but 13-19
  MINUTES on Base or Ethereum. Hiding that would leave users thinking the
  feature is broken, so the wait is stated up front, per chain, before they
  commit.
*/
export function GatewayDepositForm({ onDone }: { onDone?: () => void }) {
  const { isConnected } = useAccount()
  const { step, approveTx, depositTx, error, finality, deposit, reset } = useGatewayDeposit()

  const chains = gatewayChains()
  const [chainKey, setChainKey] = useState('arc')
  const [amount, setAmount]     = useState('')

  const chain   = chains.find(c => c.key === chainKey)
  const cctp    = chainByKey(chainKey)
  const amt     = Number(amount)
  const busy    = ['switching', 'approving', 'depositing'].includes(step)
  const canGo   = isConnected && amt > 0 && !busy

  const stepLabel: Record<string, string> = {
    switching:  `Switch your wallet to ${chain?.name ?? 'the chain'}`,
    approving:  'Approve USDC in your wallet (step 1 of 2)',
    depositing: 'Confirm the deposit in your wallet (step 2 of 2)',
  }

  if (step === 'done') {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Deposit submitted
        </p>
        <p className="mt-1 text-xs text-emerald-200/80">
          {amount} USDC deposited from {chain?.name}.
        </p>
        {/* The wait is the thing people misunderstand, so say it plainly. */}
        <p className="mt-2 flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-200/80">
          <Clock className="mt-0.5 h-3 w-3 shrink-0" />
          It becomes spendable once the deposit reaches finality on {chain?.name} —
          about {finality}. Your balance above updates automatically.
        </p>
        {depositTx && cctp && (
          <a href={`${cctp.explorer}/tx/${depositTx}`} target="_blank" rel="noopener noreferrer"
            className="mt-2 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
            View transaction <ExternalLink className="h-2.5 w-2.5" />
          </a>
        )}
        <div className="mt-3">
          <Button size="sm" variant="outline" onClick={() => { reset(); onDone?.() }}>
            Done
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-app-border bg-app-bg p-4">
      <p className="mb-3 text-xs font-semibold text-app-text">Add funds to your unified balance</p>

      <label className="mb-1 block text-[11px] text-app-muted">Deposit from</label>
      <select
        value={chainKey}
        onChange={e => setChainKey(e.target.value)}
        disabled={busy}
        className="mb-1 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => (
          <option key={c.key} value={c.key}>
            {c.name} — clears in {c.finality}
          </option>
        ))}
      </select>
      {/* Surface the trade-off at the moment of choosing, not after. */}
      <p className="mb-3 text-[10px] text-app-muted">
        {chainKey === 'arc'
          ? 'Arc finalises in about half a second, so deposits are spendable almost immediately.'
          : `Deposits from ${chain?.name} take ${chain?.finality} to become spendable.`}
      </p>

      <label className="mb-1 block text-[11px] text-app-muted">Amount (USDC)</label>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-3 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      <Button className="w-full" disabled={!canGo}
        onClick={() => deposit({ chainKey, amount: amt })}>
        {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
              : !isConnected ? 'Connect a wallet'
              : 'Deposit'}
      </Button>

      {busy && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
          <Loader2 className="h-3 w-3 animate-spin" />
          {stepLabel[step] ?? 'Working…'}
        </p>
      )}

      {step === 'error' && error && (
        <div className="mt-2 rounded-lg border border-red-900/50 bg-red-900/20 p-2.5">
          <p className="flex items-center gap-1.5 text-[11px] font-medium text-red-400">
            <AlertTriangle className="h-3 w-3" /> Deposit not completed
          </p>
          <p className="mt-1 text-[11px] text-red-300/90">{error}</p>
          {approveTx && (
            <p className="mt-1 text-[10px] text-red-300/60">
              Your approval went through but the deposit didn&apos;t — no USDC left your
              wallet. You can safely retry.
            </p>
          )}
          <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
        </div>
      )}
    </div>
  )
}
