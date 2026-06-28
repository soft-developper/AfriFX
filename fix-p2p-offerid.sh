'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits, isAddress, decodeEventLog } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'
import { arcTestnet } from '@/lib/arc-chain'

const API  = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO = '0x0000000000000000000000000000000000000000'

export function useP2P() {
  const { address }         = useAccount()
  const publicClient        = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [offerId,   setOfferId]   = useState<`0x${string}` | null>(null)

  const { writeContractAsync } = useWriteContract()

  function clearError() { setError(null) }

  /**
   * Extract the real bytes32 offerId from the OfferCreated event log.
   * This is what the smart contract generated — must be used for all
   * subsequent on-chain calls (acceptP2POffer, makerConfirm, etc.)
   */
  async function getOfferIdFromReceipt(hash: `0x${string}`): Promise<`0x${string}`> {
    if (!publicClient) throw new Error('No public client')

    const receipt = await publicClient.waitForTransactionReceipt({ hash })

    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({
          abi:       VAULT_P2P_ABI,
          eventName: 'OfferCreated',
          data:      log.data,
          topics:    log.topics,
        })
        // offerId is the first indexed topic — decoded as args.offerId
        if (decoded.args.offerId) {
          return decoded.args.offerId as `0x${string}`
        }
      } catch {
        // Not this log — continue
      }
    }
    throw new Error('OfferCreated event not found in receipt')
  }

  // ── Create offer ──────────────────────────────────────────
  async function createOffer(
    usdcAmount:    number,
    localCurrency: string,
    localAmount:   number,
  ) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setIsLoading(true)
    setError(null)

    try {
      const usdcRaw  = parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw = BigInt(Math.round(localAmount))

      // 1. Approve vault to pull USDC
      await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'approve',
        args:         [vault, usdcRaw],
      })

      // 2. Create offer — vault pulls USDC into escrow
      const hash = await writeContractAsync({
        address:      vault,
        abi:          VAULT_P2P_ABI,
        functionName: 'createP2POffer',
        args:         [usdcRaw, localCurrency, localRaw],
      })

      setTxHash(hash)

      // 3. Wait for receipt and extract the real bytes32 offerId
      const realOfferId = await getOfferIdFromReceipt(hash)
      setOfferId(realOfferId)

      const expiresAt = Math.floor(Date.now() / 1000) + 1800

      // 4. Store in backend using the real on-chain bytes32 as ID
      await fetch(`${API}/offers`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id:            realOfferId,   // ← real bytes32 from contract
          makerAddress:  address,
          usdcAmount,
          localCurrency,
          localAmount,
          rateOffered:   usdcAmount / localAmount,
          arcTxHash:     hash,
          expiresAt,
        }),
      })

      return realOfferId
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Accept offer ──────────────────────────────────────────
  // offerId here IS the bytes32 (stored as the DB primary key)
  async function acceptOffer(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)

    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'acceptP2POffer',
        args:         [offerId],
      })

      setTxHash(hash)

      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'accepted', takerAddress: address }),
      })

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Maker confirms they sent local currency ───────────────
  async function makerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)
    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'makerConfirm',
        args:         [offerId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ makerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Taker confirms they received local currency ───────────
  async function takerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)
    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'takerConfirm',
        args:         [offerId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ takerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    createOffer,
    acceptOffer,
    makerConfirm,
    takerConfirm,
    isLoading,
    error,
    txHash,
    offerId,
    clearError,
  }
}
__EOF__
echo "✅  useP2P.ts — reads real bytes32 offerId from OfferCreated event"

# ============================================================
# Fix marketplace page — pass offerId directly (it IS bytes32)
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { useP2P } from '@/hooks/useP2P'
import { Plus, Clock, Zap, ShieldCheck, Loader2 } from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function timeLeft(expiresAt: number): string {
  const secs = expiresAt - Math.floor(Date.now() / 1000)
  if (secs <= 0) return 'Expired'
  const mins = Math.floor(secs / 60)
  return mins > 0 ? `${mins}m left` : `${secs}s left`
}

export default function MarketplacePage() {
  const { address }                       = useAccount()
  const [offers,    setOffers]            = useState<P2POffer[]>([])
  const [loading,   setLoading]           = useState(true)
  const [currency,  setCurrency]          = useState('all')
  const [accepting, setAccepting]         = useState<string | null>(null)
  const { acceptOffer, error: p2pErr }    = useP2P()

  async function load() {
    setLoading(true)
    try {
      const url  = currency === 'all'
        ? `${API}/offers`
        : `${API}/offers?currency=${currency}`
      const res  = await fetch(url)
      const data = await res.json()
      setOffers(Array.isArray(data) ? data : [])
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address) return
    setAccepting(offer.id)
    try {
      // offer.id IS the bytes32 from the contract — pass directly
      await acceptOffer(offer.id as `0x${string}`)
      await load()
    } catch {}
    finally { setAccepting(null) }
  }

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">P2P Marketplace</h1>
          <p className="text-sm text-[#64748B]">
            Buy USDC directly from other users. Funds held in vault escrow.
          </p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm">
            <Plus className="h-4 w-4" /> Create offer
          </Button>
        </Link>
      </div>

      {/* Trust badges */}
      <div className="mb-6 flex gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow' },
          { icon: Zap,         label: 'Arc settlement' },
          { icon: Clock,       label: '30 min timeout' },
        ].map(({ icon: Icon, label }) => (
          <div key={label}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#64748B]">
            <Icon className="h-3.5 w-3.5 text-[#378ADD]" />
            {label}
          </div>
        ))}
      </div>

      {/* Currency filter */}
      <div className="mb-4 flex flex-wrap gap-2">
        {['all', 'NGN', 'GHS', 'KES', 'ZAR', 'EGP'].map((c) => (
          <button
            key={c}
            onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-[#378ADD] text-white'
                : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}
          >
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c]} ${c}`}
          </button>
        ))}
        <button
          onClick={load}
          className="ml-auto rounded-full border border-[#1B2B4B] px-3 py-1 text-xs text-[#64748B] hover:text-[#E2E8F0]"
        >
          ↻ Refresh
        </button>
      </div>

      {/* Offers */}
      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => (
            <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
          ))}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <p className="text-sm text-[#64748B]">No open offers right now.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" className="mt-4" size="sm">
              <Plus className="h-4 w-4" /> Create the first offer
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn   = address?.toLowerCase() === offer.maker_address?.toLowerCase()
          const expired = offer.expires_at < Math.floor(Date.now() / 1000)

          return (
            <div key={offer.id}
              className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">

              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
              </div>

              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="font-medium text-[#E2E8F0]">
                    {Number(offer.local_amount).toLocaleString()} {offer.local_currency}
                    <span className="mx-1.5 text-[#64748B]">→</span>
                    {Number(offer.usdc_amount).toFixed(2)} USDC
                  </p>
                  {isOwn && <Badge variant="arc">Your offer</Badge>}
                </div>
                <div className="mt-0.5 flex items-center gap-3 text-xs text-[#64748B]">
                  <span>
                    Rate: {Number(offer.rate_offered).toFixed(4)} USDC/{offer.local_currency}
                  </span>
                  <span className="flex items-center gap-1">
                    <Clock className="h-3 w-3" />
                    {timeLeft(offer.expires_at)}
                  </span>
                  <span className="font-mono text-[10px]">
                    {offer.id.slice(0, 10)}…
                  </span>
                </div>
              </div>

              <div className="shrink-0">
                {isOwn ? (
                  <Badge variant="warning">Listed</Badge>
                ) : expired ? (
                  <Badge variant="danger">Expired</Badge>
                ) : offer.status !== 'open' ? (
                  <Badge variant="success">{offer.status}</Badge>
                ) : (
                  <ClientOnly>
                    <Button
                      size="sm"
                      onClick={() => handleAccept(offer)}
                      disabled={!address || accepting === offer.id}
                    >
                      {accepting === offer.id
                        ? <><Loader2 className="h-3.5 w-3.5 animate-spin" /> Accepting…</>
                        : 'Accept offer'
                      }
                    </Button>
                  </ClientOnly>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}
