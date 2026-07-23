#!/bin/bash
# ============================================================
# AfriFX GATEWAY -- FIX: "Gateway API 404" + missing deposit button
#
# TWO BUGS, and the first caused the second.
#
# *** BUG 1: I CALLED THE WRONG KIND OF REQUEST ***
# I wrote  GET /v1/balances?token=USDC&depositor=0x...
# Circle's API reference is explicit that it's a POST taking a `sources` array:
#     POST /v1/balances
#     { "token": "USDC",
#       "sources": [ { "domain": 26, "depositor": "0x..." }, ... ] }
# Hence the 404 -- the GET route simply doesn't exist. Now fixed, and the
# response is parsed against the DOCUMENTED shape
# ({ token, balances: [{ domain, depositor, balance }] }) rather than my earlier
# guesswork. Error messages now include the API's own response text, so a future
# failure says WHY instead of just a status code.
#
# *** BUG 2: THE DEPOSIT BUTTON WAS HIDDEN BY THE ERROR ***
# I gated the deposit UI behind `!error`. So one failed balance READ made the
# entire deposit feature vanish -- which is why you couldn't see it. That gating
# was simply wrong: being unable to READ your balance is no reason to prevent
# you DEPOSITING.
# Now the read failure renders as a NOTICE ABOVE the balance, and the rest of
# the panel -- including "Add funds" -- stays usable.
#
# Lesson worth keeping: don't let a read failure disable a write path. They're
# independent, and coupling them turns a minor API hiccup into a missing feature.
#
# Run from ~/AfriFX:  bash gateway-balances-api-fix.sh
# ============================================================
set -e
echo ""
echo "Fixing the Gateway balances request + deposit visibility..."
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
    const chains = gatewayChains(env)

    /*
      POST, not GET.

      An earlier version called GET /v1/balances?depositor=... and got a 404.
      Circle's API reference is explicit: /v1/balances is a POST that takes a
      `sources` array of { domain, depositor } pairs — one per chain you want
      balances for — plus the token.

      Response shape (from the reference):
        { token: "USDC", balances: [ { domain, depositor, balance }, ... ] }
    */
    const res = await fetch(`${gatewayApi(env)}/balances`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        token: 'USDC',
        sources: chains.map(c => ({ domain: c.domain, depositor: address })),
      }),
    })

    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      return { error: `Gateway API ${res.status}${detail ? `: ${detail.slice(0, 140)}` : ''}` }
    }

    const data: any = await res.json()
    const entries: any[] = Array.isArray(data?.balances) ? data.balances : []

    const perChain = chains.map(c => {
      const hit = entries.find((e: any) => Number(e?.domain) === c.domain)
      return {
        key: c.key, name: c.name, domain: c.domain, finality: c.finality,
        amount: Number(hit?.balance ?? 0) || 0,
      }
    })

    return {
      token: 'USDC',
      total: perChain.reduce((sum, c) => sum + c.amount, 0),
      perChain,
      raw: data,
    }
  } catch (err: any) {
    return { error: err?.message ?? 'Could not reach the Gateway API' }
  }
}

// ── Deposit (stage 3) ───────────────────────────────────────

/*
  GatewayWallet ABI — only the pieces we call.

  Signature confirmed from Circle's own integration guide:
      deposit(address token, uint256 amount)
  The resulting balance belongs to the FUNCTION CALLER, which is what we want:
  the connected user deposits for themselves.
*/
export const GATEWAY_WALLET_ABI = [
  {
    type: 'function', name: 'deposit', stateMutability: 'nonpayable',
    inputs: [
      { name: 'token',  type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    // Deposit crediting SOMEONE ELSE's balance. Not used by the UI, but
    // included so the ABI is complete and the difference is documented:
    // `deposit` credits msg.sender, `depositFor` credits `depositor`.
    type: 'function', name: 'depositFor', stateMutability: 'nonpayable',
    inputs: [
      { name: 'token',     type: 'address' },
      { name: 'depositor', type: 'address' },
      { name: 'amount',    type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function', name: 'availableBalance', stateMutability: 'view',
    inputs: [
      { name: 'token',     type: 'address' },
      { name: 'depositor', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export const GATEWAY_ERC20_ABI = [
  {
    type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'allowance', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

/*
  *** THE MOST DANGEROUS MISTAKE IN GATEWAY ***

  Circle's docs: "Directly transferring USDC to the Gateway Wallet contract with
  a standard ERC-20 transfer will result in loss of that USDC."

  There is no recovery. So this guard exists to make that mistake structurally
  impossible from our code: any call that would send USDC to the GatewayWallet
  via `transfer` is rejected before it can be signed.

  Deposits MUST go through the wallet contract's deposit() method, which is what
  useGatewayDeposit does.
*/
export function assertNotPlainTransfer(fnName: string, to: string, env: GatewayEnv = GATEWAY_ENV) {
  const wallet = gatewayContracts(env).wallet.toLowerCase()
  if (to.toLowerCase() === wallet && /^(transfer|transferFrom|send)$/i.test(fnName)) {
    throw new Error(
      'Refusing to send USDC directly to the Gateway Wallet — a plain ERC-20 ' +
      'transfer to that contract permanently destroys the funds. Use deposit() instead.',
    )
  }
}

// USDC is 6 decimals on every Gateway chain.
export function usdcToUnits(amount: number): bigint {
  const [whole, frac = ''] = String(amount).split('.')
  const padded = (frac + '000000').slice(0, 6)
  return BigInt(whole || '0') * BigInt(1000000) + BigInt(padded || '0')
}
AFX_EOF
echo "  afrifx-web/lib/gateway.ts"

mkdir -p "afrifx-web/components/treasury"
cat > "afrifx-web/components/treasury/GatewayBalancePanel.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Info, ExternalLink, Plus } from 'lucide-react'
import { GatewayDepositForm } from './GatewayDepositForm'
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
  const [showDeposit, setShowDeposit] = useState(false)
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

      {/* A read failure is shown as a NOTICE above the balance, not instead of
          it — the rest of the panel (and the deposit button) stays usable. */}
      {error && (
        <div className="mb-3 rounded-lg border border-amber-700/40 bg-amber-900/10 p-3">
          <p className="flex items-center gap-1.5 text-xs text-amber-400">
            <AlertCircle className="h-3.5 w-3.5" /> Couldn&apos;t read your Gateway balance
          </p>
          <p className="mt-1 text-[11px] text-amber-200/80">{error}</p>
          <p className="mt-1 text-[11px] text-amber-200/60">
            Read-only problem — no funds are affected, and you can still deposit.
          </p>
        </div>
      )}

      {(
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

      {/* Deposit — deliberately NOT gated on the balance read succeeding.
          Failing to READ your balance is no reason to prevent you DEPOSITING;
          an earlier version hid this button behind !error, which meant one API
          hiccup made the whole feature look absent. */}
      {(
        <div className="mt-4">
          {showDeposit ? (
            <GatewayDepositForm onDone={() => { setShowDeposit(false); load() }} />
          ) : (
            <button
              onClick={() => setShowDeposit(true)}
              className="flex w-full items-center justify-center gap-1.5 rounded-lg border border-dashed border-app-border py-2 text-xs text-app-muted hover:border-app-accent hover:text-app-text"
            >
              <Plus className="h-3.5 w-3.5" /> Add funds
            </button>
          )}
        </div>
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
echo "  cd .. && git add -A && git commit -m 'Fix: Gateway balances POST + deposit visibility'"
echo "  git push"
echo ""
echo "  After deploy, open /treasury with your wallet connected:"
echo "    * the 404 should be gone (balance likely 0.00 until you deposit)"
echo "    * 'Add funds' should now be visible"
echo ""
echo "  Then deposit 0.1 USDC FROM ARC (clears in ~0.5s). You'll sign twice:"
echo "  approve, then deposit. Hit Refresh and the balance should appear."
echo ""
echo "  If it still errors, the message now includes Circle's own response --"
echo "  paste it here and I can fix it precisely."
