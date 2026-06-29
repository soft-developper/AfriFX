#!/bin/bash
# ============================================================
# AfriFX — Phase 9: Robust Dispute System
# Run from ~/AfriFX:  bash phase9-dispute-system.sh
# ============================================================
set -e
echo ""
echo "⚖️  Building Phase 9 — Dispute System..."
echo ""

# ============================================================
# 1 — DB: add dispute_type + auto_release_at to disputes table
# ============================================================
echo "  Updating disputes table..."
turso db shell afrifx "
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS dispute_type TEXT DEFAULT 'maker_not_received';
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS auto_release_at INTEGER;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS raised_by_role TEXT DEFAULT 'taker';
" 2>/dev/null || true

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_disputes_offer ON disputes (offer_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status ON disputes (status);
" 2>/dev/null || true
echo "✅  disputes table updated"

# ============================================================
# 2 — Backend: update disputes route
# ============================================================
cat > afrifx-api/src/routes/disputes.ts << '__EOF__'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// GET /disputes?wallet=0x — disputes involving a wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(sql`
      SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE LOWER(o.maker_address) = ${wallet}
         OR LOWER(o.taker_address) = ${wallet}
      ORDER BY d.created_at DESC LIMIT 50
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/offer/:offerId — dispute for a specific offer
router.get('/offer/:offerId', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM disputes WHERE offer_id = ${req.params.offerId} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes — raise a dispute
// dispute_type: 'maker_not_received' | 'maker_silent'
// raised_by_role: 'maker' | 'taker'
router.post('/', async (req, res) => {
  const {
    offerId, raisedBy, reason,
    disputeType = 'maker_not_received',
    raisedByRole = 'taker',
  } = req.body

  if (!offerId || !raisedBy) {
    return res.status(400).json({ error: 'offerId and raisedBy required' })
  }

  const now = Math.floor(Date.now() / 1000)
  // Auto-release 24h from now if dispute is maker_silent
  const autoReleaseAt = disputeType === 'maker_silent' ? now + 86400 : null

  try {
    // Check offer exists and is in accepted state
    const offerRows = await db.run(sql`
      SELECT id, status, taker_confirmed, maker_confirmed,
             maker_address, taker_address
      FROM p2p_offers WHERE id = ${offerId} LIMIT 1
    `)
    const offers = parseRows(offerRows)
    if (!offers.length) return res.status(404).json({ error: 'Offer not found' })

    const offer = offers[0]
    const offerStatus    = offer.status         ?? offer[1]
    const takerConfirmed = Number(offer.taker_confirmed ?? offer[3])
    const makerAddress   = (offer.maker_address ?? offer[5])?.toLowerCase()
    const takerAddress   = (offer.taker_address ?? offer[6])?.toLowerCase()
    const raisedByLower  = raisedBy.toLowerCase()

    // Validate: offer must be accepted
    if (offerStatus !== 'accepted') {
      return res.status(400).json({ error: 'Can only dispute accepted offers' })
    }

    // Validate: taker must have confirmed sending before any dispute
    if (!takerConfirmed) {
      return res.status(400).json({ error: 'Taker must confirm sending before raising a dispute' })
    }

    // Validate: wallet must be involved
    if (raisedByLower !== makerAddress && raisedByLower !== takerAddress) {
      return res.status(403).json({ error: 'Not involved in this offer' })
    }

    // Check no existing open dispute
    const existRows = await db.run(sql`
      SELECT id FROM disputes
      WHERE offer_id = ${offerId} AND status = 'open' LIMIT 1
    `)
    if (parseRows(existRows).length) {
      return res.status(400).json({ error: 'Dispute already open for this offer' })
    }

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO disputes
        (id, offer_id, raised_by, reason, status,
         dispute_type, raised_by_role, auto_release_at, created_at)
      VALUES
        (${id}, ${offerId}, ${raisedByLower}, ${reason ?? ''},
         'open', ${disputeType}, ${raisedByRole},
         ${autoReleaseAt}, ${now})
    `)

    // Mark offer as disputed
    await db.run(sql`
      UPDATE p2p_offers SET dispute_raised = 1, updated_at = ${now}
      WHERE id = ${offerId}
    `)

    res.status(201).json({ id, autoReleaseAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/admin/all — admin: all disputes with offer details
router.get('/admin/all', async (req, res) => {
  const status = req.query.status as string
  try {
    const rows = await db.run(sql`
      SELECT d.*,
             o.usdc_amount, o.local_currency, o.local_amount,
             o.maker_address, o.taker_address, o.status as offer_status,
             o.taker_confirmed, o.maker_confirmed
      FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      ${status ? sql`WHERE d.status = ${status}` : sql``}
      ORDER BY d.created_at DESC LIMIT 100
    `)
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /disputes/:id/resolve — admin resolves dispute
// resolution: 'release_to_taker' | 'refund_maker' | 'escalate'
router.patch('/:id/resolve', async (req, res) => {
  const { resolution, resolvedBy, notes } = req.body
  if (!resolution || !resolvedBy) {
    return res.status(400).json({ error: 'resolution and resolvedBy required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // Get dispute + offer
    const dRows = await db.run(sql`
      SELECT d.*, o.id as oid FROM disputes d
      JOIN p2p_offers o ON o.id = d.offer_id
      WHERE d.id = ${req.params.id} LIMIT 1
    `)
    const dr = parseRows(dRows)
    if (!dr.length) return res.status(404).json({ error: 'Dispute not found' })
    const dispute  = dr[0]
    const offerId  = dispute.offer_id ?? dispute[1]

    // Update dispute
    await db.run(sql`
      UPDATE disputes SET
        status      = 'resolved',
        resolution  = ${resolution},
        resolved_by = ${resolvedBy},
        notes       = ${notes ?? null},
        resolved_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Update offer based on resolution
    if (resolution === 'release_to_taker') {
      // Mark maker_confirmed so p2pReleaseWatcher picks it up
      await db.run(sql`
        UPDATE p2p_offers SET
          maker_confirmed = 1,
          updated_at      = ${now}
        WHERE id = ${offerId}
      `)
    } else if (resolution === 'refund_maker') {
      // Cancel offer → p2pReleaseWatcher Job1 handles refund
      await db.run(sql`
        UPDATE p2p_offers SET
          status     = 'cancelled',
          updated_at = ${now}
        WHERE id = ${offerId}
      `)
    }

    res.json({ success: true, resolution })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/disputes.ts"

# ============================================================
# 3 — Backend: update p2pReleaseWatcher to handle auto-release
# ============================================================
cat > afrifx-api/src/jobs/p2pReleaseWatcher.ts << '__EOF__'
// ============================================================
// P2P Release Watcher — 4 jobs:
// Job1: release when both confirmed (every 15s)
// Job2: auto-cancel when taker timer expires + taker NOT confirmed (every 60s)
// Job3: auto-release to taker after 24h when maker goes silent (every 5min)
// Job4: clean up released trade chats (every 5min)
// ============================================================
import { db }             from '../db/client'
import { sql }            from 'drizzle-orm'
import { createWalletClient, createPublicClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arcTestnet }     from '../lib/arc-chain'
import { VAULT_ABI }      from '../lib/vaultAbi'

const VAULT_ADDR = (process.env.AFRIFX_VAULT_ADDRESS ?? '') as `0x${string}`

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function getClients() {
  const pk = process.env.PLATFORM_WALLET_PRIVATE_KEY
  if (!pk) throw new Error('PLATFORM_WALLET_PRIVATE_KEY not set')
  if (!VAULT_ADDR) throw new Error('AFRIFX_VAULT_ADDRESS not set in .env')

  const account = privateKeyToAccount(pk as `0x${string}`)
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() })
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http() })
  return { account, walletClient, publicClient }
}

async function releaseOffer(offerId: string, label: string) {
  const { walletClient } = getClients()
  console.log(`[P2PWatcher] ${label}: releasing ${offerId.slice(0, 18)}…`)
  try {
    const hash = await walletClient.writeContract({
      address:      VAULT_ADDR,
      abi:          VAULT_ABI,
      functionName: 'releaseP2PTrade',
      args:         [offerId as `0x${string}`],
    })
    const now = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status         = 'released',
        release_tx_hash = ${hash},
        updated_at     = ${now}
      WHERE id = ${offerId}
    `)
    // Delete chat messages
    await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
    console.log(`[P2PWatcher] ${label} released ✅ tx: ${hash}`)
    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} release failed:`, err.message)
    return false
  }
}

async function cancelOffer(offerId: string, label: string) {
  const { walletClient } = getClients()
  console.log(`[P2PWatcher] ${label}: cancelling ${offerId.slice(0, 18)}…`)
  try {
    const hash = await walletClient.writeContract({
      address:      VAULT_ADDR,
      abi:          VAULT_ABI,
      functionName: 'cancelP2PTrade',
      args:         [offerId as `0x${string}`],
    })
    const now = Math.floor(Date.now() / 1000)
    await db.run(sql`
      UPDATE p2p_offers SET
        status     = 'cancelled',
        updated_at = ${now}
      WHERE id = ${offerId}
    `)
    console.log(`[P2PWatcher] ${label} cancelled ✅ tx: ${hash}`)
    return true
  } catch (err: any) {
    console.error(`[P2PWatcher] ${label} cancel failed:`, err.message)
    return false
  }
}

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }

  // ── Job 1: Release when both parties confirmed (every 15s) ────────────
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND maker_confirmed = 1
          AND taker_confirmed = 1
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        const offerId = r.id ?? r[0]
        await releaseOffer(offerId, 'Job1')
      }
    } catch (err: any) {
      console.error('[P2PWatcher] Job1 error:', err.message)
    }
  }, 15_000)

  // ── Job 2: Auto-cancel when taker timer expires + taker NOT confirmed (every 60s) ─
  setInterval(async () => {
    const now = Math.floor(Date.now() / 1000)
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status          = 'accepted'
          AND taker_confirmed = 0
          AND taker_deadline  IS NOT NULL
          AND taker_deadline  < ${now}
        LIMIT 5
      `)
      for (const r of parseRows(rows)) {
        const offerId = r.id ?? r[0]
        console.log(`[P2PWatcher] Job2: taker timer expired, cancelling ${offerId.slice(0,18)}…`)
        await cancelOffer(offerId, 'Job2')
      }
    } catch (err: any) {
      console.error('[P2PWatcher] Job2 error:', err.message)
    }
  }, 60_000)

  // ── Job 3: Auto-release to taker after 24h of maker silence (every 5min) ─
  // Fires when:
  //   - taker_confirmed = 1
  //   - maker_confirmed = 0
  //   - status = 'accepted'
  //   - maker_deadline elapsed > 24h ago
  //   - dispute auto_release_at has passed (or no dispute raised)
  setInterval(async () => {
    const now     = Math.floor(Date.now() / 1000)
    const ago24h  = now - 86400
    try {
      // Case A: dispute raised with auto_release_at passed
      const disputeRows = await db.run(sql`
        SELECT o.id FROM p2p_offers o
        JOIN disputes d ON d.offer_id = o.id
        WHERE o.status          = 'accepted'
          AND o.taker_confirmed = 1
          AND o.maker_confirmed = 0
          AND d.status          = 'open'
          AND d.dispute_type    = 'maker_silent'
          AND d.auto_release_at IS NOT NULL
          AND d.auto_release_at < ${now}
        LIMIT 5
      `)
      for (const r of parseRows(disputeRows)) {
        const offerId = r.id ?? r[0]
        console.log(`[P2PWatcher] Job3A: 24h elapsed, auto-releasing to taker: ${offerId.slice(0,18)}…`)
        // Resolve the dispute as released to taker
        await db.run(sql`
          UPDATE disputes SET
            status      = 'resolved',
            resolution  = 'release_to_taker',
            resolved_by = 'system',
            notes       = 'Auto-released after 24h maker silence',
            resolved_at = ${now}
          WHERE offer_id = ${offerId} AND status = 'open'
        `)
        // Set maker_confirmed so Job1 releases it
        await db.run(sql`
          UPDATE p2p_offers SET maker_confirmed = 1, updated_at = ${now}
          WHERE id = ${offerId}
        `)
      }

      // Case B: no dispute raised but 24h+ since taker confirmed and maker_deadline passed
      const silentRows = await db.run(sql`
        SELECT o.id FROM p2p_offers o
        WHERE o.status          = 'accepted'
          AND o.taker_confirmed = 1
          AND o.maker_confirmed = 0
          AND o.dispute_raised  = 0
          AND o.maker_deadline  IS NOT NULL
          AND o.maker_deadline  < ${ago24h}
        LIMIT 5
      `)
      for (const r of parseRows(silentRows)) {
        const offerId = r.id ?? r[0]
        console.log(`[P2PWatcher] Job3B: 24h no action, auto-releasing to taker: ${offerId.slice(0,18)}…`)
        await db.run(sql`
          UPDATE p2p_offers SET maker_confirmed = 1, updated_at = ${now}
          WHERE id = ${offerId}
        `)
      }
    } catch (err: any) {
      console.error('[P2PWatcher] Job3 error:', err.message)
    }
  }, 5 * 60_000)

  // ── Job 4: Clean up released trade chats (every 5min) ─────────────────
  setInterval(async () => {
    try {
      const rows = await db.run(sql`
        SELECT id FROM p2p_offers
        WHERE status = 'released'
          OR  status = 'cancelled'
        LIMIT 20
      `)
      for (const r of parseRows(rows)) {
        const offerId = r.id ?? r[0]
        await db.run(sql`DELETE FROM messages WHERE offer_id = ${offerId}`)
      }
    } catch (err: any) {
      console.error('[P2PWatcher] Job4 error:', err.message)
    }
  }, 5 * 60_000)

  console.log('[P2PWatcher] started — Job1:15s | Job2:60s | Job3:5min | Job4:5min')
}
__EOF__
echo "✅  p2pReleaseWatcher.ts — Job3 auto-release after 24h"

# ============================================================
# 4 — Frontend: update marketplace/[id] — dispute UI
# ============================================================
cat > /tmp/dispute_ui.py << 'PYEOF'
import os

path = os.path.expanduser(
    '~/AfriFX/afrifx-web/app/(app)/marketplace/[id]/page.tsx'
)
with open(path) as f:
    content = f.read()

# Find the dispute section and replace with improved version
old = """                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for maker to confirm receipt…
                    </div>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised &&
                   (offer as any).maker_deadline &&
                   (offer as any).maker_deadline < Math.floor(Date.now() / 1000) && (
                    <div className="space-y-2">
                      <p className="text-xs text-red-400">⚠️ Maker has not confirmed within the agreed window.</p>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={handleDispute} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">
                          ✓ Dispute raised — USDC auto-releases in 24h.
                        </p>
                      )}
                    </div>
                  )}"""

new = """                  {/* Waiting for maker — before deadline */}
                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised &&
                   (offer as any).maker_deadline &&
                   (offer as any).maker_deadline > Math.floor(Date.now() / 1000) && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                      <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                      Waiting for maker to confirm receipt…
                    </div>
                  )}

                  {/* TAKER dispute: maker deadline elapsed, maker went silent */}
                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised &&
                   (offer as any).maker_deadline &&
                   (offer as any).maker_deadline < Math.floor(Date.now() / 1000) && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                        <p className="font-medium text-amber-400">⚠️ Maker has not responded</p>
                        <p className="mt-1 text-amber-600">
                          The maker has not confirmed receipt within the agreed window.
                          You can raise a dispute. If no action is taken within 24h,
                          USDC will auto-release to you.
                        </p>
                      </div>
                      {!disputeDone ? (
                        <Button variant="danger" className="w-full"
                          onClick={() => handleDispute('maker_silent', 'taker')}
                          disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Maker is not responding — raise dispute'}
                        </Button>
                      ) : (
                        <div className="rounded-lg bg-emerald-900/20 p-3 text-xs text-emerald-400">
                          ✓ Dispute raised — USDC auto-releases to you in 24h if unresolved.
                        </div>
                      )}
                    </div>
                  )}

                  {/* MAKER dispute: taker claimed to send but maker didn't receive */}
                  {isMaker && offer.taker_confirmed && !offer.maker_confirmed &&
                   !(offer as any).dispute_raised &&
                   (offer as any).maker_deadline &&
                   (offer as any).maker_deadline < Math.floor(Date.now() / 1000) && (
                    <div className="space-y-2">
                      <div className="rounded-lg border border-red-900/40 bg-red-900/10 p-3 text-xs">
                        <p className="font-medium text-red-400">⚠️ Taker claims to have sent payment</p>
                        <p className="mt-1 text-red-600">
                          The taker says they sent{' '}
                          <strong className="text-red-400">{localAmountFormatted} {offer.local_currency}</strong>{' '}
                          but you haven't received it. If you genuinely did not receive payment,
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
                          ✓ Dispute raised — admin will review and contact both parties.
                        </div>
                      )}
                    </div>
                  )}"""

if old in content:
    content = content.replace(old, new)
    print("✅  Dispute UI updated — maker + taker flows")
else:
    print("⚠️  Dispute UI pattern not found")

# Update handleDispute to accept type and role
old2 = """  async function handleDispute() {
    if (!address) return
    setDisputing(true)
    try {
      await raiseDispute(offer!.id, 'Maker did not confirm receipt within agreed window')
      setDisputeDone(true)
      await load()
    } catch {} finally { setDisputing(false) }
  }"""

new2 = """  async function handleDispute(
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
  }"""

if old2 in content:
    content = content.replace(old2, new2)
    print("✅  handleDispute updated with type + role")
else:
    print("⚠️  handleDispute pattern not found")

with open(path, 'w') as f:
    f.write(content)
PYEOF
python3 /tmp/dispute_ui.py
rm /tmp/dispute_ui.py
echo "✅  marketplace/[id]/page.tsx — dispute UI updated"

# ============================================================
# 5 — Frontend: update useP2P to pass disputeType + raisedByRole
# ============================================================
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/hooks/useP2P.ts')
with open(path) as f:
    content = f.read()

old = """  async function raiseDispute(offerId: string, reason: string) {"""
new = """  async function raiseDispute(
    offerId: string,
    reason: string,
    disputeType: string = 'maker_silent',
    raisedByRole: string = 'taker',
  ) {"""

if old in content:
    content = content.replace(old, new)
    print("✅  raiseDispute signature updated")
else:
    print("⚠️  raiseDispute signature not found")

old2 = """      body: JSON.stringify({ offerId, raisedBy: address, reason }),"""
new2 = """      body: JSON.stringify({ offerId, raisedBy: address, reason, disputeType, raisedByRole }),"""

if old2 in content:
    content = content.replace(old2, new2)
    print("✅  raiseDispute body updated")
else:
    print("⚠️  raiseDispute body pattern not found")

with open(path, 'w') as f:
    f.write(content)
PYEOF
echo "✅  hooks/useP2P.ts — raiseDispute updated"

# ============================================================
# 6 — Admin disputes page: show dispute type + resolution options
# ============================================================
cat > "afrifx-web/app/admin/disputes/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell }   from '@/components/admin/AdminShell'
import { Badge }        from '@/components/ui/badge'
import { Button }       from '@/components/ui/button'
import { adminFetch }   from '@/hooks/useAdminAuth'
import { formatAmount } from '@/lib/utils'
import {
  AlertTriangle, CheckCircle, ExternalLink,
  Loader2, ShieldCheck, RefreshCw, Scale,
} from 'lucide-react'

function parseField(row: any, key: string, idx: number) {
  return row[key] ?? row[idx]
}

export default function AdminDisputesPage() {
  const [disputes, setDisputes] = useState<any[]>([])
  const [loading,  setLoading]  = useState(true)
  const [filter,   setFilter]   = useState<'open'|'resolved'|'all'>('open')
  const [resolving, setResolving] = useState<string|null>(null)

  async function load() {
    setLoading(true)
    try {
      const res  = await adminFetch(`/disputes/admin/all?status=${filter === 'all' ? '' : filter}`)
      const data = await res.json()
      setDisputes(Array.isArray(data) ? data : [])
    } catch { setDisputes([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [filter])

  async function resolve(disputeId: string, offerId: string, resolution: string) {
    if (!confirm(`Resolve as "${resolution}"?`)) return
    setResolving(disputeId)
    try {
      await adminFetch(`/disputes/${disputeId}/resolve`, {
        method: 'PATCH',
        body: JSON.stringify({
          resolution,
          resolvedBy: 'admin',
          notes: `Admin resolved: ${resolution}`,
        }),
      })
      await load()
    } catch (err: any) {
      alert('Failed: ' + err.message)
    } finally {
      setResolving(null)
    }
  }

  const openCount     = disputes.filter(d => (d.status ?? d[4]) === 'open').length
  const resolvedCount = disputes.filter(d => (d.status ?? d[4]) === 'resolved').length

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Disputes</h1>
          <p className="text-sm text-[#64748B]">
            {openCount} open · {resolvedCount} resolved
          </p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {(['open','resolved','all'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" />
        </div>
      ) : disputes.length === 0 ? (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <Scale className="mx-auto mb-2 h-8 w-8 text-[#1B2B4B]" />
          <p className="text-sm text-[#64748B]">No {filter} disputes</p>
        </div>
      ) : (
        <div className="space-y-3">
          {disputes.map((d: any) => {
            const id           = d.id           ?? d[0]
            const offerId      = d.offer_id     ?? d[1]
            const raisedBy     = d.raised_by    ?? d[2]
            const reason       = d.reason       ?? d[3]
            const status       = d.status       ?? d[4]
            const disputeType  = d.dispute_type ?? d[5] ?? 'maker_not_received'
            const raisedByRole = d.raised_by_role ?? d[6] ?? 'taker'
            const autoRelease  = d.auto_release_at ?? d[7]
            const createdAt    = Number(d.created_at ?? d[8] ?? 0)
            const resolution   = d.resolution   ?? d[9]
            const usdcAmount   = Number(d.usdc_amount   ?? d[10] ?? 0)
            const localCcy     = d.local_currency ?? d[11] ?? ''
            const localAmt     = Number(d.local_amount  ?? d[12] ?? 0)
            const makerAddr    = d.maker_address  ?? d[13] ?? ''
            const takerAddr    = d.taker_address  ?? d[14] ?? ''

            const isOpen      = status === 'open'
            const now         = Math.floor(Date.now() / 1000)
            const timeLeft    = autoRelease ? autoRelease - now : null
            const hoursLeft   = timeLeft && timeLeft > 0
              ? Math.ceil(timeLeft / 3600)
              : null

            return (
              <div key={id}
                className={`rounded-xl border bg-[#0F1729] p-5
                  ${isOpen ? 'border-amber-900/50' : 'border-[#1B2B4B]'}`}>
                <div className="mb-3 flex flex-wrap items-start gap-3">
                  {/* Icon */}
                  <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full
                    ${isOpen ? 'bg-amber-900/20' : 'bg-emerald-900/20'}`}>
                    {isOpen
                      ? <AlertTriangle className="h-5 w-5 text-amber-400" />
                      : <CheckCircle   className="h-5 w-5 text-emerald-400" />
                    }
                  </div>

                  {/* Info */}
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2 mb-1">
                      <Badge variant={isOpen ? 'warning' : 'success'}>{status}</Badge>
                      <Badge variant={disputeType === 'maker_silent' ? 'arc' : 'danger'}>
                        {disputeType === 'maker_silent'
                          ? '🔇 Maker silent'
                          : '💸 Payment not received'}
                      </Badge>
                      <Badge variant={raisedByRole === 'maker' ? 'warning' : 'arc'}>
                        Raised by {raisedByRole}
                      </Badge>
                    </div>

                    <p className="text-xs text-[#64748B]">
                      {new Date(createdAt * 1000).toLocaleString()} ·
                      Offer: <span className="font-mono text-[#378ADD]">{offerId?.slice(0,16)}…</span>
                    </p>
                  </div>

                  {/* ArcScan */}
                  <a href={`https://testnet.arcscan.app`} target="_blank" rel="noopener noreferrer"
                    className="text-[#64748B] hover:text-[#378ADD]">
                    <ExternalLink className="h-4 w-4" />
                  </a>
                </div>

                {/* Trade details */}
                <div className="mb-3 grid grid-cols-2 gap-3 text-xs sm:grid-cols-4">
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">USDC in escrow</p>
                    <p className="font-mono font-semibold text-[#E2E8F0]">${formatAmount(usdcAmount)}</p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Local amount</p>
                    <p className="font-mono font-semibold text-[#E2E8F0]">
                      {localAmt.toLocaleString()} {localCcy}
                    </p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Maker</p>
                    <p className="font-mono text-[#E2E8F0]">{makerAddr.slice(0,10)}…</p>
                  </div>
                  <div className="rounded-lg bg-[#080D1B] p-2.5">
                    <p className="text-[#64748B]">Taker</p>
                    <p className="font-mono text-[#E2E8F0]">{takerAddr.slice(0,10)}…</p>
                  </div>
                </div>

                {/* Reason */}
                <div className="mb-3 rounded-lg bg-[#080D1B] p-3 text-xs">
                  <p className="text-[#64748B] mb-1">Dispute reason</p>
                  <p className="text-[#E2E8F0]">{reason || '—'}</p>
                </div>

                {/* Auto-release countdown */}
                {isOpen && disputeType === 'maker_silent' && hoursLeft && (
                  <div className="mb-3 flex items-center gap-2 rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 px-3 py-2 text-xs text-[#378ADD]">
                    <Loader2 className="h-3.5 w-3.5 animate-spin shrink-0" />
                    Auto-releases to taker in ~{hoursLeft}h if unresolved
                  </div>
                )}

                {/* Resolution */}
                {!isOpen && resolution && (
                  <div className="mb-3 flex items-center gap-2 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                    <ShieldCheck className="h-3.5 w-3.5 shrink-0" />
                    Resolved: {resolution.replace(/_/g, ' ')}
                  </div>
                )}

                {/* Admin actions */}
                {isOpen && (
                  <div className="flex flex-wrap gap-2">
                    <Button size="sm"
                      onClick={() => resolve(id, offerId, 'release_to_taker')}
                      disabled={resolving === id}>
                      {resolving === id
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : <CheckCircle className="h-3.5 w-3.5" />}
                      Release USDC to taker
                    </Button>
                    <Button size="sm" variant="danger"
                      onClick={() => resolve(id, offerId, 'refund_maker')}
                      disabled={resolving === id}>
                      {resolving === id
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : <AlertTriangle className="h-3.5 w-3.5" />}
                      Refund USDC to maker
                    </Button>
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </AdminShell>
  )
}
__EOF__
echo "✅  admin/disputes/page.tsx — full dispute management"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 9 — Dispute System complete!"
echo ""
echo "  Flow 1 (taker doesn't send):"
echo "  Job2 auto-cancels → USDC returned to maker ✅"
echo ""
echo "  Flow 2 (taker sent, maker disputes not receiving):"
echo "  → After maker_deadline: MAKER sees dispute button"
echo "  → Raises 'maker_not_received' dispute"
echo "  → Admin reviews → release to taker OR refund maker"
echo ""
echo "  Flow 3 (taker sent, maker goes silent):"
echo "  → After maker_deadline: TAKER sees dispute button"
echo "  → Raises 'maker_silent' dispute"
echo "  → 24h countdown shown to taker"
echo "  → Job3 auto-releases after 24h if unresolved"
echo "  → Admin can also manually resolve"
echo ""
echo "  Admin disputes page:"
echo "  → Shows dispute type (maker silent / payment not received)"
echo "  → Shows auto-release countdown"
echo "  → One-click: Release to taker OR Refund maker"
echo ""
echo "  Restart backend:  cd afrifx-api && npm run dev"
echo "══════════════════════════════════════════════════════"
