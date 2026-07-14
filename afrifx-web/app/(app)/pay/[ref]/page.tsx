'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits } from 'viem'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useCreatePayment } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { formatAmount } from '@/lib/utils'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { buildMemoId, buildMemoTransferArgs, MEMO_ADDRESS } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import {
  FileText, CheckCircle, AlertCircle,
  Loader2, ExternalLink, Wallet, XCircle,
  ArrowRight,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type PayStatus =
  | 'idle'
  | 'submitting'
  | 'confirming'
  | 'success'
  | 'failed'
  | 'error'

export default function PayPage() {
  return <ClientOnly><PayContent /></ClientOnly>
}

function PayContent() {
  const { ref }                          = useParams()
  const { address, isConnected }         = useAccount()
  const publicClient                     = usePublicClient({ chainId: arcTestnet.id })
  const { data: invoice, isLoading }     = useInvoiceByRef(ref as string)
  const { data: rates = [] }             = useFXRates()
  const createPayment                    = useCreatePayment()
  const { writeContractAsync }           = useWriteContract()

  const [status, setStatus] = useState<PayStatus>('idle')
  const [txHash, setTxHash] = useState<string | null>(null)
  const [errMsg, setErrMsg] = useState<string | null>(null)

  // ── Convert invoice amount to USDC ──────────────────────────
  // Invoice can be in any currency (NGN, GHS, KES, ZAR, EGP, EURC, USDC)
  // Transfer always happens in USDC on-chain
  function getUSDCAmount(amount: number, currency: string): number {
    if (currency === 'USDC') return amount

    if (currency === 'EURC') {
      // EURC/USDC rate = local units per USDC (inverted for EUR)
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }

    // Local currency: rate = local units per 1 USDC
    // So usdcAmount = localAmount / rate
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate || rate <= 0) return 0
    return amount / rate
  }

  if (isLoading) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!invoice) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <AlertCircle className="h-8 w-8 text-red-400" />
      <p className="text-sm text-app-muted">Invoice not found</p>
    </div>
  )

  // USDC amount the payer will actually send on-chain
  const usdcAmount     = getUSDCAmount(invoice.amount, invoice.currency)
  const isLocalCcy     = invoice.currency !== 'USDC' && invoice.currency !== 'EURC'
  const ratesLoaded    = rates.length > 0
  const rateAvailable  = !isLocalCcy || usdcAmount > 0

  const alreadyPaid  = invoice.status === 'paid'
  const isCancelled  = invoice.status === 'cancelled'
  const isCreator    = address?.toLowerCase() === invoice.creator_address.toLowerCase()
  const wrongPayer   = invoice.payer_address &&
    address?.toLowerCase() !== invoice.payer_address.toLowerCase()

  async function handlePay() {
    if (!address || !isConnected || !invoice || usdcAmount <= 0) return
    setStatus('submitting')
    setErrMsg(null)
    setTxHash(null)

    let hash: `0x${string}` | null = null

    try {
      // Always transfer in USDC regardless of invoice currency
      const usdcRaw = parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)
      const memoId  = buildMemoId(`invoice-${invoice.memo_ref}`)
      const target  = invoice.creator_address as `0x${string}`

      const code = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!code && code !== '0x'

      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, target, usdcAmount, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'p2p-create', ref: invoice.memo_ref },
        )
        hash = await writeContractAsync(args)
      } else {
        hash = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [target, usdcRaw],
        })
      }

      setTxHash(hash)
      setStatus('confirming')

      // Check on-chain status NEVER skip this
      let receiptStatus: 'success' | 'reverted' = 'success'
      if (publicClient) {
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        receiptStatus = receipt.status
      }

      if (receiptStatus === 'reverted') {
        setStatus('failed')
        await createPayment.mutateAsync({
          recipientAddress: invoice.creator_address,
          amount:           usdcAmount,
          currency:         'USDC',
          description:      `FAILED: ${invoice.description ?? invoice.memo_ref}`,
          invoiceRef:       invoice.memo_ref,
          arcTxHash:        hash,
          status:           'failed',
        } as any).catch(() => {})
        return
      }

      // ── SUCCESS ────────────────────────────────────────────
      // Mark invoice paid
      await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ txHash: hash, payerAddress: address, usdcAmount }),
      })

      // Record payment in USDC (actual on-chain amount)
      await createPayment.mutateAsync({
        recipientAddress: invoice.creator_address,
        amount:           usdcAmount,
        currency:         'USDC',
        description:      invoice.description ?? invoice.memo_ref,
        invoiceRef:       invoice.memo_ref,
        arcTxHash:        hash,
      })

      setStatus('success')

    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setStatus('error')
      setErrMsg(msg)
      if (hash) {
        await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
          method:  'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ txHash: hash, status: 'failed' }),
        }).catch(() => {})
      }
    }
  }

  return (
    <div className="mx-auto max-w-lg">
      <div className="rounded-2xl border border-app-border bg-app-surface p-6">

        {/* Header */}
        <div className="mb-5 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-app-bg">
            <FileText className="h-6 w-6 text-app-accent-text" />
          </div>
          <div>
            <p className="text-sm font-medium text-app-text">Payment request</p>
            <p className="font-mono text-xs text-app-accent-text">{invoice.memo_ref}</p>
          </div>
          <Badge className="ml-auto" variant={
            alreadyPaid ? 'success' : isCancelled ? 'danger' : 'arc'
          }>
            {invoice.status}
          </Badge>
        </div>

        {/* Amount show original + USDC equivalent */}
        <div className="mb-5 rounded-xl bg-app-bg p-5 text-center">
          <p className="text-xs text-app-muted">Amount due</p>
          <p className="mt-1 font-mono text-4xl font-bold text-app-text">
            {formatAmount(invoice.amount)}
          </p>
          <p className="text-sm text-app-accent-text">{invoice.currency}</p>

          {/* USDC conversion shown when invoice is in local currency */}
          {isLocalCcy && (
            <div className="mt-3 flex items-center justify-center gap-2">
              <span className="text-xs text-app-muted">You will pay</span>
              <div className="flex items-center gap-1.5 rounded-full border border-app-accent/30 bg-app-accent/10 px-3 py-1">
                <ArrowRight className="h-3 w-3 text-app-accent-text" />
                {!ratesLoaded ? (
                  <span className="text-xs text-app-muted animate-pulse">Loading rate…</span>
                ) : usdcAmount > 0 ? (
                  <span className="font-mono text-sm font-semibold text-app-accent-text">
                    {formatAmount(usdcAmount, 6)} USDC
                  </span>
                ) : (
                  <span className="text-xs text-red-400">Rate unavailable</span>
                )}
              </div>
            </div>
          )}

          {/* Rate used */}
          {isLocalCcy && usdcAmount > 0 && (
            <p className="mt-1.5 text-[10px] text-app-muted">
              Rate: 1 USDC = {rates.find(r => r.pair === `${invoice.currency}/USDC`)?.rate.toLocaleString()} {invoice.currency}
            </p>
          )}
        </div>

        {/* Invoice details */}
        <div className="mb-5 space-y-2 text-xs">
          {[
            ['From',        invoice.creator_address.slice(0,12) + '…'],
            ['Description', invoice.description ?? '-'],
            ['Due',         invoice.due_date
              ? new Date(invoice.due_date * 1000).toLocaleDateString()
              : 'No deadline'],
          ].map(([l, v]) => (
            <div key={l} className="flex justify-between">
              <span className="text-app-muted">{l}</span>
              <span className="text-app-text">{v}</span>
            </div>
          ))}
          {invoice.notes && (
            <div className="rounded-lg bg-app-bg p-2.5 text-app-muted">{invoice.notes}</div>
          )}
        </div>

        {/* Payment status UI */}
        {status === 'success' ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
            <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
            <p className="font-medium text-emerald-400">Payment confirmed on-chain!</p>
            <p className="mt-1 text-xs text-emerald-600">
              {formatAmount(usdcAmount, 6)} USDC sent · Invoice marked as paid
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
              </a>
            )}
          </div>

        ) : status === 'failed' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-center">
            <XCircle className="mx-auto mb-2 h-8 w-8 text-red-400" />
            <p className="font-medium text-red-400">Transaction reverted on-chain</p>
            <p className="mt-1 text-xs text-red-600">
              The transaction failed on Arc. Your USDC was not deducted.
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-red-400 hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View failed tx
              </a>
            )}
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setTxHash(null); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'error' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4">
            <div className="flex items-start gap-2">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-400" />
              <div>
                <p className="text-sm font-medium text-red-400">Payment failed</p>
                <p className="mt-0.5 text-xs text-red-600">{errMsg}</p>
              </div>
            </div>
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'submitting' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div>
                <p className="text-sm font-medium text-app-text">Waiting for signature…</p>
                <p className="text-xs text-app-muted">Approve in your wallet</p>
              </div>
            </div>
          </div>

        ) : status === 'confirming' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div className="flex-1">
                <p className="text-sm font-medium text-app-text">Confirming on Arc…</p>
                <p className="text-xs text-app-muted">Waiting for on-chain confirmation</p>
              </div>
            </div>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> Track on ArcScan
              </a>
            )}
          </div>

        ) : alreadyPaid ? (
          <div className="rounded-xl bg-emerald-900/20 p-4 text-center text-sm text-emerald-400">
            ✓ This invoice has already been paid
          </div>

        ) : isCancelled ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-sm text-red-400">
            This invoice has been cancelled
          </div>

        ) : isCreator ? (
          <div className="rounded-xl bg-amber-900/20 p-4 text-center text-xs text-amber-400">
            You created this invoice, share this link with your payer
          </div>

        ) : wrongPayer ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            This invoice is addressed to a specific wallet, connected wallet doesn't match
          </div>

        ) : !isConnected ? (
          <div className="rounded-xl bg-app-bg p-4 text-center text-sm text-app-muted">
            <Wallet className="mx-auto mb-2 h-6 w-6" />
            Connect your wallet to pay this invoice
          </div>

        ) : !ratesLoaded && isLocalCcy ? (
          <div className="rounded-xl bg-app-bg p-4 text-center text-xs text-app-muted">
            <Loader2 className="mx-auto mb-2 h-5 w-5 animate-spin" />
            Loading exchange rates…
          </div>

        ) : !rateAvailable ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            Exchange rate for {invoice.currency} is currently unavailable.
            Please try again in a moment.
          </div>

        ) : (
          <>
            <Button className="w-full" size="lg" onClick={handlePay}>
              Pay {isLocalCcy
                ? `${formatAmount(usdcAmount, 4)} USDC (≈ ${formatAmount(invoice.amount)} ${invoice.currency})`
                : `${formatAmount(invoice.amount)} USDC`
              }
            </Button>
            <p className="mt-2 text-center text-[10px] text-app-muted">
              {isLocalCcy
                ? `${invoice.currency} converted to USDC at live rate · `
                : ''}
              Memo ref: {invoice.memo_ref}
            </p>
          </>
        )}
      </div>
    </div>
  )
}
