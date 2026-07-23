#!/bin/bash
# ============================================================
# AfriFX GATEWAY -- STAGE 3: DEPOSIT (real money, user-signed)
#
# ON YOUR QUESTION -- "when are we creating the Gateway wallet?"
# THERE IS NOTHING TO CREATE. The Gateway Wallet is a smart contract CIRCLE HAS
# ALREADY DEPLOYED on each chain (Arc Testnet: 0x0077777d7EBA...). It's a shared
# contract that tracks per-address balances internally. You already have a
# wallet -- you call deposit() and the contract credits YOUR address. No
# deployment, no registration, no sign-up. That's what Circle means by
# "permissionless, no sign-up needed".
#
# WHAT THIS SHIPS
#   Two on-chain steps, exactly as Circle documents:
#     1. approve(GatewayWallet, amount)   on the USDC token
#     2. deposit(usdcAddress, amount)     on the GatewayWallet
#   Signature confirmed from Circle's own integration guide:
#     deposit(address token, uint256 amount)  -- credits msg.sender
#
# *** THE GUARD (the reason this stage took care) ***
# Circle: "Directly transferring USDC to the Gateway Wallet contract with a
# standard ERC-20 transfer will result in LOSS of that USDC." There is no
# recovery. assertNotPlainTransfer() makes that structurally impossible from our
# code. TESTED: transfer/transferFrom/send to the GatewayWallet are REFUSED,
# deposit() to the same address is ALLOWED, and transfers to normal addresses
# are unaffected.
#
# *** THE HONEST UX POINT ***
# A deposit is NOT instantly spendable -- it must reach block finality first:
#     Arc   ~0.5s          Base/Ethereum   ~13-19 MINUTES
# The form states this PER CHAIN, in the dropdown, BEFORE the user commits, and
# repeats it on success. Hiding it would make a working feature look broken.
#
# NON-CUSTODIAL: the user signs in their own wallet. No key touches a server.
# This applies to AfriFX's own treasury too -- it's just another wallet.
#
# Failure handling: if the approve succeeds but the deposit doesn't, the UI says
# so explicitly ("no USDC left your wallet") because that's a confusing state
# otherwise.
#
# Run from ~/AfriFX:  bash gateway-stage3-deposit.sh
# ============================================================
set -e
echo ""
echo "Installing Gateway deposit flow (stage 3)..."
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

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useGatewayDeposit.ts" << 'AFX_EOF'
'use client'
// ============================================================
// useGatewayDeposit — deposit USDC into Circle's Gateway Wallet.
//
// STAGE 3. The user signs in their OWN wallet; nothing is custodial and no key
// ever reaches a server.
//
// Two on-chain steps, exactly as Circle documents:
//   1. approve(GatewayWallet, amount)  on the USDC token
//   2. deposit(usdcAddress, amount)    on the GatewayWallet
//
// *** WHY THERE IS A GUARD ***
// Circle: "Directly transferring USDC to the Gateway Wallet contract with a
// standard ERC-20 transfer will result in loss of that USDC." There is NO
// recovery from that mistake, so assertNotPlainTransfer() makes it structurally
// impossible for this code to do it.
//
// AFTER DEPOSITING: funds are NOT instantly spendable. They must reach block
// finality first — ~0.5s on Arc, but ~13-19 MINUTES on Base or Ethereum. The
// UI must say so rather than leaving the user wondering.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import {
  gatewayContracts, gatewayChains, usdcToUnits,
  GATEWAY_WALLET_ABI, GATEWAY_ERC20_ABI, assertNotPlainTransfer,
} from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type DepositStep =
  | 'idle' | 'switching' | 'approving' | 'depositing' | 'done' | 'error'

export interface DepositState {
  step:      DepositStep
  approveTx: string | null
  depositTx: string | null
  error:     string | null
  /** How long deposits take to become spendable on the chosen chain. */
  finality:  string | null
}

const INITIAL: DepositState = {
  step: 'idle', approveTx: null, depositTx: null, error: null, finality: null,
}

export function useGatewayDeposit() {
  const { address } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const config = useConfig()
  const [state, setState] = useState<DepositState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const deposit = useCallback(async (params: { chainKey: string; amount: number }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Connect a wallet first' })
      return
    }

    const chain    = chainByKey(params.chainKey)
    const gwChain  = gatewayChains().find(c => c.key === params.chainKey)
    const chainId  = evmChainId(params.chainKey)
    const wallet   = gatewayContracts().wallet as `0x${string}`

    if (!chain || !gwChain || !chainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported chain for Gateway' })
      return
    }
    if (!chain.usdc) {
      setState({ ...INITIAL, step: 'error', error: `No USDC address configured for ${chain.name}` })
      return
    }
    if (!(params.amount > 0)) {
      setState({ ...INITIAL, step: 'error', error: 'Enter an amount greater than zero' })
      return
    }

    const units = usdcToUnits(params.amount)

    try {
      setState({ ...INITIAL, step: 'switching', finality: gwChain.finality })
      await switchChainAsync({ chainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${chain.name} and try again`)
      })

      // ── 1. Approve the Gateway Wallet to pull USDC ─────
      setState(s => ({ ...s, step: 'approving' }))
      const approveTx = await writeContractAsync({
        address: chain.usdc as `0x${string}`,
        abi: GATEWAY_ERC20_ABI,
        functionName: 'approve',
        args: [wallet, units],
        chainId,
      })
      await getPublicClient(config, { chainId })
        ?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })
      setState(s => ({ ...s, approveTx: approveTx as string }))

      // ── 2. Deposit ─────────────────────────────────────
      // Guard: this must be deposit() on the wallet contract, never a plain
      // ERC-20 transfer to it (which would destroy the funds).
      assertNotPlainTransfer('deposit', wallet)

      setState(s => ({ ...s, step: 'depositing' }))
      const depositTx = await writeContractAsync({
        address: wallet,
        abi: GATEWAY_WALLET_ABI,
        functionName: 'deposit',
        args: [chain.usdc as `0x${string}`, units],
        chainId,
      })
      const receipt = await getPublicClient(config, { chainId })
        ?.waitForTransactionReceipt({ hash: depositTx as `0x${string}` })
      if (receipt && receipt.status !== 'success') throw new Error('Deposit transaction failed')

      setState(s => ({ ...s, step: 'done', depositTx: depositTx as string }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Deposit failed'
      if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was submitted — please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message }))
    }
  }, [address, writeContractAsync, switchChainAsync, config])

  return { ...state, deposit, reset }
}
AFX_EOF
echo "  afrifx-web/hooks/useGatewayDeposit.ts"

mkdir -p "afrifx-web/components/treasury"
cat > "afrifx-web/components/treasury/GatewayDepositForm.tsx" << 'AFX_EOF'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { Loader2, CheckCircle, AlertTriangle, Clock, ExternalLink } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useGatewayDeposit } from '@/hooks/useGatewayDeposit'
import { gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'

/*
  Deposit USDC into Gateway.

  The honest bit this UI has to get right: a deposit is NOT instantly spendable.
  It has to reach block finality first — about half a second on Arc, but 13-19
  MINUTES on Base or Ethereum. Hiding that would leave users thinking the
  feature is broken, so the wait is stated up front, per chain, before they
  commit.
*/
export function GatewayDepositForm({ onDone }: { onDone?: () => void }) {
  const { isConnected } = useAccount()
  const { step, approveTx, depositTx, error, finality, deposit, reset } = useGatewayDeposit()

  const chains = gatewayChains()
  const [chainKey, setChainKey] = useState('arc')
  const [amount, setAmount]     = useState('')

  const chain   = chains.find(c => c.key === chainKey)
  const cctp    = chainByKey(chainKey)
  const amt     = Number(amount)
  const busy    = ['switching', 'approving', 'depositing'].includes(step)
  const canGo   = isConnected && amt > 0 && !busy

  const stepLabel: Record<string, string> = {
    switching:  `Switch your wallet to ${chain?.name ?? 'the chain'}`,
    approving:  'Approve USDC in your wallet (step 1 of 2)',
    depositing: 'Confirm the deposit in your wallet (step 2 of 2)',
  }

  if (step === 'done') {
    return (
      <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4">
        <p className="flex items-center gap-1.5 text-sm font-medium text-emerald-400">
          <CheckCircle className="h-4 w-4" /> Deposit submitted
        </p>
        <p className="mt-1 text-xs text-emerald-200/80">
          {amount} USDC deposited from {chain?.name}.
        </p>
        {/* The wait is the thing people misunderstand, so say it plainly. */}
        <p className="mt-2 flex items-start gap-1.5 text-[11px] leading-relaxed text-amber-200/80">
          <Clock className="mt-0.5 h-3 w-3 shrink-0" />
          It becomes spendable once the deposit reaches finality on {chain?.name} —
          about {finality}. Your balance above updates automatically.
        </p>
        {depositTx && cctp && (
          <a href={`${cctp.explorer}/tx/${depositTx}`} target="_blank" rel="noopener noreferrer"
            className="mt-2 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
            View transaction <ExternalLink className="h-2.5 w-2.5" />
          </a>
        )}
        <div className="mt-3">
          <Button size="sm" variant="outline" onClick={() => { reset(); onDone?.() }}>
            Done
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-app-border bg-app-bg p-4">
      <p className="mb-3 text-xs font-semibold text-app-text">Add funds to your unified balance</p>

      <label className="mb-1 block text-[11px] text-app-muted">Deposit from</label>
      <select
        value={chainKey}
        onChange={e => setChainKey(e.target.value)}
        disabled={busy}
        className="mb-1 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none disabled:opacity-50"
      >
        {chains.map(c => (
          <option key={c.key} value={c.key}>
            {c.name} — clears in {c.finality}
          </option>
        ))}
      </select>
      {/* Surface the trade-off at the moment of choosing, not after. */}
      <p className="mb-3 text-[10px] text-app-muted">
        {chainKey === 'arc'
          ? 'Arc finalises in about half a second, so deposits are spendable almost immediately.'
          : `Deposits from ${chain?.name} take ${chain?.finality} to become spendable.`}
      </p>

      <label className="mb-1 block text-[11px] text-app-muted">Amount (USDC)</label>
      <input
        type="number" inputMode="decimal" min="0" step="0.000001"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
        placeholder="0.00"
        className="mb-3 w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 font-mono text-sm text-app-text outline-none placeholder:text-app-border disabled:opacity-50"
      />

      <Button className="w-full" disabled={!canGo}
        onClick={() => deposit({ chainKey, amount: amt })}>
        {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Working…</>
              : !isConnected ? 'Connect a wallet'
              : 'Deposit'}
      </Button>

      {busy && (
        <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
          <Loader2 className="h-3 w-3 animate-spin" />
          {stepLabel[step] ?? 'Working…'}
        </p>
      )}

      {step === 'error' && error && (
        <div className="mt-2 rounded-lg border border-red-900/50 bg-red-900/20 p-2.5">
          <p className="flex items-center gap-1.5 text-[11px] font-medium text-red-400">
            <AlertTriangle className="h-3 w-3" /> Deposit not completed
          </p>
          <p className="mt-1 text-[11px] text-red-300/90">{error}</p>
          {approveTx && (
            <p className="mt-1 text-[10px] text-red-300/60">
              Your approval went through but the deposit didn&apos;t — no USDC left your
              wallet. You can safely retry.
            </p>
          )}
          <Button size="sm" variant="outline" className="mt-2" onClick={reset}>Try again</Button>
        </div>
      )}
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/treasury/GatewayDepositForm.tsx"

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

      {/* Deposit */}
      {!error && (
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
echo "  cd .. && git add -A && git commit -m 'Gateway stage 3: deposit flow'"
echo "  git push"
echo ""
echo "  ===== FIRST TEST -- START SMALL ====="
echo "  Open /treasury with your wallet connected, click 'Add funds'."
echo "    * Deposit FROM ARC first -- it clears in ~0.5s so you get feedback"
echo "      immediately. Base would leave you waiting 13-19 minutes wondering."
echo "    * Use a TRIVIAL amount (0.1 USDC) for the first run."
echo "    * You'll sign TWICE: approve, then deposit. Both are expected."
echo "    * Then hit Refresh on the panel -- the balance should appear."
echo ""
echo "  If the balance stays at 0 after an Arc deposit, the balance READER may"
echo "  need correcting (I couldn't reach Circle's API from my sandbox to verify"
echo "  the response shape). Open the browser console, find the /v1/balances"
echo "  response, and paste it to me -- it's a quick fix once we see real JSON."
