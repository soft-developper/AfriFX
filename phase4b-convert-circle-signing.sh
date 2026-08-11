#!/usr/bin/env bash
# ============================================================
# phase4b-convert-circle-signing.sh
#
# /convert (the "Trade" nav item today) signs with the Circle wallet.
#
# Run AFTER fix-send-confirmation.sh.
#
# A conversion is a USDC transfer to the vault, so it reuses the same
# transfer path proven by Send - no new backend needed.
#
# ⚠ TRADEOFF: THE ON-CHAIN MEMO IS DROPPED
# Memo requires a CONTRACT CALL (contractExecution), not a transfer,
# and that endpoint is not built yet. The reference and memoId are
# still persisted with the transaction record, so reconciliation is
# unaffected - only the on-chain annotation is missing. If the Memo
# matters to you on-chain, this feature should wait for
# contractExecution instead.
#
# ALSO FIXED: waitForTransactionReceipt is now skipped when there is no
# hash yet. Circle reports a transfer as approved before it surfaces a
# hash, and asking viem for a receipt for an empty hash throws.
#
# NOTE ON NAMING: the nav label "Trade" currently points at /convert.
# Per your plan, Trade will eventually point at the fiat on-ramp /
# off-ramp, and Bridge is the Circle CCTP bridge. This script only
# touches /convert, which is the placeholder behind that label - so
# some of it is expected to be replaced when the real ramp lands.
#
# VERIFIED: web tsc clean, npm run build succeeds.
# NOT verified: the browser flow.
#
# AFTER RUNNING:
#   cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
echo "→ Writing files…"

mkdir -p "$(dirname "afrifx-web/hooks/useSwap.ts")"
cat > 'afrifx-web/hooks/useSwap.ts' <<'AFX_T00_EOF'
'use client'
import { useState } from 'react'
import { usePublicClient } from 'wagmi'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { sendUsdc } from '@/hooks/useCircleTx'
import { isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import {
  buildMemoId, buildReference,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { Currency, SwapQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export function useSwap() {
  const { address }   = useAccount()
  const publicClient  = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading,  setIsLoading]  = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [txHash,     setTxHash]     = useState<`0x${string}` | null>(null)
  const [txStatus,   setTxStatus]   = useState<'idle'|'pending'|'settled'|'failed'>('idle')
  const [reference,  setReference]  = useState<string | null>(null)
  // What the user is waiting for while they approve on their device.
  const [statusMessage, setTxStatusMessage] = useState<string | null>(null)


  function buildQuote(
    fromCurrency: Currency, toCurrency: Currency,
    fromAmount: number, rate: number,
  ): SwapQuote {
    const usdcAmount = fromCurrency === 'USDC' ? fromAmount : fromAmount / rate
    const spread     = usdcAmount * (SPREAD_BPS / 10_000)
    const networkFee = 0.001
    return {
      fromCurrency, toCurrency, fromAmount,
      toAmount:   usdcAmount - spread - networkFee,
      rate, spreadFee: spread, networkFee,
      deadline:   Math.floor(Date.now() / 1000) + 600,
    }
  }

  async function execute(quote: SwapQuote) {
    if (!address) throw new Error('Sign in to convert')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured')
    }

    setIsLoading(true); setError(null); setTxStatus('pending')

    try {
      const ref    = buildReference()
      const memoId = buildMemoId(`convert-${address}`)
      setReference(ref)

      const usdcIn = quote.fromCurrency === 'USDC'
        ? quote.fromAmount
        : quote.toAmount + quote.spreadFee + quote.networkFee

      /*
        Circle wallets sign through a challenge the user approves on
        their device, so there is no connected wallet to writeContract
        with. A conversion is a USDC transfer to the vault, which the
        transfer endpoint covers directly.

        TRADEOFF: the on-chain Memo is dropped. Memo needs a contract
        call (contractExecution) rather than a transfer, and the
        reference is already persisted with the transaction record
        below, so nothing is lost operationally - only the on-chain
        annotation.
      */
      const result = await sendUsdc(
        { to: vault, amount: usdcIn.toFixed(6) },
        setTxStatusMessage,
      )
      const hash = (result.txHash ?? '') as `0x${string}`

      setTxHash(hash)

      // Save to DB as pending
      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address, ...quote,
          arcTxHash: hash, memoId, reference: ref,
        }),
      }).catch(console.error)

      // Wait for on-chain confirmation, then mark settled or failed
      // based on the actual receipt status (a tx can broadcast then revert).
      //
      // `hash` can be empty: Circle reports the transfer as approved
      // before it surfaces a hash. That is not a failure, so leave the
      // conversion pending rather than asking viem for a receipt for
      // nothing, which would throw.
      if (publicClient && hash) {
        publicClient.waitForTransactionReceipt({ hash }).then(receipt => {
          const settled = receipt.status === 'success'
          fetch(`${API_BASE}/transactions/${hash}`, {
            method:  'PATCH',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ status: settled ? 'settled' : 'failed' }),
          }).catch(console.error)
          setTxStatus(settled ? 'settled' : 'failed')
          if (!settled) setError('Transaction reverted on-chain')
        }).catch(() => {
          // Receipt lookup failed (e.g. timeout) leave as pending; the
          // txSettler job will reconcile it against the chain shortly.
        })
      }

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg); setTxStatus('failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    buildQuote, execute,
    isLoading, error, txHash, txStatus, reference, statusMessage,
  }
}
AFX_T00_EOF
echo "  ✓ afrifx-web/hooks/useSwap.ts"

echo ""
echo "→ Done."
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo ""
