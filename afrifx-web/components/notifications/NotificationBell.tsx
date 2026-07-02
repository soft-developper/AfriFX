'use client'
import { useEffect, useState, useRef } from 'react'
import { useAccount } from 'wagmi'
import { Bell, Check, X } from 'lucide-react'
import Link from 'next/link'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Notification {
  id:         string
  type:       string
  subject:    string
  payload:    string
  read_at:    number | null
  created_at: number
}

export function NotificationBell() {
  const { address }               = useAccount()
  const [open,         setOpen]   = useState(false)
  const [notifs,       setNotifs] = useState<Notification[]>([])
  const [unreadCount,  setCount]  = useState(0)
  const dropdownRef = useRef<HTMLDivElement>(null)

  async function loadUnreadCount() {
    if (!address) return
    try {
      const res = await fetch(`${API}/notifications/unread?wallet=${address}`)
      const data = await res.json()
      setCount(Number(data.count ?? 0))
    } catch {}
  }

  async function loadNotifs() {
    if (!address) return
    try {
      const res  = await fetch(`${API}/notifications?wallet=${address}`)
      const data = await res.json()
      setNotifs(Array.isArray(data) ? data : [])
    } catch {}
  }

  async function markRead(id: string) {
    try {
      await fetch(`${API}/notifications/${id}/read`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  async function markAllRead() {
    if (!address) return
    try {
      await fetch(`${API}/notifications/mark-all-read?wallet=${address}`, { method: 'PATCH' })
      await loadNotifs()
      await loadUnreadCount()
    } catch {}
  }

  useEffect(() => {
    if (!address) return
    loadUnreadCount()
    const interval = setInterval(loadUnreadCount, 30_000)
    return () => clearInterval(interval)
  }, [address])

  useEffect(() => {
    if (open) loadNotifs()
  }, [open])

  // Close on outside click
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    if (open) document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [open])

  if (!address) return null

  const getNotifLink = (n: Notification) => {
    try {
      const p = JSON.parse(n.payload)
      if (n.type.startsWith('trade')   && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type.startsWith('dispute') && p.offerId)   return `/marketplace/${p.offerId}`
      if (n.type === 'invoice_paid'    && p.invoiceId) return `/invoices/${p.invoiceId}`
    } catch {}
    return '#'
  }

  const getIcon = (type: string) => {
    if (type.startsWith('trade'))   return '🤝'
    if (type.startsWith('dispute')) return '⚠️'
    if (type === 'invoice_paid')    return '💰'
    return '🔔'
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button onClick={() => setOpen(!open)}
        className="relative flex h-9 w-9 items-center justify-center rounded-lg border border-app-border text-app-muted hover:bg-app-surface hover:text-app-text transition-colors">
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 mt-2 w-80 rounded-xl border border-app-border bg-app-surface shadow-2xl z-50">
          <div className="flex items-center justify-between border-b border-app-border px-4 py-3">
            <p className="text-sm font-medium text-app-text">Notifications</p>
            <div className="flex items-center gap-2">
              {unreadCount > 0 && (
                <button onClick={markAllRead}
                  className="text-xs text-app-accent hover:underline">
                  Mark all read
                </button>
              )}
              <button onClick={() => setOpen(false)}
                className="text-app-muted hover:text-app-text">
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>
          <div className="max-h-96 overflow-y-auto">
            {notifs.length === 0 ? (
              <p className="px-4 py-8 text-center text-xs text-app-muted">No notifications yet</p>
            ) : (
              notifs.map(n => {
                const link   = getNotifLink(n)
                const isUnread = !n.read_at
                return (
                  <Link key={n.id} href={link}
                    onClick={() => { markRead(n.id); setOpen(false) }}
                    className={`flex items-start gap-3 border-b border-app-border px-4 py-3 last:border-0
                      ${isUnread ? 'bg-app-accent/5' : ''} hover:bg-app-bg transition-colors`}>
                    <span className="text-lg">{getIcon(n.type)}</span>
                    <div className="flex-1 min-w-0">
                      <p className={`text-xs ${isUnread ? 'font-medium text-app-text' : 'text-app-muted'}`}>
                        {n.subject}
                      </p>
                      <p className="mt-0.5 text-[10px] text-app-muted">
                        {new Date(n.created_at * 1000).toLocaleString()}
                      </p>
                    </div>
                    {isUnread && (
                      <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-app-accent" />
                    )}
                  </Link>
                )
              })
            )}
          </div>
        </div>
      )}
    </div>
  )
}
