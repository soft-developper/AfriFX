#!/bin/bash
# ============================================================
# AfriFX GATEWAY -- FIX: the panel showed the WRONG WALLET (you caught this)
#
# Your question "what happens when other users use the treasury dashboard?"
# exposed a real design mistake in what I shipped.
#
# THE MISTAKE
# I built the Gateway panel around a single hardcoded
# NEXT_PUBLIC_TREASURY_ADDRESS -- AfriFX's own company wallet. But /treasury is
# a PER-USER page: it already reads useAccount() and shows the connected user's
# balance, escrow and payroll.
#
# So every user opening /treasury would have seen AFRIFX'S OPERATIONAL BALANCE.
# Confusing for them, and a disclosure of company finances. That's a genuine
# bug, not a cosmetic one.
#
# THE FIX
# The panel now reads the CONNECTED USER'S wallet. Gateway is permissionless and
# non-custodial, so every user can hold their own unified balance keyed to their
# own address. AfriFX's company treasury becomes just another wallet using the
# same feature -- no special casing, no hardcoded address, no leak.
#
# NEXT_PUBLIC_TREASURY_ADDRESS IS NO LONGER NEEDED. If you already set it in
# Vercel you can remove it (harmless either way -- nothing reads it now).
#
# This also makes the feature BETTER: a unified cross-chain USDC balance is
# genuinely useful to your users, not just to you.
#
# Still read-only. Nothing signs, nothing moves.
#
# Run from ~/AfriFX:  bash gateway-per-user-fix.sh
# ============================================================
set -e
echo ""
echo "Fixing Gateway panel to use the connected user's wallet..."
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
  WHOSE balance are we showing?

  /treasury is a PER-USER page (it reads the connected wallet), so the Gateway
  panel must show the CONNECTED USER'S OWN unified balance — never a hardcoded
  company address. An earlier draft of this file used a single
  NEXT_PUBLIC_TREASURY_ADDRESS, which would have shown AfriFX's operational
  balance to every user: confusing, and a disclosure of company finances.

  Gateway is permissionless and non-custodial, so every user can have their own
  unified balance keyed to their own wallet. AfriFX's company treasury is simply
  one more wallet — it isn't special-cased here.
*/
export function isValidAddress(a?: string | null): boolean {
  return !!a && /^0x[a-fA-F0-9]{40}$/.test(a)
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
import { useAccount } from 'wagmi'
import {
  fetchGatewayBalances, gatewayChains, isValidAddress,
  GATEWAY_ENV, gatewayContracts,
} from '@/lib/gateway'

/*
  READ-ONLY view of the CONNECTED USER'S Circle Gateway unified balance.

  Gateway is permissionless and non-custodial, so this is a genuine user
  feature: any AfriFX user can hold one USDC balance spendable across chains.
  AfriFX's own company treasury uses the same feature with its own wallet — it
  is not special-cased.

  Stage 2 of the Gateway work: this panel only LOOKS. It cannot deposit,
  transfer or withdraw — those need a signer and are deliberately not wired up
  yet.
*/
export function GatewayBalancePanel() {
  const [data, setData]       = useState<any>(null)
  const [error, setError]     = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  /*
    The CONNECTED USER'S wallet — not a hardcoded company address. /treasury is
    a per-user page, so each user sees their own unified balance. AfriFX's own
    company treasury is just another wallet using the same feature.
  */
  const { address } = useAccount()
  const addr = isValidAddress(address) ? address : undefined

  const load = useCallback(async () => {
    if (!addr) return
    setLoading(true); setError(null)
    const res = await fetchGatewayBalances(addr)
    if ('error' in res) setError(res.error)
    else setData(res)
    setLoading(false)
  }, [addr])

  useEffect(() => { load() }, [load])

  // No wallet connected — explain rather than render an empty box.
  if (!addr) {
    return (
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <h3 className="mb-1 flex items-center gap-2 text-sm font-semibold text-app-text">
          <Layers className="h-4 w-4 text-app-accent-text" /> Unified balance
        </h3>
        <p className="text-xs leading-relaxed text-app-muted">
          Connect your wallet to see your Circle Gateway balance — a single USDC
          balance you can spend on any supported chain, without bridging first.
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
          If Circle&apos;s API is ever unavailable, withdrawing takes 7 days. Keep
          only working capital here, not everything you hold.
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

echo ""
echo "Done. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Fix: Gateway panel uses connected user wallet'"
echo "  git push"
echo ""
echo "  After deploy, open /treasury with a wallet connected -- the panel shows"
echo "  THAT wallet's Gateway balance. Connect a different wallet and it changes."
echo ""
echo "  You can delete NEXT_PUBLIC_TREASURY_ADDRESS from Vercel; nothing uses it."
