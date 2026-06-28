'use client'
import { useWallet }   from '@/hooks/useWallet'
import { useAccount }  from 'wagmi'
import { useProfile }  from '@/hooks/useProfile'
import Link            from 'next/link'
import { Badge }       from '@/components/ui/badge'
import { Button }      from '@/components/ui/button'
import {
  PieChart, Pie, Cell, Tooltip,
  ResponsiveContainer,
} from 'recharts'
import {
  RefreshCw, ArrowLeftRight, Send,
  Store, ExternalLink, ShieldCheck,
  TrendingUp, Wallet, Copy, Check,
} from 'lucide-react'
import { useState } from 'react'
import { formatAmount } from '@/lib/utils'

const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

export function WalletContent() {
  const { address }               = useAccount()
  const { data: profile }         = useProfile()
  const { data, isLoading, refetch } = useWallet()
  const [copied, setCopied]       = useState(false)

  function copyAddress() {
    if (!address) return
    navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const totalUSD   = (data?.tokens ?? []).reduce((s, t) => s + t.usdValue, 0)
  const escrowUSD  = data?.escrow.locked ?? 0
  const grandTotal = totalUSD + escrowUSD

  // Local currency colors
  const LOCAL_COLORS: Record<string, string> = {
    NGN: '#16A34A', GHS: '#DC2626',
    KES: '#9333EA', ZAR: '#0891B2', EGP: '#C2410C',
  }

  // Local currency slices — USD equivalent (localAmount / rate = usdcBalance)
  const localSlices = (data?.localEquiv ?? [])
    .map(({ currency, amount, rate }) => ({
      name:  currency,
      value: rate > 0 ? parseFloat((amount / rate).toFixed(2)) : 0,
      color: LOCAL_COLORS[currency] ?? '#6366F1',
    }))
    .filter(d => d.value > 0)

  // Full pie: tokens + escrow + local equivalents
  const pieData = [
    ...(data?.tokens ?? []).map(t => ({
      name: t.symbol, value: t.usdValue, color: t.color,
    })),
    ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : []),
    ...localSlices,
  ].filter(d => d.value > 0)

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Wallet</h1>
          <p className="text-sm text-[#64748B]">Your balances on Arc Testnet</p>
        </div>
        <button onClick={() => refetch()}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className={`h-3 w-3 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Top section: Portfolio overview */}
      <div className="mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3">

        {/* Total balance card */}
        <div className="lg:col-span-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          <div className="mb-4 flex items-start justify-between">
            <div>
              <p className="text-sm text-[#64748B]">Total portfolio value</p>
              <p className="mt-1 font-mono text-4xl font-bold text-[#E2E8F0]">
                {isLoading
                  ? <span className="inline-block h-10 w-40 animate-pulse rounded bg-[#1B2B4B]" />
                  : `$${formatAmount(grandTotal)}`
                }
              </p>
              <p className="mt-1 text-xs text-[#64748B]">USD equivalent on Arc Testnet</p>
            </div>
            <div className="flex h-12 w-12 items-center justify-center rounded-full bg-[#378ADD]/10">
              <Wallet className="h-6 w-6 text-[#378ADD]" />
            </div>
          </div>

          {/* Wallet address */}
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2">
            <div>
              <p className="text-xs font-medium text-[#E2E8F0]">
                {profile?.display_name ?? 'Wallet'}
              </p>
              <p className="font-mono text-[10px] text-[#64748B]">
                {address ?? '—'}
              </p>
            </div>
            <button onClick={copyAddress} className="ml-auto shrink-0 text-[#64748B] hover:text-[#E2E8F0]">
              {copied
                ? <Check className="h-3.5 w-3.5 text-emerald-400" />
                : <Copy className="h-3.5 w-3.5" />
              }
            </button>
            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-[#64748B] hover:text-[#378ADD]">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>

          {/* Quick actions */}
          <div className="flex gap-2">
            <Link href="/convert" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <ArrowLeftRight className="h-3.5 w-3.5" /> Convert
              </Button>
            </Link>
            <Link href="/send" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <Send className="h-3.5 w-3.5" /> Send
              </Button>
            </Link>
            <Link href="/marketplace/create" className="flex-1">
              <Button variant="outline" size="sm" className="w-full">
                <Store className="h-3.5 w-3.5" /> P2P
              </Button>
            </Link>
          </div>
        </div>

        {/* Donut chart */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-3 text-sm font-medium text-[#E2E8F0]">Allocation</p>
          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <RefreshCw className="h-5 w-5 animate-spin text-[#64748B]" />
            </div>
          ) : grandTotal === 0 ? (
            <div className="flex h-40 flex-col items-center justify-center gap-2">
              <p className="text-xs text-[#64748B]">No holdings yet</p>
            </div>
          ) : (
            <>
              <ResponsiveContainer width="100%" height={140}>
                <PieChart>
                  <Pie
                    data={pieData}
                    cx="50%" cy="50%"
                    innerRadius={42} outerRadius={62}
                    paddingAngle={3}
                    dataKey="value"
                  >
                    {pieData.map((entry, i) => (
                      <Cell key={i} fill={entry.color} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 11, color: '#E2E8F0' }}
                    labelStyle={{ color: '#E2E8F0' }}
                    itemStyle={{ color: '#E2E8F0' }}
                    formatter={(v: number, name: string) => [`$${formatAmount(v)} USD`, name]}
                    labelStyle={{ color: '#E2E8F0' }}
                    itemStyle={{ color: '#E2E8F0' }}
                  />
                </PieChart>
              </ResponsiveContainer>
              <div className="mt-2 max-h-44 overflow-y-auto space-y-1.5 pr-1">
                {pieData.map(d => (
                  <div key={d.name} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: d.color }} />
                      <span className="text-[#64748B]">{d.name}</span>
                    </div>
                    <span className="font-mono text-[#E2E8F0]">${formatAmount(d.value)}</span>
                  </div>
                ))}
              </div>
              <p className="mt-2 border-t border-[#1B2B4B] pt-2 text-[10px] text-[#64748B]">
                Local currencies show USD equivalent of your USDC holdings
              </p>
            </>
          )}
        </div>
      </div>

      {/* Token balances */}
      <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
        <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Token balances</p>
        <div className="grid gap-3 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">

          {/* USDC + EURC */}
          {(data?.tokens ?? [{ symbol: 'USDC', name: 'USD Coin', balance: 0, usdValue: 0, color: '#378ADD', address: '' }, { symbol: 'EURC', name: 'Euro Coin', balance: 0, usdValue: 0, color: '#10B981', address: '' }]).map(token => (
            <div key={token.symbol}
              className="flex items-center gap-3 rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-4">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-base font-bold text-white"
                style={{ background: token.color }}>
                {token.symbol[0]}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center justify-between">
                  <p className="text-sm font-medium text-[#E2E8F0]">{token.symbol}</p>
                  <p className="font-mono text-sm font-semibold text-[#E2E8F0]">
                    {isLoading
                      ? <span className="inline-block h-4 w-16 animate-pulse rounded bg-[#1B2B4B]" />
                      : formatAmount(token.balance)
                    }
                  </p>
                </div>
                <div className="flex items-center justify-between">
                  <p className="text-xs text-[#64748B]">{token.name}</p>
                  <p className="text-xs text-[#64748B]">≈ ${formatAmount(token.usdValue)}</p>
                </div>
              </div>
            </div>
          ))}

          {/* Escrow card */}
          <div className="flex items-center gap-3 rounded-xl border border-amber-900/40 bg-amber-900/10 p-4">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-amber-500/20">
              <ShieldCheck className="h-5 w-5 text-amber-400" />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center justify-between">
                <p className="text-sm font-medium text-[#E2E8F0]">Escrow</p>
                <p className="font-mono text-sm font-semibold text-amber-400">
                  {isLoading
                    ? <span className="inline-block h-4 w-16 animate-pulse rounded bg-[#1B2B4B]" />
                    : formatAmount(data?.escrow.locked ?? 0)
                  }
                </p>
              </div>
              <div className="flex items-center justify-between">
                <p className="text-xs text-amber-600">Locked in P2P offers</p>
                <p className="text-xs text-amber-600">
                  {data?.escrow.openOffers ?? 0} open · {data?.escrow.activeOffers ?? 0} active
                </p>
              </div>
            </div>
          </div>

          {/* Local currency equivalent cards */}
          {(data?.localEquiv ?? []).map(({ currency, flag, rate, amount }) => (
            <div key={currency}
              className="flex items-center gap-3 rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-4">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#1B2B4B] text-xl">
                {flag}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center justify-between">
                  <p className="text-sm font-medium text-[#E2E8F0]">{currency}</p>
                  <p className="font-mono text-sm font-semibold text-[#E2E8F0]">
                    {isLoading
                      ? <span className="inline-block h-4 w-20 animate-pulse rounded bg-[#1B2B4B]" />
                      : amount.toLocaleString(undefined, { maximumFractionDigits: 0 })
                    }
                  </p>
                </div>
                <div className="flex items-center justify-between">
                  <p className="text-xs text-[#64748B]">USDC equivalent</p>
                  <p className="text-xs text-[#64748B]">1 USDC = {rate.toLocaleString()}</p>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* P2P summary + Recent transactions */}
      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* P2P summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">P2P summary</p>
          <div className="space-y-3">
            {[
              { label: 'Completed trades', value: String(data?.p2p.completed ?? 0), icon: TrendingUp, color: 'text-emerald-400' },
              { label: 'P2P volume traded', value: `$${formatAmount(data?.p2p.totalVolume ?? 0)}`, icon: ArrowLeftRight, color: 'text-[#378ADD]' },
              { label: 'Open offers',       value: String(data?.escrow.openOffers ?? 0),   icon: Store,       color: 'text-amber-400' },
              { label: 'Active trades',     value: String(data?.escrow.activeOffers ?? 0), icon: ShieldCheck, color: 'text-[#378ADD]' },
            ].map(({ label, value, icon: Icon, color }) => (
              <div key={label} className="flex items-center justify-between rounded-lg bg-[#080D1B] px-4 py-2.5">
                <div className="flex items-center gap-2 text-xs text-[#64748B]">
                  <Icon className={`h-3.5 w-3.5 ${color}`} />
                  {label}
                </div>
                <span className={`font-mono text-sm font-semibold ${color}`}>
                  {isLoading ? '—' : value}
                </span>
              </div>
            ))}
          </div>
          <Link href="/my-trades" className="mt-3 block">
            <Button variant="outline" size="sm" className="w-full">
              View all trades →
            </Button>
          </Link>
        </div>

        {/* Recent transactions */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Recent transactions</p>
          {isLoading ? (
            <div className="space-y-2">
              {[1,2,3].map(i => <div key={i} className="h-12 animate-pulse rounded bg-[#1B2B4B]" />)}
            </div>
          ) : data?.transactions.length ? (
            <div className="space-y-2 max-h-64 overflow-y-auto">
              {data.transactions.map(tx => (
                <div key={tx.id}
                  className="flex items-center gap-3 rounded-lg bg-[#080D1B] px-3 py-2.5">
                  <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-[#378ADD]/10">
                    <ArrowLeftRight className="h-3.5 w-3.5 text-[#378ADD]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium text-[#E2E8F0]">
                      {tx.fromCurrency} → {tx.toCurrency}
                    </p>
                    <p className="text-[10px] text-[#64748B]">
                      {new Date(tx.createdAt * 1000).toLocaleDateString()}
                      {tx.reference && <span className="ml-1 font-mono">· {tx.reference}</span>}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="font-mono text-xs text-emerald-400">
                      +{formatAmount(tx.toAmount)} {tx.toCurrency}
                    </p>
                    <Badge variant={
                      tx.status === 'settled'  ? 'success' :
                      tx.status === 'failed'   ? 'danger'  : 'warning'
                    }>
                      {tx.status}
                    </Badge>
                  </div>
                  {tx.arcTxHash && (
                    <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}
                      target="_blank" rel="noopener noreferrer" className="shrink-0">
                      <ExternalLink className="h-3 w-3 text-[#64748B] hover:text-[#378ADD]" />
                    </a>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <div className="flex h-32 flex-col items-center justify-center gap-2">
              <p className="text-xs text-[#64748B]">No transactions yet</p>
              <Link href="/convert">
                <Button variant="outline" size="sm">Make your first conversion</Button>
              </Link>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
