'use client'
// ============================================================
// useAttestationStatus, is a stranded bridge ready to be minted yet?
//
// WHY: showing a "Complete transfer" button before Circle has attested invites
// a click that can only fail. Ethereum needs 13 to 19 minutes to finalise
// before Circle will attest at all, so for that route the button is unusable
// for most of the transfer's life.
//
// This polls Circle for each unfinished bridge and reports one of:
//   'waiting'  attestation not ready, show a waiting state instead of a button
//   'ready'    attestation available, the button will work
//   'unknown'  we could not tell (network issue), so allow the attempt anyway
//
// Polling is deliberately gentle: Circle's rate limit is 40 requests/second and
// breaching it blocks you for FIVE MINUTES, so we check every 30s and only for
// bridges that are actually unfinished.
// ============================================================

import { useState, useEffect, useCallback, useRef } from 'react'
import { irisBase, chainByKey } from '@/lib/cctp-chains'
import { fetchAttestation } from '@/lib/cctp-client'

export type AttestState = 'waiting' | 'ready' | 'unknown'

interface Pending {
  id: string
  from_chain: string
  burn_tx?: string | null
}

const POLL_MS = 30_000

export function useAttestationStatus(pending: Pending[]) {
  const [status, setStatus] = useState<Record<string, AttestState>>({})
  // Keep the latest list in a ref so the interval doesn't need re-creating
  // every time the parent re-renders.
  const listRef = useRef<Pending[]>(pending)
  listRef.current = pending

  const check = useCallback(async () => {
    const items = listRef.current.filter(p => !!p.burn_tx)
    if (!items.length) return

    const next: Record<string, AttestState> = {}
    for (const p of items) {
      const from = chainByKey(p.from_chain)
      if (!from) { next[p.id] = 'unknown'; continue }
      try {
        const att = await fetchAttestation(irisBase(), from.domain, p.burn_tx!)
        next[p.id] = att.status === 'complete' ? 'ready' : 'waiting'
      } catch {
        // Network problem, not a definitive "not ready". Let the user try.
        next[p.id] = 'unknown'
      }
    }
    setStatus(s => ({ ...s, ...next }))
  }, [])

  useEffect(() => {
    check()
    const t = setInterval(check, POLL_MS)
    return () => clearInterval(t)
  }, [check])

  return { status, refresh: check }
}

/*
  Rough guidance on how long a route takes to finalise, so the waiting state can
  set expectations instead of showing an open-ended spinner. Figures are
  Circle's published finality times.
*/
export function finalityHint(fromChainKey: string): string {
  switch (fromChainKey) {
    case 'arc':      return 'about a second'
    case 'polygon':  return 'a few minutes'
    case 'ethereum':
    case 'base':
    case 'arbitrum': return '13 to 19 minutes'
    default:         return 'a few minutes'
  }
}
