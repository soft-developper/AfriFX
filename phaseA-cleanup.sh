#!/bin/bash
# ============================================================
# AfriFX -- Phase A: Codebase audit & cleanup
#
# Scope (from a full scan of afrifx-web + afrifx-api/src):
#   * FIX (functional): dispute document upload was broken -- it built
#     a FormData but sent JSON with URL.createObjectURL(file), an
#     in-browser blob URL that never reached the server. Now sends the
#     real file as multipart; backend streams it to Cloudinary (same
#     path chat.ts already uses) and stores the real URL.
#   * Removed 7 debug console.log statements (transaction memo IDs were
#     being logged to the browser console in production).
#   * Replaced native alert() error popups in the admin offers,
#     disputes, and sub-admins pages with inline, dismissable banners.
#   * Removed a stray leftover comment in disputes.ts and trailing
#     whitespace in offers/page.tsx.
#
# NOT changed (scanned, deliberately left alone):
#   * 'coming soon' on the connect page -- genuine roadmap copy.
#   * unified-balance.ts Phase-2 stub -- documented intentional stub.
#   * XXXX in reference-format strings (INV-YYYYMMDD-XXXX) -- real format.
#   * confirm()/prompt() on destructive admin actions -- left as
#     deliberate friction; converting to modals is a separate UX task.
#   * No spelling errors or test-phase copy were found in user-facing
#     strings -- the product text already reads as final.
#
# Run from ~/AfriFX:  bash phaseA-cleanup.sh
# ============================================================
set -e
echo ""
echo "Applying Phase A -- audit & cleanup..."
echo ""

mkdir -p "afrifx-api/src/routes"
cat > "afrifx-api/src/routes/disputes.ts" << 'DISPUTES_EOF'
import { Router }     from 'express'
import { notifyDisputeRaised, notifyAdminsOfNewDispute, notifyDisputeAccepted, notifyAdminMessage } from '../services/email/notifications'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'
import multer         from 'multer'
import { uploadBuffer } from '../lib/cloudinary'

const router = Router()

// Multer — hold the file in memory, then stream it to Cloudinary
const upload = multer({
  storage: multer.memoryStorage(),
  limits:  { fileSize: 10 * 1024 * 1024 }, // 10 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'image/jpeg', 'image/png', 'image/webp', 'image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ]
    cb(null, allowed.includes(file.mimetype))
  },
})

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
  const autoReleaseAt = null // No auto-release when dispute raised — admin must resolve

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
         dispute_type, raised_by_role, auto_release_at,
         auto_settle_at, created_at)
      VALUES
        (${id}, ${offerId}, ${raisedByLower}, ${reason ?? ''},
         'open', ${disputeType}, ${raisedByRole},
         ${autoReleaseAt},
         ${now + 86400}, ${now})
    `)

    // Mark offer as disputed
    await db.run(sql`
      UPDATE p2p_offers SET dispute_raised = 1, updated_at = ${now}
      WHERE id = ${offerId}
    `)

    // Determine other party
    const otherPartyWallet = raisedByLower === makerAddress ? takerAddress : makerAddress

    // Fire notification (non-blocking)
    // Alert all admins with resolve_disputes permission
    notifyAdminsOfNewDispute({
      raisedByWallet: raisedByLower,
      raisedByRole:   raisedByRole as 'maker' | 'taker',
      disputeType:    disputeType as 'maker_silent' | 'maker_not_received',
      usdcAmount:     Number(offer.usdc_amount ?? 0),
      localAmount:    Number(offer.local_amount ?? 0),
      localCcy:       offer.local_currency ?? '',
      disputeId:      id,
    }).catch((err: any) => console.error('[Notify] admin_alert:', err.message))

    notifyDisputeRaised({
      raisedByWallet:   raisedByLower,
      otherPartyWallet: otherPartyWallet ?? '',
      raisedByRole:     raisedByRole as 'maker' | 'taker',
      disputeType:      disputeType as 'maker_silent' | 'maker_not_received',
      offerId,
      disputeId:        id,
    }).catch(err => console.error('[Notify] dispute_raised failed:', err.message))

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
        resolution_type = ${resolution},
        admin_resolved_by = ${resolvedBy},
        admin_notes = ${notes ?? null},
        admin_resolved_at = ${now}
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

// ── Dispute Assignment ─────────────────────────────────────

// POST /disputes/:id/accept — admin accepts to handle dispute
router.post('/:id/accept', async (req, res) => {
  const { adminId, adminName } = req.body
  if (!adminId || !adminName) {
    return res.status(400).json({ error: 'adminId and adminName required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    // Check not already assigned
    const existing = await db.run(sql`
      SELECT id FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    if (parseRows(existing).length) {
      return res.status(400).json({ error: 'Dispute already accepted by another admin' })
    }

    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_assignments (id, dispute_id, admin_id, admin_name, accepted_at)
      VALUES (${id}, ${req.params.id}, ${adminId}, ${adminName}, ${now})
    `)

    // Update dispute status to 'in_review'
    await db.run(sql`
      UPDATE disputes SET status = 'in_review', updated_at = ${now}
      WHERE id = ${req.params.id}
    `)

    // Fetch offer_id from dispute
    const dRows = await db.run(sql`SELECT offer_id FROM disputes WHERE id = ${req.params.id} LIMIT 1`)
    const dr = parseRows(dRows)[0]

    if (dr) {
      notifyDisputeAccepted({
        disputeId: req.params.id,
        offerId:   dr.offer_id ?? dr[0],
        adminName,
      }).catch((err: any) => console.error('[Notify] dispute_accepted:', err.message))
    }

    res.json({ success: true, adminName })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/:id/assignment — get assigned admin for a dispute
router.get('/:id/assignment', async (req, res) => {
  try {
    const rows = await db.run(sql`
      SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1
    `)
    const r = parseRows(rows)
    res.json(r.length ? r[0] : null)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Dispute Messages ───────────────────────────────────────

// GET /disputes/:id/messages?viewerType=admin|maker|taker
router.get('/:id/messages', async (req, res) => {
  const viewerType = req.query.viewerType as string ?? 'user'
  const isAdmin    = viewerType === 'admin'
  try {
    // Admins see all messages; users only see non-admin-only messages
    const rows = await db.run(
      isAdmin
        ? sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`
        : sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} AND admin_only = 0 ORDER BY created_at ASC`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages — send a message
router.post('/:id/messages', async (req, res) => {
  const { senderId, senderType, senderName, content, adminOnly = 0 } = req.body
  if (!senderId || !senderType || !content) {
    return res.status(400).json({ error: 'senderId, senderType, content required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType},
         ${senderName ?? null}, ${content}, ${adminOnly ? 1 : 0}, ${now})
    `)

    // If admin sent a message, notify both parties (rate-limited)
    if (senderType === 'admin' && !adminOnly) {
      const dRows = await db.run(sql`
        SELECT o.id as offer_id, o.maker_address, o.taker_address
        FROM disputes d
        JOIN p2p_offers o ON o.id = d.offer_id
        WHERE d.id = ${req.params.id} LIMIT 1
      `)
      const d = parseRows(dRows)[0]
      if (d) {
        const offerId = d.offer_id ?? d[0]
        const parties = [d.maker_address ?? d[1], d.taker_address ?? d[2]].filter(Boolean)
        for (const wallet of parties) {
          notifyAdminMessage({
            recipientWallet: wallet,
            adminName:       senderName ?? 'Admin',
            offerId,
            disputeId:       req.params.id,
          }).catch((err: any) => console.error('[Notify] admin_message:', err.message))
        }
      }
    }

    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages/document — upload a supporting document
// Accepts multipart form-data (field name "file"), stores it on Cloudinary,
// and records the resulting URL as an admin-only dispute message.
router.post('/:id/messages/document', upload.single('file'), async (req, res) => {
  const { senderId, senderType, senderName } = req.body
  if (!senderId) return res.status(400).json({ error: 'senderId required' })
  if (!req.file) return res.status(400).json({ error: 'No file provided' })

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    return res.status(500).json({ error: 'File storage is not configured on the server' })
  }

  const now = Math.floor(Date.now() / 1000)
  try {
    const uploaded = await uploadBuffer(
      req.file.buffer,
      req.file.originalname,
      req.file.mimetype,
      `dispute-${req.params.id}`,
    )

    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, is_document, doc_url, doc_name, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType ?? 'user'},
         ${senderName ?? null},
         'Supporting document submitted',
         1, ${uploaded.url}, ${uploaded.name}, 1, ${now})
    `)
    res.status(201).json({ id, docUrl: uploaded.url, docName: uploaded.name })
  } catch (err: any) {
    console.error('[Disputes] Document upload failed:', err.message)
    res.status(500).json({ error: 'Upload failed: ' + err.message })
  }
})

// GET /disputes/:id/archive — full archived dispute for super-admin audit
router.get('/:id/archive', async (req, res) => {
  try {
    const [disputeRows, msgRows, assignRows] = await Promise.all([
      db.run(sql`SELECT d.*, o.usdc_amount, o.local_currency, o.local_amount, o.maker_address, o.taker_address FROM disputes d JOIN p2p_offers o ON o.id = d.offer_id WHERE d.id = ${req.params.id} LIMIT 1`),
      db.run(sql`SELECT * FROM dispute_messages WHERE dispute_id = ${req.params.id} ORDER BY created_at ASC`),
      db.run(sql`SELECT * FROM dispute_assignments WHERE dispute_id = ${req.params.id} LIMIT 1`),
    ])
    res.json({
      dispute:    parseRows(disputeRows)[0] ?? null,
      messages:   parseRows(msgRows),
      assignment: parseRows(assignRows)[0] ?? null,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})
DISPUTES_EOF
echo "  afrifx-api/src/routes/disputes.ts (real multipart -> Cloudinary upload; removed stray comment)"

mkdir -p "afrifx-web/components/dispute"
cat > "afrifx-web/components/dispute/DisputeChat.tsx" << 'DISPUTECHAT_EOF'
'use client'
import { useState, useEffect, useRef } from 'react'
import { Send, FileText, Upload, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Message {
  id:          string
  sender_id:   string
  sender_type: 'maker' | 'taker' | 'admin'
  sender_name: string | null
  content:     string | null
  is_document: number
  doc_url:     string | null
  doc_name:    string | null
  admin_only:  number
  created_at:  number
}

interface Props {
  disputeId:   string
  senderId:    string
  senderType:  'maker' | 'taker' | 'admin'
  senderName:  string
  viewerType?: 'admin' | 'user'
  title?:      string
}

export function DisputeChat({
  disputeId, senderId, senderType, senderName,
  viewerType = 'user', title = 'Dispute communication',
}: Props) {
  const [messages,  setMessages]  = useState<Message[]>([])
  const [text,      setText]      = useState('')
  const [sending,   setSending]   = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploadError, setUploadError] = useState<string | null>(null)
  const bottomRef = useRef<HTMLDivElement>(null)
  const fileRef   = useRef<HTMLInputElement>(null)

  async function load() {
    try {
      const res  = await fetch(`${API}/disputes/${disputeId}/messages?viewerType=${viewerType}`)
      const data = await res.json()
      setMessages(Array.isArray(data) ? data : [])
    } catch {}
  }

  useEffect(() => {
    load()
    const interval = setInterval(load, 5000)
    return () => clearInterval(interval)
  }, [disputeId])

  async function sendMessage() {
    if (!text.trim() || sending) return
    setSending(true)
    try {
      await fetch(`${API}/disputes/${disputeId}/messages`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          senderId:   senderId,
          senderType: senderType,
          senderName: senderName,
          content:    text.trim(),
          adminOnly:  0,
        }),
      })
      setText('')
      await load()
    } catch {} finally { setSending(false) }
  }

  async function uploadDocument(file: File) {
    setUploading(true)
    setUploadError(null)
    try {
      // Send the actual file as multipart form-data; the backend streams
      // it to Cloudinary and records the returned URL.
      const formData = new FormData()
      formData.append('file',       file)
      formData.append('senderId',   senderId)
      formData.append('senderType', senderType)
      formData.append('senderName', senderName)

      const res = await fetch(`${API}/disputes/${disputeId}/messages/document`, {
        method: 'POST',
        body:   formData, // no Content-Type header — the browser sets the multipart boundary
      })
      if (res.ok) {
        await load()
      } else {
        const data = await res.json().catch(() => ({}))
        setUploadError(data.error ?? 'Upload failed. Please try again.')
      }
    } catch {
      setUploadError('Upload failed. Please check your connection and try again.')
    } finally { setUploading(false) }
  }

  function getBubbleStyle(msg: Message) {
    const isMe = msg.sender_id === senderId
    if (isMe) return 'ml-auto bg-[#378ADD]/20 border-[#378ADD]/30'
    if (msg.sender_type === 'admin') return 'bg-amber-900/20 border-amber-900/30'
    return 'bg-[#080D1B] border-[#1B2B4B]'
  }

  function getSenderLabel(msg: Message) {
    if (msg.sender_id === senderId) return 'You'
    if (msg.sender_type === 'admin') return `⚖️ Admin${msg.sender_name ? ` (${msg.sender_name})` : ''}`
    if (msg.sender_type === 'maker') return msg.sender_name ?? `Seller${msg.sender_name ? ` (${msg.sender_name})` : ''}`
    return msg.sender_name ?? 'Buyer'
  }

  return (
    <div className="flex flex-col rounded-xl border border-[#1B2B4B] bg-[#0F1729] overflow-hidden">
      {/* Header */}
      <div className="border-b border-[#1B2B4B] px-4 py-3">
        <p className="text-sm font-medium text-[#E2E8F0]">{title}</p>
        <p className="text-xs text-[#64748B]">
          {viewerType === 'admin'
            ? 'All parties — messages sent here are visible to maker and taker'
            : 'Communicate with the assigned admin · Upload bank statements below'}
        </p>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-3 min-h-[200px] max-h-[400px]">
        {messages.length === 0 ? (
          <p className="text-center text-xs text-[#64748B] py-4">
            No messages yet — start the conversation
          </p>
        ) : (
          messages.map(msg => (
            <div key={msg.id} className={`max-w-[80%] rounded-xl border p-3 text-xs ${getBubbleStyle(msg)}`}>
              <p className={`mb-1 font-medium ${msg.sender_type === 'admin' ? 'text-amber-400' : 'text-[#378ADD]'}`}>
                {getSenderLabel(msg)}
                {msg.admin_only === 1 && (
                  <span className="ml-2 rounded bg-amber-900/30 px-1 py-0.5 text-[10px] text-amber-400">
                    Admin only
                  </span>
                )}
              </p>
              {msg.is_document === 1 ? (
                <div className="flex items-center gap-2">
                  <FileText className="h-4 w-4 text-[#378ADD]" />
                  <span className="text-[#E2E8F0]">{msg.doc_name ?? 'Document'}</span>
                  {msg.doc_url && (
                    <a href={msg.doc_url} target="_blank" rel="noopener noreferrer"
                      className="text-[#378ADD] hover:underline">View</a>
                  )}
                </div>
              ) : (
                <p className="text-[#E2E8F0] whitespace-pre-wrap">{msg.content}</p>
              )}
              <p className="mt-1 text-[10px] text-[#64748B]">
                {new Date(msg.created_at * 1000).toLocaleTimeString()}
              </p>
            </div>
          ))
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div className="border-t border-[#1B2B4B] p-3 space-y-2">
        <div className="flex gap-2">
          <input
            value={text}
            onChange={e => setText(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.shiftKey && sendMessage()}
            placeholder="Type your message…"
            className="flex-1 rounded-lg border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-xs text-[#E2E8F0] placeholder:text-[#64748B] outline-none focus:ring-1 focus:ring-[#378ADD]"
          />
          <Button size="sm" onClick={sendMessage} disabled={!text.trim() || sending}>
            {sending ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Send className="h-3.5 w-3.5" />}
          </Button>
        </div>

        {/* Document upload — only for users (maker/taker), not admin */}
        {viewerType !== 'admin' && (
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <input ref={fileRef} type="file" className="hidden"
                accept=".pdf,.png,.jpg,.jpeg,.webp"
                onChange={e => e.target.files?.[0] && uploadDocument(e.target.files[0])} />
              <button onClick={() => fileRef.current?.click()} disabled={uploading}
                className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors disabled:opacity-50">
                {uploading
                  ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  : <Upload className="h-3.5 w-3.5" />
                }
                Upload supporting document (PDF or image — admin will review)
              </button>
            </div>
            {uploadError && (
              <p className="text-xs text-red-400">{uploadError}</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
DISPUTECHAT_EOF
echo "  components/dispute/DisputeChat.tsx (send real file, surface upload errors, broaden accepted types)"

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useP2P.ts" << 'USEP2P_EOF'
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
USEP2P_EOF
echo "  hooks/useP2P.ts (removed debug console.log)"

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useCorridorSwap.ts" << 'USECORRIDOR_EOF'
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
    if (!useMemo) console.warn('[Memo] Corridor: Memo not available, using direct transfers')

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
USECORRIDOR_EOF
echo "  hooks/useCorridorSwap.ts (removed debug console.log)"

mkdir -p "afrifx-web/app/admin/offers"
cat > "afrifx-web/app/admin/offers/page.tsx" << 'OFFERS_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Loader2, ExternalLink, RefreshCw, AlertCircle, X } from 'lucide-react'

const FLAGS: Record<string,string> = { NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬' }

function norm(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], maker_address: r[1], taker_address: r[2], usdc_amount: r[3],
    local_currency: r[4], local_amount: r[5], status: r[7],
    maker_confirmed: r[8], taker_confirmed: r[9], created_at: r[13],
  }
  return r
}

export default function AdminOffers() {
  const [offers,  setOffers]  = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [filter,  setFilter]  = useState('all')
  const [busy,    setBusy]    = useState<string|null>(null)
  const [error,   setError]   = useState<string|null>(null)

  async function load() {
    setLoading(true)
    const q = filter === 'all' ? '' : `?status=${filter}`
    const res = await adminFetch(`/admin/manage/offers${q}`)
    const data = await res.json()
    setOffers(Array.isArray(data) ? data.map(norm) : [])
    setLoading(false)
  }

  useEffect(() => { load() }, [filter])

  async function forceRelease(id: string) {
    if (!confirm('Force release USDC to the taker? This is irreversible.')) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/release`, { method: 'POST' })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to release offer')
    } finally { setBusy(null) }
  }

  async function forceCancel(id: string) {
    const reason = prompt('Reason for cancellation (refunds maker):')
    if (reason === null) return
    setBusy(id)
    try {
      const res = await adminFetch(`/admin/manage/offers/${id}/cancel`, {
        method: 'POST', body: JSON.stringify({ reason }),
      })
      if (res.ok) await load()
      else setError((await res.json()).error ?? 'Failed to cancel offer')
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Offers management</h1>
        <button onClick={load} className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      <div className="mb-4 flex gap-2">
        {['all','open','accepted','released','cancelled'].map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-full px-3 py-1 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#378ADD] text-white' : 'border border-[#1B2B4B] text-[#64748B]'}`}>
            {f}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-2">
          {offers.map(o => (
            <div key={o.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
              <div className="flex items-center gap-4">
                <div className="flex h-9 w-9 items-center justify-center rounded-full bg-[#080D1B] text-lg">
                  {FLAGS[o.local_currency] ?? '🌍'}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-medium text-[#E2E8F0]">
                      {Number(o.usdc_amount).toFixed(2)} USDC ↔ {Number(o.local_amount).toLocaleString()} {o.local_currency}
                    </p>
                    <Badge variant={
                      o.status === 'released' ? 'success' :
                      o.status === 'accepted' ? 'arc' :
                      o.status === 'cancelled' ? 'danger' : 'warning'
                    }>{o.status}</Badge>
                  </div>
                  <p className="font-mono text-[10px] text-[#64748B]">
                    {o.id.slice(0,20)}… · maker {o.maker_address?.slice(0,8)}…
                    {o.taker_address && ` · taker ${o.taker_address.slice(0,8)}…`}
                  </p>
                </div>
                {o.status === 'accepted' && (
                  <div className="flex gap-2">
                    <Button size="sm" onClick={() => forceRelease(o.id)} disabled={busy === o.id}>
                      {busy === o.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Force release'}
                    </Button>
                    <Button size="sm" variant="danger" onClick={() => forceCancel(o.id)} disabled={busy === o.id}>
                      Cancel
                    </Button>
                  </div>
                )}
              </div>
            </div>
          ))}
          {offers.length === 0 && <p className="py-8 text-center text-sm text-[#64748B]">No offers found</p>}
        </div>
      )}
    </AdminShell>
  )
}
OFFERS_EOF
echo "  app/admin/offers/page.tsx (alert() -> inline error banner; trailing ws)"

mkdir -p "afrifx-web/app/admin/disputes"
cat > "afrifx-web/app/admin/disputes/page.tsx" << 'ADISPUTES_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell }    from '@/components/admin/AdminShell'
import { Badge }         from '@/components/ui/badge'
import { Button }        from '@/components/ui/button'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { DisputeChat }   from '@/components/dispute/DisputeChat'
import { formatAmount }  from '@/lib/utils'
import {
  AlertTriangle, CheckCircle, ExternalLink,
  Loader2, Scale, RefreshCw, ChevronDown, ChevronUp,
  AlertCircle, X,
} from 'lucide-react'

export default function AdminDisputesPage() {
  const { admin }                     = useAdminAuth()
  const [disputes,   setDisputes]     = useState<any[]>([])
  const [loading,    setLoading]      = useState(true)
  const [filter,     setFilter]       = useState<'open'|'in_review'|'resolved'|'all'>('open')
  const [resolving,  setResolving]    = useState<string|null>(null)
  const [accepting,  setAccepting]    = useState<string|null>(null)
  const [expanded,   setExpanded]     = useState<string|null>(null)
  const [assignments, setAssignments] = useState<Record<string, any>>({})
  const [error,       setError]       = useState<string|null>(null)

  async function load() {
    setLoading(true)
    try {
      const res  = await adminFetch(`/disputes/admin/all${filter !== 'all' ? `?status=${filter}` : ''}`)
      const data = await res.json()
      const list = Array.isArray(data) ? data : []
      setDisputes(list)

      // Fetch assignments for all disputes
      const assignMap: Record<string, any> = {}
      await Promise.all(list.map(async (d: any) => {
        const id = d.id ?? d[0]
        try {
          const r = await adminFetch(`/disputes/${id}/assignment`)
          const a = await r.json()
          if (a) assignMap[id] = a
        } catch {}
      }))
      setAssignments(assignMap)
    } catch { setDisputes([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [filter])

  async function acceptDispute(disputeId: string) {
    if (!admin) return
    setAccepting(disputeId)
    try {
      const res = await adminFetch(`/disputes/${disputeId}/accept`, {
        method: 'POST',
        body:   JSON.stringify({ adminId: admin.id, adminName: admin.username }),
      })
      const data = await res.json()
      if (data.success) {
        setFilter('in_review') // switch to in_review tab
        await load()
        setExpanded(disputeId) // auto-expand to show chat
      } else {
        setError(data.error ?? 'Failed to accept dispute')
      }
    } catch (err: any) { setError(err.message ?? 'Failed to accept dispute') }
    finally { setAccepting(null) }
  }

  async function resolve(disputeId: string, resolution: string) {
    if (!confirm(`Resolve as "${resolution}"?`)) return
    setResolving(disputeId)
    try {
      await adminFetch(`/disputes/${disputeId}/resolve`, {
        method: 'PATCH',
        body:   JSON.stringify({
          resolution,
          resolvedBy: admin?.username ?? 'admin',
          notes:      `Admin resolved: ${resolution}`,
        }),
      })
      await load()
    } catch (err: any) { setError(err.message ?? 'Failed to resolve dispute') }
    finally { setResolving(null) }
  }

  const openCount     = disputes.filter(d => (d.status ?? d[4]) === 'open').length
  const inReviewCount = disputes.filter(d => (d.status ?? d[4]) === 'in_review').length
  const resolvedCount = disputes.filter(d => (d.status ?? d[4]) === 'resolved').length

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Disputes</h1>
          <p className="text-sm text-[#64748B]">
            {openCount} open · {inReviewCount} in review · {resolvedCount} resolved
          </p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </div>

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Filter */}
      <div className="mb-4 flex gap-1 rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-1 w-fit">
        {(['open','in_review','resolved','all'] as const).map(f => (
          <button key={f} onClick={() => setFilter(f)}
            className={`rounded-md px-3 py-1.5 text-xs capitalize transition-colors
              ${filter === f ? 'bg-[#1B2B4B] text-[#E2E8F0]' : 'text-[#64748B]'}`}>
            {f.replace('_', ' ')}
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
            const id           = d.id            ?? d[0]
            const offerId      = d.offer_id      ?? d[1]
            const raisedBy     = d.raised_by     ?? d[2]
            const reason       = d.reason        ?? d[3]
            const status       = d.status        ?? d[4]
            const disputeType  = d.dispute_type  ?? 'maker_not_received'
            const raisedByRole = d.raised_by_role ?? 'taker'
            const createdAt    = Number(d.created_at ?? d[8] ?? 0)
            const resolution   = d.resolution_type
            const usdcAmount   = Number(d.usdc_amount   ?? 0)
            const localCcy     = d.local_currency ?? ''
            const localAmt     = Number(d.local_amount  ?? 0)
            const makerAddr    = d.maker_address  ?? ''
            const takerAddr    = d.taker_address  ?? ''

            const isOpen      = status === 'open'
            const isInReview  = status === 'in_review'
            const assignment  = assignments[id]
            const isMyCase    = assignment?.admin_id === admin?.id
            const isExpanded  = expanded === id

            return (
              <div key={id}
                className={`rounded-xl border bg-[#0F1729] overflow-hidden
                  ${isOpen ? 'border-amber-900/50' :
                    isInReview ? 'border-[#378ADD]/40' : 'border-[#1B2B4B]'}`}>

                {/* Header */}
                <div className="p-5">
                  <div className="mb-3 flex flex-wrap items-start gap-3">
                    <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full
                      ${isOpen ? 'bg-amber-900/20' : isInReview ? 'bg-[#378ADD]/10' : 'bg-emerald-900/20'}`}>
                      {isOpen ? <AlertTriangle className="h-5 w-5 text-amber-400" />
                       : isInReview ? <Scale className="h-5 w-5 text-[#378ADD]" />
                       : <CheckCircle className="h-5 w-5 text-emerald-400" />}
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="flex flex-wrap items-center gap-2 mb-1">
                        <Badge variant={isOpen ? 'warning' : isInReview ? 'arc' : 'success'}>
                          {status.replace('_', ' ')}
                        </Badge>
                        <Badge variant={disputeType === 'maker_silent' ? 'arc' : 'danger'}>
                          {disputeType === 'maker_silent' ? '🔇 Maker silent' : '💸 Payment not received'}
                        </Badge>
                        <Badge variant={raisedByRole === 'maker' ? 'warning' : 'arc'}>
                          By {raisedByRole}
                        </Badge>
                        {assignment && (
                          <Badge variant="success">⚖️ {assignment.admin_name}</Badge>
                        )}
                      </div>
                      <p className="text-xs text-[#64748B]">
                        {new Date(createdAt * 1000).toLocaleString()} ·
                        <span className="font-mono text-[#378ADD] ml-1">{offerId?.slice(0,16)}…</span>
                      </p>
                    </div>

                    {/* Expand toggle */}
                    <button onClick={() => setExpanded(isExpanded ? null : id)}
                      className="text-[#64748B] hover:text-[#E2E8F0]">
                      {isExpanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                    </button>
                  </div>

                  {/* Trade details */}
                  <div className="mb-3 grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                    <div className="rounded-lg bg-[#080D1B] p-2">
                      <p className="text-[#64748B]">USDC</p>
                      <p className="font-mono font-semibold text-[#E2E8F0]">${formatAmount(usdcAmount)}</p>
                    </div>
                    <div className="rounded-lg bg-[#080D1B] p-2">
                      <p className="text-[#64748B]">Local</p>
                      <p className="font-mono font-semibold text-[#E2E8F0]">{localAmt.toLocaleString()} {localCcy}</p>
                    </div>
                    <div className="rounded-lg bg-[#080D1B] p-2">
                      <p className="text-[#64748B]">Maker</p>
                      <p className="font-mono text-[#E2E8F0]">{makerAddr.slice(0,10)}…</p>
                    </div>
                    <div className="rounded-lg bg-[#080D1B] p-2">
                      <p className="text-[#64748B]">Taker</p>
                      <p className="font-mono text-[#E2E8F0]">{takerAddr.slice(0,10)}…</p>
                    </div>
                  </div>

                  {/* Reason */}
                  <div className="mb-3 rounded-lg bg-[#080D1B] p-2.5 text-xs">
                    <p className="text-[#64748B] mb-1">Reason</p>
                    <p className="text-[#E2E8F0]">{reason || '—'}</p>
                  </div>

                  {/* Resolution */}
                  {resolution && (
                    <div className="mb-3 rounded-lg bg-emerald-900/20 px-3 py-2 text-xs text-emerald-400">
                      Resolved: {resolution.replace(/_/g, ' ')}
                    </div>
                  )}

                  {/* Actions */}
                  <div className="flex flex-wrap gap-2">
                    {/* Accept button — for unassigned open disputes */}
                    {isOpen && !assignment && (
                      <Button size="sm" onClick={() => acceptDispute(id)}
                        disabled={accepting === id}>
                        {accepting === id
                          ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          : <Scale className="h-3.5 w-3.5" />
                        }
                        Accept dispute — become judge
                      </Button>
                    )}

                    {/* Already assigned to another admin */}
                    {(isOpen || isInReview) && assignment && !isMyCase && (
                      <p className="text-xs text-[#64748B] py-1">
                        Handled by Admin {assignment.admin_name}
                      </p>
                    )}

                    {/* Resolve buttons — only for assigned admin */}
                    {isInReview && isMyCase && (
                      <>
                        <Button size="sm"
                          onClick={() => resolve(id, 'release_to_taker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <CheckCircle className="h-3.5 w-3.5" />}
                          Release to taker
                        </Button>
                        <Button size="sm" variant="danger"
                          onClick={() => resolve(id, 'refund_maker')}
                          disabled={resolving === id}>
                          {resolving === id ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            : <AlertTriangle className="h-3.5 w-3.5" />}
                          Refund maker
                        </Button>
                      </>
                    )}

                    <a href={`https://testnet.arcscan.app`} target="_blank" rel="noopener noreferrer"
                      className="ml-auto text-[#64748B] hover:text-[#378ADD]">
                      <ExternalLink className="h-4 w-4" />
                    </a>
                  </div>
                </div>

                {/* Chat — expanded section */}
                {isExpanded && admin && (isInReview || isOpen) && isMyCase && (
                  <div className="border-t border-[#1B2B4B] p-4">
                    <p className="mb-2 text-xs font-medium text-[#64748B]">
                      ⚖️ Messages go to both parties · Request statements privately below
                    </p>
                    {/* Request statement buttons */}
                    <div className="mb-3 flex gap-2">
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank account statement for the disputed period so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-[#378ADD]/40 bg-[#378ADD]/10 px-3 py-1.5 text-xs text-[#378ADD] hover:bg-[#378ADD]/20 transition-colors">
                        📋 Request statement from maker
                      </button>
                      <button
                        onClick={async () => {
                          await adminFetch(`/disputes/${id}/messages`, {
                            method: 'POST',
                            body: JSON.stringify({
                              senderId: admin?.id, senderType: 'admin',
                              senderName: admin?.username,
                              content: '📋 Please upload your bank transfer receipt or proof of payment so we can review your case.',
                              adminOnly: 0,
                            }),
                          })
                        }}
                        className="rounded-lg border border-[#378ADD]/40 bg-[#378ADD]/10 px-3 py-1.5 text-xs text-[#378ADD] hover:bg-[#378ADD]/20 transition-colors">
                        📋 Request statement from taker
                      </button>
                    </div>
                    <DisputeChat
                      disputeId={id}
                      senderId={admin.id}
                      senderType="admin"
                      senderName={admin.username}
                      viewerType="admin"
                      title="Three-way dispute chat"
                    />
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
ADISPUTES_EOF
echo "  app/admin/disputes/page.tsx (alert() -> inline error banner)"

mkdir -p "afrifx-web/app/admin/sub-admins"
cat > "afrifx-web/app/admin/sub-admins/page.tsx" << 'SUBADMINS_EOF'
'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Loader2, Plus, Shield, Trash2, Pause, Play,
  Key, Check, Mail, CheckCircle, AlertCircle, X,
} from 'lucide-react'

export default function AdminSubAdmins() {
  const { admin, invite } = useAdminAuth()
  const [admins,  setAdmins]  = useState<any[]>([])
  const [permMeta, setPermMeta] = useState<any>({})
  const [allPerms, setAllPerms] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [busy, setBusy] = useState<string|null>(null)

  // Invite form state
  const [inviteEmail, setInviteEmail] = useState('')
  const [selectedPerms, setSelectedPerms] = useState<string[]>([])
  const [inviteError,   setInviteError]   = useState<string|null>(null)
  const [inviteSuccess, setInviteSuccess] = useState<string|null>(null)

  // Editing
  const [editingId, setEditingId] = useState<string|null>(null)
  const [editPerms, setEditPerms] = useState<string[]>([])

  async function load() {
    setLoading(true)
    const [adminRes, permRes] = await Promise.all([
      adminFetch('/admin/manage/admins'),
      adminFetch('/admin/manage/permissions'),
    ])
    const adminData = await adminRes.json()
    const permData  = await permRes.json()
    setAdmins(Array.isArray(adminData) ? adminData : [])
    setPermMeta(permData.meta ?? {})
    setAllPerms(permData.all ?? [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  async function sendInvite() {
    if (!inviteEmail || selectedPerms.length === 0) return
    setInviteError(null); setInviteSuccess(null)
    setBusy('create')
    try {
      const result = await invite(inviteEmail, selectedPerms)
      if (result.success) {
        setInviteSuccess(result.message ?? `Invitation sent to ${inviteEmail}`)
        setInviteEmail(''); setSelectedPerms([])
      } else {
        setInviteError((result as any).error ?? 'Could not send invitation')
      }
    } finally { setBusy(null) }
  }

  async function toggleStatus(a: any) {
    setBusy(a.id)
    const newStatus = a.status === 'active' ? 'suspended' : 'active'
    let suspendedUntil = null
    if (newStatus === 'suspended') {
      const days = prompt('Suspend for how many days? (leave blank for indefinite)')
      if (days && !isNaN(Number(days))) {
        suspendedUntil = Math.floor(Date.now() / 1000) + Number(days) * 86400
      }
    }
    try {
      await adminFetch(`/admin/manage/admins/${a.id}`, {
        method: 'PATCH', body: JSON.stringify({ status: newStatus, suspendedUntil }),
      })
      await load()
    } finally { setBusy(null) }
  }

  async function deleteAdmin(id: string) {
    if (!confirm('Remove this sub-admin permanently?')) return
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, { method: 'DELETE' })
      await load()
    } finally { setBusy(null) }
  }

  async function savePerms(id: string) {
    setBusy(id)
    try {
      await adminFetch(`/admin/manage/admins/${id}`, {
        method: 'PATCH', body: JSON.stringify({ permissions: editPerms }),
      })
      setEditingId(null)
      await load()
    } finally { setBusy(null) }
  }

  async function resetCredentials(a: any) {
    const newPassword = prompt(`Reset password for ${a.username}:\nEnter new password (min 12 chars):`)
    if (!newPassword) return
    setInviteError(null); setInviteSuccess(null)
    setBusy(a.id)
    try {
      const res = await adminFetch(`/admin/manage/admins/${a.id}/credentials`, {
        method: 'PATCH', body: JSON.stringify({ newPassword }),
      })
      if (res.ok) setInviteSuccess(`Password reset for ${a.username}`)
      else setInviteError((await res.json()).error ?? 'Failed to reset password')
    } finally { setBusy(null) }
  }

  function togglePerm(list: string[], setList: (l: string[]) => void, perm: string) {
    setList(list.includes(perm) ? list.filter(p => p !== perm) : [...list, perm])
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Sub-admin management</h1>
        {admin?.role === 'super_admin' && (
          <Button size="sm" onClick={() => { setShowForm(!showForm); setInviteError(null); setInviteSuccess(null) }}>
            <Plus className="h-4 w-4" /> Invite sub-admin
          </Button>
        )}
      </div>

      {admin?.role !== 'super_admin' && (
        <div className="mb-6 flex items-center gap-2 rounded-lg bg-[#0F1729] border border-[#1B2B4B] px-4 py-3 text-xs text-[#64748B]">
          Only the super admin can invite new sub-admins.
        </div>
      )}

      {/* Standalone feedback (e.g. after a password reset, when the invite form is closed) */}
      {!showForm && inviteSuccess && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
          <span className="flex items-start gap-2">
            <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
          </span>
          <button onClick={() => setInviteSuccess(null)} className="shrink-0 hover:text-emerald-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}
      {!showForm && inviteError && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
          </span>
          <button onClick={() => setInviteError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Invite form */}
      {showForm && (
        <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-1 text-sm font-medium text-[#E2E8F0]">Invite a sub-admin</p>
          <p className="mb-4 text-xs text-[#64748B]">
            They'll get an email with a link to set their own password and, optionally, 2FA.
          </p>
          <div className="relative mb-4">
            <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#64748B]" />
            <Input className="pl-9" placeholder="Email address" type="email" autoComplete="off"
              value={inviteEmail} onChange={e => setInviteEmail(e.target.value)} />
          </div>

          <p className="mb-2 text-xs font-medium text-[#E2E8F0]">Permissions</p>
          <div className="mb-4 grid grid-cols-2 gap-2 lg:grid-cols-3">
            {allPerms.map(perm => (
              <button key={perm} onClick={() => togglePerm(selectedPerms, setSelectedPerms, perm)}
                className={`flex items-start gap-2 rounded-lg border p-2.5 text-left transition-colors
                  ${selectedPerms.includes(perm)
                    ? 'border-[#378ADD] bg-[#378ADD]/10'
                    : 'border-[#1B2B4B] bg-[#080D1B]'}`}>
                <div className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded
                  ${selectedPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                  {selectedPerms.includes(perm) && <Check className="h-3 w-3 text-white" />}
                </div>
                <div>
                  <p className="text-xs font-medium text-[#E2E8F0]">{permMeta[perm]?.label ?? perm}</p>
                  <p className="text-[10px] text-[#64748B]">{permMeta[perm]?.description}</p>
                </div>
              </button>
            ))}
          </div>

          <div className="flex gap-2">
            <Button variant="outline" className="flex-1" onClick={() => setShowForm(false)}>Cancel</Button>
            <Button className="flex-1" onClick={sendInvite}
              disabled={!inviteEmail || selectedPerms.length === 0 || busy === 'create'}>
              {busy === 'create' ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Mail className="h-4 w-4" /> Send invite</>}
            </Button>
          </div>

          {inviteSuccess && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-emerald-900/20 px-3 py-2.5 text-xs text-emerald-400">
              <CheckCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteSuccess}
            </div>
          )}
          {inviteError && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{inviteError}
            </div>
          )}
        </div>
      )}

      {/* Admins list */}
      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-[#378ADD]" /></div>
      ) : (
        <div className="space-y-3">
          {admins.map(a => (
            <div key={a.id} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <div className={`flex h-10 w-10 items-center justify-center rounded-full
                    ${a.role === 'super_admin' ? 'bg-amber-500/20' : 'bg-[#378ADD]/10'}`}>
                    <Shield className={`h-5 w-5 ${a.role === 'super_admin' ? 'text-amber-400' : 'text-[#378ADD]'}`} />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-[#E2E8F0]">{a.username}</p>
                      <Badge variant={a.role === 'super_admin' ? 'warning' : 'arc'}>
                        {a.role === 'super_admin' ? '★ Super Admin' : 'Sub-admin'}
                      </Badge>
                      {a.status === 'suspended' && <Badge variant="danger">Suspended</Badge>}
                    </div>
                    <p className="text-xs text-[#64748B]">{a.email}</p>
                    {a.last_login && (
                      <p className="text-[10px] text-[#64748B]">
                        Last login: {new Date(Number(a.last_login) * 1000).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>

                {a.role !== 'super_admin' && (
                  <div className="flex gap-1">
                    <button onClick={() => resetCredentials(a)} disabled={busy === a.id}
                      title="Reset password"
                      className="rounded p-1.5 text-[#64748B] hover:text-[#378ADD]">
                      <Key className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => toggleStatus(a)} disabled={busy === a.id}
                      title={a.status === 'active' ? 'Suspend' : 'Activate'}
                      className="rounded p-1.5 text-[#64748B] hover:text-amber-400">
                      {a.status === 'active' ? <Pause className="h-3.5 w-3.5" /> : <Play className="h-3.5 w-3.5" />}
                    </button>
                    <button onClick={() => deleteAdmin(a.id)} disabled={busy === a.id}
                      title="Remove"
                      className="rounded p-1.5 text-[#64748B] hover:text-red-400">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                )}
              </div>

              {/* Permissions */}
              {a.role !== 'super_admin' && (
                <div className="mt-3 border-t border-[#1B2B4B] pt-3">
                  {editingId === a.id ? (
                    <div>
                      <div className="mb-2 grid grid-cols-2 gap-2 lg:grid-cols-3">
                        {allPerms.map(perm => (
                          <button key={perm} onClick={() => togglePerm(editPerms, setEditPerms, perm)}
                            className={`flex items-center gap-1.5 rounded-lg border p-2 text-left text-xs transition-colors
                              ${editPerms.includes(perm) ? 'border-[#378ADD] bg-[#378ADD]/10 text-[#E2E8F0]' : 'border-[#1B2B4B] text-[#64748B]'}`}>
                            <div className={`flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded
                              ${editPerms.includes(perm) ? 'bg-[#378ADD]' : 'border border-[#1B2B4B]'}`}>
                              {editPerms.includes(perm) && <Check className="h-2.5 w-2.5 text-white" />}
                            </div>
                            {permMeta[perm]?.label ?? perm}
                          </button>
                        ))}
                      </div>
                      <div className="flex gap-2">
                        <Button size="sm" variant="outline" onClick={() => setEditingId(null)}>Cancel</Button>
                        <Button size="sm" onClick={() => savePerms(a.id)} disabled={busy === a.id}>
                          {busy === a.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Save permissions'}
                        </Button>
                      </div>
                    </div>
                  ) : (
                    <div className="flex items-center justify-between">
                      <div className="flex flex-wrap gap-1.5">
                        {(a.permissions ?? []).length === 0 ? (
                          <span className="text-xs text-[#64748B]">No permissions granted</span>
                        ) : (a.permissions ?? []).map((p: string) => (
                          <span key={p} className="rounded-full bg-[#1B2B4B] px-2 py-0.5 text-[10px] text-[#E2E8F0]">
                            {permMeta[p]?.label ?? p}
                          </span>
                        ))}
                      </div>
                      <button onClick={() => { setEditingId(a.id); setEditPerms(a.permissions ?? []) }}
                        className="shrink-0 text-xs text-[#378ADD] hover:underline">
                        Edit permissions
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </AdminShell>
  )
}
SUBADMINS_EOF
echo "  app/admin/sub-admins/page.tsx (alert() -> inline feedback banner)"

echo ""
echo "======================================================"
echo "Phase A complete."
echo ""
echo "  IMPORTANT -- the dispute upload fix relies on Cloudinary,"
echo "  which chat.ts already uses. Make sure these env vars are set"
echo "  on the API (Render) -- they should already be, since chat"
echo "  uploads work:"
echo "    CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET"
echo ""
echo "  NEXT:"
echo "    cd afrifx-api && npm install && npx tsc --noEmit"
echo "    cd afrifx-web && npm run build"
echo "    git add -A && git commit -m 'Phase A: audit & cleanup (fix dispute upload, remove debug logs, alert->banners)'"
echo "    git push   # then verify on prod: raise a dispute, upload a PDF as a user, confirm the admin can open it"
echo "======================================================"
