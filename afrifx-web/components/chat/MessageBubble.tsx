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
