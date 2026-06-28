'use client'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { useProfileByUsername } from '@/hooks/useProfile'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ArrowLeft, Twitter, AtSign, ExternalLink, ShieldCheck } from 'lucide-react'

export default function PublicProfilePage() {
  const { username }        = useParams()
  const { data: profile, isLoading } = useProfileByUsername(username as string)

  if (isLoading) return (
    <div className="space-y-4">
      <div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />
    </div>
  )

  if (!profile) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-[#E2E8F0]">Profile not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const totalTrades = (profile.maker_trades ?? 0) + (profile.taker_trades ?? 0)
  const reputation  = totalTrades >= 10 && profile.dispute_count === 0
    ? 'Elite' : totalTrades >= 5 ? 'Trusted' : totalTrades >= 1 ? 'Active' : 'New'
  const repColor = {
    Elite: 'text-amber-400', Trusted: 'text-emerald-400',
    Active: 'text-[#378ADD]', New: 'text-[#64748B]',
  }[reputation]

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Trader profile</h1>
      </div>

      <div className="max-w-lg space-y-4">
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-6">
          <div className="mb-4 flex items-center gap-4">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="lg"
              verified={profile.verified}
            />
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-lg font-semibold text-[#E2E8F0]">{profile.display_name}</h2>
                {profile.verified && (
                  <Badge variant="arc"><ShieldCheck className="h-3 w-3" /> Verified</Badge>
                )}
              </div>
              <p className="text-sm text-[#378ADD]">@{profile.username}</p>
              {profile.bio && <p className="mt-1 text-xs text-[#64748B]">{profile.bio}</p>}
            </div>
          </div>

          {/* Stats */}
          <div className="mb-4 grid grid-cols-3 gap-2">
            {[
              { label: 'Reputation', value: reputation, color: repColor },
              { label: 'Trades',     value: String(totalTrades),          color: 'text-[#E2E8F0]' },
              { label: 'Disputes',   value: String(profile.dispute_count), color: profile.dispute_count > 0 ? 'text-red-400' : 'text-emerald-400' },
            ].map(({ label, value, color }) => (
              <div key={label} className="rounded-lg bg-[#080D1B] p-3 text-center">
                <p className="text-[10px] text-[#64748B]">{label}</p>
                <p className={`mt-1 text-base font-bold ${color}`}>{value}</p>
              </div>
            ))}
          </div>

          {/* Socials */}
          {(profile.twitter_handle || profile.telegram_handle) && (
            <div className="space-y-1.5 border-t border-[#1B2B4B] pt-4 text-xs text-[#64748B]">
              {profile.twitter_handle && (
                <a href={`https://twitter.com/${profile.twitter_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="ml-auto h-3 w-3" />
                </a>
              )}
            </div>
          )}
        </div>

        <p className="text-center text-xs text-[#64748B]">
          Member since {new Date(profile.created_at * 1000).toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}
        </p>
      </div>
    </div>
  )
}
