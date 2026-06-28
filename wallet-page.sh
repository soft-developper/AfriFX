#!/bin/bash
# ============================================================
# AfriFX — Multi-currency Wallet Page
# Run from ~/AfriFX:  bash wallet-page.sh
# ============================================================
set -e
echo ""
echo "💰  Building Multi-currency Wallet page..."
echo ""

# ============================================================
# 1 — Backend: wallet endpoint
#     Returns token balances + escrow + local equivalents
# ============================================================
cat > afrifx-api/src/routes/wallet.ts << '__EOF__'
import { Router }   from 'express'
import { db }       from '../db/client'
import { sql }      from 'drizzle-orm'
import { createPublicClient, http, formatUnits } from 'viem'

const router = Router()

const ARC_RPC   = process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
const USDC_ADDR = '0x3600000000000000000000000000000000000000' as const
const EURC_ADDR = '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a' as const
const VAULT     = process.env.AFRIFX_VAULT_ADDRESS as `0x${string}` | undefined

const ERC20_ABI = [{
  name: 'balanceOf', type: 'function', stateMutability: 'view',
  inputs:  [{ name: 'account', type: 'address' }],
  outputs: [{ name: '', type: 'uint256' }],
}] as const

const arcClient = createPublicClient({
  transport: http(ARC_RPC),
  chain: {
    id: 5042002, name: 'Arc Testnet',
    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },
    rpcUrls: { default: { http: [ARC_RPC] } },
  } as any,
})

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

// GET /wallet/:address
router.get('/:address', async (req, res) => {
  const addr = req.params.address as `0x${string}`

  try {
    // ── On-chain balances (parallel) ──────────────────────
    const [usdcRaw, eurcRaw] = await Promise.all([
      arcClient.readContract({ address: USDC_ADDR, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }).catch(() => 0n),
      arcClient.readContract({ address: EURC_ADDR, abi: ERC20_ABI, functionName: 'balanceOf', args: [addr] }).catch(() => 0n),
    ])

    const usdcBalance = parseFloat(formatUnits(BigInt(usdcRaw), 6))
    const eurcBalance = parseFloat(formatUnits(BigInt(eurcRaw), 6))

    // ── USDC locked in open P2P offers (escrow) ───────────
    const escrowRows = await db.run(
      sql`SELECT SUM(usdc_amount) as locked
          FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr.toLowerCase()}
            AND status IN ('open', 'accepted')`
    )
    const er = parseRows(escrowRows)
    const escrowLocked = parseFloat(
      String(er[0]?.locked ?? er[0]?.[0] ?? 0)
    ) || 0

    // ── Active & completed P2P counts ─────────────────────
    const p2pRows = await db.run(
      sql`SELECT status, COUNT(*) as cnt, SUM(usdc_amount) as vol
          FROM p2p_offers
          WHERE LOWER(maker_address) = ${addr.toLowerCase()}
             OR LOWER(taker_address) = ${addr.toLowerCase()}
          GROUP BY status`
    )
    const p2pStats = { open: 0, accepted: 0, released: 0, cancelled: 0, totalVolume: 0 }
    for (const r of parseRows(p2pRows)) {
      const status = r.status ?? r[0]
      const cnt    = Number(r.cnt    ?? r[1] ?? 0)
      const vol    = Number(r.vol    ?? r[2] ?? 0)
      if (status in p2pStats) (p2pStats as any)[status] = cnt
      p2pStats.totalVolume += vol
    }

    // ── Live rates for local equivalents ──────────────────
    const rateRows = await db.run(
      sql`SELECT pair, rate FROM fx_rates
          WHERE pair IN ('NGN/USDC','GHS/USDC','KES/USDC','ZAR/USDC','EGP/USDC','EURC/USDC')
          ORDER BY fetched_at DESC`
    )
    const rates: Record<string, number> = {}
    const seen = new Set<string>()
    for (const r of parseRows(rateRows)) {
      const pair = r.pair ?? r[0]
      const rate = Number(r.rate ?? r[1])
      if (!seen.has(pair)) { rates[pair] = rate; seen.add(pair) }
    }

    // ── Local currency equivalents of USDC balance ────────
    const localEquiv = [
      { currency: 'NGN', flag: '🇳🇬', pair: 'NGN/USDC' },
      { currency: 'GHS', flag: '🇬🇭', pair: 'GHS/USDC' },
      { currency: 'KES', flag: '🇰🇪', pair: 'KES/USDC' },
      { currency: 'ZAR', flag: '🇿🇦', pair: 'ZAR/USDC' },
      { currency: 'EGP', flag: '🇪🇬', pair: 'EGP/USDC' },
    ].map(({ currency, flag, pair }) => {
      const rate   = rates[pair] ?? 0
      // rate = USDC per local unit → invert for local per USDC
      const localPerUsdc = rate > 0 ? 1 / rate : 0
      return {
        currency, flag,
        rate:   parseFloat(localPerUsdc.toFixed(2)),
        amount: parseFloat((usdcBalance * localPerUsdc).toFixed(2)),
      }
    })

    // ── Recent transactions (last 10) ─────────────────────
    const txRows = await db.run(
      sql`SELECT id, from_currency, to_currency, from_amount, to_amount,
                 status, arc_tx_hash, reference, created_at
          FROM transactions
          WHERE LOWER(wallet_address) = ${addr.toLowerCase()}
          ORDER BY created_at DESC LIMIT 10`
    )
    const transactions = parseRows(txRows).map((r: any) => Array.isArray(r) ? {
      id: r[0], fromCurrency: r[1], toCurrency: r[2],
      fromAmount: Number(r[3]), toAmount: Number(r[4]),
      status: r[5], arcTxHash: r[6], reference: r[7], createdAt: Number(r[8]),
    } : {
      id: r.id, fromCurrency: r.from_currency, toCurrency: r.to_currency,
      fromAmount: Number(r.from_amount), toAmount: Number(r.to_amount),
      status: r.status, arcTxHash: r.arc_tx_hash, reference: r.reference,
      createdAt: Number(r.created_at),
    })

    res.json({
      tokens: [
        {
          symbol:    'USDC',
          name:      'USD Coin',
          balance:   usdcBalance,
          usdValue:  usdcBalance,  // 1:1
          color:     '#378ADD',
          address:   USDC_ADDR,
        },
        {
          symbol:    'EURC',
          name:      'Euro Coin',
          balance:   eurcBalance,
          usdValue:  eurcBalance * (rates['EURC/USDC'] ? 1 / rates['EURC/USDC'] : 1.09),
          color:     '#10B981',
          address:   EURC_ADDR,
        },
      ],
      escrow: {
        locked:   parseFloat(escrowLocked.toFixed(6)),
        openOffers:    p2pStats.open,
        activeOffers:  p2pStats.accepted,
      },
      p2p: {
        completed:   p2pStats.released,
        totalVolume: parseFloat(p2pStats.totalVolume.toFixed(2)),
      },
      localEquiv,
      transactions,
    })
  } catch (err: any) {
    console.error('[Wallet]', err.message)
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  routes/wallet.ts"

# Register wallet route
sed -i "s|app.use('/chat',         chatRouter)|app.use('/chat',         chatRouter)\napp.use('/wallet',       walletRouter)|" \
  afrifx-api/src/index.ts

sed -i "s|import chatRouter                 from './routes/chat'|import chatRouter                 from './routes/chat'\nimport walletRouter              from './routes/wallet'|" \
  afrifx-api/src/index.ts

echo "✅  index.ts — /wallet route registered"

# ============================================================
# 2 — Frontend: useWallet hook
# ============================================================
cat > afrifx-web/hooks/useWallet.ts << '__EOF__'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TokenBalance {
  symbol:   string
  name:     string
  balance:  number
  usdValue: number
  color:    string
  address:  string
}

export interface WalletData {
  tokens:       TokenBalance[]
  escrow:       { locked: number; openOffers: number; activeOffers: number }
  p2p:          { completed: number; totalVolume: number }
  localEquiv:   { currency: string; flag: string; rate: number; amount: number }[]
  transactions: {
    id: string; fromCurrency: string; toCurrency: string
    fromAmount: number; toAmount: number
    status: string; arcTxHash: string | null
    reference: string | null; createdAt: number
  }[]
}

export function useWallet() {
  const { address } = useAccount()
  return useQuery<WalletData | null>({
    queryKey:        ['wallet', address],
    queryFn:         async () => {
      if (!address) return null
      const res = await fetch(`${API}/wallet/${address}`)
      if (!res.ok) throw new Error('Failed to fetch wallet')
      return res.json()
    },
    enabled:         !!address,
    refetchInterval: 30_000,
    staleTime:       15_000,
  })
}
__EOF__
echo "✅  hooks/useWallet.ts"

# ============================================================
# 3 — Frontend: Wallet page
# ============================================================
mkdir -p "afrifx-web/app/(app)/wallet"

cat > "afrifx-web/app/(app)/wallet/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { WalletContent } from './WalletContent'

export default function WalletPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="grid gap-4 lg:grid-cols-3">
          {[1,2,3].map(i => <div key={i} className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />)}
        </div>
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <WalletContent />
    </ClientOnly>
  )
}
__EOF__

cat > "afrifx-web/app/(app)/wallet/WalletContent.tsx" << '__EOF__'
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

  const totalUSD  = (data?.tokens ?? []).reduce((s, t) => s + t.usdValue, 0)
  const escrowUSD = data?.escrow.locked ?? 0
  const grandTotal = totalUSD + escrowUSD

  // Pie chart data
  const pieData = [
    ...( data?.tokens ?? []).map(t => ({
      name:  t.symbol,
      value: t.usdValue,
      color: t.color,
    })),
    ...(escrowUSD > 0 ? [{
      name:  'Escrow',
      value: escrowUSD,
      color: '#F59E0B',
    }] : []),
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
      <div className="mb-4 grid gap-4 lg:grid-cols-3">

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
                    contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 11 }}
                    formatter={(v: number, name: string) => [`$${formatAmount(v)}`, name]}
                    labelStyle={{ color: '#E2E8F0' }}
                    itemStyle={{ color: '#E2E8F0' }}
                  />
                </PieChart>
              </ResponsiveContainer>
              <div className="mt-2 space-y-1.5">
                {pieData.map(d => (
                  <div key={d.name} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <span className="h-2 w-2 rounded-full" style={{ background: d.color }} />
                      <span className="text-[#64748B]">{d.name}</span>
                    </div>
                    <span className="font-mono text-[#E2E8F0]">${formatAmount(d.value)}</span>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>

      {/* Token balances */}
      <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
        <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Token balances</p>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">

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
        </div>
      </div>

      {/* Local currency equivalents */}
      <div className="mb-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
        <p className="mb-4 text-sm font-medium text-[#E2E8F0]">
          Local currency equivalents
          <span className="ml-2 text-xs font-normal text-[#64748B]">
            (what your USDC is worth)
          </span>
        </p>
        {isLoading ? (
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
            {[1,2,3,4,5].map(i => <div key={i} className="h-16 animate-pulse rounded-lg bg-[#1B2B4B]" />)}
          </div>
        ) : (
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
            {(data?.localEquiv ?? []).map(({ currency, flag, rate, amount }) => (
              <div key={currency}
                className="rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-3 text-center">
                <p className="text-xl">{flag}</p>
                <p className="mt-1 font-mono text-sm font-semibold text-[#E2E8F0]">
                  {amount.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                </p>
                <p className="text-xs text-[#64748B]">{currency}</p>
                <p className="mt-0.5 text-[10px] text-[#64748B]">
                  1 USDC = {rate.toLocaleString()}
                </p>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* P2P summary + Recent transactions */}
      <div className="grid gap-4 lg:grid-cols-2">

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
__EOF__
echo "✅  app/(app)/wallet/ — page + WalletContent"

# ============================================================
# 4 — Add Wallet to sidebar
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User, Wallet,
} from 'lucide-react'
import { cn } from '@/lib/utils'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',   icon: ArrowLeftRight, label: 'Convert'   },
    { href: '/corridor',  icon: Globe,          label: 'Corridor'  },
    { href: '/send',      icon: Send,           label: 'Send'      },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Account', items: [
    { href: '/wallet',    icon: Wallet,          label: 'Wallet'    },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()
  return (
    <aside className="w-52 shrink-0 overflow-y-auto border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href ||
              (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Wallet link added under Account"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Multi-currency Wallet page complete!"
echo ""
echo "  Route: /wallet"
echo ""
echo "  Sections:"
echo "  • Portfolio total (USD) + wallet address + copy/ArcScan"
echo "  • Quick actions: Convert | Send | P2P"
echo "  • Donut chart — USDC / EURC / Escrow allocation"
echo "  • Token balances — USDC · EURC · Escrow (locked in offers)"
echo "  • Local currency equivalents — NGN GHS KES ZAR EGP"
echo "    (what your USDC is worth in each currency)"
echo "  • P2P summary — completed trades, volume, open/active"
echo "  • Recent transactions — last 10 with ArcScan links"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
