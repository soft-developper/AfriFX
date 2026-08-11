'use client'
// ============================================================
// useP2P - marketplace escrow, signed by the user's CIRCLE wallet.
//
// CIRCLE MIGRATION (Phase 4, marketplace). Each on-chain action is a vault
// contract call the user approves on their device via executeContractCall,
// not a wagmi writeContract. Reads stay as plain Arc RPC lookups (receipts,
// event logs) - those need no wallet, so usePublicClient is kept for them.
//
// MEMO DROPPED. Arc's Memo.memo() must be called from an EOA (its CallFrom
// precompile forwards the EOA as msg.sender). A Circle wallet is a smart
// contract, so a Memo-wrapped call reverts - verified on-chain with a probe
// before this migration, and already the case for Convert (4b). We therefore
// call the vault directly: the Circle SCA IS msg.sender for its own
// contractExecution, which is exactly what the vault needs. The reference /
// pair / memoId metadata is still persisted to the API below, so nothing is
// lost operationally - only the on-chain annotation.
//
// DISCIPLINE (unchanged): a tx hash only means "broadcast". We read the
// receipt and require status === success before recording an action as done,
// so a reverted tx is never persisted as complete.
// ============================================================

import { useState } from 'react'
import { usePublicClient } from 'wagmi'
import { parseUnits, isAddress, decodeEventLog } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'
import { buildMemoId, buildReference } from '@/lib/memo'
import { arcTestnet } from '@/lib/arc-chain'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'

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
  const [note,      setNote]      = useState<string | null>(null)

  function clearError() { setError(null) }

  // Turn any executeContractCall failure into a user-facing message, keeping
  // the reauth / chain signals meaningful instead of a generic "Failed".
  function toMessage(err: any): string {
    if (err instanceof NeedsReauthError) return err.message
    if (err instanceof NeedsChainError)  return err.message
    return err?.shortMessage ?? err?.message ?? 'Failed'
  }

  // Extract OfferCreated bytes32 from a receipt (RPC read, no wallet needed).
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
  // A tx hash existing only means it was broadcast; it can still revert, in
  // which case we must NOT record the action as done.
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
  // Two vault-chain calls: approve() then createP2POffer(). executeContractCall
  // returns only after each call surfaces on-chain, so the approve is mined
  // before the create - preserving the nonce ordering the old code enforced
  // manually (no "nonce too low" from firing both instantly).
  async function createOffer(params: CreateOfferParams) {
    if (!address) throw new Error('Sign in first')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) throw new Error('Vault not configured')

    setIsLoading(true); setError(null); setNote(null)
    try {
      const usdcRaw  = parseUnits(params.usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw = BigInt(Math.round(params.localAmount))
      const orderN   = params.orderType === 'limit' ? 1 : 0
      const memoId   = buildMemoId(`p2p-create-${address}`)
      const ref      = buildReference()

      // 1. Approve the vault to pull the maker's USDC.
      await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.USDC,
        abiFunctionSignature: 'approve(address,uint256)',
        abiParameters:        [vault, usdcRaw.toString()],
      }, setNote)

      // 2. Create the offer.
      const createResult = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      vault,
        abiFunctionSignature: 'createP2POffer(uint256,string,uint256,uint8,uint256)',
        abiParameters: [
          usdcRaw.toString(),
          params.localCurrency,
          localRaw.toString(),
          orderN,
          params.makerTimerSeconds.toString(),
        ],
      }, setNote)

      const hash = (createResult.txHash ?? '') as `0x${string}`
      if (!hash) {
        throw new Error(
          'The offer was approved but is taking longer than usual to confirm. ' +
          'Check the marketplace shortly - if it appears, it went through.')
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
      setError(toMessage(err))
      throw err
    } finally { setIsLoading(false); setNote(null) }
  }

  // ── Accept offer ──────────────────────────────────────────
  async function acceptOffer(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Sign in first')
    setIsLoading(true); setError(null); setNote(null)
    try {
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.AFRIFX_VAULT,
        abiFunctionSignature: 'acceptP2POffer(bytes32)',
        abiParameters:        [offerId],
      }, setNote)

      const hash = (result.txHash ?? '') as `0x${string}`
      setTxHash(hash)
      if (!hash || !(await confirmedOnChain(hash))) {
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
      setError(toMessage(err))
      throw err
    } finally { setIsLoading(false); setNote(null) }
  }

  // ── Taker confirms sent ───────────────────────────────────
  async function takerConfirm(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Sign in first')
    setIsLoading(true); setError(null); setNote(null)
    try {
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.AFRIFX_VAULT,
        abiFunctionSignature: 'takerConfirm(bytes32)',
        abiParameters:        [offerId],
      }, setNote)

      const hash = (result.txHash ?? '') as `0x${string}`
      setTxHash(hash)
      if (!hash || !(await confirmedOnChain(hash))) {
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
      setError(toMessage(err))
      throw err
    } finally { setIsLoading(false); setNote(null) }
  }

  // ── Maker confirms received ───────────────────────────────
  async function makerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Sign in first')
    setIsLoading(true); setError(null); setNote(null)
    try {
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.AFRIFX_VAULT,
        abiFunctionSignature: 'makerConfirm(bytes32)',
        abiParameters:        [offerId],
      }, setNote)

      const hash = (result.txHash ?? '') as `0x${string}`
      setTxHash(hash)
      if (!hash || !(await confirmedOnChain(hash))) {
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
      setError(toMessage(err))
      throw err
    } finally { setIsLoading(false); setNote(null) }
  }

  // ── Taker raises dispute ──────────────────────────────────
  // Server-only, no chain call - unchanged by the Circle migration.
  async function raiseDispute(
    offerId: string,
    reason?: string,
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address) throw new Error('Sign in first')
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
    if (!address) throw new Error('Sign in first')
    setIsLoading(true); setError(null); setNote(null)
    try {
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.AFRIFX_VAULT,
        abiFunctionSignature: 'makerCancelOffer(bytes32)',
        abiParameters:        [offerId],
      }, setNote)

      const hash = (result.txHash ?? '') as `0x${string}`
      setTxHash(hash)
      if (!hash || !(await confirmedOnChain(hash))) {
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
      setError(toMessage(err))
      throw err
    } finally { setIsLoading(false); setNote(null) }
  }

  return {
    createOffer, acceptOffer, takerConfirm,
    makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading, error, txHash, offerId, note, clearError,
  }
}
