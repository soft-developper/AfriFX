'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import {
  Loader2, Search, Ban, CheckCircle, ChevronDown, ChevronUp,
  ArrowUpDown, Twitter, Send, AlertTriangle,
} from 'lucide-react'

type SortKey = 'volume' | 'trades' | 'disputes' | 'avg' | 'active' | 'joined' | 'name'

const COLUMNS: { key: SortKey; label: string }[] = [
  { key: 'name',     label: 'User' },
  { key: 'volume',   label: 'Volume' },
  { key: 'trades',   label: 'Trades' },
  { key: 'avg',      label: 'Avg size' },
  { key: 'disputes', label: 'Disputes' },
  { key: 'active',   label: 'Last active' },
]

function fmtUsd(n: number) {
  if (!n) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}k`
  return n.toFixed(2)
}

function fmtDate(ts: number | null | undefined) {
  if (!ts) return '-'
  return new Date(Number(ts) * 1000).toLocaleDateString()
}

function relativeDays(ts: number | null | undefined) {
  if (!ts) return null
  const days = Math.floor((Date.now() / 1000 - Number(ts)) / 86400)
  if (days <= 0) return 'today'
  if (days === 1) return 'yesterday'
  if (days < 30)  return `${days}d ago`
  if (days < 365) return `${Math.floor(days / 30)}mo ago`
  return `${Math.floor(days / 365)}y ago`
}

export default function AdminUsers() {
  const [users,   setUsers]   = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [search,  setSearch]  = useState('')
  const [busy,    setBusy]    = useState<string | null>(null)
  const [sort,    setSort]    = useState<SortKey>('volume')
  const [dir,     setDir]     = useState<'asc' | 'desc'>('desc')
  const [openRow, setOpenRow] = useState<string | null>(null)

  async function load(q = search, s = sort, d = dir) {
    setLoading(true)
    try {
      const params = new URLSearchParams({ sort: s, dir: d })
      if (q) params.set('search', q)
      const res  = await adminFetch(`/admin/manage/users?${params.toString()}`)
      const data = await res.json()
      setUsers(Array.isArray(data) ? data : [])
    } finally { setLoading(false) }
  }
  useEffect(() => { load() }, [])   // eslint-disable-line react-hooks/exhaustive-deps

  // Clicking a header sorts by it; clicking the active one flips direction.
  function toggleSort(key: SortKey) {
    const nextDir = sort === key && dir === 'desc' ? 'asc' : 'desc'
    setSort(key); setDir(nextDir)
    load(search, key, nextDir)
  }

  async function suspend(addr: string) {
    const reason = prompt('Reason for suspension:')
    if (reason === null) return
    setBusy(addr)
    try {
      await adminFetch(`/admin/manage/users/${addr}/suspend`, {
        method: 'POST', body: JSON.stringify({ reason }),
      })
      await load()
    } finally { setBusy(null) }
  }

  async function unsuspend(addr: string) {
    setBusy(addr)
    try {
      await adminFetch(`/admin/manage/users/${addr}/unsuspend`, { method: 'POST' })
      await load()
    } finally { setBusy(null) }
  }

  return (
    <AdminShell>
      <h1 className="mb-1 text-xl font-semibold text-app-text">User management</h1>
      <p className="mb-6 text-xs text-app-muted">
        Click a column to sort, click a row to see the full profile
      </p>

      <div className="mb-4 flex gap-2">
        <div className="relative max-w-md flex-1">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-app-muted" />
          <Input placeholder="Search by username, wallet or name..." value={search}
            onChange={e => setSearch(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && load(search)}
            className="pl-9" />
        </div>
        <Button size="sm" onClick={() => load(search)}>Search</Button>
      </div>

      {/* Sort header */}
      <div className="mb-2 hidden items-center gap-4 rounded-lg bg-app-bg px-4 py-2 md:flex">
        <span className="w-9" />
        {COLUMNS.map(c => (
          <button
            key={c.key}
            onClick={() => toggleSort(c.key)}
            className={`flex items-center gap-1 text-[11px] font-semibold uppercase tracking-wide transition-colors
              ${c.key === 'name' ? 'flex-1 justify-start' : 'w-24 justify-end'}
              ${sort === c.key ? 'text-app-accent-text' : 'text-app-muted hover:text-app-text'}`}
          >
            {c.label}
            {sort === c.key
              ? (dir === 'desc' ? <ChevronDown className="h-3 w-3" /> : <ChevronUp className="h-3 w-3" />)
              : <ArrowUpDown className="h-2.5 w-2.5 opacity-40" />}
          </button>
        ))}
        <span className="w-4" />
      </div>

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : (
        <div className="space-y-2">
          {users.map(u => {
            const isOpen = openRow === u.wallet_address
            // A high dispute rate on a meaningful number of trades is the thing
            // an admin most needs to notice.
            const risky  = u.trades >= 3 && u.dispute_rate >= 30

            return (
              <div key={u.wallet_address}
                className="rounded-xl border border-app-border bg-app-surface">

                {/* Row */}
                <div
                  onClick={() => setOpenRow(isOpen ? null : u.wallet_address)}
                  className="flex cursor-pointer flex-wrap items-center gap-4 p-4 hover:bg-app-bg/40"
                >
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold text-white"
                    style={{ background: u.avatar_color ?? '#D9A441' }}>
                    {(u.display_name ?? u.username ?? '?')[0].toUpperCase()}
                  </div>

                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-sm font-medium text-app-text">{u.display_name ?? u.username}</p>
                      <span className="text-xs text-app-accent-text">@{u.username}</span>
                      {u.verified  ? <Badge variant="arc">Verified</Badge> : null}
                      {u.suspended ? <Badge variant="danger">Suspended</Badge> : null}
                      {risky ? (
                        <span className="flex items-center gap-1 rounded-full bg-amber-900/30 px-2 py-0.5 text-[10px] text-amber-400">
                          <AlertTriangle className="h-2.5 w-2.5" /> High dispute rate
                        </span>
                      ) : null}
                    </div>
                    <p className="font-mono text-[10px] text-app-muted">{u.wallet_address}</p>
                  </div>

                  <div className="w-24 text-right">
                    <p className="font-mono text-sm text-app-text">{fmtUsd(u.volume)}</p>
                    <p className="text-[10px] text-app-muted">USDC</p>
                  </div>
                  <div className="w-24 text-right">
                    <p className="font-mono text-sm text-app-text">{u.trades}</p>
                    <p className="text-[10px] text-app-muted">
                      {u.maker_trades}S / {u.taker_trades}B
                    </p>
                  </div>
                  <div className="w-24 text-right">
                    <p className="font-mono text-sm text-app-text">{fmtUsd(u.avg_trade)}</p>
                    <p className="text-[10px] text-app-muted">avg</p>
                  </div>
                  <div className="w-24 text-right">
                    <p className={`font-mono text-sm ${risky ? 'text-amber-400' : 'text-app-text'}`}>
                      {u.disputes}
                    </p>
                    <p className="text-[10px] text-app-muted">{u.dispute_rate}%</p>
                  </div>
                  <div className="w-24 text-right">
                    <p className="text-xs text-app-text">{relativeDays(u.last_active) ?? '-'}</p>
                    <p className="text-[10px] text-app-muted">{fmtDate(u.last_active)}</p>
                  </div>

                  {isOpen
                    ? <ChevronUp className="h-4 w-4 shrink-0 text-app-muted" />
                    : <ChevronDown className="h-4 w-4 shrink-0 text-app-muted" />}
                </div>

                {/* Expanded profile */}
                {isOpen && (
                  <div className="border-t border-app-border bg-app-bg/40 p-4">
                    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      <div>
                        <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-app-muted">Profile</p>
                        <p className="text-xs text-app-text">{u.display_name ?? '-'}</p>
                        <p className="text-xs text-app-muted">@{u.username}</p>
                        <p className="mt-1 text-[11px] text-app-muted">Joined {fmtDate(u.created_at)}</p>
                      </div>

                      <div>
                        <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-app-muted">Socials</p>
                        {u.show_socials === false && (
                          <p className="text-[11px] italic text-app-muted">User hides socials publicly</p>
                        )}
                        {u.twitter_handle ? (
                          <p className="flex items-center gap-1.5 text-xs text-app-text">
                            <Twitter className="h-3 w-3 text-app-muted" /> @{u.twitter_handle}
                          </p>
                        ) : null}
                        {u.telegram_handle ? (
                          <p className="flex items-center gap-1.5 text-xs text-app-text">
                            <Send className="h-3 w-3 text-app-muted" /> @{u.telegram_handle}
                          </p>
                        ) : null}
                        {!u.twitter_handle && !u.telegram_handle && (
                          <p className="text-xs text-app-muted">None linked</p>
                        )}
                      </div>

                      <div>
                        <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-app-muted">Activity</p>
                        <p className="text-xs text-app-text">
                          {u.trades} completed, {fmtUsd(u.volume)} USDC
                        </p>
                        <p className="text-xs text-app-muted">
                          {u.maker_trades} as seller, {u.taker_trades} as buyer
                        </p>
                        <p className={`text-xs ${risky ? 'text-amber-400' : 'text-app-muted'}`}>
                          {u.disputes} dispute(s), {u.dispute_rate}% of trades
                        </p>
                      </div>

                      {u.bio ? (
                        <div className="sm:col-span-2 lg:col-span-3">
                          <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-app-muted">Bio</p>
                          <p className="text-xs leading-relaxed text-app-text">{u.bio}</p>
                        </div>
                      ) : null}
                    </div>

                    <div className="mt-4 flex justify-end" onClick={e => e.stopPropagation()}>
                      {u.suspended ? (
                        <Button size="sm" variant="outline"
                          onClick={() => unsuspend(u.wallet_address)}
                          disabled={busy === u.wallet_address}>
                          <CheckCircle className="h-3.5 w-3.5" /> Unsuspend
                        </Button>
                      ) : (
                        <Button size="sm" variant="danger"
                          onClick={() => suspend(u.wallet_address)}
                          disabled={busy === u.wallet_address}>
                          <Ban className="h-3.5 w-3.5" /> Suspend
                        </Button>
                      )}
                    </div>
                  </div>
                )}
              </div>
            )
          })}

          {users.length === 0 && (
            <p className="py-8 text-center text-sm text-app-muted">No users found</p>
          )}
        </div>
      )}
    </AdminShell>
  )
}
