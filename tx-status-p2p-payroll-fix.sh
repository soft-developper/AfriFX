#!/bin/bash
# ============================================================
# AfriFX -- On-chain status fix, part 2: P2P (marketplace) & Payroll
#
# Follow-up to the corridor/convert fix. An audit of every tx-submitting
# flow found two more with the same bug (marking success without checking
# the on-chain receipt) and confirmed the rest are already correct:
#
#   Already correct (no change): Send (wagmi isSuccess waits for receipt),
#     Pay invoice (explicitly checks receipt.status), Convert & Corridor
#     (fixed in the previous patch).
#
#   Fixed here:
#   * useP2P.ts -- acceptOffer / takerConfirm / makerConfirm / cancelOwnOffer
#     each PATCHed the offer status immediately after broadcasting, with no
#     receipt check. They now wait for the receipt and only record the action
#     when it actually succeeded on-chain (createOffer also now rejects a
#     reverted receipt explicitly).
#   * PayrollExecuteContent.tsx -- marked each recipient 'sent' as soon as the
#     tx was broadcast. It now waits for the receipt and marks 'sent' only on
#     success, 'failed' on revert. The "All payments sent" banner already
#     keys off the real sent count, so it now reflects the truth.
#
# Run from ~/AfriFX:  bash tx-status-p2p-payroll-fix.sh
# ============================================================
set -e
echo ""
echo "Applying on-chain status fix to P2P & Payroll..."
echo ""

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useP2P.ts" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import {
  parseUnits, isAddress, decodeEventLog, encodeFunctionData,
} from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  buildMemoCallArgs, encodeMemoData,
  MEMO_ADDRESS, MEMO_ABI,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'

const API  = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO = '0x0000000000000000000000000000000000000000'

export type OrderType = 'market' | 'limit'

export interface CreateOfferParams {
  usdcAmount:        number
  localCurrency:     string
  localAmount:       number
  orderType:         OrderType
  limitRate?:        number
  makerTimerSeconds: number
}

export function useP2P() {
  const { address }  = useAccount()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [offerId,   setOfferId]   = useState<`0x${string}` | null>(null)

  const { writeContractAsync } = useWriteContract()

  function clearError() { setError(null) }

  // Check Memo availability once
  async function isMemoAvailable(): Promise<boolean> {
    if (!publicClient) return false
    try {
      const code = await publicClient.getCode({ address: MEMO_ADDRESS })
      return !!code && code !== '0x'
    } catch { return false }
  }

  // Extract OfferCreated bytes32 from receipt
  async function getOfferIdFromReceipt(hash: `0x${string}`): Promise<`0x${string}`> {
    if (!publicClient) throw new Error('No public client')
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') {
      throw new Error('Offer creation reverted on-chain — no offer was created.')
    }
    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({
          abi: VAULT_P2P_ABI, eventName: 'OfferCreated',
          data: log.data, topics: log.topics,
        })
        if (decoded.args.offerId) return decoded.args.offerId as `0x${string}`
      } catch {}
    }
    throw new Error('OfferCreated event not found in receipt')
  }

  // Wait for the on-chain receipt and return whether it actually succeeded.
  // A tx hash existing only means it was broadcast — it can still revert,
  // in which case we must NOT record the action as done.
  async function confirmedOnChain(hash: `0x${string}`): Promise<boolean> {
    if (!publicClient) return false
    try {
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      return receipt.status === 'success'
    } catch {
      return false
    }
  }

  // ── Create offer ──────────────────────────────────────────
  // Note: approve() cannot be memo-wrapped (no state change to forward)
  // createP2POffer() IS memo-wrapped — vault sees user as msg.sender via CallFrom
  async function createOffer(params: CreateOfferParams) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) throw new Error('Vault not configured')

    setIsLoading(true); setError(null)
    try {
      const usdcRaw  = parseUnits(params.usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw = BigInt(Math.round(params.localAmount))
      const orderN   = params.orderType === 'limit' ? 1 : 0
      const memoId   = buildMemoId(`p2p-create-${address}`)
      const ref      = buildReference()
      const useMemo  = await isMemoAvailable()

      // 1. Approve vault (must be direct — not memo-wrapped)
      await writeContractAsync({
        address: CONTRACTS.USDC, abi: USDC_ABI,
        functionName: 'approve', args: [vault, usdcRaw],
      })

      let hash: `0x${string}`

      if (useMemo) {
        // 2. createP2POffer via Memo — vault sees user as msg.sender
        const createData = encodeFunctionData({
          abi:          VAULT_P2P_ABI,
          functionName: 'createP2POffer',
          args:         [usdcRaw, params.localCurrency, localRaw, orderN, BigInt(params.makerTimerSeconds)],
        })
        const args = buildMemoCallArgs(vault, createData, memoId, {
          app:  'afrifx',
          type: 'p2p-create',
          ref,
          pair: `${params.localCurrency}/USDC`,
        })
        hash = await writeContractAsync(args)
      } else {
        hash = await writeContractAsync({
          address: vault, abi: VAULT_P2P_ABI,
          functionName: 'createP2POffer',
          args: [usdcRaw, params.localCurrency, localRaw, orderN, BigInt(params.makerTimerSeconds)],
        })
      }

      setTxHash(hash)
      const realOfferId = await getOfferIdFromReceipt(hash)
      setOfferId(realOfferId)

      await fetch(`${API}/offers`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id:            realOfferId,
          makerAddress:  address,
          usdcAmount:    params.usdcAmount,
          localCurrency: params.localCurrency,
          localAmount:   params.localAmount,
          rateOffered:   params.usdcAmount / params.localAmount,
          orderType:     params.orderType,
          limitRate:     params.limitRate ?? null,
          makerTimerSeconds: params.makerTimerSeconds,
          arcTxHash:     hash,
          memoId,
        }),
      })
      return realOfferId
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Accept offer ──────────────────────────────────────────
  async function acceptOffer(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-accept-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const acceptData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'acceptP2POffer', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, acceptData, memoId,
          { app: 'afrifx', type: 'p2p-accept', offerId },
        ))
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'acceptP2POffer', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain — the offer was not accepted.')
        throw new Error('accept reverted on-chain')
      }
      const takerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'accepted', takerAddress: address, takerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker confirms sent ───────────────────────────────────
  async function takerConfirm(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-taker-confirm-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const confirmData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'takerConfirm', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, confirmData, memoId,
          { app: 'afrifx', type: 'p2p-taker-confirm', offerId },
        ))
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'takerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain — your confirmation was not recorded.')
        throw new Error('takerConfirm reverted on-chain')
      }
      const makerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ takerConfirmed: 1, makerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker confirms received ───────────────────────────────
  async function makerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-maker-confirm-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const confirmData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'makerConfirm', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, confirmData, memoId,
          { app: 'afrifx', type: 'p2p-maker-confirm', offerId },
        ))
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'makerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain — your confirmation was not recorded.')
        throw new Error('makerConfirm reverted on-chain')
      }
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ makerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker raises dispute ──────────────────────────────────
  async function raiseDispute(
    offerId: string,
    reason?: string,
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const res = await fetch(`${API}/disputes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          offerId, raisedBy: address, reason,
          disputeType, raisedByRole,
        }),
      })
      return await res.json()
    } catch (err: any) {
      setError(err?.message ?? 'Failed to raise dispute')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker cancels own open offer ──────────────────────────
  async function cancelOwnOffer(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'makerCancelOffer', args: [offerId],
      })
      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain — the offer was not cancelled.')
        throw new Error('cancel reverted on-chain')
      }
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'cancelled' }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  return {
    createOffer, acceptOffer, takerConfirm,
    makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading, error, txHash, offerId, clearError,
  }
}
AFX_EOF
echo "  afrifx-web/hooks/useP2P.ts"

mkdir -p "afrifx-web/app/(app)/treasury/payroll/[id]"
cat > "afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatch, useUpdateRecipient } from '@/hooks/usePayroll'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs } from '@/lib/memo'
import { MEMO_ADDRESS, MEMO_ABI } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import { formatAmount } from '@/lib/utils'
import { parseUnits } from 'viem'
import {
  ArrowLeft, CheckCircle, XCircle, Loader2,
  ExternalLink, Play, AlertCircle, Clock,
} from 'lucide-react'

export function PayrollExecuteContent() {
  const { id }           = useParams()
  const { address }      = useAccount()
  const { data: batch }  = usePayrollBatch(id as string)
  const updateRecipient  = useUpdateRecipient()
  const { writeContractAsync } = useWriteContract()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })

  const [executing,    setExecuting]    = useState(false)
  const [currentIdx,   setCurrentIdx]   = useState(0)
  const [errorMsg,     setErrorMsg]     = useState<string | null>(null)
  const [done,         setDone]         = useState(false)

  if (!batch) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-muted" />
    </div>
  )

  const recipients = batch!.recipients ?? []
  const sentCount  = recipients.filter(r => r.status === 'sent').length
  const pct        = recipients.length > 0 ? Math.round((sentCount / recipients.length) * 100) : 0

  async function executePayroll() {
    if (!address || executing) return
    setExecuting(true)
    setErrorMsg(null)

    const pending = recipients.filter(r => r.status === 'pending')

    for (let i = 0; i < pending.length; i++) {
      const recipient = pending[i]
      setCurrentIdx(i)
      try {
        const usdcRaw = parseUnits(recipient.amount.toFixed(6), USDC_DECIMALS)
        const memoId  = buildMemoId(`payroll-${batch!.id}-${recipient.id}`)

        // Check if Memo is available
        let hash: `0x${string}`
        try {
          const args = buildMemoTransferArgs(
            CONTRACTS.USDC,
            recipient.wallet_address as `0x${string}`,
            recipient.amount,
            USDC_DECIMALS,
            memoId,
            {
              app:  'afrifx',
              type: 'p2p-create', // reuse as generic transfer
              ref:  recipient.memo_ref ?? undefined,
            },
          )
          hash = await writeContractAsync(args)
        } catch {
          // Fallback to direct transfer
          hash = await writeContractAsync({
            address:      CONTRACTS.USDC,
            abi:          USDC_ABI,
            functionName: 'transfer',
            args:         [recipient.wallet_address as `0x${string}`, usdcRaw],
          })
        }

        // Confirm on-chain before marking sent — a broadcast tx can revert.
        let onChainOk = true
        if (publicClient) {
          try {
            const receipt = await publicClient.waitForTransactionReceipt({ hash })
            onChainOk = receipt.status === 'success'
          } catch {
            onChainOk = false
          }
        }

        if (onChainOk) {
          await updateRecipient.mutateAsync({
            id:      recipient.id,
            batchId: batch!.id,
            status:  'sent',
            txHash:  hash,
          })
        } else {
          await updateRecipient.mutateAsync({
            id:      recipient.id,
            batchId: batch!.id,
            status:  'failed',
            txHash:  hash,
          })
          setErrorMsg(`Payment to ${recipient.name ?? recipient.wallet_address.slice(0,10)} reverted on-chain`)
        }
      } catch (err: any) {
        const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
        await updateRecipient.mutateAsync({
          id:      recipient.id,
          batchId: batch!.id,
          status:  'failed',
        })
        setErrorMsg(`Payment to ${recipient.name ?? recipient.wallet_address.slice(0,10)} failed: ${msg}`)
        // Continue with next recipients
      }
    }

    setExecuting(false)
    setDone(true)
  }

  const statusBadge = {
    draft:      'warning',
    processing: 'arc',
    completed:  'success',
    failed:     'danger',
  }[batch!.status] as any

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/treasury">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">{batch!.name}</h1>
            <Badge variant={statusBadge}>{batch!.status}</Badge>
          </div>
          <p className="text-xs text-app-muted">
            {batch.recipient_count} recipients · ${formatAmount(batch!.total_amount)} USDC
            · Created {new Date(batch!.created_at * 1000).toLocaleDateString()}
          </p>
        </div>
      </div>

      {/* Progress bar */}
      {(executing || batch!.status === 'completed') && (
        <div className="mb-4 rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-2 flex items-center justify-between text-xs">
            <span className="text-app-muted">
              {executing ? `Sending payment ${currentIdx + 1} of ${recipients.filter(r => r.status === 'pending').length}…` : 'All payments sent'}
            </span>
            <span className={`font-medium ${pct === 100 ? 'text-emerald-400' : 'text-app-text'}`}>
              {sentCount}/{recipients.length} · {pct}%
            </span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-full bg-app-border">
            <div
              className="h-full rounded-full bg-emerald-500 transition-all duration-500"
              style={{ width: `${pct}%` }}
            />
          </div>
          {executing && (
            <p className="mt-1.5 text-center text-xs text-app-muted">
              Do not close this tab until all payments are sent.
            </p>
          )}
        </div>
      )}

      {done && sentCount === recipients.length && (
        <div className="mb-4 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
          <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
          <p className="text-sm font-medium text-emerald-400">All payments sent successfully!</p>
          <p className="mt-1 text-xs text-emerald-600">
            ${formatAmount(batch!.total_amount)} USDC distributed to {sentCount} recipients
          </p>
        </div>
      )}

      {errorMsg && (
        <div className="mb-4 flex items-start gap-2 rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-xs text-red-400">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-medium">Payment failed</p>
            <p className="mt-0.5">{errorMsg}</p>
            <p className="mt-1 text-red-600">The remaining payments will continue. You can retry failed ones separately.</p>
          </div>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-3">

        {/* Recipients table */}
        <div className="lg:col-span-2 rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Recipients</p>
          <div className="space-y-2">
            {recipients.map((r, i) => (
              <div key={r.id}
                className={`flex items-center gap-3 rounded-xl p-3 transition-colors
                  ${executing && i === currentIdx && r.status === 'pending'
                    ? 'border border-app-accent/40 bg-app-accent/5'
                    : 'border border-app-border bg-app-bg'}`}>

                {/* Status icon */}
                <div className="shrink-0">
                  {r.status === 'sent'    ? <CheckCircle className="h-4 w-4 text-emerald-400" />
                  : r.status === 'failed' ? <XCircle     className="h-4 w-4 text-red-400" />
                  : executing && i === currentIdx
                  ? <Loader2 className="h-4 w-4 animate-spin text-app-accent-text" />
                  : <Clock   className="h-4 w-4 text-app-muted" />}
                </div>

                {/* Info */}
                <div className="flex-1 min-w-0">
                  {r.name && (
                    <p className="text-xs font-medium text-app-text">{r.name}</p>
                  )}
                  <p className="font-mono text-[11px] text-app-muted truncate">{r.wallet_address}</p>
                  {r.memo_ref && (
                    <p className="text-[10px] text-app-muted">{r.memo_ref}</p>
                  )}
                </div>

                {/* Amount */}
                <div className="shrink-0 text-right">
                  <p className="font-mono text-sm font-medium text-app-text">
                    {formatAmount(r.amount)} USDC
                  </p>
                  {r.tx_hash && (
                    <a href={`https://testnet.arcscan.app/tx/${r.tx_hash}`}
                      target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-[10px] text-app-accent-text hover:underline">
                      View tx <ExternalLink className="h-2.5 w-2.5" />
                    </a>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Action panel */}
        <div className="space-y-4">
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Execute</p>
            <div className="space-y-2 text-xs">
              {[
                ['Recipients', String(batch.recipient_count)],
                ['Total',      `${formatAmount(batch!.total_amount)} USDC`],
                ['Sent',       `${sentCount} / ${batch.recipient_count}`],
              ].map(([l,v]) => (
                <div key={l} className="flex justify-between">
                  <span className="text-app-muted">{l}</span>
                  <span className="font-mono text-app-text">{v}</span>
                </div>
              ))}
            </div>

            {batch!.status !== 'completed' && (
              <Button className="mt-4 w-full" size="lg"
                onClick={executePayroll}
                disabled={executing || done || sentCount === recipients.length}>
                {executing
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
                  : sentCount > 0
                  ? `Resume (${recipients.length - sentCount} remaining)`
                  : <><Play className="h-4 w-4" /> Start payroll</>
                }
              </Button>
            )}

            {batch!.status === 'completed' && (
              <div className="mt-4 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                <CheckCircle className="h-3.5 w-3.5" />
                Payroll complete
              </div>
            )}

            <p className="mt-2 text-center text-[10px] text-app-muted">
              Each payment is sent individually on Arc with a unique Memo reference
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Fix: P2P and payroll status reflect actual on-chain receipt'"
echo "  git push"
