'use client'
import { getInitials } from '@/lib/avatar'

interface ProfileAvatarProps {
  displayName:  string
  avatarColor:  string
  size?:        'xs' | 'sm' | 'md' | 'lg' | 'xl'
  verified?:    boolean
  className?:   string
}

const SIZES = {
  xs: { outer: 'h-6 w-6',   font: 'text-[10px]', badge: 'h-2 w-2'   },
  sm: { outer: 'h-8 w-8',   font: 'text-xs',     badge: 'h-2.5 w-2.5'},
  md: { outer: 'h-10 w-10', font: 'text-sm',      badge: 'h-3 w-3'   },
  lg: { outer: 'h-14 w-14', font: 'text-lg',      badge: 'h-4 w-4'   },
  xl: { outer: 'h-20 w-20', font: 'text-2xl',     badge: 'h-5 w-5'   },
}

export function ProfileAvatar({
  displayName, avatarColor, size = 'md', verified, className
}: ProfileAvatarProps) {
  const s       = SIZES[size]
  const initials = getInitials(displayName)

  return (
    <div className={`relative inline-flex shrink-0 ${className ?? ''}`}>
      <div
        className={`${s.outer} flex items-center justify-center rounded-full font-bold text-white`}
        style={{ background: avatarColor }}
      >
        <span className={s.font}>{initials}</span>
      </div>
      {verified && (
        <div className={`absolute -bottom-0.5 -right-0.5 ${s.badge} rounded-full bg-app-accent ring-1 ring-app-bg flex items-center justify-center`}>
          <svg viewBox="0 0 10 10" className="h-full w-full p-0.5">
            <path d="M2 5l2 2 4-4" stroke="white" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      )}
    </div>
  )
}
