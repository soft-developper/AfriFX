#!/bin/bash
# Run from ~/AfriFX:  bash fix-invoice-payment.sh
set -e
echo "🔧  Fixing invoice payment status tracking..."

# ============================================================
# 1 — Fix /pay/[ref]/page.tsx — check receipt.status
# ============================================================
cat > "afrifx-web/app/(app)/pay/[ref]/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useParams } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits } from 'viem'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useCreatePayment } from '@/hooks/usePayments'
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
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type PayStatus =
  | 'idle'
  | 'submitting'   // waiting for wallet to sign
  | 'confirming'   // tx submitted, waiting for receipt
  | 'success'      // receipt confirmed + status = success
  | 'failed'       // receipt confirmed but status = reverted
  | 'error'        // wallet rejection or network error

export default function PayPage() {
  return <ClientOnly><PayContent /></ClientOnly>
}

function PayContent() {
  const { ref }                          = useParams()
  const { address, isConnected }         = useAccount()
  const publicClient                     = usePublicClient({ chainId: arcTestnet.id })
  const { data: invoice, isLoading }     = useInvoiceByRef(ref as string)
  const createPayment                    = useCreatePayment()
  const { writeContractAsync }           = useWriteContract()

  const [status,  setStatus]  = useState<PayStatus>('idle')
  const [txHash,  setTxHash]  = useState<string | null>(null)
  const [errMsg,  setErrMsg]  = useState<string | null>(null)

  if (isLoading) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
    </div>
  )

  if (!invoice) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <AlertCircle className="h-8 w-8 text-red-400" />
      <p className="text-sm text-[#64748B]">Invoice not found</p>
    </div>
  )

  const alreadyPaid  = invoice.status === 'paid'
  const isCancelled  = invoice.status === 'cancelled'
  const isCreator    = address?.toLowerCase() === invoice.creator_address.toLowerCase()
  const wrongPayer   = invoice.payer_address &&
    address?.toLowerCase() !== invoice.payer_address.toLowerCase()

  async function handlePay() {
    if (!address || !isConnected) return
    setStatus('submitting')
    setErrMsg(null)
    setTxHash(null)

    let hash: `0x${string}` | null = null

    try {
      // ── Step 1: Submit tx ──────────────────────────────────
      const amount  = parseUnits(invoice!.amount.toFixed(6), USDC_DECIMALS)
      const memoId  = buildMemoId(`invoice-${invoice!.memo_ref}`)
      const target  = invoice!.creator_address as `0x${string}`

      const code = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS }).catch(() => null)
        : null
      const useMemo = !!code && code !== '0x'

      if (useMemo) {
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, target, invoice!.amount, USDC_DECIMALS, memoId,
          { app: 'afrifx', type: 'p2p-create', ref: invoice!.memo_ref },
        )
        hash = await writeContractAsync(args)
      } else {
        hash = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [target, amount],
        })
      }

      setTxHash(hash)
      setStatus('confirming')

      // ── Step 2: Wait for receipt + CHECK STATUS ────────────
      // receipt.status = 'success' | 'reverted'
      // NEVER skip this check — a reverted tx still returns a receipt
      let receiptStatus: 'success' | 'reverted' = 'success'
      if (publicClient) {
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        receiptStatus = receipt.status
      }

      if (receiptStatus === 'reverted') {
        // ── FAILED on-chain ───────────────────────────────────
        setStatus('failed')

        // Record as failed payment (not paid)
        await createPayment.mutateAsync({
          recipientAddress: invoice!.creator_address,
          amount:           invoice!.amount,
          currency:         invoice!.currency,
          description:      `FAILED: ${invoice!.description ?? ''}`,
          invoiceRef:       invoice!.memo_ref,
          arcTxHash:        hash,
          status:           'failed',
        } as any).catch(() => {})

        // Do NOT update invoice status
        return
      }

      // ── Step 3: SUCCESS — update invoice + record payment ──
      await fetch(`${API}/invoices/ref/${invoice!.memo_ref}/pay`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ txHash: hash, payerAddress: address }),
      })

      await createPayment.mutateAsync({
        recipientAddress: invoice!.creator_address,
        amount:           invoice!.amount,
        currency:         invoice!.currency,
        description:      invoice!.description ?? undefined,
        invoiceRef:       invoice!.memo_ref,
        arcTxHash:        hash,
      })

      setStatus('success')

    } catch (err: any) {
      // Wallet rejected / network error (tx never submitted or submission failed)
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setStatus('error')
      setErrMsg(msg)

      // If tx was submitted but failed before receipt, record as failed
      if (hash) {
        await fetch(`${API}/invoices/ref/${invoice!.memo_ref}/pay`, {
          method:  'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ txHash: hash, status: 'failed' }),
        }).catch(() => {})
      }
    }
  }

  return (
    <div className="mx-auto max-w-lg">
      <div className="rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-6">
        {/* Header */}
        <div className="mb-5 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-[#080D1B]">
            <FileText className="h-6 w-6 text-[#378ADD]" />
          </div>
          <div>
            <p className="text-sm font-medium text-[#E2E8F0]">Payment request</p>
            <p className="font-mono text-xs text-[#378ADD]">{invoice.memo_ref}</p>
          </div>
          <Badge className="ml-auto" variant={
            alreadyPaid  ? 'success' :
            isCancelled  ? 'danger'  : 'arc'
          }>
            {invoice.status}
          </Badge>
        </div>

        {/* Amount */}
        <div className="mb-5 rounded-xl bg-[#080D1B] p-5 text-center">
          <p className="text-xs text-[#64748B]">Amount due</p>
          <p className="mt-1 font-mono text-4xl font-bold text-[#E2E8F0]">
            {formatAmount(invoice.amount)}
          </p>
          <p className="text-sm text-[#378ADD]">{invoice.currency}</p>
        </div>

        {/* Details */}
        <div className="mb-5 space-y-2 text-xs">
          {[
            ['From',        invoice.creator_address.slice(0,12)+'…'],
            ['Description', invoice.description ?? '—'],
            ['Due',         invoice.due_date
              ? new Date(invoice.due_date * 1000).toLocaleDateString()
              : 'No deadline'],
          ].map(([l, v]) => (
            <div key={l} className="flex justify-between">
              <span className="text-[#64748B]">{l}</span>
              <span className="text-[#E2E8F0]">{v}</span>
            </div>
          ))}
          {invoice.notes && (
            <div className="rounded-lg bg-[#080D1B] p-2.5 text-[#64748B]">
              {invoice.notes}
            </div>
          )}
        </div>

        {/* States */}
        {status === 'success' ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
            <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
            <p className="font-medium text-emerald-400">Payment confirmed on-chain!</p>
            <p className="mt-1 text-xs text-emerald-600">Invoice marked as paid</p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-[#378ADD] hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
              </a>
            )}
          </div>

        ) : status === 'failed' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-center">
            <XCircle className="mx-auto mb-2 h-8 w-8 text-red-400" />
            <p className="font-medium text-red-400">Transaction reverted on-chain</p>
            <p className="mt-1 text-xs text-red-600">
              The transaction was submitted but failed on Arc. Your USDC was not deducted.
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-red-400 hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View failed tx on ArcScan
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
              <div className="flex-1">
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
          <div className="rounded-xl bg-[#080D1B] p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-[#378ADD]" />
              <div>
                <p className="text-sm font-medium text-[#E2E8F0]">Waiting for signature…</p>
                <p className="text-xs text-[#64748B]">Please approve in your wallet</p>
              </div>
            </div>
          </div>

        ) : status === 'confirming' ? (
          <div className="rounded-xl bg-[#080D1B] p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-[#378ADD]" />
              <div className="flex-1">
                <p className="text-sm font-medium text-[#E2E8F0]">Confirming on Arc…</p>
                <p className="text-xs text-[#64748B]">Waiting for on-chain confirmation</p>
              </div>
            </div>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 flex items-center gap-1 text-xs text-[#378ADD] hover:underline">
                <ExternalLink className="h-3.5 w-3.5" />
                Track on ArcScan
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
            You created this invoice — share this link with your payer
          </div>

        ) : wrongPayer ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            This invoice is addressed to a specific wallet — connected wallet doesn't match
          </div>

        ) : !isConnected ? (
          <div className="rounded-xl bg-[#080D1B] p-4 text-center text-sm text-[#64748B]">
            <Wallet className="mx-auto mb-2 h-6 w-6" />
            Connect your wallet to pay this invoice
          </div>

        ) : (
          <>
            <Button className="w-full" size="lg" onClick={handlePay}>
              Pay {formatAmount(invoice.amount)} {invoice.currency}
            </Button>
            <p className="mt-2 text-center text-[10px] text-[#64748B]">
              Payment sent on Arc with Memo reference {invoice.memo_ref}
            </p>
          </>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  pay/[ref]/page.tsx — receipt.status check added"

# ============================================================
# 2 — Backend: update /invoices/ref/:ref/pay to accept status
#     so failed txs can also be recorded properly
# ============================================================
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/invoices.ts')
with open(path) as f:
    content = f.read()

old = """// PATCH /invoices/ref/:ref/pay — mark paid by memo ref (called after on-chain tx)
router.patch('/ref/:ref/pay', async (req, res) => {
  const { txHash, payerAddress } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = 'paid',
            payment_tx_hash = ${txHash ?? null},
            payer_address   = COALESCE(${payerAddress?.toLowerCase() ?? null}, payer_address),
            paid_at         = ${now},
            updated_at      = ${now}
          WHERE memo_ref = ${req.params.ref}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})"""

new = """// PATCH /invoices/ref/:ref/pay — mark paid or failed by memo ref
// Called by frontend after on-chain confirmation with receipt.status
router.patch('/ref/:ref/pay', async (req, res) => {
  const { txHash, payerAddress, status: txStatus } = req.body
  const now = Math.floor(Date.now() / 1000)

  // Only mark as 'paid' if tx actually succeeded on-chain
  // txStatus = 'failed' means receipt.status === 'reverted'
  const invoiceStatus = txStatus === 'failed' ? 'sent' : 'paid' // keep as 'sent' if failed
  const paidAt        = txStatus === 'failed' ? null : now

  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = ${invoiceStatus},
            payment_tx_hash = COALESCE(${txHash ?? null}, payment_tx_hash),
            payer_address   = COALESCE(${payerAddress?.toLowerCase() ?? null}, payer_address),
            paid_at         = COALESCE(${paidAt}, paid_at),
            updated_at      = ${now}
          WHERE memo_ref = ${req.params.ref}`
    )
    res.json({ success: true, invoiceStatus })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})"""

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  invoices.ts — /ref/:ref/pay handles failed status")
else:
    print("❌  Pattern not found in invoices.ts")
    idx = content.find("ref/:ref/pay")
    print(content[idx:idx+300] if idx >= 0 else "not found")
PYEOF

# ============================================================
# 3 — Backend: update payments route to accept status field
# ============================================================
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/payments.ts')
with open(path) as f:
    content = f.read()

old = """    await db.run(
      sql`INSERT INTO payments
          (id, sender_address, recipient_address, amount, currency,
           local_currency, local_amount, description, invoice_ref,
           memo_ref, status, arc_tx_hash, created_at)
          VALUES
          (${id}, ${senderAddress.toLowerCase()}, ${recipientAddress.toLowerCase()},
           ${Number(amount)}, ${currency},
           ${localCurrency ?? null}, ${localAmount},
           ${description ?? null}, ${invoiceRef ?? null},
           ${memoRef}, ${arcTxHash ? 'settled' : 'pending'},
           ${arcTxHash ?? null}, ${now})`
    )"""

new = """    // Allow explicit status override (e.g. 'failed' for reverted txs)
    const paymentStatus = req.body.status === 'failed' ? 'failed'
      : arcTxHash ? 'settled' : 'pending'

    await db.run(
      sql`INSERT INTO payments
          (id, sender_address, recipient_address, amount, currency,
           local_currency, local_amount, description, invoice_ref,
           memo_ref, status, arc_tx_hash, created_at)
          VALUES
          (${id}, ${senderAddress.toLowerCase()}, ${recipientAddress.toLowerCase()},
           ${Number(amount)}, ${currency},
           ${localCurrency ?? null}, ${localAmount},
           ${description ?? null}, ${invoiceRef ?? null},
           ${memoRef}, ${paymentStatus},
           ${arcTxHash ?? null}, ${now})`
    )"""

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("✅  payments.ts — status field accepted on POST")
else:
    print("⚠️  Payment INSERT pattern not found — skipping")
PYEOF

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Invoice payment flow fixed!"
echo ""
echo "  Root cause:"
echo "  waitForTransactionReceipt() returns a receipt even for"
echo "  reverted txs — we never checked receipt.status so"
echo "  all txs (including failed ones) were marked as paid"
echo ""
echo "  Fix:"
echo "  • Check receipt.status === 'success' | 'reverted'"
echo "  • 'reverted' → show red 'Transaction reverted' screen"
echo "    Invoice stays 'sent' (unpaid) in DB"
echo "    Payment recorded as 'failed'"
echo "    'Try again' button appears"
echo "  • 'success' → mark invoice paid, record payment settled"
echo "  • Wallet rejection → 'error' screen, nothing recorded"
echo ""
echo "  Payment states:"
echo "  idle → submitting (wallet sign) → confirming (on-chain)"
echo "       → success ✅ or failed ❌ or error ⚠️"
echo ""
echo "  Restart backend:  cd afrifx-api && npm run dev"
echo "══════════════════════════════════════════════════════"
