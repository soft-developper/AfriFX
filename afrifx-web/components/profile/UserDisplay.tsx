'use client'
import Link from 'next/link'
import { ProfileAvatar } from './ProfileAvatar'
import { useProfileByAddress } from '@/hooks/useProfile'
import { getAvatarColor } from '@/lib/avatar'
import { shortenAddress } from '@/lib/utils'

interface UserDisplayProps {
  address:     string | null | undefined
  size?:       'xs' | 'sm' | 'md'
  showAvatar?: boolean
  clickable?:  boolean
  suffix?:     string
  fallback?:   string   // custom fallback text if no address
}

export function UserDisplay({
  address,
  size       = 'sm',
  showAvatar = true,
  clickable  = true,
  suffix,
  fallback,
}: UserDisplayProps) {
  const { data: profile, isLoading } = useProfileByAddress(address)

  if (!address) {
    return <span className="text-xs text-[#64748B]">{fallback ?? '—'}</span>
  }

  if (isLoading) {
    return (
      <span className="inline-flex items-center gap-1.5">
        {showAvatar && (
          <span className={`${size === 'xs' ? 'h-5 w-5' : 'h-6 w-6'} animate-pulse rounded-full bg-[#1B2B4B]`} />
        )}
        <span className="h-3 w-20 animate-pulse rounded bg-[#1B2B4B]" />
      </span>
    )
  }

  const displayName = profile?.display_name ?? shortenAddress(address)
  const username    = profile?.username
  const color       = profile?.avatar_color ?? getAvatarColor(address)
  const verified    = profile?.verified ?? false

  const label = username ? `@${username}` : displayName

  const inner = (
    <span className="inline-flex items-center gap-1.5">
      {showAvatar && (
        <ProfileAvatar
          displayName={displayName}
          avatarColor={color}
          size={size === 'md' ? 'sm' : 'xs'}
          verified={verified}
        />
      )}
      <span className={`font-medium ${
        size === 'xs' ? 'text-[11px]' :
        size === 'sm' ? 'text-xs'     : 'text-sm'
      } text-[#E2E8F0]`}>
        {label}
        {suffix && <span className="ml-1 text-[#378ADD] text-[10px]">{suffix}</span>}
      </span>
    </span>
  )

  if (clickable && username) {
    return (
      <Link href={`/profile/${username}`} className="hover:opacity-80 transition-opacity">
        {inner}
      </Link>
    )
  }

  return inner
}
