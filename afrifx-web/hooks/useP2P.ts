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
  paymentMethod:     'bank' | 'mobile_money'
  accountName:       string
  accountNumber:     string
  bankName:          string
  paymentNote?:      string
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
    if (receipt.status !== 'success') {
      throw new Error('Offer creation reverted on-chain, no offer was created.')
    }
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

  // Wait for the on-chain receipt and return whether it actually succeeded.
  // A tx hash existing only means it was broadcast it can still revert,
  // in which case we must NOT record the action as done.
  async function confirmedOnChain(hash: `0x${string}`): Promise<boolean> {
    if (!publicClient) return false
    try {
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      return receipt.status === 'success'
    } catch {
      return false
    }
  }

  // ── Create offer ──────────────────────────────────────────
  // Note: approve() cannot be memo-wrapped (no state change to forward)
  // createP2POffer() IS memo-wrapped vault sees user as msg.sender via CallFrom
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

      // 1. Approve vault (must be direct not memo-wrapped)
      // Wait for it to be MINED before sending the next tx, otherwise the
      // create tx grabs the same/stale nonce and the chain rejects it with
      // "nonce too low". This matters most for the embedded (social-login)
      // wallet, which signs both txs instantly in the background with no
      // manual pause between them (unlike MetaMask's per-tx confirmation).
      const approveHash = await writeContractAsync({
        address: CONTRACTS.USDC, abi: USDC_ABI,
        functionName: 'approve', args: [vault, usdcRaw],
      })
      if (publicClient) {
        const approveReceipt = await publicClient.waitForTransactionReceipt({ hash: approveHash })
        if (approveReceipt.status !== 'success') {
          throw new Error('USDC approval failed on-chain, the offer was not created.')
        }
      }

      let hash: `0x${string}`

      if (useMemo) {
        // 2. createP2POffer via Memo vault sees user as msg.sender
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
          paymentMethod: params.paymentMethod,
          accountName:   params.accountName,
          accountNumber: params.accountNumber,
          bankName:      params.bankName,
          paymentNote:   params.paymentNote ?? null,
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
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'acceptP2POffer', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain, the offer was not accepted.')
        throw new Error('accept reverted on-chain')
      }
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
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'takerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain, your confirmation was not recorded.')
        throw new Error('takerConfirm reverted on-chain')
      }
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
      } else {
        hash = await writeContractAsync({
          address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
          functionName: 'makerConfirm', args: [offerId],
        })
      }

      setTxHash(hash)
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain, your confirmation was not recorded.')
        throw new Error('makerConfirm reverted on-chain')
      }
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
  async function raiseDispute(
    offerId: string,
    reason?: string,
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const res = await fetch(`${API}/disputes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          offerId, raisedBy: address, reason,
          disputeType, raisedByRole,
        }),
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
      if (!(await confirmedOnChain(hash))) {
        setError('Transaction reverted on-chain, the offer was not cancelled.')
        throw new Error('cancel reverted on-chain')
      }
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
