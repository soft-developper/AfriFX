'use client'
import { EmailPreferences } from '@/components/notifications/EmailPreferences'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import {
  Twitter, AtSign, Edit2, CheckCircle,
  Loader2, ExternalLink, Star, ShieldCheck,
  TrendingUp, AlertTriangle, Copy, Check,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function ProfilePage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <ProfileContent />
    </ClientOnly>
  )
}

function ProfileContent() {
  const { address }                    = useAccount()
  const { data: profile, refetch }     = useProfile()
  const queryClient                    = useQueryClient()

  const [editing,     setEditing]     = useState(false)
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [saving,      setSaving]      = useState(false)
  const [copied,      setCopied]      = useState(false)

  function startEdit() {
    if (!profile) return
    setDisplayName(profile.display_name)
    setBio(profile.bio ?? '')
    setTwitter(profile.twitter_handle ?? '')
    setTelegram(profile.telegram_handle ?? '')
    setShowSocials(profile.show_socials)
    setEditing(true)
  }

  async function saveEdit() {
    if (!address) return
    setSaving(true)
    try {
      await fetch(`${API}/profile/${address}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          displayName, bio,
          twitterHandle: twitter, telegramHandle: telegram, showSocials,
        }),
      })
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      await refetch()
      setEditing(false)
    } finally { setSaving(false) }
  }

  function copyAddress() {
    if (!address) return
    navigator.clipboard.writeText(address)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (!profile) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-[#64748B]" />
      </div>
    )
  }

  // Use live counts from subquery (never 0 if trades exist)
  const makerTrades   = Number((profile as any).maker_trades   ?? 0)
  const takerTrades   = Number((profile as any).taker_trades   ?? 0)
  const totalTrades   = makerTrades + takerTrades
  const totalDisputes = Number((profile as any).total_disputes ?? profile.dispute_count ?? 0)

  // Reputation tiers
  const reputation =
    totalTrades >= 20 && totalDisputes === 0 ? 'Elite' :
    totalTrades >= 10 && totalDisputes === 0 ? 'Verified' :
    totalTrades >= 5  ? 'Trusted' :
    totalTrades >= 1  ? 'Active'  : 'New'

  const isVerified = totalTrades >= 10 && totalDisputes === 0

  const repColor = {
    Elite:    'text-amber-400',
    Verified: 'text-[#378ADD]',
    Trusted:  'text-emerald-400',
    Active:   'text-emerald-400',
    New:      'text-[#64748B]',
  }[reputation]

  const repBg = {
    Elite:    'bg-amber-900/20 border-amber-900/40',
    Verified: 'bg-[#378ADD]/10 border-[#378ADD]/30',
    Trusted:  'bg-emerald-900/20 border-emerald-900/40',
    Active:   'bg-emerald-900/10 border-emerald-900/20',
    New:      'bg-[#1B2B4B] border-[#1B2B4B]',
  }[reputation]

  // Progress to next tier
  const nextTier = totalTrades < 1 ? { label: 'Active', need: 1, current: totalTrades }
    : totalTrades < 5  ? { label: 'Trusted',  need: 5,  current: totalTrades }
    : totalTrades < 10 ? { label: 'Verified', need: 10, current: totalTrades }
    : totalTrades < 20 ? { label: 'Elite',    need: 20, current: totalTrades }
    : null

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">My profile</h1>
        {!editing && (
          <Button variant="outline" size="sm" onClick={startEdit}>
            <Edit2 className="h-3.5 w-3.5" /> Edit
          </Button>
        )}
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-3">

        {/* Profile card */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <div className="mb-4 flex flex-col items-center gap-3 text-center">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="xl"
              verified={isVerified}
            />
            {editing ? (
              <Input value={displayName} onChange={e => setDisplayName(e.target.value)}
                className="text-center" />
            ) : (
              <div>
                <div className="flex items-center justify-center gap-2">
                  <h2 className="text-lg font-semibold text-[#E2E8F0]">
                    {profile.display_name}
                  </h2>
                  {isVerified && <Badge variant="arc">✓ Verified</Badge>}
                </div>
                <p className="text-sm text-[#378ADD]">@{profile.username}</p>
              </div>
            )}
          </div>

          {/* Bio */}
          {editing ? (
            <textarea value={bio} onChange={e => setBio(e.target.value)}
              placeholder="Add a bio…" maxLength={160} rows={3}
              className="mb-3 w-full resize-none rounded-md border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] placeholder:text-[#64748B] focus:outline-none focus:ring-1 focus:ring-[#378ADD]" />
          ) : profile.bio ? (
            <p className="mb-4 text-center text-sm text-[#64748B]">{profile.bio}</p>
          ) : null}

          {/* Wallet address */}
          <div className="mb-4 flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2">
            <div className="flex-1 min-w-0">
              <p className="text-[10px] text-[#64748B]">Wallet</p>
              <p className="truncate font-mono text-xs text-[#E2E8F0]">
                {address?.slice(0,10)}…{address?.slice(-6)}
              </p>
            </div>
            <button onClick={copyAddress} className="shrink-0 text-[#64748B] hover:text-[#E2E8F0]">
              {copied
                ? <Check className="h-3.5 w-3.5 text-emerald-400" />
                : <Copy className="h-3.5 w-3.5" />
              }
            </button>
            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-[#64748B] hover:text-[#378ADD]">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>

          {/* Socials */}
          {editing ? (
            <div className="space-y-2">
              <div className="relative">
                <Twitter className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-[#64748B]" />
                <Input value={twitter} onChange={e => setTwitter(e.target.value.replace('@',''))}
                  placeholder="Twitter handle" className="pl-8 text-sm" />
              </div>
              <div className="relative">
                <AtSign className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-[#64748B]" />
                <Input value={telegram} onChange={e => setTelegram(e.target.value.replace('@',''))}
                  placeholder="Telegram handle" className="pl-8 text-sm" />
              </div>
              <div className="flex items-center justify-between text-xs">
                <span className="text-[#64748B]">Show socials publicly</span>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-5 w-9 rounded-full transition-colors ${showSocials ? 'bg-[#378ADD]' : 'bg-[#1B2B4B]'}`}>
                  <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-4' : 'translate-x-0.5'}`} />
                </button>
              </div>
            </div>
          ) : (
            <div className="space-y-1.5 text-xs text-[#64748B]">
              {profile.twitter_handle && (
                <a href={`https://twitter.com/${profile.twitter_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`}
                  target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {!profile.twitter_handle && !profile.telegram_handle && (
                <p className="text-center">No socials added yet</p>
              )}
            </div>
          )}

          {editing && (
            <div className="mt-4 flex gap-2">
              <Button variant="outline" className="flex-1" onClick={() => setEditing(false)}>Cancel</Button>
              <Button className="flex-1" onClick={saveEdit} disabled={saving}>
                {saving ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save'}
              </Button>
            </div>
          )}
        </div>

        {/* Reputation + Stats */}
        <div className="lg:col-span-2 space-y-4">

          {/* Reputation banner */}
          <div className={`rounded-xl border p-5 ${repBg}`}>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className={`flex h-12 w-12 items-center justify-center rounded-full border ${repBg}`}>
                  <Star className={`h-6 w-6 ${repColor}`} />
                </div>
                <div>
                  <p className={`text-lg font-bold ${repColor}`}>{reputation} Trader</p>
                  <p className="text-xs text-[#64748B]">
                    {totalTrades} completed trade{totalTrades !== 1 ? 's' : ''} ·{' '}
                    {totalDisputes === 0
                      ? 'Clean record'
                      : `${totalDisputes} dispute${totalDisputes !== 1 ? 's' : ''}`}
                  </p>
                </div>
              </div>
              {isVerified && (
                <div className="flex items-center gap-2 rounded-full bg-[#378ADD]/10 px-3 py-1.5 text-xs text-[#378ADD]">
                  <ShieldCheck className="h-3.5 w-3.5" />
                  Verified
                </div>
              )}
            </div>

            {/* Progress to next tier */}
            {nextTier && (
              <div className="mt-4">
                <div className="mb-1 flex justify-between text-xs">
                  <span className="text-[#64748B]">Progress to {nextTier.label}</span>
                  <span className="text-[#E2E8F0]">
                    {nextTier.current}/{nextTier.need} trades
                    {totalDisputes > 0 ? ' · disputes blocking upgrade' : ''}
                  </span>
                </div>
                <div className="h-1.5 w-full overflow-hidden rounded-full bg-[#1B2B4B]">
                  <div
                    className={`h-full rounded-full transition-all ${repColor.replace('text-','bg-')}`}
                    style={{ width: `${Math.min(100, (nextTier.current / nextTier.need) * 100)}%` }}
                  />
                </div>
              </div>
            )}
          </div>

          {/* Stats grid */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {[
              {
                label: 'Total trades',
                value: String(totalTrades),
                icon:  TrendingUp,
                color: 'text-emerald-400',
                sub:   `${makerTrades} as maker · ${takerTrades} as taker`,
              },
              {
                label: 'Maker trades',
                value: String(makerTrades),
                icon:  TrendingUp,
                color: 'text-[#378ADD]',
                sub:   'Offers you created',
              },
              {
                label: 'Taker trades',
                value: String(takerTrades),
                icon:  TrendingUp,
                color: 'text-[#378ADD]',
                sub:   'Offers you accepted',
              },
              {
                label: 'Disputes',
                value: String(totalDisputes),
                icon:  totalDisputes > 0 ? AlertTriangle : CheckCircle,
                color: totalDisputes > 0 ? 'text-red-400' : 'text-emerald-400',
                sub:   totalDisputes === 0 ? 'Clean record ✓' : 'Raised against you',
              },
            ].map(({ label, value, icon: Icon, color, sub }) => (
              <div key={label} className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-center">
                <Icon className={`mx-auto mb-1 h-4 w-4 ${color}`} />
                <p className={`font-mono text-2xl font-bold ${color}`}>{value}</p>
                <p className="mt-0.5 text-xs font-medium text-[#E2E8F0]">{label}</p>
                <p className="mt-0.5 text-[10px] text-[#64748B]">{sub}</p>
              </div>
            ))}
          </div>

          {/* Shareable profile link */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-2 text-sm font-medium text-[#E2E8F0]">Public profile link</p>
            <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2">
              <p className="flex-1 truncate font-mono text-xs text-[#378ADD]">
                {typeof window !== 'undefined' ? window.location.origin : ''}/profile/{profile.username}
              </p>
              <button
                onClick={() => navigator.clipboard.writeText(
                  `${window.location.origin}/profile/${profile.username}`
                )}
                className="shrink-0 text-xs text-[#64748B] hover:text-[#E2E8F0]">
                Copy
              </button>
            </div>
            <p className="mt-2 text-xs text-[#64748B]">
              Share this link so traders can verify your reputation before trading with you.
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
