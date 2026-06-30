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

        {/* Document upload — only for users (maker/taker), not admin */}
        {viewerType !== 'admin' && (
          <div className="flex items-center gap-2">
            <input ref={fileRef} type="file" className="hidden"
              accept=".pdf"
              onChange={e => e.target.files?.[0] && uploadDocument(e.target.files[0])} />
            <button onClick={() => fileRef.current?.click()}
              className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
              {uploading
                ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                : <Upload className="h-3.5 w-3.5" />
              }
              Upload bank statement (PDF only — admin will review)
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
