#!/bin/bash
# ============================================================
# AfriFX — P2P Trade Chat System
# Run from ~/AfriFX:  bash p2p-chat.sh
# ============================================================
set -e
echo ""
echo "💬  Building P2P Trade Chat System..."
echo ""

# ============================================================
# 1 — Turso: messages table
# ============================================================
echo "  Creating messages table in Turso..."
turso db shell afrifx "
CREATE TABLE IF NOT EXISTS messages (
  id           TEXT PRIMARY KEY,
  offer_id     TEXT NOT NULL,
  sender       TEXT NOT NULL,
  content      TEXT,
  media_url    TEXT,
  media_type   TEXT,
  msg_type     TEXT NOT NULL DEFAULT 'text',
  quick_action TEXT,
  read_maker   INTEGER NOT NULL DEFAULT 0,
  read_taker   INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL
);" && echo "  ✅  messages table created"

turso db shell afrifx "
CREATE INDEX IF NOT EXISTS idx_messages_offer
ON messages (offer_id, created_at ASC);" && echo "  ✅  index created"

# ============================================================
# 2 — Backend: chat routes
# ============================================================
cat > afrifx-api/src/routes/chat.ts << '__EOF__'
import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// Verify the requester is maker or taker of this offer
async function verifyAccess(offerId: string, wallet: string): Promise<'maker'|'taker'|null> {
  const rows = await db.run(
    sql`SELECT maker_address, taker_address FROM p2p_offers WHERE id = ${offerId} LIMIT 1`
  )
  const r = Array.isArray((rows as any).rows) ? (rows as any).rows : []
  if (!r.length) return null
  const offer = r[0]
  const maker = (offer.maker_address ?? offer[0] ?? '').toLowerCase()
  const taker = (offer.taker_address ?? offer[1] ?? '').toLowerCase()
  const w     = wallet.toLowerCase()
  if (w === maker) return 'maker'
  if (w === taker) return 'taker'
  return null
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

function normalizeMsg(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], offer_id: row[1], sender: row[2], content: row[3],
      media_url: row[4], media_type: row[5], msg_type: row[6],
      quick_action: row[7], read_maker: Number(row[8]),
      read_taker: Number(row[9]), created_at: Number(row[10]),
    }
  }
  return { ...row, read_maker: Number(row.read_maker), read_taker: Number(row.read_taker) }
}

// GET /chat/:offerId?wallet=0x&after=<timestamp>
// after: only return messages newer than this unix timestamp
router.get('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  const after  = Number(req.query.after ?? 0)

  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  const role = await verifyAccess(offerId, wallet)
  if (!role) return res.status(403).json({ error: 'Access denied' })

  try {
    const rows = await db.run(
      sql`SELECT * FROM messages
          WHERE offer_id  = ${offerId}
            AND created_at > ${after}
          ORDER BY created_at ASC
          LIMIT 100`
    )
    const msgs = parseRows(rows).map(normalizeMsg)

    // Mark as read
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    await db.run(
      sql`UPDATE messages SET ${sql.raw(field)} = 1
          WHERE offer_id = ${offerId}
            AND sender   != ${wallet}`
    ).catch(() => {})

    res.json({ messages: msgs, role })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /chat/:offerId/unread?wallet=0x
router.get('/:offerId/unread', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })

  const role = await verifyAccess(offerId, wallet)
  if (!role) return res.json({ count: 0 })

  try {
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    const rows  = await db.run(
      sql`SELECT COUNT(*) as cnt FROM messages
          WHERE offer_id  = ${offerId}
            AND sender    != ${wallet}
            AND ${sql.raw(field)} = 0`
    )
    const r = parseRows(rows)
    res.json({ count: Number(r[0]?.cnt ?? r[0]?.[0] ?? 0) })
  } catch { res.json({ count: 0 }) }
})

// POST /chat/:offerId — send message
router.post('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const {
    wallet, content, mediaUrl, mediaType,
    msgType = 'text', quickAction,
  } = req.body

  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  if (!content && !mediaUrl) return res.status(400).json({ error: 'content or mediaUrl required' })

  const role = await verifyAccess(offerId, wallet.toLowerCase())
  if (!role) return res.status(403).json({ error: 'Access denied' })

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO messages
          (id, offer_id, sender, content, media_url, media_type,
           msg_type, quick_action, created_at)
          VALUES
          (${id}, ${offerId}, ${wallet.toLowerCase()},
           ${content ?? null}, ${mediaUrl ?? null}, ${mediaType ?? null},
           ${msgType}, ${quickAction ?? null}, ${now})`
    )
    res.status(201).json({
      id, offer_id: offerId, sender: wallet.toLowerCase(),
      content, media_url: mediaUrl, media_type: mediaType,
      msg_type: msgType, quick_action: quickAction,
      read_maker: 0, read_taker: 0, created_at: now,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /chat/:offerId/system — post a system message (internal use)
router.post('/:offerId/system', async (req, res) => {
  const { offerId } = req.params
  const { content } = req.body
  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`INSERT INTO messages
          (id, offer_id, sender, content, msg_type, created_at)
          VALUES
          (${id}, ${offerId}, 'system', ${content}, 'system', ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /chat/:offerId/typing — typing indicator
router.post('/:offerId/typing', async (req, res) => {
  // Stored in memory — expires after 3s on client side
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const role = await verifyAccess(req.params.offerId, wallet)
  if (!role) return res.status(403).json({ error: 'Access denied' })
  typingMap.set(`${req.params.offerId}-${role}`, Date.now())
  res.json({ ok: true })
})

// GET /chat/:offerId/typing?wallet=0x — check if other party is typing
router.get('/:offerId/typing', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ typing: false })
  const role = await verifyAccess(offerId, wallet)
  if (!role) return res.json({ typing: false })
  const otherRole = role === 'maker' ? 'taker' : 'maker'
  const lastTyped = typingMap.get(`${offerId}-${otherRole}`) ?? 0
  res.json({ typing: Date.now() - lastTyped < 3000 })
})

// In-memory typing store (cleared on restart — fine for MVP)
const typingMap = new Map<string, number>()

export default router
__EOF__
echo "✅  routes/chat.ts"

# Register chat route
cat >> afrifx-api/src/index.ts << '__APPEND__'
// This append handled by index.ts rewrite below
__APPEND__

cat > afrifx-api/src/index.ts << '__EOF__'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }         from './middleware/cors'
import { rateLimitMiddleware }    from './middleware/rateLimit'
import { errorHandler }           from './middleware/errorHandler'
import ratesRouter                from './routes/rates'
import transactionsRouter         from './routes/transactions'
import userRouter                 from './routes/user'
import offersRouter               from './routes/offers'
import profileRouter              from './routes/profile'
import chatRouter                 from './routes/chat'
import { startRatePoller }        from './jobs/ratePoller'
import { startEventListener }     from './services/eventListener'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', chain: 'Arc Testnet 5042002', ts: Date.now() })
})

app.use('/rates',        ratesRouter)
app.use('/transactions', transactionsRouter)
app.use('/user',         userRouter)
app.use('/offers',       offersRouter)
app.use('/profile',      profileRouter)
app.use('/chat',         chatRouter)

app.use(errorHandler)

app.listen(PORT, () => {
  console.log(`\n🚀  AfriFX API · http://localhost:${PORT}`)
  console.log(`    Chain: Arc Testnet · Chain ID 5042002`)
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
})
__EOF__
echo "✅  index.ts — /chat route registered"

# ============================================================
# 3 — Frontend: Cloudinary .env vars
# ============================================================
cat >> afrifx-web/.env.local << '__EOF__'

# Cloudinary — media uploads for P2P chat
# Create a free account at cloudinary.com
# Create an unsigned upload preset in Settings > Upload
NEXT_PUBLIC_CLOUDINARY_CLOUD_NAME=your_cloud_name
NEXT_PUBLIC_CLOUDINARY_UPLOAD_PRESET=afrifx_chat
__EOF__
echo "✅  .env.local — Cloudinary vars added (fill in your values)"

# ============================================================
# 4 — Frontend: lib/cloudinary.ts
# ============================================================
cat > afrifx-web/lib/cloudinary.ts << '__EOF__'
// Cloudinary media upload for P2P chat
// Uses unsigned upload — create preset at cloudinary.com
// Settings → Upload → Upload Presets → Add unsigned preset

export interface CloudinaryUploadResult {
  url:      string
  type:     'image' | 'document' | 'video'
  name:     string
  size:     number
  format:   string
}

const CLOUD_NAME     = process.env.NEXT_PUBLIC_CLOUDINARY_CLOUD_NAME
const UPLOAD_PRESET  = process.env.NEXT_PUBLIC_CLOUDINARY_UPLOAD_PRESET ?? 'afrifx_chat'

export async function uploadToCloudinary(
  file: File,
  onProgress?: (pct: number) => void,
): Promise<CloudinaryUploadResult> {
  if (!CLOUD_NAME) throw new Error('NEXT_PUBLIC_CLOUDINARY_CLOUD_NAME not set in .env.local')

  const formData = new FormData()
  formData.append('file',           file)
  formData.append('upload_preset',  UPLOAD_PRESET)
  formData.append('folder',         'afrifx/chat')

  const url = `https://api.cloudinary.com/v1_1/${CLOUD_NAME}/auto/upload`

  // Use XHR for progress tracking
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', url)

    xhr.upload.addEventListener('progress', (e) => {
      if (e.lengthComputable && onProgress) {
        onProgress(Math.round((e.loaded / e.total) * 100))
      }
    })

    xhr.addEventListener('load', () => {
      if (xhr.status === 200) {
        const data = JSON.parse(xhr.responseText)
        const type = data.resource_type === 'image' ? 'image'
                   : data.resource_type === 'video' ? 'video'
                   : 'document'
        resolve({
          url:    data.secure_url,
          type,
          name:   file.name,
          size:   data.bytes,
          format: data.format,
        })
      } else {
        reject(new Error(`Upload failed: ${xhr.responseText}`))
      }
    })

    xhr.addEventListener('error', () => reject(new Error('Upload failed')))
    xhr.send(formData)
  })
}

export function isImageFile(file: File): boolean {
  return file.type.startsWith('image/')
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024)        return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
__EOF__
echo "✅  lib/cloudinary.ts"

# ============================================================
# 5 — Frontend: hooks/useChat.ts
# ============================================================
cat > afrifx-web/hooks/useChat.ts << '__EOF__'
'use client'
import { useState, useEffect, useRef, useCallback } from 'react'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface ChatMessage {
  id:           string
  offer_id:     string
  sender:       string      // wallet address | 'system'
  content:      string | null
  media_url:    string | null
  media_type:   'image' | 'document' | 'video' | null
  msg_type:     'text' | 'media' | 'system' | 'quick-action'
  quick_action: string | null
  read_maker:   number
  read_taker:   number
  created_at:   number
}

export function useChat(offerId: string | null) {
  const { address } = useAccount()
  const [messages,  setMessages]  = useState<ChatMessage[]>([])
  const [role,      setRole]      = useState<'maker'|'taker'|null>(null)
  const [typing,    setTyping]    = useState(false)
  const [unread,    setUnread]    = useState(0)
  const [error,     setError]     = useState<string|null>(null)

  const lastTsRef    = useRef(0)
  const intervalRef  = useRef<NodeJS.Timeout>()
  const typingTimerRef = useRef<NodeJS.Timeout>()

  const fetchMessages = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(
        `${API}/chat/${offerId}?wallet=${address}&after=${lastTsRef.current}`
      )
      if (res.status === 403) { setError('Access denied'); return }
      const data = await res.json()
      if (data.messages?.length) {
        setMessages(prev => {
          const ids = new Set(prev.map(m => m.id))
          const fresh = data.messages.filter((m: ChatMessage) => !ids.has(m.id))
          if (!fresh.length) return prev
          const updated = [...prev, ...fresh].sort((a,b) => a.created_at - b.created_at)
          lastTsRef.current = updated[updated.length - 1].created_at
          return updated
        })
        setRole(data.role)
      } else if (!role && data.role) {
        setRole(data.role)
      }
    } catch {}
  }, [offerId, address, role])

  const fetchTyping = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(`${API}/chat/${offerId}/typing?wallet=${address}`)
      const data = await res.json()
      setTyping(data.typing ?? false)
    } catch {}
  }, [offerId, address])

  // Poll every 2 seconds
  useEffect(() => {
    if (!offerId || !address) return
    fetchMessages()
    intervalRef.current = setInterval(() => {
      fetchMessages()
      fetchTyping()
    }, 2000)
    return () => clearInterval(intervalRef.current)
  }, [offerId, address, fetchMessages, fetchTyping])

  // Send typing indicator with debounce
  const sendTyping = useCallback(() => {
    if (!offerId || !address) return
    fetch(`${API}/chat/${offerId}/typing`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ wallet: address }),
    }).catch(() => {})
    clearTimeout(typingTimerRef.current)
  }, [offerId, address])

  // Send a message
  const sendMessage = useCallback(async (
    content?:    string,
    mediaUrl?:   string,
    mediaType?:  string,
    msgType:     string = 'text',
    quickAction?: string,
  ): Promise<ChatMessage | null> => {
    if (!offerId || !address) return null
    try {
      const res  = await fetch(`${API}/chat/${offerId}`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
          wallet: address, content, mediaUrl, mediaType,
          msgType, quickAction,
        }),
      })
      const msg: ChatMessage = await res.json()
      setMessages(prev => {
        const ids = new Set(prev.map(m => m.id))
        if (ids.has(msg.id)) return prev
        const updated = [...prev, msg].sort((a,b) => a.created_at - b.created_at)
        lastTsRef.current = updated[updated.length - 1].created_at
        return updated
      })
      return msg
    } catch (err: any) {
      setError(err.message)
      return null
    }
  }, [offerId, address])

  return { messages, role, typing, unread, error, sendMessage, sendTyping }
}
__EOF__
echo "✅  hooks/useChat.ts"

# ============================================================
# 6 — Frontend: chat components
# ============================================================
mkdir -p afrifx-web/components/chat

# MessageBubble
cat > afrifx-web/components/chat/MessageBubble.tsx << '__EOF__'
'use client'
import { Download, FileText, Image as ImageIcon } from 'lucide-react'
import type { ChatMessage } from '@/hooks/useChat'

const QUICK_ACTION_LABELS: Record<string, { emoji: string; label: string; color: string }> = {
  payment_sent:     { emoji: '💸', label: 'Payment sent',         color: 'bg-blue-900/40 text-blue-300 border-blue-700/40'     },
  payment_received: { emoji: '✅', label: 'Payment received',     color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
  need_more_time:   { emoji: '⏰', label: 'Need a bit more time', color: 'bg-amber-900/40 text-amber-300 border-amber-700/40'   },
  dispute_warning:  { emoji: '⚠️', label: 'Dispute raised',       color: 'bg-red-900/40 text-red-300 border-red-700/40'        },
  trade_complete:   { emoji: '🎉', label: 'Trade complete!',       color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
}

interface Props {
  msg:     ChatMessage
  isMe:    boolean
  senderName: string
}

export function MessageBubble({ msg, isMe, senderName }: Props) {
  const time = new Date(msg.created_at * 1000).toLocaleTimeString([], {
    hour: '2-digit', minute: '2-digit',
  })

  // System message
  if (msg.msg_type === 'system' || msg.sender === 'system') {
    return (
      <div className="flex justify-center py-1">
        <span className="rounded-full bg-[#1B2B4B] px-3 py-1 text-[11px] text-[#64748B]">
          {msg.content}
        </span>
      </div>
    )
  }

  // Quick action message
  if (msg.msg_type === 'quick-action' && msg.quick_action) {
    const qa = QUICK_ACTION_LABELS[msg.quick_action]
    return (
      <div className={`flex ${isMe ? 'justify-end' : 'justify-start'} py-0.5`}>
        <div className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-medium ${qa?.color ?? 'bg-[#1B2B4B] text-[#64748B] border-[#1B2B4B]'}`}>
          <span>{qa?.emoji}</span>
          <span>{qa?.label ?? msg.quick_action}</span>
          <span className="opacity-60 text-[10px]">{time}</span>
        </div>
      </div>
    )
  }

  return (
    <div className={`flex ${isMe ? 'justify-end' : 'justify-start'} group py-0.5`}>
      <div className={`max-w-[75%] ${isMe ? 'items-end' : 'items-start'} flex flex-col gap-0.5`}>
        {/* Sender name (only for received messages) */}
        {!isMe && (
          <span className="px-1 text-[10px] font-medium text-[#64748B]">{senderName}</span>
        )}

        <div className={`rounded-2xl px-3 py-2 ${
          isMe
            ? 'rounded-tr-sm bg-[#378ADD] text-white'
            : 'rounded-tl-sm bg-[#1B2B4B] text-[#E2E8F0]'
        }`}>

          {/* Media content */}
          {msg.media_url && (
            <div className="mb-2">
              {msg.media_type === 'image' ? (
                <a href={msg.media_url} target="_blank" rel="noopener noreferrer">
                  <img
                    src={msg.media_url}
                    alt="Shared image"
                    className="max-h-48 w-full rounded-lg object-cover cursor-pointer hover:opacity-90 transition-opacity"
                  />
                </a>
              ) : (
                <a
                  href={msg.media_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={`flex items-center gap-2 rounded-lg p-2 text-xs
                    ${isMe ? 'bg-white/10 text-white' : 'bg-[#0F1729] text-[#E2E8F0]'}`}
                >
                  <FileText className="h-4 w-4 shrink-0" />
                  <span className="flex-1 truncate">{msg.content ?? 'Document'}</span>
                  <Download className="h-3.5 w-3.5 shrink-0 opacity-60" />
                </a>
              )}
            </div>
          )}

          {/* Text content */}
          {msg.content && msg.media_type !== 'document' && (
            <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">
              {msg.content}
            </p>
          )}

          {/* Timestamp */}
          <p className={`mt-0.5 text-right text-[10px] ${isMe ? 'text-white/60' : 'text-[#64748B]'}`}>
            {time}
            {isMe && <span className="ml-1">{msg.read_maker && msg.read_taker ? '✓✓' : '✓'}</span>}
          </p>
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  components/chat/MessageBubble.tsx"

# QuickActions component
cat > afrifx-web/components/chat/QuickActions.tsx << '__EOF__'
'use client'
interface Props {
  onAction: (action: string, label: string) => void
  disabled: boolean
}

const ACTIONS = [
  { id: 'payment_sent',     emoji: '💸', label: 'Payment sent'         },
  { id: 'payment_received', emoji: '✅', label: 'Payment received'     },
  { id: 'need_more_time',   emoji: '⏰', label: 'Need more time'       },
]

export function QuickActions({ onAction, disabled }: Props) {
  return (
    <div className="flex flex-wrap gap-1.5 px-3 pb-2">
      {ACTIONS.map(({ id, emoji, label }) => (
        <button
          key={id}
          onClick={() => onAction(id, label)}
          disabled={disabled}
          className="flex items-center gap-1.5 rounded-full border border-[#1B2B4B] bg-[#0F1729] px-2.5 py-1 text-xs text-[#64748B] transition-colors hover:border-[#378ADD] hover:text-[#E2E8F0] disabled:opacity-40"
        >
          <span>{emoji}</span>
          <span>{label}</span>
        </button>
      ))}
    </div>
  )
}
__EOF__
echo "✅  components/chat/QuickActions.tsx"

# MediaUploadButton component
cat > afrifx-web/components/chat/MediaUploadButton.tsx << '__EOF__'
'use client'
import { useRef, useState } from 'react'
import { Paperclip, Loader2 } from 'lucide-react'
import { uploadToCloudinary, type CloudinaryUploadResult } from '@/lib/cloudinary'

interface Props {
  onUpload:  (result: CloudinaryUploadResult) => void
  disabled?: boolean
}

export function MediaUploadButton({ onUpload, disabled }: Props) {
  const inputRef    = useRef<HTMLInputElement>(null)
  const [progress, setProgress] = useState(0)
  const [uploading, setUploading] = useState(false)

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return

    // 10MB limit
    if (file.size > 10 * 1024 * 1024) {
      alert('File too large — max 10MB')
      return
    }

    setUploading(true)
    setProgress(0)
    try {
      const result = await uploadToCloudinary(file, setProgress)
      onUpload(result)
    } catch (err: any) {
      alert(err.message ?? 'Upload failed')
    } finally {
      setUploading(false)
      setProgress(0)
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="file"
        accept="image/*,application/pdf,.doc,.docx"
        onChange={handleFile}
        className="hidden"
      />
      <button
        onClick={() => inputRef.current?.click()}
        disabled={disabled || uploading}
        className="flex h-9 w-9 items-center justify-center rounded-full border border-[#1B2B4B] bg-[#0F1729] text-[#64748B] transition-colors hover:border-[#378ADD] hover:text-[#E2E8F0] disabled:opacity-40"
        title="Attach file or image"
      >
        {uploading
          ? <Loader2 className="h-4 w-4 animate-spin" />
          : <Paperclip className="h-4 w-4" />
        }
      </button>
      {uploading && (
        <div className="absolute -top-6 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-[#0F1729] px-2 py-0.5 text-[10px] text-[#378ADD]">
          {progress}%
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  components/chat/MediaUploadButton.tsx"

# Main ChatWindow component
cat > afrifx-web/components/chat/ChatWindow.tsx << '__EOF__'
'use client'
import { useState, useRef, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { MessageBubble }     from './MessageBubble'
import { QuickActions }      from './QuickActions'
import { MediaUploadButton } from './MediaUploadButton'
import { useChat }           from '@/hooks/useChat'
import { useProfileByAddress } from '@/hooks/useProfile'
import { ProfileAvatar }     from '@/components/profile/ProfileAvatar'
import { getAvatarColor }    from '@/lib/avatar'
import { shortenAddress }    from '@/lib/utils'
import type { CloudinaryUploadResult } from '@/lib/cloudinary'
import {
  Send, MessageSquare, ChevronDown, Shield,
} from 'lucide-react'

interface Props {
  offerId:      string
  makerAddress: string
  takerAddress: string
  currency:     string
  amount:       number
}

function UserChip({ address }: { address: string }) {
  const { data: profile } = useProfileByAddress(address)
  const color = profile?.avatar_color ?? getAvatarColor(address)
  const name  = profile?.display_name ?? shortenAddress(address)
  return (
    <div className="flex items-center gap-1.5">
      <ProfileAvatar displayName={name} avatarColor={color} size="xs" verified={profile?.verified} />
      <span className="text-xs text-[#E2E8F0]">{profile?.username ? `@${profile.username}` : name}</span>
    </div>
  )
}

export function ChatWindow({ offerId, makerAddress, takerAddress, currency, amount }: Props) {
  const { address }                  = useAccount()
  const { messages, role, typing, sendMessage, sendTyping } = useChat(offerId)
  const { data: otherProfile }       = useProfileByAddress(
    role === 'maker' ? takerAddress : makerAddress
  )
  const { data: myProfile }          = useProfileByAddress(address ?? '')

  const [input,       setInput]       = useState('')
  const [sending,     setSending]     = useState(false)
  const [showActions, setShowActions] = useState(false)
  const [minimized,   setMinimized]   = useState(false)
  const [imagePreview, setImagePreview] = useState<string | null>(null)
  const [pendingMedia, setPendingMedia] = useState<CloudinaryUploadResult | null>(null)

  const bottomRef  = useRef<HTMLDivElement>(null)
  const inputRef   = useRef<HTMLTextAreaElement>(null)

  // Auto-scroll to latest message
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  const otherAddress  = role === 'maker' ? takerAddress : makerAddress
  const otherName     = otherProfile?.display_name ?? shortenAddress(otherAddress)
  const otherColor    = otherProfile?.avatar_color  ?? getAvatarColor(otherAddress)
  const myName        = myProfile?.display_name     ?? shortenAddress(address ?? '')

  function getSenderName(sender: string): string {
    if (sender === address?.toLowerCase()) return 'You'
    return otherProfile?.display_name ?? shortenAddress(sender)
  }

  function isMe(sender: string): boolean {
    return sender.toLowerCase() === address?.toLowerCase()
  }

  async function handleSend() {
    if ((!input.trim() && !pendingMedia) || sending) return
    setSending(true)
    try {
      if (pendingMedia) {
        await sendMessage(
          input.trim() || pendingMedia.name,
          pendingMedia.url,
          pendingMedia.type,
          'media',
        )
        setPendingMedia(null)
        setImagePreview(null)
      } else {
        await sendMessage(input.trim())
      }
      setInput('')
    } finally { setSending(false) }
  }

  async function handleQuickAction(action: string, label: string) {
    setShowActions(false)
    setSending(true)
    try {
      await sendMessage(label, undefined, undefined, 'quick-action', action)
    } finally { setSending(false) }
  }

  function handleMediaUpload(result: CloudinaryUploadResult) {
    setPendingMedia(result)
    if (result.type === 'image') setImagePreview(result.url)
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSend()
    }
    sendTyping()
  }

  if (!address || !role) return null

  return (
    <div className={`flex flex-col rounded-2xl border border-[#1B2B4B] bg-[#080D1B] shadow-2xl transition-all duration-200 ${minimized ? 'h-14' : 'h-[520px]'}`}>

      {/* Header */}
      <div
        className="flex cursor-pointer items-center gap-3 rounded-t-2xl border-b border-[#1B2B4B] bg-[#0F1729] px-4 py-3"
        onClick={() => setMinimized(!minimized)}
      >
        <div className="relative">
          <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="sm" verified={otherProfile?.verified} />
          <span className="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-emerald-400 ring-1 ring-[#0F1729]" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <p className="text-sm font-medium text-[#E2E8F0] truncate">
              {otherProfile?.username ? `@${otherProfile.username}` : otherName}
            </p>
            <span className={`text-[10px] rounded-full px-1.5 py-0.5 font-medium
              ${role === 'maker' ? 'bg-[#378ADD]/20 text-[#378ADD]' : 'bg-emerald-900/40 text-emerald-400'}`}>
              {role === 'maker' ? 'Taker' : 'Maker'}
            </span>
          </div>
          <p className="text-[10px] text-[#64748B]">
            {typing ? (
              <span className="text-emerald-400 animate-pulse">typing…</span>
            ) : (
              `Trade: ${amount.toLocaleString()} ${currency} ↔ USDC`
            )}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1 rounded-full bg-emerald-900/30 px-2 py-0.5 text-[10px] text-emerald-400">
            <Shield className="h-3 w-3" />
            Secured
          </div>
          <ChevronDown className={`h-4 w-4 text-[#64748B] transition-transform ${minimized ? 'rotate-180' : ''}`} />
        </div>
      </div>

      {!minimized && (
        <>
          {/* Trade parties banner */}
          <div className="flex items-center justify-between border-b border-[#1B2B4B] bg-[#0A1020] px-4 py-2">
            <UserChip address={makerAddress} />
            <span className="text-[10px] text-[#64748B]">⇄</span>
            <UserChip address={takerAddress} />
          </div>

          {/* Messages area */}
          <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1 scroll-smooth">
            {messages.length === 0 && (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <div className="flex h-12 w-12 items-center justify-center rounded-full bg-[#1B2B4B]">
                  <MessageSquare className="h-5 w-5 text-[#64748B]" />
                </div>
                <div>
                  <p className="text-sm font-medium text-[#E2E8F0]">Trade chat</p>
                  <p className="text-xs text-[#64748B]">Messages are private between you and your trading partner.</p>
                  <p className="mt-1 text-xs text-[#64748B]">Use quick actions below to confirm payment status.</p>
                </div>
              </div>
            )}

            {messages.map((msg) => (
              <MessageBubble
                key={msg.id}
                msg={msg}
                isMe={isMe(msg.sender)}
                senderName={getSenderName(msg.sender)}
              />
            ))}

            {/* Typing indicator */}
            {typing && (
              <div className="flex items-end gap-2">
                <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="xs" />
                <div className="rounded-2xl rounded-tl-sm bg-[#1B2B4B] px-3 py-2">
                  <div className="flex gap-1">
                    {[0,1,2].map(i => (
                      <span key={i} className="h-1.5 w-1.5 animate-bounce rounded-full bg-[#64748B]"
                        style={{ animationDelay: `${i * 0.15}s` }} />
                    ))}
                  </div>
                </div>
              </div>
            )}

            <div ref={bottomRef} />
          </div>

          {/* Image preview */}
          {imagePreview && (
            <div className="relative mx-4 mb-2">
              <img src={imagePreview} alt="Preview" className="h-20 rounded-lg object-cover" />
              <button
                onClick={() => { setImagePreview(null); setPendingMedia(null) }}
                className="absolute -right-1 -top-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-white text-xs"
              >×</button>
            </div>
          )}

          {/* Quick actions */}
          {showActions && (
            <QuickActions onAction={handleQuickAction} disabled={sending} />
          )}

          {/* Input area */}
          <div className="border-t border-[#1B2B4B] bg-[#0F1729] p-3">
            <div className="flex items-end gap-2">
              {/* Quick actions toggle */}
              <button
                onClick={() => setShowActions(!showActions)}
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full border transition-colors
                  ${showActions ? 'border-[#378ADD] bg-[#378ADD]/10 text-[#378ADD]' : 'border-[#1B2B4B] bg-[#0F1729] text-[#64748B] hover:text-[#E2E8F0]'}`}
                title="Quick actions"
              >
                ⚡
              </button>

              {/* Media upload */}
              <MediaUploadButton onUpload={handleMediaUpload} disabled={sending} />

              {/* Text input */}
              <div className="flex flex-1 items-end rounded-xl border border-[#1B2B4B] bg-[#080D1B] px-3 py-2">
                <textarea
                  ref={inputRef}
                  value={input}
                  onChange={(e) => { setInput(e.target.value); sendTyping() }}
                  onKeyDown={handleKeyDown}
                  placeholder="Type a message… (Enter to send)"
                  rows={1}
                  style={{ maxHeight: '80px' }}
                  className="flex-1 resize-none bg-transparent text-sm text-[#E2E8F0] placeholder:text-[#64748B] outline-none leading-relaxed"
                />
              </div>

              {/* Send button */}
              <button
                onClick={handleSend}
                disabled={(!input.trim() && !pendingMedia) || sending}
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#378ADD] text-white transition-all hover:bg-[#2a6fc4] disabled:opacity-40 disabled:cursor-not-allowed active:scale-95"
              >
                <Send className="h-4 w-4" />
              </button>
            </div>

            <p className="mt-1.5 text-center text-[10px] text-[#64748B]">
              🔒 Private · only you and your trading partner can see this chat
            </p>
          </div>
        </>
      )}
    </div>
  )
}
__EOF__
echo "✅  components/chat/ChatWindow.tsx"

# ============================================================
# 7 — Add ChatWindow to offer detail page
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { TimerBanner } from '@/components/p2p/TimerBanner'
import { ChatWindow } from '@/components/chat/ChatWindow'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer | null {
  if (!row || row.error) return null
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: row[3], local_currency: row[4], local_amount: row[5],
      rate_offered: row[6], status: row[7],
      maker_confirmed: Number(row[8]), taker_confirmed: Number(row[9]),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: row[12], created_at: row[13], updated_at: row[14],
    }
  }
  return {
    ...row,
    maker_confirmed:     Number(row.maker_confirmed     ?? 0),
    taker_confirmed:     Number(row.taker_confirmed     ?? 0),
    taker_deadline:      row.taker_deadline      ? Number(row.taker_deadline)      : null,
    maker_deadline:      row.maker_deadline      ? Number(row.maker_deadline)      : null,
    dispute_raised:      Number(row.dispute_raised      ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
    order_type:          row.order_type ?? 'market',
  } as P2POffer
}

function shortenAddr(a: string) { return `${a.slice(0,6)}…${a.slice(-4)}` }

export default function OfferDetailPage() {
  const params          = useParams()
  const { address }     = useAccount()
  const [offer, setOffer]     = useState<P2POffer | null>(null)
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound]     = useState(false)
  const [disputing, setDisputing]   = useState(false)
  const [disputeDone, setDisputeDone] = useState(false)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) { setNotFound(true); return }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) setOffer(norm)
      else setNotFound(true)
    } catch { setNotFound(true) }
    finally  { setLoading(false) }
  }, [params.id])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    const t = setInterval(load, 5000)
    return () => clearInterval(t)
  }, [load])

  if (loading) return (
    <div className="space-y-4">
      <div className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-[#64748B]">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = (offer as any).maker_timer_seconds ?? 1800

  if (offer.status === 'accepted' && !isInvolved && address) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-3">
        <p className="text-sm font-medium text-[#E2E8F0]">This trade is in progress.</p>
        <p className="text-xs text-[#64748B]">Only the two parties involved can view an active trade.</p>
        <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
      </div>
    )
  }

  const statusBadge = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }[offer.status] as any

  const steps = [
    { n:1, done: offer.status !== 'open',     label: 'Taker accepted offer',               desc: 'USDC locked in vault' },
    { n:2, done: offer.status !== 'open',     label: `Taker sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`, desc: 'Off-chain payment' },
    { n:3, done: !!offer.taker_confirmed,     label: 'Taker confirmed: "I sent the money"',desc: 'Taker window' },
    { n:4, done: !!offer.maker_confirmed,     label: 'Maker confirmed: "I received it"',   desc: 'Maker window' },
    { n:5, done: offer.status === 'released', label: 'Platform releases USDC to taker',    desc: 'Auto within 15s' },
  ]

  const showTakerTimer = offer.status === 'accepted' && !offer.taker_confirmed && !!(offer as any).taker_deadline
  const showMakerTimer = offer.status === 'accepted' && !!offer.taker_confirmed && !offer.maker_confirmed && !!(offer as any).maker_deadline

  async function handleDispute() {
    if (!address) return
    setDisputing(true)
    try {
      await raiseDispute(offer!.id, 'Maker did not confirm receipt within agreed window')
      setDisputeDone(true)
      await load()
    } catch {} finally { setDisputing(false) }
  }

  const showChat = isInvolved && (offer.status === 'accepted' || offer.status === 'released')

  return (
    <div>
      {/* Header */}
      <div className="mb-4 flex items-center gap-3">
        <Link href={isInvolved ? '/my-trades' : '/marketplace'}>
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
              {(offer as any).order_type ?? 'market'}
            </Badge>
            {!!(offer as any).dispute_raised && <Badge variant="danger">Disputed</Badge>}
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {/* Timer banners */}
      <ClientOnly>
        {showTakerTimer && (
          <div className="mb-4">
            <TimerBanner deadline={(offer as any).taker_deadline} totalSeconds={timerSecs} phase="taker" isMine={isTaker} />
          </div>
        )}
        {showMakerTimer && (
          <div className="mb-4">
            <TimerBanner deadline={(offer as any).maker_deadline} totalSeconds={timerSecs} phase="maker" isMine={isMaker} />
          </div>
        )}
      </ClientOnly>

      {/* Main grid + chat */}
      <div className={`grid gap-4 ${showChat ? 'lg:grid-cols-3' : 'lg:grid-cols-2'}`}>

        {/* Summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-[#64748B]">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()}</p>
              <p className="text-xs text-[#64748B]">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <div className="space-y-2 text-xs">
            {[
              ['Maker', `${offer.maker_address ? shortenAddr(offer.maker_address) : '—'}${isMaker ? ' (you)' : ''}`],
              ['Taker', offer.taker_address ? `${shortenAddr(offer.taker_address!)}${isTaker ? ' (you)' : ''}` : 'Waiting…'],
              ['Rate',  `1 USDC = ${Number(offer.rate_offered) > 0 ? (1/Number(offer.rate_offered)).toFixed(2) : '—'} ${offer.local_currency}`],
            ].map(([l,v]) => (
              <div key={l} className="flex justify-between">
                <span className="text-[#64748B]">{l}</span>
                <span className="font-mono text-[#E2E8F0]">{v}</span>
              </div>
            ))}
            {offer.arc_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Create tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline">
                  {offer.arc_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
            {offer.release_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Release tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                  {offer.release_tx_hash.slice(0,14)}… <ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
          </div>

          {isMaker && offer.status === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Progress + actions */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Progress</p>
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>{label}</p>
                  <p className="text-xs text-[#64748B]">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          <ClientOnly>
            <div className="space-y-3">
              {offer.status === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {offer.status === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                </div>
              )}

              {!!(offer as any).dispute_raised && offer.status === 'accepted' && (
                <div className="rounded-lg border border-amber-900/50 bg-amber-900/20 p-3 text-xs">
                  <div className="flex items-start gap-2">
                    <Flag className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-400" />
                    <div>
                      <p className="font-medium text-amber-400">Dispute raised</p>
                      <p className="mt-0.5 text-amber-600">USDC locked. Auto-releases in 24h if unresolved.</p>
                    </div>
                  </div>
                </div>
              )}

              {offer.status === 'open' && isMaker && (
                <div className="rounded-lg bg-[#080D1B] p-3 text-center text-xs text-[#64748B]">
                  Waiting for a seller to accept your offer…
                </div>
              )}

              {offer.status === 'accepted' && (
                <>
                  {isTaker && !offer.taker_confirmed && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Send {offer.local_currency} now</p>
                      <p className="mt-1 text-[#64748B]">
                        Send <strong className="text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong> to maker, then confirm below.
                        Use the chat to share payment details or proof.
                      </p>
                    </div>
                  )}

                  {isMaker && !offer.taker_confirmed && (
                    <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
                      <Loader2 className="h-4 w-4 animate-spin shrink-0" />
                      Waiting for taker to send and confirm…
                    </div>
                  )}

                  {isMaker && offer.taker_confirmed && !offer.maker_confirmed && (
                    <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                      <p className="font-medium text-[#E2E8F0]">Check your account</p>
                      <p className="mt-1 text-[#64748B]">
                        Taker confirmed sending <strong className="text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong>.
                        Confirm receipt to release USDC.
                      </p>
                    </div>
                  )}

                  {isTaker && (
                    <Button className="w-full"
                      onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                      disabled={!!offer.taker_confirmed || actionLoading}
                      variant={offer.taker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.taker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Sent confirmed</>
                        : `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`}
                    </Button>
                  )}

                  {isMaker && (
                    <Button className="w-full"
                      onClick={async () => { await makerConfirm(offerId); await load() }}
                      disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                      variant={offer.maker_confirmed ? 'outline' : 'default'}>
                      {actionLoading
                        ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                        : offer.maker_confirmed
                        ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> Receipt confirmed</>
                        : !offer.taker_confirmed
                        ? 'Waiting for taker to send first…'
                        : `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`}
                    </Button>
                  )}

                  {isTaker && offer.taker_confirmed && !offer.maker_confirmed && !(offer as any).dispute_raised && (
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
                        <Button variant="danger" className="w-full" onClick={handleDispute} disabled={disputing}>
                          <Flag className="h-4 w-4" />
                          {disputing ? 'Raising dispute…' : 'Raise dispute'}
                        </Button>
                      ) : (
                        <p className="text-xs text-emerald-400">✓ Dispute raised — USDC auto-releases in 24h.</p>
                      )}
                    </div>
                  )}

                  {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                    <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      Both confirmed — releasing USDC within 15 seconds…
                    </div>
                  )}
                </>
              )}
            </div>
          </ClientOnly>

          {error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`} target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>

        {/* Chat window — only for involved parties during/after trade */}
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
__EOF__
echo "✅  marketplace/[id]/page.tsx — ChatWindow integrated"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  P2P Trade Chat complete!"
echo ""
echo "  IMPORTANT — Set up Cloudinary:"
echo "  1. Create free account at cloudinary.com"
echo "  2. Go to Settings → Upload → Upload Presets"
echo "  3. Add unsigned preset named 'afrifx_chat'"
echo "  4. Copy your Cloud Name"
echo "  5. Fill in afrifx-web/.env.local:"
echo "     NEXT_PUBLIC_CLOUDINARY_CLOUD_NAME=your_name"
echo "     NEXT_PUBLIC_CLOUDINARY_UPLOAD_PRESET=afrifx_chat"
echo ""
echo "  Chat features:"
echo "  • Real-time polling every 2 seconds"
echo "  • Text messages + image/file sharing"
echo "  • Quick action buttons (payment sent/received/need time)"
echo "  • Typing indicator"
echo "  • Read receipts (✓ / ✓✓)"
echo "  • Media preview before sending"
echo "  • Minimizable chat window"
echo "  • Profile avatars + names in chat"
echo "  • Secured badge + privacy notice"
echo "  • System messages for trade events"
echo "  • Access control (maker + taker only)"
echo "  • 3-column layout: summary | progress | chat"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
