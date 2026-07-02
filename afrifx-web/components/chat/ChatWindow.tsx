'use client'
import { useState, useRef, useEffect, useCallback } from 'react'
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
import { Send, MessageSquare, ChevronDown, Shield, Lock } from 'lucide-react'

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
      <span className="text-xs text-app-text">
        {profile?.username ? `@${profile.username}` : name}
      </span>
    </div>
  )
}

export function ChatWindow({ offerId, makerAddress, takerAddress, currency, amount }: Props) {
  const { address } = useAccount()

  // Determine role client-side
  const isMaker = address?.toLowerCase() === makerAddress?.toLowerCase()
  const isTaker = address?.toLowerCase() === takerAddress?.toLowerCase()
  const isInvolved = isMaker || isTaker

  const otherAddress = isMaker ? takerAddress : makerAddress

  const { messages, role, typing, sendMessage, sendTyping } = useChat(
    isInvolved ? offerId : null
  )

  const { data: otherProfile } = useProfileByAddress(otherAddress)
  const { data: myProfile }    = useProfileByAddress(address ?? '')

  const [input,        setInput]        = useState('')
  const [sending,      setSending]      = useState(false)
  const [showActions,  setShowActions]  = useState(false)
  const [minimized,    setMinimized]    = useState(false)
  const [pendingMedia, setPendingMedia] = useState<CloudinaryUploadResult | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(null)

  const bottomRef = useRef<HTMLDivElement>(null)
  const inputRef  = useRef<HTMLTextAreaElement>(null)

  // Auto-scroll on new messages
  useEffect(() => {
    if (!minimized) {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
    }
  }, [messages, minimized])

  const otherName  = otherProfile?.display_name ?? shortenAddress(otherAddress)
  const otherColor = otherProfile?.avatar_color  ?? getAvatarColor(otherAddress)

  function getSenderName(sender: string | null | undefined): string {
    if (!sender || sender === 'system') return 'System'
    if (sender.toLowerCase() === address?.toLowerCase()) return 'You'
    return otherProfile?.display_name ?? shortenAddress(sender)
  }

  function isMe(sender: string | null | undefined): boolean {
    if (!sender || !address) return false
    return sender.toLowerCase() === address.toLowerCase()
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
    try { await sendMessage(label, undefined, undefined, 'quick-action', action) }
    finally { setSending(false) }
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSend() }
    sendTyping()
  }

  function handleMediaUpload(result: CloudinaryUploadResult) {
    setPendingMedia(result)
    if (result.type === 'image') setImagePreview(result.url)
  }

  // ── Not involved: show a locked placeholder ───────────────
  if (!isInvolved) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 rounded-2xl border border-app-border bg-app-bg">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
          <Lock className="h-5 w-5 text-app-muted" />
        </div>
        <p className="text-sm text-app-muted">Private trade chat</p>
      </div>
    )
  }

  // ── Wallet not yet connected / hydrating ──────────────────
  if (!address) {
    return (
      <div className="flex h-[520px] flex-col items-center justify-center gap-3 rounded-2xl border border-app-border bg-app-bg">
        <div className="h-8 w-32 animate-pulse rounded-lg bg-app-border" />
      </div>
    )
  }

  return (
    <div className={`flex flex-col rounded-2xl border border-app-border bg-app-bg shadow-2xl transition-all duration-200 ${minimized ? 'h-14' : 'h-[520px]'}`}>

      {/* ── Header ── */}
      <div
        className="flex cursor-pointer items-center gap-3 rounded-t-2xl border-b border-app-border bg-app-surface px-4 py-3"
        onClick={() => setMinimized(!minimized)}
      >
        <div className="relative">
          <ProfileAvatar displayName={otherName} avatarColor={otherColor} size="sm" verified={otherProfile?.verified} />
          <span className="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-emerald-400 ring-1 ring-app-surface" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <p className="truncate text-sm font-medium text-app-text">
              {otherProfile?.username ? `@${otherProfile.username}` : otherName}
            </p>
            <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium
              ${isMaker ? 'bg-app-accent/20 text-app-accent' : 'bg-emerald-900/40 text-emerald-400'}`}>
              {isMaker ? 'Taker' : 'Maker'}
            </span>
          </div>
          <p className="text-[10px] text-app-muted">
            {typing
              ? <span className="text-emerald-400 animate-pulse">typing…</span>
              : `${amount.toLocaleString()} ${currency} ↔ USDC`
            }
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1 rounded-full bg-emerald-900/30 px-2 py-0.5 text-[10px] text-emerald-400">
            <Shield className="h-3 w-3" /> Secured
          </div>
          <ChevronDown className={`h-4 w-4 shrink-0 text-app-muted transition-transform ${minimized ? 'rotate-180' : ''}`} />
        </div>
      </div>

      {!minimized && (
        <>
          {/* ── Parties banner ── */}
          <div className="flex items-center justify-between border-b border-app-border bg-[#0A1020] px-4 py-2">
            <UserChip address={makerAddress} />
            <span className="text-[10px] text-app-muted">⇄</span>
            <UserChip address={takerAddress} />
          </div>

          {/* ── Messages ── */}
          <div className="flex-1 overflow-y-auto px-4 py-3 space-y-1">
            {messages.length === 0 && (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <div className="flex h-12 w-12 items-center justify-center rounded-full bg-app-border">
                  <MessageSquare className="h-5 w-5 text-app-muted" />
                </div>
                <div>
                  <p className="text-sm font-medium text-app-text">Trade chat</p>
                  <p className="text-xs text-app-muted">
                    Messages are private between you and your trading partner.
                  </p>
                  <p className="mt-1 text-xs text-app-muted">
                    Use quick actions ⚡ to confirm payment status.
                  </p>
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
                <div className="rounded-2xl rounded-tl-sm bg-app-border px-3 py-2">
                  <div className="flex gap-1">
                    {[0,1,2].map(i => (
                      <span key={i}
                        className="h-1.5 w-1.5 animate-bounce rounded-full bg-app-muted"
                        style={{ animationDelay: `${i * 0.15}s` }}
                      />
                    ))}
                  </div>
                </div>
              </div>
            )}

            <div ref={bottomRef} />
          </div>

          {/* ── Image preview ── */}
          {imagePreview && (
            <div className="relative mx-4 mb-2">
              <img src={imagePreview} alt="Preview" className="h-20 rounded-lg object-cover" />
              <button
                onClick={() => { setImagePreview(null); setPendingMedia(null) }}
                className="absolute -right-1 -top-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-white text-xs font-bold"
              >
                ×
              </button>
            </div>
          )}

          {/* ── Quick actions ── */}
          {showActions && (
            <QuickActions onAction={handleQuickAction} disabled={sending} />
          )}

          {/* ── Input ── */}
          <div className="border-t border-app-border bg-app-surface p-3">
            <div className="flex items-end gap-2">
              <button
                onClick={() => setShowActions(!showActions)}
                title="Quick actions"
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full border text-sm transition-colors
                  ${showActions
                    ? 'border-app-accent bg-app-accent/10 text-app-accent'
                    : 'border-app-border bg-app-surface text-app-muted hover:text-app-text'}`}
              >
                ⚡
              </button>

              <MediaUploadButton
                offerId={offerId}
                onUpload={handleMediaUpload}
                disabled={sending}
              />

              <div className="flex flex-1 items-end rounded-xl border border-app-border bg-app-bg px-3 py-2">
                <textarea
                  ref={inputRef}
                  value={input}
                  onChange={(e) => { setInput(e.target.value); sendTyping() }}
                  onKeyDown={handleKeyDown}
                  placeholder="Message… (Enter to send, Shift+Enter for newline)"
                  rows={1}
                  style={{ maxHeight: '80px' }}
                  className="flex-1 resize-none bg-transparent text-sm text-app-text placeholder:text-app-muted outline-none leading-relaxed"
                />
              </div>

              <button
                onClick={handleSend}
                disabled={(!input.trim() && !pendingMedia) || sending}
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-app-accent text-white transition-all hover:bg-[#2a6fc4] disabled:opacity-40 active:scale-95"
              >
                <Send className="h-4 w-4" />
              </button>
            </div>

            <p className="mt-1.5 text-center text-[10px] text-app-muted">
              🔒 Private · deleted automatically when trade completes
            </p>
          </div>
        </>
      )}
    </div>
  )
}
