import { formatUnits, parseUnits } from 'viem'
import { USDC_DECIMALS } from './contracts'

// Minimal ERC-20 ABI for USDC on Arc
export const USDC_ABI = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'transfer',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'decimals',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },
  {
    name: 'Transfer',
    type: 'event',
    inputs: [
      { indexed: true,  name: 'from',  type: 'address' },
      { indexed: true,  name: 'to',    type: 'address' },
      { indexed: false, name: 'value', type: 'uint256' },
    ],
  },
] as const

/** Format raw USDC bigint to display string, e.g. "1,000.50" */
export function formatUSDC(raw: bigint): string {
  return Number(formatUnits(raw, USDC_DECIMALS)).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
}

/** Parse display string to raw USDC bigint */
export function parseUSDC(amount: string): bigint {
  return parseUnits(amount, USDC_DECIMALS)
}

/** Format NGN amount for display */
export function formatNGN(amount: number): string {
  return amount.toLocaleString('en-NG', { style: 'currency', currency: 'NGN' })
}
