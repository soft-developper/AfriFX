#!/bin/bash
# ============================================================
# AfriFX -- SEND becomes multi-chain, powered by the Gateway balance
#
# Your idea, and a better one than mine: rather than a SECOND "send" for
# Gateway, the existing Send now picks a destination chain and routes itself.
# Users never have to learn what Gateway is.
#
# *** SMART ROUTING (option B) ***
#   Arc -> Arc      : plain wallet transfer, exactly as Send always worked.
#                     Instant, and it does NOT consume the unified balance.
#   Arc -> anywhere : spends the unified Gateway balance.
# The balance shown switches to match the route, so "Max" and the insufficient-
# funds check always refer to the right pot.
#
# THE CROSS-CHAIN FLOW (per Circle's technical guide, field-for-field):
#   1. build TransferSpec + BurnIntent
#   2. sign as EIP-712 (off-chain, no gas)
#   3. POST /v1/transfer  -> attestation + signature
#   4. gatewayMint() on the destination chain
# Step 3 is the <500ms part, because finality was paid for at deposit time.
#
# *** THE RISK WE AGREED TO TEST RATHER THAN PRE-EMPT ***
# Circle: "SCA signatures such as EIP-1271 signatures can't be accepted. Burn
# intents must be signed by an EOA." If Web3Auth gives your users a SMART
# ACCOUNT, cross-chain send will fail at the signing step.
# So the hook DETECTS that specific failure and says plainly that the wallet
# type isn't supported -- and notes that same-chain Arc sends still work -- 
# rather than surfacing a cryptic signature error. We'll know on first test.
#
# ALSO IN THIS SCRIPT (the tidy you asked for):
#   * per-chain balance list is COLLAPSIBLE, collapsed by default
#   * removed the operator-facing footer (finality explainer, 7-day warning,
#     docs link, "testnet, wallet 0x0077..."). The finality note still appears
#     in the DEPOSIT FORM, where it actually affects a decision.
#
# Run from ~/AfriFX:  bash send-multichain-gateway.sh
# ============================================================
set -e
echo ""
echo "Making Send multi-chain via Gateway..."
echo ""

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useGatewaySend.ts" << 'AFX_EOF'
'use client'
// ============================================================
// useGatewaySend — spend the unified balance on any supported chain.
//
// THE FLOW (per Circle's technical guide):
//   1. Build a TransferSpec + BurnIntent describing the transfer
//   2. Sign it as EIP-712 typed data with the user's EOA (off-chain, no gas)
//   3. POST to /v1/transfer -> Circle returns an attestation + signature
//   4. Call gatewayMint() on the GatewayMinter on the DESTINATION chain
//
// Step 3 is the fast part (<500ms) because finality was already paid for at
// deposit time. That's the whole point of Gateway.
//
// *** CONSTRAINTS THAT SHAPE THIS CODE ***
//   * ONLY EOA SIGNATURES. Circle: "SCA signatures such as EIP-1271 signatures
//     can't be accepted. Burn intents must be signed by an EOA." If the user's
//     wallet is a smart account, this will fail at the signing step — we detect
//     that and say so plainly rather than showing a cryptic error.
//   * ATTESTATIONS EXPIRE AFTER 10 MINUTES, so the mint must follow promptly.
//   * maxBlockHeight must be far enough ahead to exceed the wallet's
//     withdrawalDelay, so we read the current block and add a generous buffer.
//   * Same-chain transfers ARE supported and still mint-and-burn — but for
//     Arc->Arc we don't use Gateway at all (see useSmartSend), because a plain
//     wallet transfer is instant and doesn't consume the unified balance.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useSignTypedData, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { gatewayApi, gatewayContracts, gatewayChains, usdcToUnits } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type SendStep =
  | 'idle' | 'signing' | 'requesting' | 'switching' | 'minting' | 'done' | 'error'

export interface GatewaySendState {
  step:    SendStep
  mintTx:  string | null
  error:   string | null
  /** True when the failure is "your wallet can't sign for Gateway". */
  needsEoa: boolean
}

const INITIAL: GatewaySendState = {
  step: 'idle', mintTx: null, error: null, needsEoa: false,
}

// GatewayMinter — only the method we call.
const GATEWAY_MINTER_ABI = [
  {
    type: 'function', name: 'gatewayMint', stateMutability: 'nonpayable',
    inputs: [
      { name: 'attestationPayload', type: 'bytes' },
      { name: 'signature',          type: 'bytes' },
    ],
    outputs: [],
  },
] as const

// EIP-712 types, mirroring Circle's TransferSpec / BurnIntent structs.
const EIP712_TYPES = {
  TransferSpec: [
    { name: 'version',              type: 'uint32'  },
    { name: 'sourceDomain',         type: 'uint32'  },
    { name: 'destinationDomain',    type: 'uint32'  },
    { name: 'sourceContract',       type: 'bytes32' },
    { name: 'destinationContract',  type: 'bytes32' },
    { name: 'sourceToken',          type: 'bytes32' },
    { name: 'destinationToken',     type: 'bytes32' },
    { name: 'sourceDepositor',      type: 'bytes32' },
    { name: 'destinationRecipient', type: 'bytes32' },
    { name: 'sourceSigner',         type: 'bytes32' },
    { name: 'destinationCaller',    type: 'bytes32' },
    { name: 'value',                type: 'uint256' },
    { name: 'salt',                 type: 'bytes32' },
    { name: 'hookData',             type: 'bytes'   },
  ],
  BurnIntent: [
    { name: 'maxBlockHeight', type: 'uint256' },
    { name: 'maxFee',         type: 'uint256' },
    { name: 'spec',           type: 'TransferSpec' },
  ],
} as const

const ZERO32 = `0x${'0'.repeat(64)}` as const

function toBytes32(addr: string): `0x${string}` {
  return `0x${'0'.repeat(24)}${addr.toLowerCase().replace(/^0x/, '')}` as `0x${string}`
}

function randomSalt(): `0x${string}` {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return `0x${Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')}` as `0x${string}`
}

export function useGatewaySend() {
  const { address } = useAccount()
  const { signTypedDataAsync } = useSignTypedData()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const config = useConfig()
  const [state, setState] = useState<GatewaySendState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const send = useCallback(async (params: {
    fromKey: string       // which chain's Gateway balance to spend
    toKey:   string       // destination chain
    amount:  number
    recipient: string
  }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Connect a wallet first' })
      return
    }

    const src = gatewayChains().find(c => c.key === params.fromKey)
    const dst = gatewayChains().find(c => c.key === params.toKey)
    const srcCctp = chainByKey(params.fromKey)
    const dstCctp = chainByKey(params.toKey)
    const dstChainId = evmChainId(params.toKey)

    if (!src || !dst || !srcCctp || !dstCctp || !dstChainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported route' })
      return
    }

    const contracts = gatewayContracts()
    const value = usdcToUnits(params.amount)

    try {
      // ── 1. Build the burn intent ───────────────────────
      setState({ ...INITIAL, step: 'signing' })

      // maxBlockHeight must clear the wallet's withdrawalDelay. We read the
      // source chain's current height and add a large buffer.
      const srcChainId = evmChainId(params.fromKey)
      const srcClient  = srcChainId ? getPublicClient(config, { chainId: srcChainId }) : null
      const head = srcClient ? await srcClient.getBlockNumber() : BigInt(0)
      const maxBlockHeight = head + BigInt(1_000_000)

      const spec = {
        version: 1,
        sourceDomain:         src.domain,
        destinationDomain:    dst.domain,
        sourceContract:       toBytes32(contracts.wallet),
        destinationContract:  toBytes32(contracts.minter),
        sourceToken:          toBytes32(srcCctp.usdc),
        destinationToken:     toBytes32(dstCctp.usdc),
        sourceDepositor:      toBytes32(address),
        destinationRecipient: toBytes32(params.recipient),
        sourceSigner:         toBytes32(address),
        // 0 = any caller may use the attestation, so the mint isn't locked to
        // one sender. We're not composing this with other on-chain actions.
        destinationCaller:    ZERO32,
        value,
        salt: randomSalt(),
        hookData: '0x' as `0x${string}`,
      }

      const intent = {
        maxBlockHeight,
        // Circle's fee must be covered; a generous ceiling avoids a rejected
        // request, and the actual fee charged is far lower.
        maxFee: usdcToUnits(Math.max(0.01, params.amount * 0.001)),
        spec,
      }

      // ── 2. Sign as EIP-712 (EOA only) ──────────────────
      let signature: string
      try {
        signature = await signTypedDataAsync({
          domain: { name: 'GatewayWallet', version: '1' },
          types: EIP712_TYPES as any,
          primaryType: 'BurnIntent',
          message: intent as any,
        })
      } catch (sigErr: any) {
        const m = String(sigErr?.message ?? '')
        // A smart contract account can't produce the ECDSA signature Gateway
        // requires. Say that clearly instead of surfacing a raw wallet error.
        if (/1271|smart account|not supported|unsupported/i.test(m)) {
          setState({
            ...INITIAL, step: 'error', needsEoa: true,
            error: 'This wallet can\'t sign Gateway transfers. Gateway requires a ' +
                   'standard wallet (EOA) — smart contract accounts aren\'t supported.',
          })
          return
        }
        throw sigErr
      }

      // ── 3. Request the attestation ─────────────────────
      setState(s => ({ ...s, step: 'requesting' }))
      const res = await fetch(`${gatewayApi()}/transfer`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify([{
          burnIntent: {
            maxBlockHeight: maxBlockHeight.toString(),
            maxFee: intent.maxFee.toString(),
            spec: { ...spec, value: value.toString() },
          },
          signature,
        }]),
      })

      if (!res.ok) {
        const detail = await res.text().catch(() => '')
        throw new Error(`Gateway transfer rejected (${res.status})${detail ? `: ${detail.slice(0, 200)}` : ''}`)
      }
      const data: any = await res.json()
      const attestation = data?.attestation ?? data?.attestations?.[0]?.attestation
      const attSig      = data?.signature   ?? data?.attestations?.[0]?.signature
      if (!attestation || !attSig) {
        throw new Error('Gateway did not return an attestation. Please try again.')
      }

      // ── 4. Mint on the destination chain ───────────────
      setState(s => ({ ...s, step: 'switching' }))
      await switchChainAsync({ chainId: dstChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${dst.name} to complete the transfer`)
      })

      setState(s => ({ ...s, step: 'minting' }))
      const mintTx = await writeContractAsync({
        address: contracts.minter as `0x${string}`,
        abi: GATEWAY_MINTER_ABI,
        functionName: 'gatewayMint',
        args: [attestation as `0x${string}`, attSig as `0x${string}`],
        chainId: dstChainId,
      })
      await getPublicClient(config, { chainId: dstChainId })
        ?.waitForTransactionReceipt({ hash: mintTx as `0x${string}` })

      setState(s => ({ ...s, step: 'done', mintTx: mintTx as string }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Transfer failed'
      if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was transferred — please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message }))
    }
  }, [address, signTypedDataAsync, writeContractAsync, switchChainAsync, config])

  return { ...state, send, reset }
}
AFX_EOF
echo "  afrifx-web/hooks/useGatewaySend.ts"

mkdir -p "afrifx-web/app/(app)/send"
cat > "afrifx-web/app/(app)/send/page.tsx" << 'AFX_EOF'
'use client'
import { SectionGuard } from '@/components/layout/SectionGuard'
import { useState, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useWalletReady } from '@/hooks/useWalletReady'
import { isAddress, parseUnits } from 'viem'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useGatewaySend } from '@/hooks/useGatewaySend'
import { fetchGatewayBalances, gatewayChains } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { AlertCircle, CheckCircle, Loader2, Zap, Layers, ExternalLink } from 'lucide-react'

const HOME = 'arc'

function SendPageInner() {
  const { address, isConnected }  = useAccount()
  const { ready: walletReady }    = useWalletReady()
  const [to,      setTo]          = useState('')
  const [amount,  setAmount]      = useState('')
  const [destKey, setDestKey]     = useState(HOME)

  // Wallet balance on Arc (what Send has always used).
  const { formatted: balance, rawBalance } = useUSDCBalance()
  const { writeContractAsync, isPending }  = useWriteContract()
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const { isSuccess }       = useWaitForTransactionReceipt({ hash: txHash })

  // Unified Gateway balance, for cross-chain sends.
  const gw = useGatewaySend()
  const [gwTotal,  setGwTotal]  = useState(0)
  const [gwByChain, setGwByChain] = useState<any[]>([])

  useEffect(() => {
    if (!address) return
    fetchGatewayBalances(address).then(res => {
      if ('error' in res) return
      setGwTotal(res.total)
      setGwByChain(res.perChain)
    })
  }, [address, gw.step])

  /*
    SMART ROUTING — the user picks a destination, not a mechanism.
      same chain (Arc -> Arc)  : plain wallet transfer. Instant, no Gateway
                                 balance consumed, and it's what Send always did.
      cross-chain              : spend the unified Gateway balance.
    This keeps existing behaviour intact while making other chains possible.
  */
  const isCrossChain = destKey !== HOME
  const dest    = gatewayChains().find(c => c.key === destKey)
  const destCctp = chainByKey(destKey)

  // Which balance applies to the current route?
  const availableNum = isCrossChain ? gwTotal : (parseFloat(balance) || 0)
  const availableStr = isCrossChain ? gwTotal.toFixed(2) : balance

  const amountNum        = parseFloat(amount) || 0
  const insufficientFunds = amountNum > 0 && amountNum > availableNum
  const validAddress     = isAddress(to)
  const validAmount      = amountNum > 0 && !insufficientFunds
  const valid            = validAddress && validAmount

  // For a cross-chain send we spend from whichever chain holds the balance.
  const sourceKey = gwByChain.find(c => c.amount >= amountNum)?.key ?? HOME

  const busy = isPending || ['signing','requesting','switching','minting'].includes(gw.step)

  function setMax() { setAmount(availableNum.toFixed(6)) }

  async function handleSend() {
    if (!valid) return

    if (isCrossChain) {
      await gw.send({ fromKey: sourceKey, toKey: destKey, amount: amountNum, recipient: to })
      return
    }

    const hash = await writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [to as `0x${string}`, parseUnits(amount, USDC_DECIMALS)],
    })
    setTxHash(hash)
    setTo(''); setAmount('')
  }

  const gwLabel: Record<string, string> = {
    signing:    'Sign the transfer in your wallet',
    requesting: 'Getting approval from Circle…',
    switching:  `Switch your wallet to ${dest?.name ?? 'the destination'}`,
    minting:    'Confirm the final step in your wallet',
  }

  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any supported chain. Cross-chain sends use your unified balance.
        </p>
      </div>

      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
        {/* Destination chain */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Send to chain
          </label>
          <select
            value={destKey}
            onChange={e => setDestKey(e.target.value)}
            disabled={busy}
            className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50"
          >
            {gatewayChains().map(c => (
              <option key={c.key} value={c.key}>{c.name}</option>
            ))}
          </select>
        </div>

        {/* Balance — which one depends on the route */}
        <div className="mb-4 flex items-center justify-between text-xs">
          <span className="flex items-center gap-1.5 text-app-muted">
            {isCrossChain ? <><Layers className="h-3 w-3" /> Unified balance</> : 'Wallet balance'}
          </span>
          <span className="font-mono text-app-text">{availableStr} USDC</span>
        </div>

        {isCrossChain && gwTotal === 0 && (
          <div className="mb-3 rounded-lg bg-amber-900/20 px-3 py-2 text-[11px] text-amber-300">
            Cross-chain sends spend your unified balance, which is empty. Add funds
            from the Treasury page first.
          </div>
        )}

        {/* Recipient */}
        <div className="mb-3 space-y-2">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Recipient address
          </label>
          <Input
            placeholder="0x…"
            value={to}
            onChange={e => setTo(e.target.value)}
            className={`font-mono ${to && !validAddress ? 'border-red-500/50' : ''}`}
          />
          {to && !validAddress && (
            <p className="text-xs text-red-400">Invalid wallet address</p>
          )}
        </div>

        {/* Amount */}
        <div className="mb-4 space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Amount (USDC)
            </label>
            <button onClick={setMax} className="text-xs text-app-accent-text hover:underline">
              Max
            </button>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className={`font-mono text-lg ${insufficientFunds ? 'border-red-500/50' : ''}`}
          />

          {insufficientFunds && (
            <div className="flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance, you only have {availableStr} USDC
            </div>
          )}

          {validAmount && amountNum > 0 && (
            <p className="text-xs text-emerald-400">
              Remaining after send: {(availableNum - amountNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Route info */}
        <div className="mb-4 space-y-1.5 border-t border-app-border pt-3">
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Network fee</span>
            <Badge variant="arc"><Zap className="h-2.5 w-2.5" /> ~$0.001</Badge>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-app-muted">Route</span>
            <span className="text-app-text">
              {isCrossChain ? `Unified balance → ${dest?.name}` : 'Arc Testnet · direct'}
            </span>
          </div>
        </div>

        <Button className="w-full" size="lg" onClick={handleSend}
          disabled={!isConnected || !walletReady || !valid || busy || insufficientFunds}>
          {busy
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</>
            : !walletReady && isConnected
            ? <><Loader2 className="h-4 w-4 animate-spin" /> Preparing wallet…</>
            : insufficientFunds
            ? 'Insufficient USDC balance'
            : 'Send USDC'
          }
        </Button>

        {/* Cross-chain progress */}
        {busy && isCrossChain && (
          <p className="mt-2 flex items-center gap-1.5 text-[11px] text-app-muted">
            <Loader2 className="h-3 w-3 animate-spin" /> {gwLabel[gw.step] ?? 'Working…'}
          </p>
        )}

        {/* Cross-chain errors. The EOA case gets its own explanation because
            "your wallet type isn't supported" is not something a user can
            debug from a generic error. */}
        {gw.step === 'error' && gw.error && (
          <div className="mt-3 rounded-lg border border-red-900/50 bg-red-900/20 p-3">
            <p className="flex items-center gap-1.5 text-xs font-medium text-red-400">
              <AlertCircle className="h-3.5 w-3.5" /> Transfer not completed
            </p>
            <p className="mt-1 text-[11px] text-red-300/90">{gw.error}</p>
            {gw.needsEoa && (
              <p className="mt-1.5 text-[11px] text-red-300/70">
                Same-chain sends on Arc still work normally.
              </p>
            )}
            <Button size="sm" variant="outline" className="mt-2" onClick={gw.reset}>
              Try again
            </Button>
          </div>
        )}

        {/* Success — same-chain */}
        {isSuccess && txHash && (
          <a href={`https://testnet.arcscan.app/tx/${txHash}`}
            target="_blank" rel="noopener noreferrer"
            className="mt-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400 hover:underline">
            <CheckCircle className="h-3.5 w-3.5" /> Sent · View on ArcScan
          </a>
        )}

        {/* Success — cross-chain */}
        {gw.step === 'done' && gw.mintTx && (
          <div className="mt-3 rounded-lg bg-emerald-900/20 px-3 py-2">
            <p className="flex items-center gap-2 text-xs text-emerald-400">
              <CheckCircle className="h-3.5 w-3.5" /> Sent to {dest?.name}
            </p>
            {destCctp && (
              <a href={`${destCctp.explorer}/tx/${gw.mintTx}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-1 inline-flex items-center gap-1 text-[11px] text-emerald-400 hover:underline">
                View transaction <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function SendPage() {
  return (
    <SectionGuard section="send">
      <SendPageInner />
    </SectionGuard>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/send/page.tsx"

mkdir -p "afrifx-web/components/treasury"
cat > "afrifx-web/components/treasury/GatewayBalancePanel.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { Layers, RefreshCw, AlertCircle, Plus, ChevronDown, ChevronUp } from 'lucide-react'
import { GatewayDepositForm } from './GatewayDepositForm'
import { useAccount } from 'wagmi'
import { fetchGatewayBalances, gatewayChains, isValidAddress } from '@/lib/gateway'

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
  // Collapsed by default: the chain list only grows as Gateway adds chains,
  // and most of the time the single unified figure is what matters.
  const [showChains,  setShowChains]  = useState(false)
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

          <button
            onClick={() => setShowChains(v => !v)}
            className="mb-2 flex w-full items-center justify-between text-[10px] font-semibold uppercase tracking-wide text-app-muted hover:text-app-text"
          >
            <span>Deposited per chain</span>
            {showChains ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
          </button>
          <div className={`space-y-1.5 ${showChains ? '' : 'hidden'}`}>
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

    </div>
  )
}
AFX_EOF
echo "  afrifx-web/components/treasury/GatewayBalancePanel.tsx"

echo ""
echo "Done. Then:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Send: multi-chain via Gateway unified balance'"
echo "  git push"
echo ""
echo "  ===== TEST IN THIS ORDER ====="
echo "  1) Arc -> Arc first. This must behave EXACTLY as before (direct wallet"
echo "     transfer). If that broke, stop and tell me."
echo "  2) Then Arc -> Base Sepolia with a small amount from your unified"
echo "     balance. You'll sign TWICE: the burn intent (no gas), then the mint."
echo ""
echo "  IF THE SIGN STEP FAILS with a wallet-type error, that's the EOA"
echo "  constraint biting -- Web3Auth is giving a smart account. Tell me and"
echo "  we'll look at Gateway's delegate mechanism, which exists for exactly"
echo "  this case."
