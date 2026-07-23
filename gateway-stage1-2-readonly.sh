#!/bin/bash
# ============================================================
# AfriFX GATEWAY -- STAGES 1+2: CONFIG + READ-ONLY TREASURY BALANCE
#
# NOTHING SIGNS. NOTHING MOVES. This is configuration plus a dashboard panel,
# so it's safe to deploy while the treasury wallet is still being set up.
#
# *** THE PLAN, AND WHY IT ISN'T A "MIGRATION" ***
# You asked about migrating from CCTP to Gateway. After reading Circle's own
# docs I'd push back on the framing: they are different tools, and Circle's
# guidance says so explicitly -- CCTP is the better fit for ad-hoc
# point-to-point transfers (our USER bridge), while Gateway suits "capital
# efficiency, low latency, chain abstraction" (our TREASURY).
#
# So: KEEP CCTP for user bridging. ADD Gateway for treasury. Not a swap.
#
# *** THE NUMBER THAT MAKES THIS WORTH DOING ***
# Circle's published deposit finality:
#     Arc       ~0.5 SECONDS   <-- our home chain
#     Base      ~13-19 minutes
#     Ethereum  ~13-19 minutes
# Gateway's usual drawback is that you front-load the finality wait. Because Arc
# clears in half a second, that cost barely exists for us. Treasury sits on Arc,
# tops up near-instantly, then funds a Flutterwave payout on Base in under a
# second -- instead of a CCTP bridge with an attestation wait sitting in the
# middle of a customer's payout.
#
# VERIFIED against BOTH Circle's and Arc's official docs (they agree):
#   * Gateway uses the SAME domain identifiers as CCTP (Arc = 26), so our
#     existing chain registry carries over unchanged.
#   * Arc Testnet GatewayWallet 0x0077777d... / GatewayMinter 0x0022222A...
#     match Arc's own contract-address page independently.
#
# WHAT THIS SHIPS
#   lib/gateway.ts                   config, chains, and a DEFENSIVE balance
#                                    reader (normalises several plausible
#                                    response shapes rather than assuming one
#                                    and rendering NaN)
#   GatewayBalancePanel.tsx          read-only unified-balance panel
#   TreasuryContent.tsx              panel placed above the existing cards
#
# THE TWO RISKS THE PANEL STATES PLAINLY TO WHOEVER OPERATES IT
#   1. Withdrawing without Circle's API takes SEVEN DAYS. Size Gateway holdings
#      as working capital, never the whole reserve.
#   2. (For stage 3) A PLAIN ERC-20 TRANSFER to the GatewayWallet DESTROYS the
#      USDC -- deposits must use the contract's deposit methods. A guard for
#      this goes in with the deposit flow.
#
# Also note: burn intents must be signed by an EOA (not a smart account). Since
# this is AfriFX's own treasury wallet, that's within your control.
#
# NEXT STAGES (need the treasury wallet to exist):
#   3) deposit flow, with the plain-transfer guard
#   4) instant transfers wired into the payout orchestrator
#
# Run from ~/AfriFX:  bash gateway-stage1-2-readonly.sh
# ============================================================
set -e
echo ""
echo "Installing Gateway config + read-only treasury panel..."
echo ""

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/gateway.ts" << 'AFX_EOF'
// ============================================================
// Circle Gateway configuration (TREASURY use).
//
// STAGE 1: PURE CONFIG + READ-ONLY. Nothing here signs or moves money.
//
// WHY GATEWAY FOR TREASURY (and NOT for user bridging):
// Gateway is a PRE-FUNDED UNIFIED BALANCE, not a faster bridge. You deposit
// once, wait for finality once, then spend instantly (<500ms) on any supported
// chain. Circle's own guidance is explicit that CCTP remains the better fit for
// ad-hoc point-to-point transfers — which is what our user-facing bridge does.
//
// For AfriFX's TREASURY it's a strong fit, and one number makes it compelling:
//
//   DEPOSIT FINALITY (Circle's published figures)
//     Arc       ~0.5 seconds     <-- our home chain
//     Base      ~13-19 minutes
//     Ethereum  ~13-19 minutes
//
// Because Arc finalises in about half a second, the "front-load the wait" cost
// that makes Gateway awkward elsewhere barely exists for us. Treasury sits on
// Arc, deposits near-instantly, and can then fund a Flutterwave payout on Base
// in under a second — instead of a CCTP bridge with an attestation wait sitting
// in the middle of a customer's payout.
//
// Verified against BOTH Circle's and Arc's official docs (they agree):
//   * Gateway uses the SAME domain identifiers as CCTP (Arc = 26), so our
//     existing chain registry carries over unchanged.
//   * Arc Testnet Gateway contracts match Arc's own contract-address page.
// ============================================================

export type GatewayEnv = 'testnet' | 'mainnet'

export const GATEWAY_ENV: GatewayEnv =
  (process.env.NEXT_PUBLIC_CCTP_ENV as GatewayEnv) ?? 'testnet'

export const GATEWAY_API = {
  testnet: 'https://gateway-api-testnet.circle.com/v1',
  mainnet: 'https://gateway-api.circle.com/v1',
} as const

export function gatewayApi(env: GatewayEnv = GATEWAY_ENV) {
  return GATEWAY_API[env]
}

/*
  Gateway contract addresses.

  Arc Testnet values cross-checked against Arc's own contract-address docs.
  NOTE the deposit warning in Circle's technical guide: sending USDC to the
  GatewayWallet with a PLAIN ERC-20 TRANSFER DESTROYS IT. Deposits must go
  through the contract's deposit* methods. Stage 3 will guard against this.
*/
export const GATEWAY_CONTRACTS: Record<GatewayEnv, {
  wallet: string; minter: string
}> = {
  testnet: {
    wallet: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9',
    minter: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B',
  },
  mainnet: {
    // Same deterministic addresses Circle publishes for mainnet Gateway.
    wallet: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9',
    minter: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B',
  },
}

export function gatewayContracts(env: GatewayEnv = GATEWAY_ENV) {
  return GATEWAY_CONTRACTS[env]
}

export interface GatewayChain {
  key:      string
  name:     string
  domain:   number     // same identifiers as CCTP
  /** Circle's SupportedChainName, used by the SDK and API. */
  sdkName:  string
  /** Published deposit finality, for honest UI copy. */
  finality: string
  isHome?:  boolean
}

/*
  A deliberately SHORT list: the chains AfriFX actually settles on. Gateway
  supports many more, but each one we show should be one we've reasoned about.
  Arc is home; Base matters because that's where Flutterwave settles.
*/
const TESTNET: GatewayChain[] = [
  { key: 'arc',      name: 'Arc Testnet',      domain: 26, sdkName: 'Arc_Testnet',      finality: '~0.5s', isHome: true },
  { key: 'base',     name: 'Base Sepolia',     domain: 6,  sdkName: 'Base_Sepolia',     finality: '~13-19 min' },
  { key: 'ethereum', name: 'Ethereum Sepolia', domain: 0,  sdkName: 'Ethereum_Sepolia', finality: '~13-19 min' },
  { key: 'arbitrum', name: 'Arbitrum Sepolia', domain: 3,  sdkName: 'Arbitrum_Sepolia', finality: '~13-19 min' },
  { key: 'polygon',  name: 'Polygon Amoy',     domain: 7,  sdkName: 'Polygon_Amoy',     finality: '~8s' },
]

const MAINNET: GatewayChain[] = [
  { key: 'arc',      name: 'Arc',      domain: 26, sdkName: 'Arc',      finality: '~0.5s', isHome: true },
  { key: 'base',     name: 'Base',     domain: 6,  sdkName: 'Base',     finality: '~13-19 min' },
  { key: 'ethereum', name: 'Ethereum', domain: 0,  sdkName: 'Ethereum', finality: '~13-19 min' },
  { key: 'arbitrum', name: 'Arbitrum', domain: 3,  sdkName: 'Arbitrum', finality: '~13-19 min' },
  { key: 'polygon',  name: 'Polygon',  domain: 7,  sdkName: 'Polygon',  finality: '~8s' },
]

export function gatewayChains(env: GatewayEnv = GATEWAY_ENV): GatewayChain[] {
  return env === 'mainnet' ? MAINNET : TESTNET
}

export function gatewayChainByDomain(domain: number, env: GatewayEnv = GATEWAY_ENV) {
  return gatewayChains(env).find(c => c.domain === domain)
}

/*
  The treasury wallet address. Read-only here — we only ever LOOK UP balances
  for it. Signing (stage 3+) is a separate decision and deliberately not wired
  into this file.
*/
export function treasuryAddress(): string | undefined {
  const a = process.env.NEXT_PUBLIC_TREASURY_ADDRESS
  return a && /^0x[a-fA-F0-9]{40}$/.test(a) ? a : undefined
}

export function gatewayConfigured(): boolean {
  return !!treasuryAddress()
}

// ── Read-only API helpers ───────────────────────────────────

export interface GatewayBalanceEntry {
  domain:   number
  chainName?: string
  balance:  string
}

export interface GatewayBalances {
  token: string
  total: number
  perChain: { key: string; name: string; domain: number; amount: number; finality: string }[]
  raw?: unknown
}

/*
  Fetch the unified balance for an address.

  Defensive about the response shape: Circle documents `/v1/balances`, but the
  exact nesting has varied between the API reference and the SDK. We normalise
  whatever comes back rather than assuming one shape and rendering NaN.
*/
export async function fetchGatewayBalances(
  address: string, env: GatewayEnv = GATEWAY_ENV,
): Promise<GatewayBalances | { error: string }> {
  try {
    const url = `${gatewayApi(env)}/balances?token=USDC&depositor=${address}`
    const res = await fetch(url, { headers: { accept: 'application/json' } })
    if (!res.ok) return { error: `Gateway API ${res.status}` }
    const data: any = await res.json()

    // Accept several plausible shapes.
    const entries: any[] =
      data?.balances ?? data?.data?.balances ?? data?.data ?? []

    const chains = gatewayChains(env)
    const perChain = chains.map(c => {
      const hit = (Array.isArray(entries) ? entries : []).find((e: any) =>
        Number(e?.domain) === c.domain ||
        String(e?.chain ?? '').toLowerCase() === c.sdkName.toLowerCase())
      return {
        key: c.key, name: c.name, domain: c.domain, finality: c.finality,
        amount: Number(hit?.balance ?? hit?.available ?? 0) || 0,
      }
    })

    const total =
      Number(data?.totalBalance ?? data?.total ?? 0) ||
      perChain.reduce((s, c) => s + c.amount, 0)

    return { token: 'USDC', total, perChain, raw: data }
  } catch (err: any) {
    return { error: err?.message ?? 'Could not reach the Gateway API' }
  }
}
AFX_EOF
echo "  afrifx-web/lib/gateway.ts"

mkdir -p "afrifx-web/components/treasury"
cat > "afrifx-web/components/treasury/GatewayBalancePanel.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Info, ExternalLink } from 'lucide-react'
import {
  fetchGatewayBalances, gatewayChains, treasuryAddress, gatewayConfigured,
  GATEWAY_ENV, gatewayContracts,
} from '@/lib/gateway'

/*
  READ-ONLY view of AfriFX's Circle Gateway unified balance.

  Stage 2 of the Gateway work: this panel only LOOKS. It cannot deposit,
  transfer or withdraw — those need a signer and are deliberately not wired up
  yet. The value of shipping it first is that treasury across chains becomes
  visible in one place, which it isn't today.
*/
export function GatewayBalancePanel() {
  const [data, setData]       = useState<any>(null)
  const [error, setError]     = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const addr = treasuryAddress()

  const load = useCallback(async () => {
    if (!addr) return
    setLoading(true); setError(null)
    const res = await fetchGatewayBalances(addr)
    if ('error' in res) setError(res.error)
    else setData(res)
    setLoading(false)
  }, [addr])

  useEffect(() => { load() }, [load])

  // Not configured yet — explain rather than render an empty box.
  if (!gatewayConfigured()) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <h3 className="mb-1 flex items-center gap-2 text-sm font-semibold text-app-text">
          <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
        </h3>
        <p className="text-xs leading-relaxed text-app-muted">
          Circle Gateway isn&apos;t set up yet. Once a treasury wallet address is
          configured, this shows a single USDC balance spendable on any supported
          chain — so a payout on Base can settle instantly without bridging
          mid-transaction.
        </p>
        <p className="mt-2 text-[11px] text-app-muted">
          Set <code className="rounded bg-app-bg px-1">NEXT_PUBLIC_TREASURY_ADDRESS</code> to enable.
        </p>
      </div>
    )
  }

  const chains = gatewayChains()

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5">
      <div className="mb-3 flex items-start justify-between">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-semibold text-app-text">
            <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
          </h3>
          <p className="mt-0.5 font-mono text-[10px] text-app-muted">{addr}</p>
        </div>
        <button onClick={load} disabled={loading}
          className="flex items-center gap-1 text-[11px] text-app-muted hover:text-app-text">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {error ? (
        <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
          <p className="flex items-center gap-1.5 text-xs text-amber-400">
            <AlertCircle className="h-3.5 w-3.5" /> Couldn&apos;t read the Gateway balance
          </p>
          <p className="mt-1 text-[11px] text-amber-200/80">{error}</p>
          <p className="mt-1 text-[11px] text-amber-200/60">
            This is a read failure only — no funds are affected.
          </p>
        </div>
      ) : (
        <>
          <div className="mb-4 rounded-lg bg-app-bg p-4">
            <p className="text-[10px] uppercase tracking-wide text-app-muted">
              Spendable on any chain
            </p>
            <p className="font-mono text-2xl text-app-text">
              {loading && !data ? '—' : (data?.total ?? 0).toLocaleString(undefined, {
                minimumFractionDigits: 2, maximumFractionDigits: 2,
              })}
              <span className="ml-1 text-sm text-app-muted">USDC</span>
            </p>
          </div>

          <p className="mb-2 text-[10px] font-semibold uppercase tracking-wide text-app-muted">
            Deposited per chain
          </p>
          <div className="space-y-1.5">
            {(data?.perChain ?? chains.map(c => ({ ...c, amount: 0 }))).map((c: any) => (
              <div key={c.key} className="flex items-center justify-between rounded-lg bg-app-bg/60 px-3 py-2">
                <span className="flex items-center gap-2 text-xs text-app-text">
                  {c.name}
                  {c.isHome || c.key === 'arc' ? (
                    <span className="rounded-full bg-app-accent/15 px-1.5 py-0.5 text-[9px] text-app-accent-text">
                      home
                    </span>
                  ) : null}
                </span>
                <span className="text-right">
                  <span className="block font-mono text-xs text-app-text">
                    {(c.amount ?? 0).toFixed(2)}
                  </span>
                  {/* Finality is the honest cost of depositing from that chain. */}
                  <span className="block text-[9px] text-app-muted">
                    deposits clear in {c.finality}
                  </span>
                </span>
              </div>
            ))}
          </div>
        </>
      )}

      {/* The two things anyone operating this must know. */}
      <div className="mt-4 space-y-2 border-t border-app-border pt-3">
        <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-app-muted">
          <Info className="mt-0.5 h-3 w-3 shrink-0" />
          Arc deposits clear in about half a second, so topping up from Arc is
          effectively instant. Deposits from Base or Ethereum take 13–19 minutes
          to finalise before they can be spent.
        </p>
        <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-200/70">
          <AlertCircle className="mt-0.5 h-3 w-3 shrink-0" />
          Withdrawing without Circle&apos;s API takes 7 days. Treat this as working
          capital, not the whole reserve.
        </p>
        <a
          href={`https://developers.circle.com/gateway`}
          target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-[11px] text-app-accent-text hover:underline"
        >
          Circle Gateway docs <ExternalLink className="h-2.5 w-2.5" />
        </a>
      </div>

      <p className="mt-2 text-[10px] text-app-muted">
        {GATEWAY_ENV} · wallet {gatewayContracts().wallet.slice(0, 10)}…
      </p>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/treasury/GatewayBalancePanel.tsx"

mkdir -p "afrifx-web/app/(app)/treasury"
cat > "afrifx-web/app/(app)/treasury/TreasuryContent.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useWallet } from '@/hooks/useWallet'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { useTreasuryRules, useCreateRule, useToggleRule, useDeleteRule } from '@/hooks/useTreasury'
import { useFXRates } from '@/hooks/useFXRate'
import { formatAmount } from '@/lib/utils'
import { GatewayBalancePanel } from '@/components/treasury/GatewayBalancePanel'
import {
  Plus, Zap, Trash2, Pause, Play,
  AlertTriangle, ArrowRight, Users, Building2,
  ChevronDown, ChevronUp, ExternalLink,
} from 'lucide-react'

const CURRENCIES  = ['NGN','GHS','KES','ZAR','EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬'
}

export function TreasuryContent() {
  const { address }               = useAccount()
  const router                    = useRouter()
  const { data: wallet }          = useWallet()
  const { data: rules = [] }      = useTreasuryRules()
  const { data: batches = [] }    = usePayrollBatches()
  const { data: rates = [] }      = useFXRates()
  const createRule                = useCreateRule()
  const toggleRule                = useToggleRule()
  const deleteRule                = useDeleteRule()

  const [showRuleForm, setShowRuleForm] = useState(false)
  const [ruleName,     setRuleName]     = useState('')
  const [threshold,    setThreshold]    = useState('')
  const [actionType,   setActionType]   = useState<'percent'|'fixed'>('percent')
  const [actionVal,    setActionVal]    = useState('')
  const [targetCcy,    setTargetCcy]    = useState('NGN')

  const usdcBalance = wallet?.tokens.find(t => t.symbol === 'USDC')?.balance ?? 0
  const escrowLocked = wallet?.escrow.locked ?? 0
  const triggeredRules = rules.filter(r => r.status === 'triggered')

  async function handleCreateRule() {
    if (!ruleName || !threshold || !actionVal) return
    await createRule.mutateAsync({
      name:              ruleName,
      trigger_threshold: parseFloat(threshold),
      action_percent:    actionType === 'percent' ? parseFloat(actionVal) : null,
      action_amount:     actionType === 'fixed'   ? parseFloat(actionVal) : null,
      target_currency:   targetCcy,
    })
    setRuleName(''); setThreshold(''); setActionVal('')
    setShowRuleForm(false)
  }

  function getConversionAmount(rule: typeof rules[0]): number {
    if (rule.action_percent) return usdcBalance * (rule.action_percent / 100)
    return rule.action_amount ?? 0
  }

  function getLocalEquiv(usdcAmt: number, currency: string): string {
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate) return '-'
    return (usdcAmt / rate).toLocaleString(undefined, { maximumFractionDigits: 0 })
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Business Treasury</h1>
          <p className="text-sm text-app-muted">Automate conversions · manage payroll · track funds</p>
        </div>
        <Link href="/treasury/payroll">
          <Button size="sm">
            <Users className="h-4 w-4" /> New payroll
          </Button>
        </Link>
      </div>

      {/* Triggered rules alert */}
      {triggeredRules.length > 0 && (
        <div className="mb-4 rounded-xl border border-amber-900/50 bg-amber-900/20 p-4">
          <div className="flex items-start gap-3">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-400" />
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-400">
                {triggeredRules.length} auto-conversion rule{triggeredRules.length > 1 ? 's' : ''} triggered
              </p>
              {triggeredRules.map(r => {
                const amt = getConversionAmount(r)
                return (
                  <div key={r.id} className="mt-2 flex items-center justify-between text-xs">
                    <span className="text-amber-600">
                      "{r.name}", convert {r.action_percent ? `${r.action_percent}%` : `${r.action_amount} USDC`} to {r.target_currency}
                      {amt > 0 && ` (≈ ${getLocalEquiv(amt, r.target_currency)} ${r.target_currency})`}
                    </span>
                    <div className="flex gap-2">
                      <Link href="/convert">
                        <Button size="sm" className="h-7 text-xs">
                          Convert now <ArrowRight className="h-3 w-3" />
                        </Button>
                      </Link>
                      <Button size="sm" variant="outline" className="h-7 text-xs"
                        onClick={() => toggleRule.mutate({ id: r.id, status: 'active' })}>
                        Dismiss
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* Stats row */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          { label: 'Available USDC',   value: `$${formatAmount(usdcBalance)}`,  sub: 'ready to use'        },
          { label: 'In escrow',        value: `$${formatAmount(escrowLocked)}`, sub: 'locked in P2P offers' },
          { label: 'Active rules',     value: String(rules.filter(r => r.status === 'active').length),
            sub: 'auto-conversion rules' },
          { label: 'Payrolls run',     value: String(batches.filter(b => b.status === 'completed').length),
            sub: `$${formatAmount(batches.filter(b => b.status === 'completed').reduce((s,b) => s + b.total_amount, 0))} total paid` },
        ].map(({ label, value, sub }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <p className="text-xs text-app-muted">{label}</p>
            <p className="mt-1 font-mono text-xl font-semibold text-app-text">{value}</p>
            <p className="mt-0.5 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      {/* Circle Gateway unified balance — read-only for now. Sits above the
          existing panels because "how much can I actually spend, anywhere" is
          the first question when funding a payout. */}
      <div className="mb-4">
        <GatewayBalancePanel />
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* Auto-conversion rules */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Auto-conversion rules</p>
              <p className="text-xs text-app-muted">Trigger when USDC balance crosses a threshold</p>
            </div>
            <Button size="sm" variant="outline"
              onClick={() => setShowRuleForm(!showRuleForm)}>
              <Plus className="h-3.5 w-3.5" /> New rule
            </Button>
          </div>

          {/* Create rule form */}
          {showRuleForm && (
            <div className="mb-4 space-y-3 rounded-xl border border-app-border bg-app-bg p-4">
              <p className="text-xs font-medium text-app-text">New rule</p>
              <Input placeholder="Rule name (e.g. Convert excess NGN)"
                value={ruleName} onChange={e => setRuleName(e.target.value)} />
              <div className="flex gap-2">
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">When USDC balance exceeds</p>
                  <Input type="number" placeholder="1000" value={threshold}
                    onChange={e => setThreshold(e.target.value)} />
                </div>
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">Target currency</p>
                  <select value={targetCcy} onChange={e => setTargetCcy(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {CURRENCIES.map(c => (
                      <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
                    ))}
                  </select>
                </div>
              </div>
              <div>
                <p className="mb-1 text-[10px] text-app-muted">Convert</p>
                <div className="flex gap-2">
                  <div className="flex rounded-lg border border-app-border bg-app-surface">
                    {(['percent','fixed'] as const).map(t => (
                      <button key={t} onClick={() => setActionType(t)}
                        className={`px-3 py-1.5 text-xs transition-colors rounded-lg
                          ${actionType === t ? 'bg-app-accent text-app-on-accent' : 'text-app-muted'}`}>
                        {t === 'percent' ? '%' : 'Fixed'}
                      </button>
                    ))}
                  </div>
                  <Input type="number"
                    placeholder={actionType === 'percent' ? '30 (%)' : 'Amount (USDC)'}
                    value={actionVal} onChange={e => setActionVal(e.target.value)}
                    className="flex-1" />
                </div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" className="flex-1"
                  onClick={() => setShowRuleForm(false)}>Cancel</Button>
                <Button size="sm" className="flex-1" onClick={handleCreateRule}
                  disabled={createRule.isPending || !ruleName || !threshold || !actionVal}>
                  {createRule.isPending ? 'Saving…' : 'Save rule'}
                </Button>
              </div>
            </div>
          )}

          {/* Rules list */}
          {rules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Zap className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No rules yet</p>
              <p className="text-xs text-app-muted">
                Create a rule to be alerted when your balance crosses a threshold
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {rules.map(rule => {
                const amt = getConversionAmount(rule)
                return (
                  <div key={rule.id}
                    className="rounded-xl border border-app-border bg-app-bg p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-app-text truncate">{rule.name}</p>
                          <Badge variant={
                            rule.status === 'triggered' ? 'warning' :
                            rule.status === 'active'    ? 'success'  : 'default'
                          }>
                            {rule.status}
                          </Badge>
                        </div>
                        <p className="mt-0.5 text-xs text-app-muted">
                          When USDC &gt; {rule.trigger_threshold.toLocaleString()} →{' '}
                          convert {rule.action_percent ? `${rule.action_percent}%` : `${rule.action_amount} USDC`} to{' '}
                          {CURRENCY_FLAG[rule.target_currency]} {rule.target_currency}
                        </p>
                        {rule.last_triggered && (
                          <p className="mt-0.5 text-[10px] text-amber-500">
                            Last triggered: {new Date(rule.last_triggered * 1000).toLocaleDateString()}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          onClick={() => toggleRule.mutate({
                            id: rule.id,
                            status: rule.status === 'active' ? 'paused' : 'active',
                          })}
                          className="rounded p-1.5 text-app-muted hover:text-app-text transition-colors"
                          title={rule.status === 'active' ? 'Pause' : 'Activate'}
                        >
                          {rule.status === 'active'
                            ? <Pause className="h-3.5 w-3.5" />
                            : <Play  className="h-3.5 w-3.5" />
                          }
                        </button>
                        <button
                          onClick={() => deleteRule.mutate(rule.id)}
                          className="rounded p-1.5 text-app-muted hover:text-red-400 transition-colors"
                          title="Delete rule"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent payrolls */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Recent payrolls</p>
              <p className="text-xs text-app-muted">Batch USDC payments with Memo references</p>
            </div>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline">
                <Plus className="h-3.5 w-3.5" /> New batch
              </Button>
            </Link>
          </div>

          {batches.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Building2 className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No payrolls yet</p>
              <p className="text-xs text-app-muted">
                Send USDC to multiple wallets in one batch with unique Memo references
              </p>
              <Link href="/treasury/payroll">
                <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-2">
              {batches.slice(0, 6).map(batch => (
                <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                  <div className="flex items-center justify-between rounded-xl border border-app-border bg-app-bg p-3 hover:border-app-accent/40 transition-colors cursor-pointer">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <p className="text-sm font-medium text-app-text truncate">{batch.name}</p>
                        <Badge variant={
                          batch.status === 'completed'  ? 'success' :
                          batch.status === 'processing' ? 'arc'     :
                          batch.status === 'failed'     ? 'danger'  : 'warning'
                        }>
                          {batch.status}
                        </Badge>
                      </div>
                      <p className="text-xs text-app-muted">
                        {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                        · {new Date(batch.created_at * 1000).toLocaleDateString()}
                      </p>
                    </div>
                    <ArrowRight className="h-4 w-4 shrink-0 text-app-muted" />
                  </div>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/treasury/TreasuryContent.tsx"

echo ""
echo "Done. Nothing signs or moves money. Now:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Gateway stages 1-2: config + read-only treasury balance'"
echo "  git push"
echo ""
echo "  ===== TO SEE REAL DATA ====="
echo "  Once your treasury EOA exists, set in VERCEL:"
echo "     NEXT_PUBLIC_TREASURY_ADDRESS=0xYourTreasuryEOA"
echo ""
echo "  Until then the panel explains itself rather than showing an empty box."
echo ""
echo "  I could NOT reach gateway-api-testnet.circle.com from my sandbox"
echo "  (network allowlist), so the balance READER is written defensively"
echo "  against the documented shape. On first real load, if the numbers look"
echo "  wrong, open the browser console and paste me the raw response -- the"
echo "  normaliser is easy to correct once we see the actual JSON."
echo ""
echo "  ===== YOUR TREASURY WALLET ====="
echo "  It must be an EOA (MetaMask-style, NOT a Safe/multisig) because Gateway"
echo "  burn intents cannot be signed by contract accounts. Keep it separate"
echo "  from your personal wallet, and back the seed phrase up offline."
