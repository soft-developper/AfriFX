'use client'
// TEMPORARY probe page - delete after the Memo-on-SCA question is settled.
// Visit /memo-probe while signed in (needs a live Circle signing session),
// click the button, read the result. It tells us whether to keep or drop
// Memo for the P2P migration.

import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { probeMemoOnSca, type ProbeResult } from '@/lib/memo-sca-probe'

export default function MemoProbePage() {
  const { isConnected } = useAccount()
  const [busy, setBusy]     = useState(false)
  const [step, setStep]     = useState<string | null>(null)
  const [result, setResult] = useState<ProbeResult | null>(null)

  async function run() {
    setBusy(true); setResult(null); setStep(null)
    try {
      const r = await probeMemoOnSca(setStep)
      setResult(r)
    } catch (err: any) {
      setResult({ ok: false, message: err?.message ?? String(err) })
    } finally {
      setBusy(false); setStep(null)
    }
  }

  return (
    <div className="mx-auto max-w-lg p-6">
      <h1 className="text-lg font-semibold">Memo-on-SCA probe</h1>
      <p className="mt-2 text-sm text-app-muted">
        Fires one Memo-wrapped USDC approve(vault, 0) through your Circle
        wallet. Zero allowance, so it moves no funds. Tells us if Memo works
        from a smart-contract wallet on Arc.
      </p>

      <Button className="mt-4" disabled={!isConnected || busy} onClick={run}>
        {busy ? 'Running…' : 'Run Memo probe'}
      </Button>
      {!isConnected && (
        <p className="mt-2 text-xs text-amber-500">Sign in first.</p>
      )}
      {step && <p className="mt-3 text-xs text-app-muted">{step}</p>}

      {result && (
        <div className={`mt-4 rounded-lg border p-3 text-sm ${
          result.ok ? 'border-green-700/50 bg-green-900/20 text-green-300'
                    : 'border-red-700/50 bg-red-900/20 text-red-300'}`}>
          <p className="font-medium">{result.ok ? 'CONFIRMED' : 'FAILED / PENDING'}</p>
          <p className="mt-1 leading-relaxed">{result.message}</p>
          {result.txHash && (
            <a
              href={`https://explorer.testnet.arc.network/tx/${result.txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-2 inline-block text-xs underline"
            >View on explorer</a>
          )}
        </div>
      )}
    </div>
  )
}
