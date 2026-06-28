#!/bin/bash
# Run from ~/AfriFX:  bash recreate-settlements.sh
set -e
mkdir -p "afrifx-web/app/(app)/settlements"

cat > "afrifx-web/app/(app)/settlements/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useSettlementReport } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { formatAmount } from '@/lib/utils'
import { Download, Loader2, TrendingUp, TrendingDown, ExternalLink } from 'lucide-react'

export default function SettlementsPage() {
  return <ClientOnly><SettlementsContent /></ClientOnly>
}

function SettlementsContent() {
  const { address }          = useAccount()
  const { data: rates = [] } = useFXRates()
  const [range,    setRange] = useState('30')
  const [activeTab, setTab]  = useState<'sent'|'received'|'invoices'|'transactions'>('sent')

  const now    = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  const { data, isLoading } = useSettlementReport(fromTs, now)

  // Convert any amount to USD using live rates
  function toUSD(amount: number, currency: string): number {
    if (!amount) return 0
    if (currency === 'USDC' || currency === 'USD') return amount
    if (currency === 'EURC') {
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    return rate && rate > 0 ? amount / rate : 0
  }

  function downloadCSV() {
    if (!data) return
    const rows: string[] = []
    rows.push('Type,Reference,Amount,Currency,USD Equivalent,Counterparty,Date,Status,TxHash')

    data.payments.sent.forEach((p: any) => {
      rows.push([
        'Payment Sent', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.recipient_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.payments.received.forEach((p: any) => {
      rows.push([
        'Payment Received', p.memo_ref, p.amount, p.currency,
        toUSD(p.amount, p.currency).toFixed(2),
        p.sender_address,
        new Date(p.created_at * 1000).toISOString(),
        p.status, p.arc_tx_hash ?? '',
      ].join(','))
    })
    data.invoices.forEach((inv: any) => {
      rows.push([
        'Invoice', inv.memo_ref, inv.amount, inv.currency,
        toUSD(inv.amount, inv.currency).toFixed(2),
        inv.creator_address,
        new Date(inv.created_at * 1000).toISOString(),
        inv.status, inv.payment_tx_hash ?? '',
      ].join(','))
    })
    data.transactions.forEach((tx: any) => {
      const fromCcy = tx.from_currency ?? tx[2]
      const fromAmt = Number(tx.from_amount ?? tx[4] ?? 0)
      const toAmt   = Number(tx.to_amount ?? tx[5] ?? 0)
      const toCcy   = tx.to_currency ?? tx[3]
      const usdVal  = toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy)
      rows.push([
        'FX Conversion', tx.reference ?? tx.id, fromAmt, fromCcy,
        usdVal.toFixed(2),
        'AfriFX Vault',
        new Date((Number(tx.created_at) || 0) * 1000).toISOString(),
        tx.status, tx.arc_tx_hash ?? '',
      ].join(','))
    })

    const blob = new Blob([rows.join('\n')], { type: 'text/csv' })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href     = url
    a.download = `afrifx-settlements-${new Date().toISOString().slice(0,10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const tabData = {
    sent:         data?.payments.sent         ?? [],
    received:     data?.payments.received     ?? [],
    invoices:     data?.invoices              ?? [],
    transactions: data?.transactions          ?? [],
  }

  // Compute USD totals from the current tab data
  const totalSentUSD     = (data?.payments.sent     ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const totalReceivedUSD = (data?.payments.received ?? []).reduce((s: number, p: any) => s + toUSD(Number(p.amount), p.currency), 0)
  const netFlow          = totalReceivedUSD - totalSentUSD

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Settlement reports</h1>
          <p className="text-sm text-[#64748B]">Full payment history with USD equivalents · exportable</p>
        </div>
        <div className="flex gap-2">
          <select value={range} onChange={e => setRange(e.target.value)}
            className="rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#E2E8F0] outline-none">
            <option value="7">Last 7 days</option>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last year</option>
          </select>
          <Button size="sm" onClick={downloadCSV} disabled={!data}>
            <Download className="h-4 w-4" /> Export CSV
          </Button>
        </div>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-3 gap-4">
        {[
          {
            label: 'Total sent (USD)',
            value: `$${formatAmount(totalSentUSD)}`,
            icon:  TrendingDown,
            color: 'text-red-400',
          },
          {
            label: 'Total received (USD)',
            value: `$${formatAmount(totalReceivedUSD)}`,
            icon:  TrendingUp,
            color: 'text-emerald-400',
          },
          {
            label: 'Net position',
            value: `${netFlow >= 0 ? '+' : ''}$${formatAmount(Math.abs(netFlow))}`,
            icon:  netFlow >= 0 ? TrendingUp : TrendingDown,
            color: netFlow >= 0 ? 'text-emerald-400' : 'text-red-400',
          },
        ].map(({ label, value, icon: Icon, color }) => (
          <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs text-[#64748B]">{label}</p>
              <Icon className={`h-4 w-4 ${color}`} />
            </div>
            <p className={`mt-1 font-mono text-xl font-bold ${color}`}>
              {isLoading ? <span className="inline-block h-6 w-24 animate-pulse rounded bg-[#1B2B4B]" /> : value}
            </p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {([
          ['sent',         'Sent'],
          ['received',     'Received'],
          ['invoices',     'Invoices'],
          ['transactions', 'FX conversions'],
        ] as const).map(([t, l]) => (
          <button key={t} onClick={() => setTab(t)}
            className={`rounded-md px-3 py-1.5 text-xs transition-colors
              ${activeTab === t ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
            {l} {data ? `(${tabData[t].length})` : ''}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
        </div>
      ) : tabData[activeTab].length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-8 text-center text-sm text-[#64748B]">
          No {activeTab} in this period
        </div>
      ) : (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-[#1B2B4B] text-left text-xs text-[#64748B]">
                <th className="px-4 py-3 font-medium">Reference</th>
                <th className="px-4 py-3 font-medium">Amount</th>
                <th className="px-4 py-3 font-medium">USD value</th>
                <th className="px-4 py-3 font-medium">Counterparty</th>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {tabData[activeTab].map((item: any) => {
                const ref      = item.memo_ref ?? item.reference ?? (item.id ?? '').slice(0,12)
                const fromCcy  = item.from_currency ?? item[2]
                const toCcy    = item.to_currency   ?? item[3]
                const fromAmt  = Number(item.from_amount ?? item[4] ?? 0)
                const toAmt    = Number(item.to_amount   ?? item[5] ?? 0)
                const amount   = item.amount ?? fromAmt
                const currency = item.currency ?? fromCcy
                const usdVal   = activeTab === 'transactions'
                  ? (toCcy === 'USDC' ? toAmt : fromCcy === 'USDC' ? fromAmt : toUSD(fromAmt, fromCcy))
                  : toUSD(Number(amount), currency)
                const counterparty = item.recipient_address ?? item.sender_address ?? item.creator_address ?? 'AfriFX Vault'
                const date     = new Date((Number(item.created_at) || 0) * 1000).toLocaleDateString()
                const status   = item.status ?? 'settled'
                const hash     = item.arc_tx_hash ?? item.payment_tx_hash

                return (
                  <tr key={item.id} className="border-b border-[#1B2B4B]/50 last:border-0 hover:bg-[#080D1B]/50 transition-colors">
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#378ADD]">{ref}</span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#E2E8F0]">
                        {formatAmount(Number(amount))} {currency}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-emerald-400">
                        ${formatAmount(usdVal)}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-xs text-[#64748B]">
                        {typeof counterparty === 'string' && counterparty.startsWith('0x')
                          ? `${counterparty.slice(0,8)}…`
                          : counterparty}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-xs text-[#64748B] whitespace-nowrap">{date}</td>
                    <td className="px-4 py-3">
                      <Badge variant={
                        status === 'settled' || status === 'paid' ? 'success' :
                        status === 'failed'  || status === 'cancelled' ? 'danger' : 'warning'
                      }>
                        {status}
                      </Badge>
                    </td>
                    <td className="px-4 py-3">
                      {hash && (
                        <a href={`https://testnet.arcscan.app/tx/${hash}`}
                          target="_blank" rel="noopener noreferrer"
                          className="text-[#64748B] hover:text-[#378ADD] transition-colors">
                          <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
__EOF__

echo "✅  settlements/page.tsx recreated"
