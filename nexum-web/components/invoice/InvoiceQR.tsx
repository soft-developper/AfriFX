'use client'
// Two QR codes for an invoice:
//   1. The public pay LINK  — phone cameras open it → connect wallet → pay.
//   2. An EIP-681 ethereum: URI — for wallet in-app scanners (e.g. MetaMask)
//      that support the Arc chain. Honestly labelled: support varies by wallet,
//      and EIP-681 can't carry the memo, so the link QR is the primary path.
import { useEffect, useMemo, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useFXRates } from '@/hooks/useFXRate'
import { CONTRACTS, ARC_CHAIN_ID, USDC_DECIMALS } from '@/lib/contracts'
import { parseUnits } from 'viem'

function usdcAmountFor(amount: number, currency: string, rates: any[]): number {
  if (currency === 'USDC') return amount
  if (currency === 'EURC') {
    const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
    return r ? amount / r : amount * 1.09
  }
  const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
  if (!rate || rate <= 0) return 0
  return amount / rate
}

function QRImg({ text, label, sub }: { text: string; label: string; sub?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    if (!canvasRef.current || !text) return
    QRCode.toCanvas(canvasRef.current, text, { width: 176, margin: 1 })
      .catch(e => setErr(e?.message ?? 'QR render failed'))
  }, [text])
  return (
    <div className="flex flex-col items-center gap-2">
      <div className="rounded-xl bg-white p-3">
        {err
          ? <div className="flex h-44 w-44 items-center justify-center text-center text-[10px] text-red-500">{err}</div>
          : <canvas ref={canvasRef} />}
      </div>
      <p className="text-xs font-medium text-app-text">{label}</p>
      {sub && <p className="max-w-[12rem] text-center text-[10px] text-app-muted">{sub}</p>}
    </div>
  )
}

export function InvoiceQR({ memoRef }: { memoRef: string }) {
  const { data: invoice } = useInvoiceByRef(memoRef || null)
  const { data: rates = [] } = useFXRates()

  const payLink = useMemo(
    () => (typeof window !== 'undefined' ? `${window.location.origin}/pay/${memoRef}` : `/pay/${memoRef}`),
    [memoRef],
  )

  // EIP-681: ethereum:<usdc>@<chainId>/transfer?address=<creator>&uint256=<raw>
  const eip681 = useMemo(() => {
    if (!invoice) return ''
    const usdc = usdcAmountFor(invoice.amount, invoice.currency, rates)
    if (usdc <= 0) return ''
    let raw: string
    try { raw = parseUnits(usdc.toFixed(6), USDC_DECIMALS).toString() } catch { return '' }
    return `ethereum:${CONTRACTS.USDC}@${ARC_CHAIN_ID}/transfer?address=${invoice.creator_address}&uint256=${raw}`
  }, [invoice, rates])

  if (!invoice) return null

  return (
    <div className="rounded-2xl border border-app-border bg-app-surface p-5">
      <p className="mb-1 text-sm font-medium text-app-text">Scan to pay</p>
      <p className="mb-4 text-[11px] text-app-muted">
        Scan the left code with your phone camera to open this invoice. The right code is for
        wallet apps that scan EIP-681 payment requests on Arc (support varies by wallet).
      </p>
      <div className="flex flex-wrap items-start justify-center gap-6">
        <QRImg text={payLink} label="Open invoice link" sub="Phone camera → connect wallet → pay" />
        {eip681
          ? <QRImg text={eip681} label="Wallet payment (EIP-681)" sub="Scan from your wallet app if it supports Arc" />
          : null}
      </div>
    </div>
  )
}
