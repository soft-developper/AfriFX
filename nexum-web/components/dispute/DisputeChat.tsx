'use client'
import { useState, useEffect, useRef, useCallback } from 'react'
import { Send, Upload, Loader2, FileText, Download } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useProfileByAddress } from '@/hooks/useProfile'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Message {
  id:          string
  sender_id:   string
  sender_type: 'maker' | 'taker' | 'admin' | 'system'
  sender_name: string | null
  content:     string
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
  viewerType?: 'user' | 'admin'
  title?:      string
}

/*
  Shows a sender's @username resolved from their wallet profile, the same way
  the marketplace chat does, instead of a raw wallet address.
*/
function SenderName({
  address, fallback,
}: { address: string; fallback: string }) {
  const { data: profile } = useProfileByAddress(address)
  if (profile?.username) return <>@{profile.username}</>
  return <>{fallback}</>
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
  const [downloading, setDownloading] = useState<string | null>(null)
  const bottomRef = useRef<HTMLDivElement>(null)
  const fileRef   = useRef<HTMLInputElement>(null)

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/disputes/${disputeId}/messages?viewerType=${viewerType}`)
      if (!res.ok) return                      // keep what we have on a bad response
      const data = await res.json()
      // Only replace the thread when we actually got a valid array. Previously a
      // transient failure set messages to [] and the chat visibly "went offline"
      // for a poll cycle before repopulating.
      if (Array.isArray(data)) setMessages(data)
    } catch {
      // Network blip keep the existing messages on screen.
    }
  }, [disputeId, viewerType])

  useEffect(() => {
    load()
    const interval = setInterval(load, 5000)
    return () => clearInterval(interval)
  }, [load])

  async function sendMessage() {
    if (!text.trim() || sending) return
    setSending(true)
    try {
      await fetch(`${API}/disputes/${disputeId}/messages`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          senderId, senderType, senderName, content: text.trim(),
        }),
      })
      setText('')
      await load()
    } catch {} finally { setSending(false) }
  }

  async function uploadDocument(file: File) {
    setUploadError(null)

    // PDF only. Bank receipts and statements are issued as PDFs; images are too
    // easily edited to be trusted as proof, so they're rejected outright.
    const isPdf = file.type === 'application/pdf' ||
                  file.name.toLowerCase().endsWith('.pdf')
    if (!isPdf) {
      setUploadError('Only PDF files are accepted. Please upload the bank-issued PDF receipt or statement.')
      if (fileRef.current) fileRef.current.value = ''
      return
    }

    setUploading(true)
    try {
      const formData = new FormData()
      formData.append('file',       file)
      formData.append('senderId',   senderId)
      formData.append('senderType', senderType)
      formData.append('senderName', senderName)

      const res = await fetch(`${API}/disputes/${disputeId}/messages/document`, {
        method: 'POST',
        body:   formData,
      })
      if (res.ok) {
        await load()
      } else {
        const data = await res.json().catch(() => ({}))
        setUploadError(data.error ?? 'Upload failed. Please try again.')
      }
    } catch {
      setUploadError('Upload failed. Please check your connection and try again.')
    } finally {
      setUploading(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  /*
    Download the document with its original filename and .pdf extension, rather
    than opening a new tab where the browser/CDN may serve it without a proper
    name or type. We fetch the blob and trigger a real download.
  */
  async function downloadDoc(url: string, name: string | null, msgId: string) {
    setDownloading(msgId)
    try {
      const res  = await fetch(url)
      const blob = await res.blob()
      // Force the PDF type so the browser saves it correctly.
      const pdfBlob = blob.type === 'application/pdf'
        ? blob
        : new Blob([blob], { type: 'application/pdf' })

      let filename = name ?? 'dispute-document'
      if (!filename.toLowerCase().endsWith('.pdf')) filename += '.pdf'

      const href = URL.createObjectURL(pdfBlob)
      const a = document.createElement('a')
      a.href = href
      a.download = filename
      document.body.appendChild(a)
      a.click()
      a.remove()
      URL.revokeObjectURL(href)
    } catch {
      // Fall back to opening it if the direct download is blocked (e.g. CORS).
      window.open(url, '_blank', 'noopener,noreferrer')
    } finally {
      setDownloading(null)
    }
  }

  function getBubbleStyle(msg: Message) {
    const isMe = msg.sender_id === senderId
    if (isMe) return 'ml-auto bg-app-accent/20 border-app-accent/30'
    if (msg.sender_type === 'admin') return 'bg-amber-900/20 border-amber-900/30'
    return 'bg-app-bg border-app-border'
  }

  function renderSenderLabel(msg: Message) {
    if (msg.sender_id === senderId) return <>You</>
    if (msg.sender_type === 'admin') {
      return <>⚖️ Admin{msg.sender_name ? ` (${msg.sender_name})` : ''}</>
    }
    // Maker/taker: resolve their @username from their wallet profile, falling
    // back to the stored name, then a role label never a raw wallet address.
    const roleFallback = msg.sender_type === 'maker' ? 'Seller' : 'Buyer'
    return (
      <SenderName
        address={msg.sender_id}
        fallback={msg.sender_name ?? roleFallback}
      />
    )
  }

  return (
    <div className="flex flex-col rounded-xl border border-app-border bg-app-surface overflow-hidden">
      {/* Header */}
      <div className="border-b border-app-border px-4 py-3">
        <p className="text-sm font-medium text-app-text">{title}</p>
        <p className="text-xs text-app-muted">
          {viewerType === 'admin'
            ? 'All parties, messages sent here are visible to seller and buyer'
            : 'Communicate with the assigned admin · Upload bank PDFs below'}
        </p>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-3 min-h-[200px] max-h-[400px]">
        {messages.length === 0 ? (
          <p className="text-center text-xs text-app-muted py-4">
            No messages yet, start the conversation
          </p>
        ) : (
          messages.map(msg => (
            <div key={msg.id} className={`max-w-[80%] rounded-xl border p-3 text-xs ${getBubbleStyle(msg)}`}>
              <p className={`mb-1 font-medium ${msg.sender_type === 'admin' ? 'text-amber-400' : 'text-app-accent-text'}`}>
                {renderSenderLabel(msg)}
                {msg.admin_only === 1 && (
                  <span className="ml-2 rounded bg-amber-900/30 px-1 py-0.5 text-[10px] text-amber-400">
                    Admin only
                  </span>
                )}
              </p>
              {msg.is_document === 1 ? (
                <div className="flex items-center gap-2">
                  <FileText className="h-4 w-4 shrink-0 text-app-accent-text" />
                  <span className="truncate text-app-text">{msg.doc_name ?? 'Document'}</span>
                  {msg.doc_url && (
                    <button
                      onClick={() => downloadDoc(msg.doc_url!, msg.doc_name, msg.id)}
                      disabled={downloading === msg.id}
                      className="ml-auto inline-flex shrink-0 items-center gap-1 text-app-accent-text hover:underline disabled:opacity-60">
                      {downloading === msg.id
                        ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        : <Download className="h-3.5 w-3.5" />}
                      Download
                    </button>
                  )}
                </div>
              ) : (
                <p className="text-app-text whitespace-pre-wrap">{msg.content}</p>
              )}
              <p className="mt-1 text-[10px] text-app-muted">
                {new Date(msg.created_at * 1000).toLocaleTimeString()}
              </p>
            </div>
          ))
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div className="border-t border-app-border p-3 space-y-2">
        <div className="flex gap-2">
          <input
            value={text}
            onChange={e => setText(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.shiftKey && sendMessage()}
            placeholder="Type your message…"
            className="flex-1 rounded-lg border border-app-border bg-app-bg px-3 py-2 text-xs text-app-text placeholder:text-app-muted outline-none focus:ring-1 focus:ring-app-accent"
          />
          <Button size="sm" onClick={sendMessage} disabled={!text.trim() || sending}>
            {sending ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Send className="h-3.5 w-3.5" />}
          </Button>
        </div>

        {/* Document upload PDF only, and only for users (maker/taker) */}
        {viewerType !== 'admin' && (
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <input ref={fileRef} type="file" className="hidden"
                accept="application/pdf,.pdf"
                onChange={e => e.target.files?.[0] && uploadDocument(e.target.files[0])} />
              <button onClick={() => fileRef.current?.click()} disabled={uploading}
                className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text transition-colors disabled:opacity-50">
                {uploading
                  ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  : <Upload className="h-3.5 w-3.5" />
                }
                Upload bank PDF (receipt or statement)
              </button>
            </div>
            <p className="text-[10px] text-app-muted">
              PDF only, bank-issued receipts and statements. Images aren't accepted as proof.
            </p>
            {uploadError && (
              <p className="text-xs text-red-400">{uploadError}</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
