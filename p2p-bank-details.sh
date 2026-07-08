#!/bin/bash
# ============================================================
# AfriFX -- P2P payout (bank / mobile-money) details on offers
#
# When a maker creates a P2P offer they now enter WHERE the local-currency
# payment should be sent (bank account or mobile money). Once a taker accepts,
# those payout details are revealed to the taker so they know exactly where to
# send the money. Details are PRIVATE: redacted on the public marketplace list
# and only returned to the maker or the accepted taker.
#
# Files:
#   * p2p-bank-details-schema.sql -- adds 5 columns to p2p_offers (RUN THIS
#     against your Turso DB first, see step 1 below)
#   * offers.ts        -- stores + validates payout fields; redacts on public
#     list; GET /offers/:id?wallet= returns details only to maker/accepted taker
#   * useP2P.ts        -- createOffer sends the payout fields
#   * CreateOfferClient.tsx -- "Your payout details" section (bank/mobile toggle)
#   * marketplace/[id]/page.tsx -- shows the maker's details to the taker
#
# Run from ~/AfriFX:  bash p2p-bank-details.sh
# ============================================================
set -e
echo ""
echo "Applying P2P payout-details layer..."
echo ""

mkdir -p "afrifx-api"
cat > "afrifx-api/p2p-bank-details-schema.sql" << 'AFX_EOF'
-- Adds the maker's payout details to each P2P offer, so a taker who accepts
-- knows exactly where to send the local-currency payment.
-- Safe to run more than once: each ADD COLUMN is guarded.
-- Run:  turso db shell <your-db-name> < afrifx-api/p2p-bank-details-schema.sql
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS", so if a column already
-- exists the statement errors harmlessly — run them individually if needed.

ALTER TABLE p2p_offers ADD COLUMN payment_method   TEXT DEFAULT 'bank';   -- 'bank' | 'mobile_money'
ALTER TABLE p2p_offers ADD COLUMN account_name     TEXT;                  -- account holder / recipient name
ALTER TABLE p2p_offers ADD COLUMN account_number   TEXT;                  -- bank account no. OR mobile-money phone
ALTER TABLE p2p_offers ADD COLUMN bank_name        TEXT;                  -- bank name OR mobile-money provider
ALTER TABLE p2p_offers ADD COLUMN payment_note     TEXT;                  -- optional instructions / reference
AFX_EOF
echo "  afrifx-api/p2p-bank-details-schema.sql"

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/offers.ts" << 'AFX_EOF'
import { notifyTradeAccepted, notifyTradeCompleted } from '../services/email/notifications'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// Payout detail fields (maker's bank / mobile-money info). These are private:
// only the maker and the accepted taker may see them.
const PAYOUT_FIELDS = ['payment_method', 'account_name', 'account_number', 'bank_name', 'payment_note']

// Strip payout details from an offer row (object form). Rows can come back as
// arrays or objects depending on the driver; we normalize to object elsewhere,
// so this handles the object shape used by the JSON responses.
function redactPayout(offer: any) {
  if (!offer || Array.isArray(offer)) return offer
  const clean = { ...offer }
  for (const f of PAYOUT_FIELDS) delete clean[f]
  return clean
}

// GET /offers — only OPEN offers visible to everyone
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const type     = req.query.type     as string | undefined
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status = 'open'
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          ${type     ? sql`AND order_type = ${type}`         : sql``}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    // Never expose payout details on the PUBLIC list — only the accepted
    // taker (and the maker) should see them, via GET /offers/:id.
    res.json(offers.map(redactPayout))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/my?wallet=0x… — maker + taker see ALL their offers
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id?wallet=0x… — payout details returned ONLY to the maker
// or the accepted taker; redacted for anyone else.
router.get('/:id', async (req, res) => {
  const requester = (req.query.wallet as string | undefined)?.toLowerCase()
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })

    const offer = offers[0]
    const maker = (offer.maker_address ?? '').toLowerCase()
    const taker = (offer.taker_address ?? '').toLowerCase()
    const authorized = requester && (requester === maker || requester === taker)

    res.json(authorized ? offer : redactPayout(offer))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers — create new offer
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount, localCurrency, localAmount,
    rateOffered, orderType, limitRate, makerTimerSeconds, arcTxHash,
    paymentMethod, accountName, accountNumber, bankName, paymentNote,
  } = req.body
  const now      = Math.floor(Date.now() / 1000)
  const PERPETUAL = 9999999999

  // Payout details are required so the taker knows where to send the money.
  if (!accountName || !accountNumber || !bankName) {
    return res.status(400).json({ error: 'Payout details (account name, number, and bank/provider) are required' })
  }

  try {
    await db.run(
      sql`INSERT OR IGNORE INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, order_type, limit_rate, maker_timer_seconds,
           arc_tx_hash, payment_method, account_name, account_number,
           bank_name, payment_note, expires_at, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${orderType ?? 'market'}, ${limitRate ?? null},
           ${makerTimerSeconds ?? 1800}, ${arcTxHash ?? null},
           ${paymentMethod ?? 'bank'}, ${accountName}, ${accountNumber},
           ${bankName}, ${paymentNote ?? null},
           ${PERPETUAL}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) {
    console.error('[Offers] Insert error:', err.message)
    res.status(500).json({ error: err.message })
  }
})

// PATCH /offers/:id
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress, makerConfirmed, takerConfirmed,
    releaseTxHash, takerDeadline, makerDeadline,
    disputeRaised, disputeId,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status         ?? null}, status),
            taker_address   = COALESCE(${takerAddress   ? takerAddress.toLowerCase() : null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash  ?? null}, release_tx_hash),
            taker_deadline  = COALESCE(${takerDeadline  ?? null}, taker_deadline),
            maker_deadline  = COALESCE(${makerDeadline  ?? null}, maker_deadline),
            dispute_raised  = COALESCE(${disputeRaised  ?? null}, dispute_raised),
            dispute_id      = COALESCE(${disputeId      ?? null}, dispute_id),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    // Fetch offer data for email notification
    const _offerRows = await db.run(sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`)
    const _offerData = Array.isArray((_offerRows as any).rows) ? (_offerRows as any).rows[0] : (_offerRows as any)[0]
    // Fire the "trade accepted" email ONLY on the actual accept transition —
    // i.e. when the taker accepts (status -> 'accepted' with a takerAddress).
    // Other PATCHes (takerConfirmed / makerConfirmed / release, etc.) hit this
    // same endpoint and must NOT re-trigger the email (that caused duplicate
    // notifications, including ones with a blank taker name).
    const isAcceptTransition =
      status === 'accepted' && !!takerAddress

    if (_offerData && isAcceptTransition) {
      notifyTradeAccepted({
        makerWallet: _offerData.maker_address ?? _offerData[1] ?? '',
        takerWallet: (takerAddress ?? '').toLowerCase(),
        usdcAmount:  Number(_offerData.usdc_amount  ?? _offerData[3]  ?? 0),
        localAmount: Number(_offerData.local_amount ?? _offerData[5]  ?? 0),
        localCcy:    _offerData.local_currency ?? _offerData[4] ?? '',
        offerId:     req.params.id,
      }).catch((err: any) => console.error('[Notify] trade_accepted:', err.message))
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers/:id/dispute
router.post('/:id/dispute', async (req, res) => {
  const { raisedBy, reason } = req.body
  const offerId      = req.params.id
  const now          = Math.floor(Date.now() / 1000)
  const disputeId    = randomUUID()
  const autoSettleAt = now + 86400
  try {
    await db.run(
      sql`INSERT INTO disputes (id, offer_id, raised_by, reason, auto_settle_at, created_at)
          VALUES (${disputeId}, ${offerId}, ${raisedBy.toLowerCase()},
                  ${reason ?? null}, ${autoSettleAt}, ${now})`
    )
    await db.run(
      sql`UPDATE p2p_offers
          SET dispute_raised = 1, dispute_id = ${disputeId}, updated_at = ${now}
          WHERE id = ${offerId}`
    )
    const offerRows = await db.run(sql`SELECT maker_address FROM p2p_offers WHERE id = ${offerId}`)
    const rows = Array.isArray((offerRows as any).rows) ? (offerRows as any).rows : []
    if (rows.length) {
      const maker = rows[0].maker_address ?? rows[0][0]
      await db.run(
        sql`UPDATE users SET dispute_warnings = dispute_warnings + 1
            WHERE LOWER(wallet_address) = ${maker.toLowerCase()}`
      ).catch(() => {})
    }
    res.status(201).json({ disputeId, autoSettleAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id/dispute
router.get('/:id/dispute', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM disputes WHERE offer_id = ${req.params.id}
          ORDER BY created_at DESC LIMIT 1`
    )
    const disputes = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!disputes.length) return res.status(404).json({ error: 'No dispute' })
    res.json(disputes[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})


// PATCH /offers/:id/accept — called by taker after tx confirms
// Forces DB update so detail page loads correctly
router.patch('/:id/accept', async (req, res) => {
  const { takerAddress, timerSeconds = 1800 } = req.body
  if (!takerAddress) return res.status(400).json({ error: 'takerAddress required' })

  const now          = Math.floor(Date.now() / 1000)
  const takerDeadline = now + Number(timerSeconds)

  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status         = 'accepted',
            taker_address  = ${takerAddress.toLowerCase()},
            taker_deadline = ${takerDeadline},
            updated_at     = ${now}
          WHERE id = ${req.params.id}
            AND status = 'open'`
    )
    res.json({ success: true, takerDeadline })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
AFX_EOF
echo "  afrifx-api/src/routes/offers.ts"

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useP2P.ts" << 'AFX_EOF'
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
      throw new Error('Offer creation reverted on-chain — no offer was created.')
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
  // A tx hash existing only means it was broadcast — it can still revert,
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
          throw new Error('USDC approval failed on-chain — the offer was not created.')
        }
      }

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
        setError('Transaction reverted on-chain — the offer was not accepted.')
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
        setError('Transaction reverted on-chain — your confirmation was not recorded.')
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
        setError('Transaction reverted on-chain — your confirmation was not recorded.')
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
        setError('Transaction reverted on-chain — the offer was not cancelled.')
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
AFX_EOF
echo "  afrifx-web/hooks/useP2P.ts"

mkdir -p "afrifx-web/app/(app)/marketplace/create"
cat > "afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx" << 'AFX_EOF'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders, AlertCircle } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES      = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}
const TIMER_OPTIONS = [
  { label: '30 min',  value: 1800 },
  { label: '1 hour',  value: 3600 },
  { label: '2 hours', value: 7200 },
  { label: 'Custom',  value: 0    },
]

export function CreateOfferClient() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,     setOrderType]     = useState<OrderType>('market')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [limitOffset,   setLimitOffset]   = useState(0)
  const [timerOption,   setTimerOption]   = useState(1800)
  const [customTimer,   setCustomTimer]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  // Payout details — where the taker sends the local-currency payment.
  const [paymentMethod, setPaymentMethod] = useState<'bank' | 'mobile_money'>('bank')
  const [accountName,   setAccountName]   = useState('')
  const [accountNumber, setAccountNumber] = useState('')
  const [bankName,      setBankName]      = useState('')
  const [paymentNote,   setPaymentNote]   = useState('')
  const payoutComplete = accountName.trim() && accountNumber.trim() && bankName.trim()

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  // The offer locks usdcAmount of USDC from the wallet; keep a small gas buffer.
  const GAS_BUFFER    = 0.001
  const balanceNum    = parseFloat(balance) || 0
  const usdcNum       = parseFloat(usdcAmount) || 0
  const maxUsdc       = Math.max(0, balanceNum - GAS_BUFFER)
  const insufficientUsdc = usdcNum > 0 && usdcNum > maxUsdc
  function setMaxUsdc() { setUsdcAmount(maxUsdc.toFixed(6)) }

  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
        paymentMethod,
        accountName:       accountName.trim(),
        accountNumber:     accountNumber.trim(),
        bankName:          bankName.trim(),
        paymentNote:       paymentNote.trim() || undefined,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch (_e) {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-app-muted">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-app-text">Create P2P offer</h1>
          <p className="text-sm text-app-muted">Lock USDC in escrow — perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-app-border bg-app-surface p-1">
          <button onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit' ? 'bg-app-accent text-app-on-accent' : 'text-app-muted hover:text-app-text'}`}>
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Description */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-app-accent-text" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate.'}
          </div>
        </div>

        {/* USDC + currency */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-app-muted">
              Balance: <span className="text-app-text">{balance}</span>
              <button type="button" onClick={setMaxUsdc}
                className="ml-2 text-app-accent-text hover:underline">Max</button>
            </span>
          </div>
          <div className="flex gap-2">
            <select value={localCurrency} onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none">
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input type="number" placeholder="0.00" value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className={`flex-1 font-mono text-lg ${insufficientUsdc ? 'border-red-500/50' : ''}`} />
          </div>

          {/* Insufficiency / remaining */}
          {insufficientUsdc && (
            <div className="mt-2 flex items-center gap-1.5 rounded-lg bg-red-900/20 px-3 py-2 text-xs text-red-400">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              Insufficient balance — you only have {balance} USDC
            </div>
          )}
          {!insufficientUsdc && usdcNum > 0 && (
            <p className="mt-2 text-xs text-emerald-400">
              Remaining after: {(balanceNum - usdcNum).toFixed(4)} USDC
            </p>
          )}
        </div>

        {/* Rate display + limit slider */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-app-muted">Live market rate</span>
              <span className="font-mono text-app-text">1 USDC = {marketRate.toLocaleString()} {localCurrency}</span>
            </div>
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-app-muted">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-app-text'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input type="range" min="-5" max="5" step="0.5" value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-app-accent" />
                <div className="mt-1 flex justify-between text-[10px] text-app-muted">
                  <span>-5%</span><span>Market</span><span>+5%</span>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated receive */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-app-muted">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-app-text">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-app-muted">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Timer */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
              Taker completion window
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            {TIMER_OPTIONS.map((opt) => (
              <button key={opt.value} onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-app-accent text-app-on-accent'
                    : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input type="number" placeholder="Minutes (min 5, max 1440)"
                value={customTimer} onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono" />
              <span className="text-xs text-app-muted">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-app-muted">
            If taker doesn't send {localCurrency} within this window, the offer automatically cancels and USDC returns to you.
          </p>
        </div>

        {/* Payout details — where the taker sends the money */}
        <div className="rounded-xl border border-app-border bg-app-surface p-4">
          <label className="text-xs font-medium uppercase tracking-wider text-app-muted">
            Your payout details
          </label>
          <p className="mt-1 mb-3 text-xs text-app-muted">
            Where should the taker send your {localCurrency}? Shown to a taker only after they accept.
          </p>

          {/* Method toggle */}
          <div className="mb-3 flex gap-2">
            {(['bank', 'mobile_money'] as const).map((m) => (
              <button key={m} onClick={() => setPaymentMethod(m)}
                className={`flex-1 rounded-lg px-3 py-2 text-xs font-medium transition-colors
                  ${paymentMethod === m ? 'bg-app-accent text-app-on-accent' : 'border border-app-border text-app-muted hover:text-app-text'}`}>
                {m === 'bank' ? 'Bank account' : 'Mobile money'}
              </button>
            ))}
          </div>

          <div className="space-y-2.5">
            <Input placeholder="Account holder name" value={accountName}
              onChange={(e) => setAccountName(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Account number' : 'Phone number'}
              value={accountNumber}
              onChange={(e) => setAccountNumber(e.target.value)} />
            <Input
              placeholder={paymentMethod === 'bank' ? 'Bank name' : 'Provider (e.g. M-Pesa, MTN)'}
              value={bankName}
              onChange={(e) => setBankName(e.target.value)} />
            <Input placeholder="Note / reference (optional)" value={paymentNote}
              onChange={(e) => setPaymentNote(e.target.value)} />
          </div>
          {!payoutComplete && (accountName || accountNumber || bankName) && (
            <p className="mt-2 text-xs text-amber-500">Fill in name, number, and bank/provider to continue.</p>
          )}
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-app-border bg-app-surface p-4 text-xs">
            <p className="mb-2 font-medium text-app-text">Order summary</p>
            <div className="space-y-1.5 text-app-muted">
              {[
                ['Order type', orderType],
                ['You lock',   `${usdcAmount} USDC`],
                ['You receive', `${localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${localCurrency}`],
                ['Taker window', timerSeconds >= 3600 ? `${timerSeconds/3600}h` : `${timerSeconds/60}min`],
                ['Duration',    'Perpetual until filled or cancelled'],
                ['Platform fee', `${(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span>{label}</span>
                  <span className="text-app-text">{val}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Trade flow reminder */}
        <div className="rounded-xl border border-app-border bg-app-surface p-3 text-xs text-app-muted">
          <p className="mb-1 font-medium text-app-text">Trade flow</p>
          <ol className="space-y-0.5">
            {[
              'You lock USDC in vault escrow',
              `Taker accepts + sends ${localCurrency} to you within the window`,
              'Taker confirms: "I sent the money"',
              'You confirm: "I received it"',
              'Platform releases USDC to taker',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-app-accent-text">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button className="w-full" size="lg" onClick={handleCreate}
            disabled={
              isLoading || !usdcAmount || localAmount <= 0 || timerSeconds < 300 ||
              insufficientUsdc || !payoutComplete ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }>
            {isLoading
              ? 'Locking USDC in escrow…'
              : insufficientUsdc
              ? 'Insufficient USDC balance'
              : !payoutComplete
              ? 'Add your payout details'
              : `Create ${orderType} order — ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx"

mkdir -p "afrifx-web/app/(app)/marketplace/[id]"
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << 'AFX_EOF'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams, useSearchParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { TimerBanner } from '@/components/p2p/TimerBanner'
import { ChatWindow } from '@/components/chat/ChatWindow'
import { OfferParties } from '@/components/p2p/OfferParties'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'
import { useProfileByAddress } from '@/hooks/useProfile'
import { DisputeStatus } from '@/components/dispute/DisputeStatus'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

// Extend P2POffer with extra fields we use
interface OfferExtended extends P2POffer {
  taker_deadline?:      number | null
  maker_deadline?:      number | null
  dispute_raised?:      number
  dispute_id?:          string | null
  maker_timer_seconds?: number
  order_type?:          string
  payment_method?:      string
  account_name?:        string
  account_number?:      string
  bank_name?:           string
  payment_note?:        string
}

function normalizeOffer(row: unknown): OfferExtended | null {
  if (!row || (row as Record<string, unknown>).error) return null
  if (Array.isArray(row)) {
    return {
      id:              row[0],
      maker_address:   row[1],
      taker_address:   row[2],
      usdc_amount:     row[3],
      local_currency:  row[4],
      local_amount:    row[5],
      rate_offered:    row[6],
      status:          row[7],
      maker_confirmed: Number(row[8]),
      taker_confirmed: Number(row[9]),
      arc_tx_hash:     row[10],
      release_tx_hash: row[11],
      expires_at:      row[12],
      created_at:      row[13],
      updated_at:      row[14],
    } as OfferExtended
  }
  const r = row as Record<string, unknown>
  return {
    ...(r as unknown as P2POffer),
    maker_confirmed:     Number(r.maker_confirmed     ?? 0),
    taker_confirmed:     Number(r.taker_confirmed     ?? 0),
    taker_deadline:      r.taker_deadline  ? Number(r.taker_deadline)  : null,
    maker_deadline:      r.maker_deadline  ? Number(r.maker_deadline)  : null,
    dispute_raised:      Number(r.dispute_raised      ?? 0),
    maker_timer_seconds: Number(r.maker_timer_seconds ?? 1800),
    order_type:          (r.order_type as string) ?? 'market',
  } as OfferExtended
}

export default function OfferDetailPage() {
  const params       = useParams()
  const searchParams = useSearchParams()
  const { address }  = useAccount()

  const justAccepted = searchParams.get('accepted') === '1'

  const [offer,       setOffer]       = useState<OfferExtended | null>(null)
  const [loading,     setLoading]     = useState(true)
  const [notFound,    setNotFound]    = useState(false)
  const [disputing,   setDisputing]   = useState(false)
  const [disputeDone,    setDisputeDone]    = useState(false)
  const [disputeRecord,  setDisputeRecord]  = useState<{ id: string } | null>(null)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  // Profile hooks — MUST be before any conditional returns (React rules of hooks)
  const { data: makerProfile } = useProfileByAddress(offer?.maker_address ?? null)
  const { data: takerProfile } = useProfileByAddress(offer?.taker_address ?? null)

  const load = useCallback(async () => {
    try {
      const url  = address
        ? `${API}/offers/${params.id}?wallet=${address}`
        : `${API}/offers/${params.id}`
      const res  = await fetch(url)
      if (res.status === 404) {
        if (!justAccepted) setNotFound(true)
        return
      }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) {
        setOffer(norm)
        setNotFound(false)
      } else if (!justAccepted) {
        setNotFound(true)
      }
    } catch {
      if (!justAccepted) setNotFound(true)
    } finally {
      setLoading(false)
    }
  }, [params.id, justAccepted, address])

  useEffect(() => { load() }, [load])

  // Fetch dispute record when dispute is raised
  useEffect(() => {
    if (!offer?.dispute_raised || disputeRecord) return
    fetch(`${API}/disputes/offer/${offer.id}`)
      .then(r => r.json())
      .then(data => { if (data?.id) setDisputeRecord(data) })
      .catch(() => {})
  }, [offer?.dispute_raised, offer?.id])

  useEffect(() => {
    const isStillSyncing = justAccepted && !offer?.taker_address
    const interval = setInterval(load, isStillSyncing ? 2000 : 5000)
    return () => clearInterval(interval)
  }, [load, justAccepted, offer?.taker_address])

  if (loading) return (
    <div className="space-y-4">
      <div className="h-24 animate-pulse rounded-xl bg-app-surface" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
      </div>
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-app-muted">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const offerStatus = offer.status as string

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = justAccepted
    ? !isMaker && !!address
    : address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = offer.maker_timer_seconds ?? 1800

  if (offerStatus === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-app-text">This trade is in progress.</p>
        <p className="text-xs text-app-muted">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace">
          <Button variant="outline" size="sm">← Back to marketplace</Button>
        </Link>
      </div>
    )
  }

  const statusBadgeMap: Record<string, string> = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }
  const statusBadge = (statusBadgeMap[offerStatus] ?? 'default') as
    'warning' | 'arc' | 'success' | 'danger' | 'default'

  const makerName = makerProfile?.display_name ?? makerProfile?.username ??
    (offer?.maker_address ? offer.maker_address.slice(0,8) + '…' : 'Seller')
  const takerName = takerProfile?.display_name ?? takerProfile?.username ??
    (offer?.taker_address ? offer.taker_address.slice(0,8) + '…' : 'Buyer')

  const steps = [
    { n:1, done: offerStatus !== 'open',     label: `${takerName} accepted offer`,               desc: 'USDC locked in vault' },
    { n:2, done: offerStatus !== 'open',     label: `${takerName} sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to ${makerName}`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: `${takerName} confirmed: "I sent the money"`, desc: 'Taker window' },
    { n:4, done: !!offer.maker_confirmed,     label: `${makerName} confirmed: "I received it"`,    desc: 'Maker window' },
    { n:5, done: offerStatus === 'released',  label: 'Platform releases USDC to taker',     desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offerStatus === 'accepted' && !offer.taker_confirmed && !!offer.taker_deadline
  const showMakerTimer = offerStatus === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!offer.maker_deadline

  const showChat = isInvolved && (
    offerStatus === 'accepted' ||
    offerStatus === 'released' ||
    justAccepted
  ) && !!offer.taker_address

  const isSyncing = justAccepted && !offer.taker_address

  async function handleDispute(
    disputeType: 'maker_not_received' | 'maker_silent' = 'maker_silent',
    raisedByRole: 'maker' | 'taker' = 'taker',
  ) {
    if (!address || !offer) return
    setDisputing(true)
    try {
      await raiseDispute(
        offer.id,
        disputeType === 'maker_silent'
          ? 'Maker did not confirm receipt — possible non-response'
          : 'Taker claims to have sent payment but maker did not receive it',
        disputeType,
        raisedByRole,
      )
      setDisputeDone(true)
      await load()
    } catch (_e) {}
    finally { setDisputing(false) }
  }

  const localAmountFormatted = Number(offer.local_amount).toLocaleString()
  const nowTs = Math.floor(Date.now() / 1000)

  return (
    <div>
      {/* Header */}
      <div className="mb-4 flex items-center gap-3">
        <Link href={isInvolved ? '/my-trades' : '/marketplace'}>
          <button className="rounded-lg border border-app-border p-2 text-app-muted hover:text-app-text">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-app-text">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            <Badge variant={offer.order_type === 'limit' ? 'warning' : 'arc'}>
              {offer.order_type ?? 'market'}
            </Badge>
            {!!offer.dispute_raised && <Badge variant="danger">Disputed</Badge>}
            {isTaker && <Badge variant="success">You are the buyer</Badge>}
          </div>
          <p className="font-mono text-xs text-app-muted">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {isSyncing && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-app-accent/30 bg-app-accent/10 px-4 py-3 text-sm text-app-accent-text">
          <Loader2 className="h-4 w-4 animate-spin shrink-0" />
          Trade accepted! Setting up your trade interface…
        </div>
      )}

      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.taker_deadline as number}
              totalSeconds={timerSecs}
              phase="taker"
              isMine={isTaker}
            />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner
              deadline={offer.maker_deadline as number}
              totalSeconds={timerSecs}
              phase="maker"
              isMine={isMaker}
            />
          </div>
        )}
      </ClientOnly>

      <div className={`grid gap-4 ${showChat ? 'lg:grid-cols-3' : 'lg:grid-cols-2'}`}>

        {/* Summary */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-app-bg p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-app-muted">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-app-muted" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-app-text">{localAmountFormatted}</p>
              <p className="text-xs text-app-muted">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <OfferParties
            makerAddress={offer.maker_address}
            takerAddress={offer.taker_address}
            isMaker={isMaker}
            isTaker={isTaker}
          />

          <div className="mt-2 flex justify-between text-xs">
            <span className="text-app-muted">Rate</span>
            <span className="font-mono text-app-text">
              1 USDC = {Number(offer.rate_offered) > 0
                ? (1 / Number(offer.rate_offered)).toFixed(2) : '—'} {offer.local_currency}
            </span>
          </div>

          {offer.arc_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Create tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-app-accent-text hover:underline">
                {offer.arc_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}
          {offer.release_tx_hash && (
            <div className="mt-2 flex justify-between text-xs">
              <span className="text-app-muted">Release tx</span>
              <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`}
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                {offer.release_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
              </a>
            </div>
          )}

          {isMaker && offerStatus === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Progress + actions */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <p className="mb-4 text-sm font-medium text-app-text">Progress</p>
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-app-border text-app-muted'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-app-text'}`}>{label}</p>
                  <p className="text-xs text-app-muted">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          {/* Maker payout details — shown to involved parties once accepted */}
          {isInvolved && offerStatus !== 'open' && offer.account_number && (
            <div className="mb-4 rounded-lg border border-app-accent/40 bg-app-accent/[0.06] p-4">
              <p className="mb-1 text-sm font-medium text-app-text">
                {isTaker ? `Send ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to:` : 'Your payout details (shown to taker)'}
              </p>
              <p className="mb-3 text-xs text-app-muted">
                {offer.payment_method === 'mobile_money' ? 'Mobile money' : 'Bank transfer'}
              </p>
              <div className="space-y-2 text-sm">
                {[
                  ['Account name', offer.account_name],
                  [offer.payment_method === 'mobile_money' ? 'Phone number' : 'Account number', offer.account_number],
                  [offer.payment_method === 'mobile_money' ? 'Provider' : 'Bank', offer.bank_name],
                  ...(offer.payment_note ? [['Note', offer.payment_note]] : []),
                ].map(([label, val]) => (
                  <div key={label as string} className="flex items-start justify-between gap-3">
                    <span className="text-xs text-app-muted">{label}</span>
                    <span className="text-right font-medium text-app-text">{val}</span>
                  </div>
                ))}
              </div>
              {isTaker && (
                <p className="mt-3 border-t border-app-border pt-3 text-xs text-app-muted">
                  Send the exact amount, then confirm below. Only confirm after you have completed the transfer.
                </p>
              )}
            </div>
          )}

          <ClientOnly>
            <div className="space-y-3">
              {offerStatus === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {offerStatus === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!offer.dispute_raised && offerStatus === 'accepted' && (
                disputeRecord?.id ? (
                  <DisputeStatus
                    disputeId={disputeRecord.id}
                    offerId={offer.id}
                    userAddress={address ?? ''}
                    userRole={isMaker ? 'maker' : 'taker'}
                    username={undefined}
                  />
                ) : (
                  <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                    <p className="font-medium text-amber-400">⏳ Dispute raised — awaiting admin review</p>
                    <p className="mt-1 text-amber-600">An admin will accept and handle your dispute shortly.</p>
                  </div>
                )
              )}

              {offerStatus === 'open' && isMaker && (
                <div className="rounded-lg bg-app-bg p-3 text-center text-xs text-app-muted">
                  Waiting for a buyer to accept your offer…
                </div>
              )}

              {isSyncing && (
                <div className="flex items-center gap-2 rounded-lg border border-app-accent/30 bg-app-accent/10 px-3 py-3 text-xs text-app-accent-text">
                  <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                  <div>
                    <p className="font-medium">Offer accepted on Arc!</p>
                    <p className="mt-0.5 opacity-70">Syncing trade details…</p>
                  </div>
                </div>
              )}

              {offerStatus === 'accepted' && !isSyncing && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Your turn — send {offer.local_currency} to {makerName}</p>
                      <p className="mt-1 text-app-muted">
                        Send <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong> via bank or mobile money, then confirm below.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for {takerName} to send and confirm {localAmountFormatted} {offer.local_currency}…
                    </div>
                  )}

                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="rounded-lg border border-app-accent/30 bg-app-accent/10 p-3 text-xs">
                      <p className="font-medium text-app-text">Check your account</p>
                      <p className="mt-1 text-app-muted">
                        {takerName} says they sent <strong className="text-app-text">
                          {localAmountFormatted} {offer.local_currency}
                        </strong>. Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={!!offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${localAmountFormatted} ${offer.local_currency} to ${makerName}`
                      }
                    </Button>
                  )}

                  {isMaker && !offer.dispute_raised && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={!!offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : !!offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? `Waiting for ${takerName} to send first…`
                        : `✓ I received ${localAmountFormatted} ${offer.local_currency}`
                      }
                    </Button>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed && !offer.dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-app-bg px-3 py-2 text-xs text-app-muted">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for {makerName} to confirm receipt…
                    </div>
                  )}

                  {isTaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ {makerName} has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_silent', 'taker')} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">✓ Dispute raised — admin will review and contact both parties.</p>
                      )}
                    </div>
                  )}

                  {/* MAKER dispute: deadline elapsed, no dispute yet */}
                  {isMaker && !!offer.taker_confirmed && !offer.maker_confirmed &&
                   !offer.dispute_raised && offer.maker_deadline &&
                   offer.maker_deadline < nowTs && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-red-900/40 bg-red-900/10 p-3 text-xs">
                        <p className="font-medium text-red-400">⚠️ {takerName} claims to have sent payment</p>
                        <p className="mt-1 text-red-600">
                          If you did not receive{' '}
                          <strong className="text-red-400">{localAmountFormatted} {offer.local_currency}</strong>,
                          raise a dispute for admin review.
                        </p>
                      </div>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_not_received', 'maker')}
                          disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : "I didn't receive payment — raise dispute"}
                        </Button>
                      ) : (
                        <div className="rounded-lg bg-amber-900/20 p-3 text-xs text-amber-400">
                          ✓ Dispute raised — admin will review.
                        </div>
                      )}
                    </div>
                  )}

                  {/* Both confirmed — waiting for release */}
                  {!!offer.maker_confirmed && !!offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      Both confirmed — releasing USDC within 15 seconds…
                    </div>
                  )}
                </>
              )}
            </div>
          </ClientOnly>

          {!!error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {!!txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-app-accent-text hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>

        {showChat && offer.taker_address && (
          <ClientOnly>
            <ChatWindow
              offerId={offer.id}
              makerAddress={offer.maker_address}
              takerAddress={offer.taker_address}
              currency={offer.local_currency}
              amount={Number(offer.local_amount)}
            />
          </ClientOnly>
        )}
      </div>
    </div>
  )
}
AFX_EOF
echo "  afrifx-web/app/(app)/marketplace/[id]/page.tsx"

echo ""
echo "Done writing files. NEXT STEPS:"
echo ""
echo "  1) Add the DB columns (run ONCE against your Turso database):"
echo "       turso db shell <your-db-name> < afrifx-api/p2p-bank-details-schema.sql"
echo "     (If a column already exists, that line errors harmlessly -- the"
echo "      others still apply. You can also paste each ALTER individually.)"
echo ""
echo "  2) Build both apps:"
echo "       cd afrifx-api  && npm run build   # or your API build step"
echo "       cd ../afrifx-web && npm run build"
echo ""
echo "  3) Commit + push:"
echo "       git add -A && git commit -m 'P2P: maker payout details on offers'"
echo "       git push"
echo ""
echo "  Test: create an offer (you'll now be asked for payout details), then"
echo "  from another account accept it -- you should see where to send the money."
