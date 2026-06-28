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
