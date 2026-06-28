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
