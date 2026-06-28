#!/bin/bash
# ============================================================
# AfriFX — Arc Transaction Memo Official Reintegration
# Based on docs.arc.io/arc/concepts/transaction-memos
# Memo contract: 0x5294E9927c3306DcBaDb03fe70b92e01cCede505
# Run from ~/AfriFX:  bash memo-reintegration.sh
# ============================================================
set -e
echo ""
echo "📝  Reintegrating Arc Transaction Memos (official)..."
echo ""

# ============================================================
# 1 — lib/memo.ts — official ABI from docs + helpers
# ============================================================
cat > afrifx-web/lib/memo.ts << '__EOF__'
// Arc Transaction Memo integration
// Contract: 0x5294E9927c3306DcBaDb03fe70b92e01cCede505
// Source: https://docs.arc.io/arc/concepts/transaction-memos
//
// Key rules (from official docs):
//  1. Call Memo.memo() directly from an EOA — never from a contract
//  2. CallFrom precompile preserves original EOA as msg.sender in target
//  3. If inner call reverts, entire transaction reverts
//  4. memoId is bytes32, indexed — queryable on-chain by memoId

import {
  encodeFunctionData,
  keccak256,
  stringToHex,
  parseUnits,
  type Abi,
} from 'viem'
import type { Currency } from '@/types'

// ── Official ABI from docs.arc.io/arc/tutorials/send-usdc-with-transaction-memo
export const MEMO_ABI = [
  {
    type: 'function',
    name: 'memo',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'target',   type: 'address' },
      { name: 'data',     type: 'bytes'   },
      { name: 'memoId',   type: 'bytes32' },
      { name: 'memoData', type: 'bytes'   },
    ],
    outputs: [],
  },
  {
    type: 'event',
    name: 'BeforeMemo',
    anonymous: false,
    inputs: [
      { name: 'memoIndex', type: 'uint256', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'Memo',
    anonymous: false,
    inputs: [
      { name: 'sender',       type: 'address', indexed: true  },
      { name: 'target',       type: 'address', indexed: true  },
      { name: 'callDataHash', type: 'bytes32', indexed: false },
      { name: 'memoId',       type: 'bytes32', indexed: true  },
      { name: 'memo',         type: 'bytes',   indexed: false },
      { name: 'memoIndex',    type: 'uint256', indexed: false },
    ],
  },
] as const

export const MEMO_ADDRESS = '0x5294E9927c3306DcBaDb03fe70b92e01cCede505' as const

// ── AfriFX memo payload types ─────────────────────────────
export interface AfriFXMemoPayload {
  app:  'afrifx'
  type: 'convert' | 'corridor-step1' | 'corridor-step2'
      | 'p2p-create' | 'p2p-accept'
      | 'p2p-taker-confirm' | 'p2p-maker-confirm'
  ref?: string          // AFX-YYYYMMDD-XXXX
  pair?: string         // e.g. "NGN/USDC"
  rate?: number
  corridorId?: string   // CRD-YYYYMMDD-XXXX
  offerId?: string      // bytes32 P2P offer ID
  step?: number
}

// ── memoId generation ─────────────────────────────────────
// Per docs: memoId is a bytes32 your app defines for lookup
export function buildMemoId(seed: string): `0x${string}` {
  return keccak256(stringToHex(`afrifx-${seed}-${Date.now()}`))
}

// Human-readable reference stored in DB (not on-chain)
export function buildReference(): string {
  const date   = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  const suffix = Math.random().toString(36).slice(2, 6).toUpperCase()
  return `AFX-${date}-${suffix}`
}

// ── Encode memo payload as UTF-8 bytes ───────────────────
export function encodeMemoData(payload: AfriFXMemoPayload): `0x${string}` {
  return stringToHex(JSON.stringify(payload)) as `0x${string}`
}

// ── Decode memo bytes back to payload (for backend) ───────
export function decodeMemoData(memoHex: string): AfriFXMemoPayload | null {
  try {
    const json = Buffer.from(memoHex.replace('0x', ''), 'hex').toString('utf8')
    const parsed = JSON.parse(json)
    if (parsed.app !== 'afrifx') return null
    return parsed as AfriFXMemoPayload
  } catch {
    return null
  }
}

// ── Build Memo.memo() args for a USDC transfer ────────────
// Per docs: encode inner USDC transfer, then pass to Memo.memo()
// Target: USDC contract
// The CallFrom precompile preserves EOA as msg.sender in USDC
export function buildMemoTransferArgs(
  usdcAddress:  `0x${string}`,
  toAddress:    `0x${string}`,
  usdcAmount:   number,
  decimals:     number,
  memoId:       `0x${string}`,
  payload:      AfriFXMemoPayload,
): {
  address:      `0x${string}`
  abi:          typeof MEMO_ABI
  functionName: 'memo'
  args:         [`0x${string}`, `0x${string}`, `0x${string}`, `0x${string}`]
} {
  // Encode inner USDC.transfer(to, amount) calldata
  const transferData = encodeFunctionData({
    abi: [
      {
        name: 'transfer', type: 'function', stateMutability: 'nonpayable',
        inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }],
        outputs: [{ name: '', type: 'bool' }],
      },
    ] as const,
    functionName: 'transfer',
    args:         [toAddress, parseUnits(usdcAmount.toFixed(6), decimals)],
  })

  return {
    address:      MEMO_ADDRESS,
    abi:          MEMO_ABI,
    functionName: 'memo',
    args:         [usdcAddress, transferData, memoId, encodeMemoData(payload)],
  }
}

// ── Build Memo.memo() args for ANY contract call ─────────
// Used for vault calls: createP2POffer, takerConfirm, makerConfirm
export function buildMemoCallArgs(
  targetAddress: `0x${string}`,
  callData:      `0x${string}`,
  memoId:        `0x${string}`,
  payload:       AfriFXMemoPayload,
): {
  address:      `0x${string}`
  abi:          typeof MEMO_ABI
  functionName: 'memo'
  args:         [`0x${string}`, `0x${string}`, `0x${string}`, `0x${string}`]
} {
  return {
    address:      MEMO_ADDRESS,
    abi:          MEMO_ABI,
    functionName: 'memo',
    args:         [targetAddress, callData, memoId, encodeMemoData(payload)],
  }
}
__EOF__
echo "✅  lib/memo.ts — official ABI + helpers"

# ============================================================
# 2 — Update contracts.ts: add MEMO address
# ============================================================
cat > afrifx-web/lib/contracts.ts << '__EOF__'
// All Arc Testnet addresses: docs.arc.io/arc/references/contract-addresses
const ZERO = '0x0000000000000000000000000000000000000000' as `0x${string}`

export const CONTRACTS = {
  // Stablecoins
  USDC: '0x3600000000000000000000000000000000000000' as `0x${string}`,
  EURC: '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a' as `0x${string}`,

  // Transaction Memos — docs.arc.io/arc/concepts/transaction-memos
  MEMO: '0x5294E9927c3306DcBaDb03fe70b92e01cCede505' as `0x${string}`,

  // FX + payments
  STABLE_FX_ESCROW: '0x867650F5eAe8df91445971f14d89fd84F0C9a9f8' as `0x${string}`,
  PERMIT2:          '0x000000000022D473030F116dDEE9F6B43aC78BA3' as `0x${string}`,

  // Gateway
  GATEWAY_WALLET: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9' as `0x${string}`,
  GATEWAY_MINTER: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B' as `0x${string}`,

  // CCTP (Arc = domain 26)
  CCTP_TOKEN_MESSENGER: '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA' as `0x${string}`,
  CCTP_MSG_TRANSMITTER: '0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275' as `0x${string}`,

  MULTICALL3: '0xcA11bde05977b3631167028862bE2a173976CA11' as `0x${string}`,

  // AfriFX deployed contracts — from .env.local
  AFRIFX_VAULT:    (process.env.NEXT_PUBLIC_AFRIFX_VAULT    || ZERO) as `0x${string}`,
  AFRIFX_EXCHANGE: (process.env.NEXT_PUBLIC_AFRIFX_EXCHANGE || ZERO) as `0x${string}`,
} as const

export const ARC_CHAIN_ID  = 5042002
export const ARC_RPC_URL   = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
export const ARC_DOMAIN    = 26
export const USDC_DECIMALS = 6
export const SPREAD_BPS    = 50
__EOF__
echo "✅  contracts.ts — MEMO address added"

# ============================================================
# 3 — hooks/useSwap.ts — Memo-wrapped USDC transfer
# ============================================================
cat > afrifx-web/hooks/useSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS, SPREAD_BPS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import {
  buildMemoId, buildReference, buildMemoTransferArgs, encodeMemoData,
  MEMO_ADDRESS, MEMO_ABI,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { Currency, SwapQuote } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export function useSwap() {
  const { address }   = useAccount()
  const publicClient  = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [reference, setReference] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()
  const { data: receipt, isLoading: isWaiting } = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
  })

  function buildQuote(
    fromCurrency: Currency, toCurrency: Currency,
    fromAmount: number, rate: number,
  ): SwapQuote {
    const usdcAmount = fromCurrency === 'USDC' ? fromAmount : fromAmount / rate
    const spread     = usdcAmount * (SPREAD_BPS / 10_000)
    const networkFee = 0.001
    return {
      fromCurrency, toCurrency, fromAmount,
      toAmount:  usdcAmount - spread - networkFee,
      rate, spreadFee: spread, networkFee,
      deadline: Math.floor(Date.now() / 1000) + 600,
    }
  }

  async function execute(quote: SwapQuote) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault address not configured. Check NEXT_PUBLIC_AFRIFX_VAULT in .env.local')
    }

    setIsLoading(true); setError(null)

    try {
      const ref    = buildReference()
      const memoId = buildMemoId(`convert-${address}`)
      setReference(ref)

      const usdcIn = quote.fromCurrency === 'USDC'
        ? quote.fromAmount
        : quote.toAmount + quote.spreadFee + quote.networkFee

      // Check Memo contract is deployed (per docs recommendation)
      const memoCode = publicClient
        ? await publicClient.getCode({ address: MEMO_ADDRESS })
        : null

      let hash: `0x${string}`

      if (memoCode && memoCode !== '0x') {
        // ── Memo-wrapped USDC transfer ────────────────────────
        // Per docs: encode inner transfer, call Memo.memo() from EOA
        // CallFrom precompile preserves wallet as msg.sender in USDC
        const args = buildMemoTransferArgs(
          CONTRACTS.USDC, vault, usdcIn, USDC_DECIMALS, memoId,
          {
            app:  'afrifx',
            type: 'convert',
            ref,
            pair: `${quote.fromCurrency}/${quote.toCurrency}`,
            rate: quote.rate,
          },
        )
        hash = await writeContractAsync(args)
        console.log(`[Memo] Convert tx with memoId ${memoId.slice(0,14)}…`)
      } else {
        // Fallback: direct USDC transfer (Memo not available)
        console.warn('[Memo] Memo contract not found — falling back to direct transfer')
        const { parseUnits } = await import('viem')
        hash = await writeContractAsync({
          address:      CONTRACTS.USDC,
          abi:          USDC_ABI,
          functionName: 'transfer',
          args:         [vault, parseUnits(usdcIn.toFixed(6), USDC_DECIMALS)],
        })
      }

      setTxHash(hash)

      await fetch(`${API_BASE}/transactions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote,
          walletAddress: address,
          arcTxHash:     hash,
          memoId,
          reference:     ref,
        }),
      }).catch(console.error)

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    buildQuote, execute,
    isLoading: isLoading || isWaiting,
    error, txHash, receipt, reference,
  }
}
__EOF__
echo "✅  hooks/useSwap.ts — Memo-wrapped convert"

# ============================================================
# 4 — hooks/useCorridorSwap.ts — Memo on each corridor step
# ============================================================
cat > afrifx-web/hooks/useCorridorSwap.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { isAddress, parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  MEMO_ADDRESS,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import type { CorridorQuote, Currency } from '@/types'

const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO     = '0x0000000000000000000000000000000000000000'

export type CorridorStep =
  | 'idle'
  | 'step1-pending' | 'step1-waiting' | 'step1-done'
  | 'step2-pending' | 'step2-waiting'
  | 'complete' | 'error'

export function useCorridorSwap() {
  const { address }  = useAccount()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })

  const [step,       setStep]       = useState<CorridorStep>('idle')
  const [error,      setError]      = useState<string | null>(null)
  const [step1Hash,  setStep1Hash]  = useState<`0x${string}` | null>(null)
  const [step2Hash,  setStep2Hash]  = useState<`0x${string}` | null>(null)
  const [corridorId, setCorridorId] = useState<string | null>(null)

  const { writeContractAsync } = useWriteContract()

  // Check if Memo contract is deployed (once per session)
  async function isMemoAvailable(): Promise<boolean> {
    if (!publicClient) return false
    try {
      const code = await publicClient.getCode({ address: MEMO_ADDRESS })
      return !!code && code !== '0x'
    } catch { return false }
  }

  async function sendWithMemo(
    toAddress:  `0x${string}`,
    usdcAmount: number,
    memoId:     `0x${string}`,
    payload:    Parameters<typeof buildMemoTransferArgs>[5],
    useMemo:    boolean,
  ): Promise<`0x${string}`> {
    if (useMemo) {
      const args = buildMemoTransferArgs(
        CONTRACTS.USDC, toAddress, usdcAmount, USDC_DECIMALS, memoId, payload,
      )
      return writeContractAsync(args)
    }
    // Fallback: direct USDC transfer
    return writeContractAsync({
      address:      CONTRACTS.USDC,
      abi:          USDC_ABI,
      functionName: 'transfer',
      args:         [toAddress, parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)],
    })
  }

  async function execute(quote: CorridorQuote) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setError(null)
    setCorridorId(quote.corridorId)

    const useMemo = await isMemoAvailable()
    if (useMemo) console.log('[Memo] Corridor: using Memo contract for both steps')
    else console.warn('[Memo] Corridor: Memo not available, using direct transfers')

    try {
      // ── STEP 1: from → USDC ───────────────────────────────
      setStep('step1-pending')
      const ref1    = buildReference()
      const memo1Id = buildMemoId(`corridor-${quote.corridorId}-step1`)
      const usdcIn1 = quote.step1.toAmount + quote.step1.spreadFee + quote.step1.networkFee

      const hash1 = await sendWithMemo(vault, usdcIn1, memo1Id, {
        app:  'afrifx',
        type: 'corridor-step1',
        ref:  ref1,
        pair: `${quote.from}/USDC`,
        rate: quote.step1.rate,
        corridorId: quote.corridorId,
        step: 1,
      }, useMemo)

      setStep1Hash(hash1)
      setStep('step1-waiting')
      console.log(`[Memo] Corridor Step 1 tx: ${hash1.slice(0,14)}…`)

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step1, walletAddress: address,
          arcTxHash: hash1, memoId: memo1Id, reference: ref1,
          corridorId: quote.corridorId, corridorStep: 1,
        }),
      }).catch(console.error)

      await sleep(1500)
      setStep('step1-done')

      // ── STEP 2: USDC → to ─────────────────────────────────
      setStep('step2-pending')
      const ref2    = buildReference()
      const memo2Id = buildMemoId(`corridor-${quote.corridorId}-step2`)
      const usdcIn2 = quote.step2.fromAmount

      const hash2 = await sendWithMemo(vault, usdcIn2, memo2Id, {
        app:  'afrifx',
        type: 'corridor-step2',
        ref:  ref2,
        pair: `USDC/${quote.to}`,
        rate: quote.step2.rate,
        corridorId: quote.corridorId,
        step: 2,
      }, useMemo)

      setStep2Hash(hash2)
      setStep('step2-waiting')
      console.log(`[Memo] Corridor Step 2 tx: ${hash2.slice(0,14)}…`)

      await fetch(`${API_BASE}/transactions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...quote.step2, walletAddress: address,
          arcTxHash: hash2, memoId: memo2Id, reference: ref2,
          corridorId: quote.corridorId, corridorStep: 2,
        }),
      }).catch(console.error)

      await sleep(1500)
      setStep('complete')
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      setStep('error')
      throw err
    }
  }

  function reset() {
    setStep('idle'); setError(null)
    setStep1Hash(null); setStep2Hash(null); setCorridorId(null)
  }

  return {
    execute, reset, step, error,
    step1Hash, step2Hash, corridorId,
    isLoading:  ['step1-pending','step1-waiting','step1-done','step2-pending','step2-waiting'].includes(step),
    isComplete: step === 'complete',
  }
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)) }
__EOF__
echo "✅  hooks/useCorridorSwap.ts — Memo on each step"

# ============================================================
# 5 — hooks/useP2P.ts — Memo on accept, takerConfirm, makerConfirm
# ============================================================
cat > afrifx-web/hooks/useP2P.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import {
  parseUnits, isAddress, decodeEventLog, encodeFunctionData,
} from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'
import {
  buildMemoId, buildReference, buildMemoTransferArgs,
  buildMemoCallArgs, encodeMemoData,
  MEMO_ADDRESS, MEMO_ABI,
} from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'

const API  = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO = '0x0000000000000000000000000000000000000000'

export type OrderType = 'market' | 'limit'

export interface CreateOfferParams {
  usdcAmount:        number
  localCurrency:     string
  localAmount:       number
  orderType:         OrderType
  limitRate?:        number
  makerTimerSeconds: number
}

export function useP2P() {
  const { address }  = useAccount()
  const publicClient = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [offerId,   setOfferId]   = useState<`0x${string}` | null>(null)

  const { writeContractAsync } = useWriteContract()

  function clearError() { setError(null) }

  // Check Memo availability once
  async function isMemoAvailable(): Promise<boolean> {
    if (!publicClient) return false
    try {
      const code = await publicClient.getCode({ address: MEMO_ADDRESS })
      return !!code && code !== '0x'
    } catch { return false }
  }

  // Extract OfferCreated bytes32 from receipt
  async function getOfferIdFromReceipt(hash: `0x${string}`): Promise<`0x${string}`> {
    if (!publicClient) throw new Error('No public client')
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({
          abi: VAULT_P2P_ABI, eventName: 'OfferCreated',
          data: log.data, topics: log.topics,
        })
        if (decoded.args.offerId) return decoded.args.offerId as `0x${string}`
      } catch {}
    }
    throw new Error('OfferCreated event not found in receipt')
  }

  // ── Create offer ──────────────────────────────────────────
  // Note: approve() cannot be memo-wrapped (no state change to forward)
  // createP2POffer() IS memo-wrapped — vault sees user as msg.sender via CallFrom
  async function createOffer(params: CreateOfferParams) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) throw new Error('Vault not configured')

    setIsLoading(true); setError(null)
    try {
      const usdcRaw  = parseUnits(params.usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw = BigInt(Math.round(params.localAmount))
      const orderN   = params.orderType === 'limit' ? 1 : 0
      const memoId   = buildMemoId(`p2p-create-${address}`)
      const ref      = buildReference()
      const useMemo  = await isMemoAvailable()

      // 1. Approve vault (must be direct — not memo-wrapped)
      await writeContractAsync({
        address: CONTRACTS.USDC, abi: USDC_ABI,
        functionName: 'approve', args: [vault, usdcRaw],
      })

      let hash: `0x${string}`

      if (useMemo) {
        // 2. createP2POffer via Memo — vault sees user as msg.sender
        const createData = encodeFunctionData({
          abi:          VAULT_P2P_ABI,
          functionName: 'createP2POffer',
          args:         [usdcRaw, params.localCurrency, localRaw, orderN, BigInt(params.makerTimerSeconds)],
        })
        const args = buildMemoCallArgs(vault, createData, memoId, {
          app:  'afrifx',
          type: 'p2p-create',
          ref,
          pair: `${params.localCurrency}/USDC`,
        })
        hash = await writeContractAsync(args)
        console.log(`[Memo] P2P createOffer with memoId ${memoId.slice(0,14)}…`)
      } else {
        hash = await writeContractAsync({
          address: vault, abi: VAULT_P2P_ABI,
          functionName: 'createP2POffer',
          args: [usdcRaw, params.localCurrency, localRaw, orderN, BigInt(params.makerTimerSeconds)],
        })
      }

      setTxHash(hash)
      const realOfferId = await getOfferIdFromReceipt(hash)
      setOfferId(realOfferId)

      await fetch(`${API}/offers`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id:            realOfferId,
          makerAddress:  address,
          usdcAmount:    params.usdcAmount,
          localCurrency: params.localCurrency,
          localAmount:   params.localAmount,
          rateOffered:   params.usdcAmount / params.localAmount,
          orderType:     params.orderType,
          limitRate:     params.limitRate ?? null,
          makerTimerSeconds: params.makerTimerSeconds,
          arcTxHash:     hash,
          memoId,
        }),
      })
      return realOfferId
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Accept offer ──────────────────────────────────────────
  async function acceptOffer(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-accept-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const acceptData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'acceptP2POffer', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, acceptData, memoId,
          { app: 'afrifx', type: 'p2p-accept', offerId },
        ))
        console.log(`[Memo] P2P accept with memoId ${memoId.slice(0,14)}…`)
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'acceptP2POffer', args: [offerId],
        })
      }

      setTxHash(hash)
      const takerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'accepted', takerAddress: address, takerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker confirms sent ───────────────────────────────────
  async function takerConfirm(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-taker-confirm-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const confirmData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'takerConfirm', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, confirmData, memoId,
          { app: 'afrifx', type: 'p2p-taker-confirm', offerId },
        ))
        console.log(`[Memo] P2P takerConfirm with memoId ${memoId.slice(0,14)}…`)
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'takerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      const makerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ takerConfirmed: 1, makerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker confirms received ───────────────────────────────
  async function makerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const memoId  = buildMemoId(`p2p-maker-confirm-${offerId}`)
      const useMemo = await isMemoAvailable()

      let hash: `0x${string}`
      if (useMemo) {
        const confirmData = encodeFunctionData({
          abi: VAULT_P2P_ABI, functionName: 'makerConfirm', args: [offerId],
        })
        hash = await writeContractAsync(buildMemoCallArgs(
          CONTRACTS.AFRIFX_VAULT, confirmData, memoId,
          { app: 'afrifx', type: 'p2p-maker-confirm', offerId },
        ))
        console.log(`[Memo] P2P makerConfirm with memoId ${memoId.slice(0,14)}…`)
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'makerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ makerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker raises dispute ──────────────────────────────────
  async function raiseDispute(offerId: string, reason?: string) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const res = await fetch(`${API}/offers/${offerId}/dispute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ raisedBy: address, reason }),
      })
      return await res.json()
    } catch (err: any) {
      setError(err?.message ?? 'Failed to raise dispute')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker cancels own open offer ──────────────────────────
  async function cancelOwnOffer(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'makerCancelOffer', args: [offerId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'cancelled' }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  return {
    createOffer, acceptOffer, takerConfirm,
    makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading, error, txHash, offerId, clearError,
  }
}
__EOF__
echo "✅  hooks/useP2P.ts — Memo on all P2P calls"

# ============================================================
# 6 — Backend: watch official Memo events for reconciliation
# ============================================================
cat > afrifx-api/src/services/eventListener.ts << '__EOF__'
// Arc Transaction Memo event listener
// Docs: https://docs.arc.io/arc/concepts/transaction-memos
// Memo contract: 0x5294E9927c3306DcBaDb03fe70b92e01cCede505

import { arcClient } from './arc'
import { db }        from '../db/client'
import { sql }       from 'drizzle-orm'
import { parseAbiItem } from 'viem'

const MEMO_ADDRESS = '0x5294E9927c3306DcBaDb03fe70b92e01cCede505' as const

// Official Memo event from docs.arc.io
const MEMO_EVENT = parseAbiItem(
  'event Memo(address indexed sender, address indexed target, bytes32 callDataHash, bytes32 indexed memoId, bytes memo, uint256 memoIndex)'
)

interface AfriFXMemoPayload {
  app:       string
  type:      string
  ref?:      string
  pair?:     string
  corridorId?: string
  offerId?:  string
  step?:     number
}

function decodeMemo(memoHex: string): AfriFXMemoPayload | null {
  try {
    const json = Buffer.from(memoHex.replace('0x', ''), 'hex').toString('utf8')
    const parsed = JSON.parse(json)
    return parsed.app === 'afrifx' ? parsed : null
  } catch { return null }
}

export function startEventListener() {
  console.log('[EventListener] Watching Arc Memo events for AfriFX txs')
  console.log(`[EventListener] Memo contract: ${MEMO_ADDRESS}`)

  arcClient.watchEvent({
    address: MEMO_ADDRESS,
    event:   MEMO_EVENT,
    onLogs: async (logs) => {
      for (const log of logs) {
        const { sender, memoId, memo: memoBytes } = log.args as {
          sender:  string
          memoId:  string
          memo:    string
        }

        const payload = decodeMemo(memoBytes)
        if (!payload) continue // not an AfriFX memo

        const txHash = log.transactionHash ?? ''
        const now    = Math.floor(Date.now() / 1000)

        console.log(`[EventListener] AfriFX Memo · type: ${payload.type} · ref: ${payload.ref ?? 'n/a'} · tx: ${txHash.slice(0,14)}…`)

        // Handle each memo type
        switch (payload.type) {
          case 'convert':
          case 'corridor-step1':
          case 'corridor-step2':
            // Mark transaction as settled by memoId
            await db.run(
              sql`UPDATE transactions
                  SET status = 'settled', arc_tx_hash = ${txHash}, settled_at = ${now}
                  WHERE memo_id = ${memoId}`
            ).catch(console.error)
            break

          case 'p2p-taker-confirm':
          case 'p2p-maker-confirm':
            // Update offer confirmed status by memoId
            if (payload.offerId) {
              await db.run(
                sql`UPDATE p2p_offers SET updated_at = ${now} WHERE id = ${payload.offerId}`
              ).catch(console.error)
            }
            break

          default:
            break
        }
      }
    },
    onError: (err) => {
      console.error('[EventListener] Watch error:', err.message)
    },
  })
}
__EOF__
echo "✅  services/eventListener.ts — official Memo event watcher"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Arc Transaction Memo officially reintegrated!"
echo ""
echo "  Contract: 0x5294E9927c3306DcBaDb03fe70b92e01cCede505"
echo "  Source: docs.arc.io/arc/concepts/transaction-memos"
echo ""
echo "  Covered flows:"
echo "  • Convert (NGN/USDC) — Memo-wrapped USDC transfer"
echo "  • Corridor Step 1+2  — Memo on each leg"
echo "  • P2P createOffer    — Memo-wrapped vault call"
echo "  • P2P acceptOffer    — Memo-wrapped vault call"
echo "  • P2P takerConfirm   — Memo-wrapped vault call"
echo "  • P2P makerConfirm   — Memo-wrapped vault call"
echo ""
echo "  Fallback: if Memo contract unavailable, each hook"
echo "  automatically falls back to direct call — zero downtime"
echo ""
echo "  Memo payload structure (stored in memoData bytes):"
echo "  { app: 'afrifx', type, ref, pair, rate, corridorId, offerId }"
echo ""
echo "  Backend listens for Memo events → reconciles by memoId"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
