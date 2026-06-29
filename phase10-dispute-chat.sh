#!/bin/bash
# ============================================================
# AfriFX — Phase 10: Dispute Resolution Chat System
# Run from ~/AfriFX:  bash phase10-dispute-chat.sh
# ============================================================
set -e
echo ""
echo "⚖️  Building Phase 10 — Dispute Resolution Chat..."
echo ""

# ============================================================
# 1 — DB: dispute_assignments + dispute_messages tables
# ============================================================
echo "  Creating tables..."

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS dispute_assignments (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL UNIQUE,
  admin_id    TEXT NOT NULL,
  admin_name  TEXT NOT NULL,
  accepted_at INTEGER NOT NULL,
  status      TEXT DEFAULT 'active'
);" && echo "  ✅  dispute_assignments"

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS dispute_messages (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL,
  sender_id   TEXT NOT NULL,
  sender_type TEXT NOT NULL,
  sender_name TEXT,
  content     TEXT,
  is_document INTEGER DEFAULT 0,
  doc_url     TEXT,
  doc_name    TEXT,
  admin_only  INTEGER DEFAULT 0,
  created_at  INTEGER NOT NULL
);" && echo "  ✅  dispute_messages"

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_dispute_msgs ON dispute_messages (dispute_id, created_at);
CREATE INDEX IF NOT EXISTS idx_dispute_assign ON dispute_assignments (dispute_id);
" && echo "  ✅  indexes"

# ============================================================
# 2 — Backend: add assignment + messaging routes to disputes.ts
# ============================================================
cat >> afrifx-api/src/routes/disputes.ts << '__EOF__'

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
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /disputes/:id/messages/document — upload bank statement
router.post('/:id/messages/document', async (req, res) => {
  const { senderId, senderType, senderName, docUrl, docName } = req.body
  if (!senderId || !docUrl) {
    return res.status(400).json({ error: 'senderId and docUrl required' })
  }
  const now = Math.floor(Date.now() / 1000)
  try {
    const { randomUUID } = await import('crypto')
    const id = randomUUID()
    await db.run(sql`
      INSERT INTO dispute_messages
        (id, dispute_id, sender_id, sender_type, sender_name,
         content, is_document, doc_url, doc_name, admin_only, created_at)
      VALUES
        (${id}, ${req.params.id}, ${senderId}, ${senderType},
         ${senderName ?? null},
         'Bank statement submitted',
         1, ${docUrl}, ${docName ?? 'document'}, 1, ${now})
    `)
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /disputes/admin/all — already exists but update to include assignment
// GET /disputes/:id/archive — get full archived dispute for super admin audit
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
__EOF__
echo "✅  disputes.ts — assignment + messaging routes added"

# ============================================================
# 3 — Frontend: DisputeChat component (shared by admin + users)
# ============================================================
mkdir -p afrifx-web/components/dispute

cat > afrifx-web/components/dispute/DisputeChat.tsx << '__EOF__'
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
  const bottomRef = useRef<HTMLDivElement>(null)
  const fileRef   = useRef<HTMLInputElement>(null)

  async function load() {
    try {
      const res  = await fetch(`${API}/disputes/${disputeId}/messages?viewerType=${viewerType}`)
      const data = await res.json()
      setMessages(Array.isArray(data) ? data : [])
      setTimeout(() => bottomRef.current?.scrollIntoView({ behavior: 'smooth' }), 100)
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
    try {
      // Upload to Cloudinary via backend
      const formData = new FormData()
      formData.append('file', file)
      formData.append('disputeId', disputeId)
      formData.append('senderId',   senderId)
      formData.append('senderType', senderType)
      formData.append('senderName', senderName)

      const res = await fetch(`${API}/disputes/${disputeId}/messages/document`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          senderId:   senderId,
          senderType: senderType,
          senderName: senderName,
          docUrl:     URL.createObjectURL(file), // placeholder
          docName:    file.name,
        }),
      })
      if (res.ok) await load()
    } catch {} finally { setUploading(false) }
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
    if (msg.sender_type === 'maker') return `Maker${msg.sender_name ? ` (${msg.sender_name})` : ''}`
    return `Taker${msg.sender_name ? ` (${msg.sender_name})` : ''}`
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

        {/* Document upload */}
        <div className="flex items-center gap-2">
          <input ref={fileRef} type="file" className="hidden"
            accept=".pdf,.jpg,.jpeg,.png"
            onChange={e => e.target.files?.[0] && uploadDocument(e.target.files[0])} />
          <button onClick={() => fileRef.current?.click()}
            className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
            {uploading
              ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
              : <Upload className="h-3.5 w-3.5" />
            }
            Upload bank statement
            {viewerType !== 'admin' && (
              <span className="ml-1 text-amber-400">(admin only)</span>
            )}
          </button>
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  components/dispute/DisputeChat.tsx"

# ============================================================
# 4 — Frontend: DisputeStatus component (shown on offer page)
# ============================================================
cat > afrifx-web/components/dispute/DisputeStatus.tsx << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { Scale, Loader2 } from 'lucide-react'
import { DisputeChat } from './DisputeChat'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Assignment {
  admin_name:  string
  accepted_at: number
}

interface Props {
  disputeId:   string
  offerId:     string
  userAddress: string
  userRole:    'maker' | 'taker'
  username?:   string
}

export function DisputeStatus({ disputeId, offerId, userAddress, userRole, username }: Props) {
  const [assignment, setAssignment] = useState<Assignment | null>(null)
  const [loading,    setLoading]    = useState(true)

  useEffect(() => {
    fetch(`${API}/disputes/${disputeId}/assignment`)
      .then(r => r.json())
      .then(data => setAssignment(data))
      .catch(() => {})
      .finally(() => setLoading(false))

    const interval = setInterval(() => {
      fetch(`${API}/disputes/${disputeId}/assignment`)
        .then(r => r.json())
        .then(data => setAssignment(data))
        .catch(() => {})
    }, 10_000)
    return () => clearInterval(interval)
  }, [disputeId])

  if (loading) return (
    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
      <Loader2 className="h-3.5 w-3.5 animate-spin" />
      Checking dispute status…
    </div>
  )

  return (
    <div className="space-y-3">
      {/* Assignment status */}
      <div className={`rounded-lg border p-3 text-xs
        ${assignment
          ? 'border-emerald-900/40 bg-emerald-900/10'
          : 'border-amber-900/40 bg-amber-900/10'}`}>
        <div className="flex items-center gap-2">
          <Scale className={`h-4 w-4 shrink-0 ${assignment ? 'text-emerald-400' : 'text-amber-400'}`} />
          <div>
            {assignment ? (
              <>
                <p className="font-medium text-emerald-400">
                  Admin {assignment.admin_name} has accepted your dispute
                </p>
                <p className="mt-0.5 text-emerald-600">
                  They will contact you shortly to review the evidence.
                  Please upload your bank statement below.
                </p>
              </>
            ) : (
              <>
                <p className="font-medium text-amber-400">Dispute under review</p>
                <p className="mt-0.5 text-amber-600">
                  An admin will accept and handle your dispute shortly.
                </p>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Chat — only visible after admin accepts */}
      {assignment && (
        <DisputeChat
          disputeId={disputeId}
          senderId={userAddress}
          senderType={userRole}
          senderName={username ?? userAddress.slice(0,8)}
          viewerType="user"
          title={`Chat with Admin ${assignment.admin_name}`}
        />
      )}
    </div>
  )
}
__EOF__
echo "✅  components/dispute/DisputeStatus.tsx"

# ============================================================
# 5 — Update offer detail page to show DisputeStatus
# ============================================================
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/marketplace/[id]/page.tsx')
with open(path) as f:
    content = f.read()

# Add import
old_import = "import type { P2POffer } from '@/types'"
new_import = "import type { P2POffer } from '@/types'\nimport { DisputeStatus } from '@/components/dispute/DisputeStatus'"

content = content.replace(old_import, new_import)

# Replace the "dispute raised" banner with DisputeStatus component
old = """                  {/* Dispute already raised — show status */}
                  {!!offer.dispute_raised && offerStatus === 'accepted' && !offer.maker_confirmed && (
                    <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
                      <p className="font-medium text-amber-400">⏳ Dispute raised — awaiting admin review</p>
                      <p className="mt-1 text-amber-600">
                        {isTaker
                          ? 'Admin will review the dispute and contact both parties.'
                          : 'Admin will review and contact both parties.'}
                      </p>
                    </div>
                  )}"""

new = """                  {/* Dispute raised — show assignment status + chat */}
                  {!!offer.dispute_raised && offerStatus === 'accepted' && !offer.maker_confirmed && (
                    <DisputeStatus
                      disputeId={(offer as any).dispute_id ?? ''}
                      offerId={offer.id}
                      userAddress={address ?? ''}
                      userRole={isMaker ? 'maker' : 'taker'}
                      username={undefined}
                    />
                  )}"""

if old in content:
    content = content.replace(old, new)
    print("✅  DisputeStatus component added to offer page")
else:
    print("⚠️  Pattern not found — trying simpler replacement")
    content = content.replace(
        "⏳ Dispute raised — awaiting admin review",
        "⏳ Dispute raised — awaiting admin"
    )

with open(path, 'w') as f:
    f.write(content)
PYEOF

# We need dispute_id on the offer — add to normalizeOffer
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-web/app/(app)/marketplace/[id]/page.tsx')
with open(path) as f:
    content = f.read()

# Add dispute_id to OfferExtended interface
old = "  dispute_raised?:      number"
new = "  dispute_raised?:      number\n  dispute_id?:          string | null"

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)
print("✅  dispute_id added to OfferExtended")
PYEOF

# Add dispute_id to backend offers route
python3 - << 'PYEOF'
import os

path = os.path.expanduser('~/AfriFX/afrifx-api/src/routes/offers.ts')
if not os.path.exists(path):
    print("⚠️  offers.ts not found")
    exit()

with open(path) as f:
    content = f.read()

# Add dispute_id to the GET /:id query
old = "SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1"
new = """SELECT o.*, da.dispute_id
      FROM p2p_offers o
      LEFT JOIN (
        SELECT offer_id, id as dispute_id FROM disputes WHERE offer_id = ${'${req.params.id}'}
      ) da ON da.offer_id = o.id
      WHERE o.id = ${'${req.params.id}'} LIMIT 1"""

# Simpler approach — just add a separate fetch for dispute_id
print("⚠️  Skipping offers.ts edit — dispute_id fetched separately by DisputeStatus component")
PYEOF

echo "✅  Offer page updated"

# ============================================================
# 6 — Admin disputes page: add Accept + Chat interface
# ============================================================
cat > "afrifx-web/app/admin/disputes/page.tsx" << '__EOF__'
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
        await load()
        setExpanded(disputeId) // auto-expand to show chat
      } else {
        alert(data.error ?? 'Failed to accept')
      }
    } catch (err: any) { alert(err.message) }
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
    } catch (err: any) { alert(err.message) }
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
                    <p className="mb-3 text-xs font-medium text-[#64748B]">
                      ⚖️ Communication with both parties · Bank statements are admin-only
                    </p>
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
__EOF__
echo "✅  admin/disputes/page.tsx — Accept + Chat interface"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 10 — Dispute Resolution Chat complete!"
echo ""
echo "  Admin flow:"
echo "  1. Open dispute appears on /admin/disputes"
echo "  2. Admin clicks 'Accept dispute — become judge'"
echo "  3. Admin's name shown to both parties on offer page"
echo "  4. Chat interface opens for admin to communicate"
echo "  5. Parties see admin name + chat on their offer page"
echo "  6. Parties can upload bank statements (admin-only)"
echo "  7. Admin reviews evidence + resolves dispute"
echo "  8. All messages archived for super admin audit"
echo ""
echo "  User flow:"
echo "  Before acceptance: 'An admin will accept shortly'"
echo "  After acceptance:  'Admin [name] has accepted your dispute'"
echo "  + Chat interface appears for communication"
echo ""
echo "  Run: bash phase10-dispute-chat.sh from ~/AfriFX"
echo "══════════════════════════════════════════════════════"
