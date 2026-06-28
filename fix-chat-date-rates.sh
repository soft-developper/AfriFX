#!/bin/bash
# Run from ~/AfriFX:  bash fix-chat-date-rates.sh
set -e
echo "🔧  Fixing invalid date + rate oracle timeout..."

# ============================================================
# FIX 1 — MessageBubble: guard created_at as number
# Turso returns row values as strings in some cases
# ============================================================
cat > afrifx-web/components/chat/MessageBubble.tsx << '__EOF__'
'use client'
import { Download, FileText } from 'lucide-react'
import type { ChatMessage } from '@/hooks/useChat'

const QUICK_ACTION_LABELS: Record<string, { emoji: string; label: string; color: string }> = {
  payment_sent:     { emoji: '💸', label: 'Payment sent',         color: 'bg-blue-900/40 text-blue-300 border-blue-700/40'         },
  payment_received: { emoji: '✅', label: 'Payment received',     color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
  need_more_time:   { emoji: '⏰', label: 'Need a bit more time', color: 'bg-amber-900/40 text-amber-300 border-amber-700/40'       },
  dispute_warning:  { emoji: '⚠️', label: 'Dispute raised',       color: 'bg-red-900/40 text-red-300 border-red-700/40'            },
  trade_complete:   { emoji: '🎉', label: 'Trade complete!',       color: 'bg-emerald-900/40 text-emerald-300 border-emerald-700/40' },
}

interface Props {
  msg:        ChatMessage
  isMe:       boolean
  senderName: string
}

function formatTime(createdAt: number | string | null | undefined): string {
  if (!createdAt) return ''
  // Turso may return string — coerce to number
  const ts = typeof createdAt === 'string' ? parseInt(createdAt, 10) : Number(createdAt)
  if (isNaN(ts) || ts === 0) return ''
  // Unix seconds → milliseconds
  const ms   = ts < 1e12 ? ts * 1000 : ts
  const date = new Date(ms)
  if (isNaN(date.getTime())) return ''
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export function MessageBubble({ msg, isMe, senderName }: Props) {
  const time = formatTime(msg.created_at)

  // System message
  if (!msg.sender || msg.msg_type === 'system' || msg.sender === 'system') {
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
        <div className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-medium
          ${qa?.color ?? 'bg-[#1B2B4B] text-[#64748B] border-[#1B2B4B]'}`}>
          <span>{qa?.emoji}</span>
          <span>{qa?.label ?? msg.quick_action}</span>
          {time && <span className="opacity-60 text-[10px]">{time}</span>}
        </div>
      </div>
    )
  }

  return (
    <div className={`flex ${isMe ? 'justify-end' : 'justify-start'} group py-0.5`}>
      <div className={`max-w-[75%] flex flex-col gap-0.5 ${isMe ? 'items-end' : 'items-start'}`}>

        {/* Sender name — only for received messages */}
        {!isMe && (
          <span className="px-1 text-[10px] font-medium text-[#64748B]">{senderName}</span>
        )}

        <div className={`rounded-2xl px-3 py-2 ${
          isMe
            ? 'rounded-tr-sm bg-[#378ADD] text-white'
            : 'rounded-tl-sm bg-[#1B2B4B] text-[#E2E8F0]'
        }`}>

          {/* Media */}
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

          {/* Text */}
          {msg.content && msg.media_type !== 'document' && (
            <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{msg.content}</p>
          )}

          {/* Timestamp + read receipt */}
          {time && (
            <p className={`mt-0.5 text-right text-[10px] ${isMe ? 'text-white/60' : 'text-[#64748B]'}`}>
              {time}
              {isMe && (
                <span className="ml-1">
                  {msg.read_maker && msg.read_taker ? '✓✓' : '✓'}
                </span>
              )}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  MessageBubble.tsx — formatTime() guards string/null/NaN"

# ============================================================
# FIX 2 — useChat hook: coerce created_at to number
# ============================================================
cat > afrifx-web/hooks/useChat.ts << '__EOF__'
'use client'
import { useState, useEffect, useRef, useCallback } from 'react'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface ChatMessage {
  id:           string
  offer_id:     string
  sender:       string | null
  content:      string | null
  media_url:    string | null
  media_type:   'image' | 'document' | 'video' | null
  msg_type:     'text' | 'media' | 'system' | 'quick-action'
  quick_action: string | null
  read_maker:   number
  read_taker:   number
  created_at:   number
}

// Normalise a raw message row (object or Turso array)
function normalizeMessage(raw: any): ChatMessage {
  const m = Array.isArray(raw)
    ? {
        id: raw[0], offer_id: raw[1], sender: raw[2], content: raw[3],
        media_url: raw[4], media_type: raw[5], msg_type: raw[6],
        quick_action: raw[7], read_maker: raw[8], read_taker: raw[9],
        created_at: raw[10],
      }
    : raw

  return {
    ...m,
    read_maker: Number(m.read_maker  ?? 0),
    read_taker: Number(m.read_taker  ?? 0),
    // Coerce created_at — Turso may return string or float
    created_at: typeof m.created_at === 'string'
      ? parseInt(m.created_at, 10)
      : Number(m.created_at ?? 0),
  }
}

export function useChat(offerId: string | null) {
  const { address } = useAccount()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [role,     setRole]     = useState<'maker'|'taker'|null>(null)
  const [typing,   setTyping]   = useState(false)
  const [error,    setError]    = useState<string|null>(null)

  const lastTsRef      = useRef(0)
  const intervalRef    = useRef<NodeJS.Timeout>()
  const typingTimerRef = useRef<NodeJS.Timeout>()

  const fetchMessages = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(
        `${API}/chat/${offerId}?wallet=${address}&after=${lastTsRef.current}`
      )
      if (res.status === 403) { setError('Access denied'); return }
      if (!res.ok) return
      const data = await res.json()

      const incoming: ChatMessage[] = Array.isArray(data.messages)
        ? data.messages.map(normalizeMessage)
        : []

      if (incoming.length) {
        setMessages(prev => {
          const ids   = new Set(prev.map(m => m.id))
          const fresh = incoming.filter(m => !ids.has(m.id))
          if (!fresh.length) return prev
          const all = [...prev, ...fresh].sort((a, b) => a.created_at - b.created_at)
          // Update lastTs to the latest message's created_at
          lastTsRef.current = all[all.length - 1].created_at
          return all
        })
      }

      if (data.role) setRole(data.role)
    } catch { /* network blip — ignore */ }
  }, [offerId, address])

  const fetchTyping = useCallback(async () => {
    if (!offerId || !address) return
    try {
      const res  = await fetch(`${API}/chat/${offerId}/typing?wallet=${address}`)
      if (!res.ok) return
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

  // Send typing indicator
  const sendTyping = useCallback(() => {
    if (!offerId || !address) return
    fetch(`${API}/chat/${offerId}/typing`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ wallet: address }),
    }).catch(() => {})
  }, [offerId, address])

  // Send a message
  const sendMessage = useCallback(async (
    content?:     string,
    mediaUrl?:    string,
    mediaType?:   string,
    msgType:      string = 'text',
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
      const raw: ChatMessage = await res.json()
      const msg = normalizeMessage(raw)
      setMessages(prev => {
        const ids = new Set(prev.map(m => m.id))
        if (ids.has(msg.id)) return prev
        const all = [...prev, msg].sort((a, b) => a.created_at - b.created_at)
        lastTsRef.current = all[all.length - 1].created_at
        return all
      })
      return msg
    } catch (err: any) {
      setError(err.message)
      return null
    }
  }, [offerId, address])

  return { messages, role, typing, error, sendMessage, sendTyping }
}
__EOF__
echo "✅  hooks/useChat.ts — normalizeMessage() coerces created_at"

# ============================================================
# FIX 3 — Rate oracle: add timeout + better error handling
# ============================================================
cat > afrifx-api/src/services/rateOracle.ts << '__EOF__'
import type { FXRate } from '../types'

const PAIRS = ['NGN/USDC','GHS/USDC','KES/USDC','ZAR/USDC','EGP/USDC','EURC/USDC']

// Hardcoded fallback rates — served when API is unavailable
let cachedRates: FXRate[] = [
  { pair: 'NGN/USDC',  rate: 1620,  change24h: +0.42, source: 'fallback', fetchedAt: Date.now() },
  { pair: 'GHS/USDC',  rate: 14.8,  change24h: -0.18, source: 'fallback', fetchedAt: Date.now() },
  { pair: 'KES/USDC',  rate: 130.5, change24h: +0.11, source: 'fallback', fetchedAt: Date.now() },
  { pair: 'ZAR/USDC',  rate: 18.6,  change24h: -0.05, source: 'fallback', fetchedAt: Date.now() },
  { pair: 'EGP/USDC',  rate: 49.2,  change24h: +0.29, source: 'fallback', fetchedAt: Date.now() },
  { pair: 'EURC/USDC', rate: 1.09,  change24h: +0.03, source: 'fallback', fetchedAt: Date.now() },
]

let consecutiveFailures = 0

export function getCachedRates(): FXRate[] { return cachedRates }

export function getRateByPair(pair: string): FXRate | undefined {
  return cachedRates.find(r => r.pair === pair)
}

export async function fetchLatestRates(): Promise<void> {
  const apiKey = process.env.EXCHANGE_RATE_API_KEY
  if (!apiKey) {
    // No key — serve fallback silently (no spam in logs)
    return
  }

  try {
    // 8-second timeout — prevents ETIMEDOUT from hanging
    const controller = new AbortController()
    const timeout    = setTimeout(() => controller.abort(), 8_000)

    const res = await fetch(
      `https://v6.exchangerate-api.com/v6/${apiKey}/latest/USD`,
      { signal: controller.signal }
    )
    clearTimeout(timeout)

    if (!res.ok) {
      consecutiveFailures++
      if (consecutiveFailures <= 3) {
        console.warn(`[RateOracle] API returned ${res.status} — using cached rates`)
      }
      return
    }

    const json = await res.json()
    if (json.result !== 'success') {
      consecutiveFailures++
      return
    }

    const rates    = json.conversion_rates as Record<string, number>
    const prevMap  = Object.fromEntries(cachedRates.map(r => [r.pair, r.rate]))
    const now      = Date.now()

    cachedRates = [
      { pair: 'NGN/USDC',  rate: rates.NGN ?? 1620,  change24h: pctChange(prevMap['NGN/USDC'],  rates.NGN),  source: 'exchangerate-api', fetchedAt: now },
      { pair: 'GHS/USDC',  rate: rates.GHS ?? 14.8,  change24h: pctChange(prevMap['GHS/USDC'],  rates.GHS),  source: 'exchangerate-api', fetchedAt: now },
      { pair: 'KES/USDC',  rate: rates.KES ?? 130.5, change24h: pctChange(prevMap['KES/USDC'],  rates.KES),  source: 'exchangerate-api', fetchedAt: now },
      { pair: 'ZAR/USDC',  rate: rates.ZAR ?? 18.6,  change24h: pctChange(prevMap['ZAR/USDC'],  rates.ZAR),  source: 'exchangerate-api', fetchedAt: now },
      { pair: 'EGP/USDC',  rate: rates.EGP ?? 49.2,  change24h: pctChange(prevMap['EGP/USDC'],  rates.EGP),  source: 'exchangerate-api', fetchedAt: now },
      { pair: 'EURC/USDC', rate: rates.EUR ? +(1/rates.EUR).toFixed(4) : 1.09,
        change24h: 0, source: 'exchangerate-api', fetchedAt: now },
    ]

    consecutiveFailures = 0
    console.log(`[RateOracle] ✅ Rates updated from API`)
  } catch (err: any) {
    consecutiveFailures++
    // Only log first 3 failures to avoid spam
    if (consecutiveFailures <= 3) {
      const reason = err.name === 'AbortError' ? 'timeout (8s)' : err.message
      console.warn(`[RateOracle] Fetch failed (${consecutiveFailures}): ${reason} — using cached rates`)
    } else if (consecutiveFailures === 4) {
      console.warn('[RateOracle] Suppressing further rate fetch errors — still serving cached rates')
    }
  }
}

function pctChange(prev: number | undefined, curr: number | undefined): number {
  if (!prev || !curr) return 0
  return parseFloat((((curr - prev) / prev) * 100).toFixed(2))
}
__EOF__
echo "✅  rateOracle.ts — 8s timeout + failure suppression after 3 tries"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Both fixes applied"
echo ""
echo "  Invalid date fix:"
echo "  • formatTime() in MessageBubble guards string/null/NaN"
echo "  • normalizeMessage() in useChat coerces created_at"
echo "    from Turso string → number before storing in state"
echo ""
echo "  Rate oracle fix:"
echo "  • 8-second AbortController timeout on fetch"
echo "  • Only logs first 3 failures (no more spam)"
echo "  • After 3 failures: silent fallback to cached rates"
echo "  • Fallback rates updated to current approximate values"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
