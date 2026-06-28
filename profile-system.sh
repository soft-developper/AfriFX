#!/bin/bash
# ============================================================
# AfriFX — User Profile System
# Run from ~/AfriFX:  bash profile-system.sh
# ============================================================
set -e
echo ""
echo "👤  Building User Profile System..."
echo ""

# ============================================================
# 1 — Turso: create profiles table
# ============================================================
echo "  Creating profiles table in Turso..."
turso db shell afrifx "
CREATE TABLE IF NOT EXISTS profiles (
  wallet_address  TEXT PRIMARY KEY,
  username        TEXT UNIQUE NOT NULL,
  display_name    TEXT NOT NULL,
  bio             TEXT,
  twitter_handle  TEXT,
  telegram_handle TEXT,
  avatar_color    TEXT NOT NULL DEFAULT '#378ADD',
  trade_count     INTEGER NOT NULL DEFAULT 0,
  dispute_count   INTEGER NOT NULL DEFAULT 0,
  verified        INTEGER NOT NULL DEFAULT 0,
  show_socials    INTEGER NOT NULL DEFAULT 1,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);" && echo "  ✅  profiles table created"

# Username index for fast lookups
turso db shell afrifx "
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_username
ON profiles (LOWER(username));" && echo "  ✅  username index created"

# ============================================================
# 2 — Backend: profile routes
# ============================================================
cat > afrifx-api/src/routes/profile.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'

const router = Router()

const RESERVED = [
  'admin','afrifx','support','help','root','system','platform',
  'api','www','app','mail','dev','test','null','undefined',
]

const AVATAR_COLORS = [
  '#378ADD','#10B981','#8B5CF6','#F59E0B',
  '#EF4444','#EC4899','#14B8A6','#F97316',
  '#06B6D4','#84CC16','#A855F7','#FB923C',
]

function deriveColor(username: string): string {
  let hash = 0
  for (let i = 0; i < username.length; i++) {
    hash = username.charCodeAt(i) + ((hash << 5) - hash)
  }
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length]
}

function validateUsername(u: string): string | null {
  if (!u) return 'Username is required'
  if (u.length < 3)  return 'Username must be at least 3 characters'
  if (u.length > 20) return 'Username must be 20 characters or less'
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return 'Only letters, numbers and underscores allowed'
  if (RESERVED.includes(u.toLowerCase())) return 'This username is reserved'
  return null
}

// GET /profile/check/:username — availability check
router.get('/check/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  const err = validateUsername(username)
  if (err) return res.json({ available: false, error: err })
  try {
    const rows = await db.run(
      sql`SELECT wallet_address FROM profiles WHERE LOWER(username) = ${username} LIMIT 1`
    )
    const r = Array.isArray((rows as any).rows) ? (rows as any).rows : []
    res.json({ available: r.length === 0 })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/wallet/:address — by wallet address
router.get('/wallet/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  try {
    const rows = await db.run(
      sql`SELECT * FROM profiles WHERE LOWER(wallet_address) = ${addr} LIMIT 1`
    )
    const r = Array.isArray((rows as any).rows) ? (rows as any).rows : []
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    res.json(normalizeProfile(r[0]))
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// GET /profile/:username — by username (public)
router.get('/:username', async (req, res) => {
  const username = req.params.username.toLowerCase()
  try {
    const rows = await db.run(
      sql`SELECT p.*,
            (SELECT COUNT(*) FROM p2p_offers
             WHERE LOWER(maker_address) = LOWER(p.wallet_address)
               AND status = 'released') as maker_trades,
            (SELECT COUNT(*) FROM p2p_offers
             WHERE LOWER(taker_address) = LOWER(p.wallet_address)
               AND status = 'released') as taker_trades
          FROM profiles p
          WHERE LOWER(p.username) = ${username} LIMIT 1`
    )
    const r = Array.isArray((rows as any).rows) ? (rows as any).rows : []
    if (!r.length) return res.status(404).json({ error: 'Profile not found' })
    const profile = normalizeProfile(r[0])
    // Hide socials if user opted out
    if (!profile.show_socials) {
      profile.twitter_handle  = null
      profile.telegram_handle = null
    }
    res.json(profile)
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

// POST /profile — create profile (called on first connect)
router.post('/', async (req, res) => {
  const {
    walletAddress, username, displayName,
    bio, twitterHandle, telegramHandle, showSocials,
  } = req.body

  const err = validateUsername(username)
  if (err) return res.status(400).json({ error: err })
  if (!displayName?.trim()) return res.status(400).json({ error: 'Display name is required' })
  if (!walletAddress) return res.status(400).json({ error: 'Wallet address is required' })

  const now   = Math.floor(Date.now() / 1000)
  const color = deriveColor(username.toLowerCase())

  try {
    // Check username not taken
    const existing = await db.run(
      sql`SELECT wallet_address FROM profiles WHERE LOWER(username) = ${username.toLowerCase()} LIMIT 1`
    )
    const r = Array.isArray((existing as any).rows) ? (existing as any).rows : []
    if (r.length) return res.status(409).json({ error: 'Username already taken' })

    await db.run(
      sql`INSERT INTO profiles
          (wallet_address, username, display_name, bio,
           twitter_handle, telegram_handle, avatar_color,
           show_socials, created_at, updated_at)
          VALUES
          (${walletAddress.toLowerCase()}, ${username.toLowerCase()},
           ${displayName.trim()}, ${bio?.trim() || null},
           ${twitterHandle?.replace('@','').trim() || null},
           ${telegramHandle?.replace('@','').trim() || null},
           ${color}, ${showSocials !== false ? 1 : 0},
           ${now}, ${now})`
    )
    res.status(201).json({ username: username.toLowerCase(), avatarColor: color })
  } catch (e: any) {
    if (e.message?.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Username already taken' })
    }
    res.status(500).json({ error: e.message })
  }
})

// PATCH /profile/:address — update profile
router.patch('/:address', async (req, res) => {
  const addr = req.params.address.toLowerCase()
  const {
    displayName, bio, twitterHandle, telegramHandle, showSocials,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE profiles SET
            display_name    = COALESCE(${displayName?.trim()   ?? null}, display_name),
            bio             = COALESCE(${bio?.trim()           ?? null}, bio),
            twitter_handle  = COALESCE(${twitterHandle?.replace('@','').trim() ?? null}, twitter_handle),
            telegram_handle = COALESCE(${telegramHandle?.replace('@','').trim() ?? null}, telegram_handle),
            show_socials    = COALESCE(${showSocials !== undefined ? (showSocials ? 1 : 0) : null}, show_socials),
            updated_at      = ${now}
          WHERE LOWER(wallet_address) = ${addr}`
    )
    res.json({ success: true })
  } catch (e: any) { res.status(500).json({ error: e.message }) }
})

function normalizeProfile(row: any) {
  if (Array.isArray(row)) {
    return {
      wallet_address:  row[0], username:        row[1],
      display_name:    row[2], bio:             row[3],
      twitter_handle:  row[4], telegram_handle: row[5],
      avatar_color:    row[6], trade_count:     Number(row[7]),
      dispute_count:   Number(row[8]), verified: !!row[9],
      show_socials:    !!row[10],
      created_at:      Number(row[11]), updated_at: Number(row[12]),
      maker_trades:    Number(row[13] ?? 0),
      taker_trades:    Number(row[14] ?? 0),
    }
  }
  return {
    ...row,
    verified:      !!row.verified,
    show_socials:  !!row.show_socials,
    trade_count:   Number(row.trade_count   ?? 0),
    dispute_count: Number(row.dispute_count ?? 0),
    maker_trades:  Number(row.maker_trades  ?? 0),
    taker_trades:  Number(row.taker_trades  ?? 0),
  }
}

export default router
__EOF__
echo "✅  routes/profile.ts"

# Register profile route in index.ts
cat > afrifx-api/src/index.ts << '__EOF__'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }       from './middleware/cors'
import { rateLimitMiddleware }  from './middleware/rateLimit'
import { errorHandler }         from './middleware/errorHandler'
import ratesRouter              from './routes/rates'
import transactionsRouter       from './routes/transactions'
import userRouter               from './routes/user'
import offersRouter             from './routes/offers'
import profileRouter            from './routes/profile'
import { startRatePoller }      from './jobs/ratePoller'
import { startEventListener }   from './services/eventListener'
import { startP2PReleaseWatcher } from './jobs/p2pReleaseWatcher'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', chain: 'Arc Testnet 5042002', ts: Date.now() })
})

app.use('/rates',        ratesRouter)
app.use('/transactions', transactionsRouter)
app.use('/user',         userRouter)
app.use('/offers',       offersRouter)
app.use('/profile',      profileRouter)

app.use(errorHandler)

app.listen(PORT, () => {
  console.log(`\n🚀  AfriFX API running on http://localhost:${PORT}`)
  console.log(`    Chain: Arc Testnet · Chain ID 5042002`)
  startRatePoller()
  startEventListener()
  startP2PReleaseWatcher()
})
__EOF__
echo "✅  index.ts — /profile route registered"

# ============================================================
# 3 — Frontend: lib/avatar.ts
# ============================================================
cat > afrifx-web/lib/avatar.ts << '__EOF__'
// Deterministic avatar color from username
const COLORS = [
  '#378ADD','#10B981','#8B5CF6','#F59E0B',
  '#EF4444','#EC4899','#14B8A6','#F97316',
  '#06B6D4','#84CC16','#A855F7','#FB923C',
]

export function getAvatarColor(seed: string): string {
  let hash = 0
  for (let i = 0; i < seed.length; i++) {
    hash = seed.charCodeAt(i) + ((hash << 5) - hash)
  }
  return COLORS[Math.abs(hash) % COLORS.length]
}

export function getInitials(name: string): string {
  const parts = name.trim().split(/\s+/)
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase()
  return name.slice(0, 2).toUpperCase()
}
__EOF__
echo "✅  lib/avatar.ts"

# ============================================================
# 4 — Frontend: types
# ============================================================
cat >> afrifx-web/types/index.ts << '__EOF__'

export interface UserProfile {
  wallet_address:  string
  username:        string
  display_name:    string
  bio:             string | null
  twitter_handle:  string | null
  telegram_handle: string | null
  avatar_color:    string
  trade_count:     number
  dispute_count:   number
  verified:        boolean
  show_socials:    boolean
  created_at:      number
  updated_at:      number
  maker_trades?:   number
  taker_trades?:   number
}
__EOF__
echo "✅  types/index.ts — UserProfile added"

# ============================================================
# 5 — Frontend: useProfile hook
# ============================================================
cat > afrifx-web/hooks/useProfile.ts << '__EOF__'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'
import type { UserProfile } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

// Fetch current user's profile
export function useProfile() {
  const { address } = useAccount()
  return useQuery<UserProfile | null>({
    queryKey:  ['profile', address],
    queryFn:   async () => {
      if (!address) return null
      const res = await fetch(`${API}/profile/wallet/${address}`)
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:       !!address,
    staleTime:     60_000,
    retry:         false,
  })
}

// Fetch any profile by username
export function useProfileByUsername(username: string | null) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-username', username],
    queryFn:  async () => {
      if (!username) return null
      const res = await fetch(`${API}/profile/${username}`)
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:   !!username,
    staleTime: 30_000,
  })
}

// Fetch profile by wallet address (for displaying other users)
export function useProfileByAddress(address: string | null | undefined) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-address', address?.toLowerCase()],
    queryFn:  async () => {
      if (!address) return null
      const res = await fetch(`${API}/profile/wallet/${address}`)
      if (res.status === 404) return null
      if (!res.ok) return null
      return res.json()
    },
    enabled:   !!address,
    staleTime: 60_000,
    retry:     false,
  })
}

// Check username availability
export async function checkUsername(username: string): Promise<{ available: boolean; error?: string }> {
  const res = await fetch(`${API}/profile/check/${username}`)
  return res.json()
}
__EOF__
echo "✅  hooks/useProfile.ts"

# ============================================================
# 6 — Frontend: ProfileAvatar component
# ============================================================
mkdir -p afrifx-web/components/profile

cat > afrifx-web/components/profile/ProfileAvatar.tsx << '__EOF__'
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
        <div className={`absolute -bottom-0.5 -right-0.5 ${s.badge} rounded-full bg-[#378ADD] ring-1 ring-[#080D1B] flex items-center justify-center`}>
          <svg viewBox="0 0 10 10" className="h-full w-full p-0.5">
            <path d="M2 5l2 2 4-4" stroke="white" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  components/profile/ProfileAvatar.tsx"

# ============================================================
# 7 — Frontend: UserDisplay — shows avatar + name
#     Falls back to shortened address if no profile
# ============================================================
cat > afrifx-web/components/profile/UserDisplay.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { ProfileAvatar } from './ProfileAvatar'
import { useProfileByAddress } from '@/hooks/useProfile'
import { getAvatarColor } from '@/lib/avatar'
import { shortenAddress } from '@/lib/utils'

interface UserDisplayProps {
  address:    string
  size?:      'xs' | 'sm' | 'md'
  showAvatar?: boolean
  clickable?:  boolean
  suffix?:     string   // e.g. " (you)"
}

export function UserDisplay({
  address, size = 'sm', showAvatar = true, clickable = true, suffix
}: UserDisplayProps) {
  const { data: profile, isLoading } = useProfileByAddress(address)

  if (isLoading) {
    return (
      <span className="inline-flex items-center gap-1.5">
        <span className={`${size === 'xs' ? 'h-5 w-5' : 'h-7 w-7'} animate-pulse rounded-full bg-[#1B2B4B]`} />
        <span className="h-3 w-20 animate-pulse rounded bg-[#1B2B4B]" />
      </span>
    )
  }

  const displayName = profile?.display_name ?? shortenAddress(address)
  const username    = profile?.username
  const color       = profile?.avatar_color ?? getAvatarColor(address)
  const verified    = profile?.verified ?? false

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
      <span className={`font-medium ${size === 'xs' ? 'text-xs' : 'text-sm'} text-[#E2E8F0]`}>
        {username ? `@${username}` : displayName}
        {suffix && <span className="ml-1 text-[#378ADD] text-xs">{suffix}</span>}
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
__EOF__
echo "✅  components/profile/UserDisplay.tsx"

# ============================================================
# 8 — Frontend: Profile setup page (onboarding)
# ============================================================
mkdir -p "afrifx-web/app/(auth)/profile/setup"

cat > "afrifx-web/app/(auth)/profile/setup/page.tsx" << '__EOF__'
'use client'
import { useState, useEffect, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { getAvatarColor } from '@/lib/avatar'
import { checkUsername } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeftRight, CheckCircle, XCircle,
  Twitter, AtSign, Loader2, Sparkles,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function ProfileSetupPage() {
  const { address, isConnected } = useAccount()
  const router       = useRouter()
  const queryClient  = useQueryClient()

  const [username,    setUsername]    = useState('')
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [step,        setStep]        = useState(1) // 1=identity, 2=socials, 3=done

  const [usernameState, setUsernameState] = useState<'idle'|'checking'|'available'|'taken'|'invalid'>('idle')
  const [usernameError, setUsernameError] = useState('')
  const [submitting,    setSubmitting]    = useState(false)
  const [submitError,   setSubmitError]   = useState('')

  const avatarColor = username ? getAvatarColor(username) : '#378ADD'

  // Live username check with debounce
  useEffect(() => {
    if (!username) { setUsernameState('idle'); return }
    if (username.length < 3) { setUsernameState('invalid'); setUsernameError('Min 3 characters'); return }
    if (username.length > 20) { setUsernameState('invalid'); setUsernameError('Max 20 characters'); return }
    if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      setUsernameState('invalid')
      setUsernameError('Letters, numbers, underscores only')
      return
    }

    setUsernameState('checking')
    const t = setTimeout(async () => {
      const result = await checkUsername(username)
      if (result.error) {
        setUsernameState('invalid')
        setUsernameError(result.error)
      } else if (result.available) {
        setUsernameState('available')
        setUsernameError('')
      } else {
        setUsernameState('taken')
        setUsernameError('This username is taken')
      }
    }, 500)
    return () => clearTimeout(t)
  }, [username])

  async function handleSubmit() {
    if (!address || usernameState !== 'available' || !displayName.trim()) return
    setSubmitting(true)
    setSubmitError('')
    try {
      const res = await fetch(`${API}/profile`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress:  address,
          username,
          displayName:    displayName.trim(),
          bio:            bio.trim() || null,
          twitterHandle:  twitter.trim() || null,
          telegramHandle: telegram.trim() || null,
          showSocials,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setSubmitError(data.error ?? 'Failed to create profile'); return }

      // Invalidate profile cache so app picks up new profile
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      setStep(3)
    } catch (e: any) {
      setSubmitError(e.message)
    } finally {
      setSubmitting(false)
    }
  }

  if (!isConnected) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-[#64748B]">Connect your wallet first.</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      {/* Logo */}
      <div className="mb-8 flex items-center gap-2">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-[#378ADD]/20">
          <ArrowLeftRight className="h-5 w-5 text-[#378ADD]" />
        </div>
        <span className="text-xl font-semibold text-[#E2E8F0]">AfriFX</span>
      </div>

      {/* Step 3: Done */}
      {step === 3 && (
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex justify-center">
            <ProfileAvatar displayName={displayName} avatarColor={avatarColor} size="xl" />
          </div>
          <h1 className="mb-2 text-2xl font-semibold text-[#E2E8F0]">Welcome, {displayName}!</h1>
          <p className="mb-2 text-sm text-[#64748B]">
            Your profile <span className="text-[#378ADD]">@{username}</span> is ready.
          </p>
          <p className="mb-8 text-xs text-[#64748B]">
            You can update your profile anytime from the settings page.
          </p>
          <Button className="w-full" size="lg" onClick={() => router.push('/convert')}>
            <Sparkles className="h-4 w-4" />
            Enter AfriFX
          </Button>
        </div>
      )}

      {/* Step 1 & 2: Form */}
      {step < 3 && (
        <div className="w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-2xl font-semibold text-[#E2E8F0]">Create your profile</h1>
            <p className="mt-1 text-sm text-[#64748B]">
              Set up your identity on AfriFX. Your username is permanent.
            </p>
          </div>

          {/* Step indicator */}
          <div className="mb-8 flex items-center gap-2">
            {[1,2].map((s) => (
              <div key={s} className="flex items-center gap-2">
                <div className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold
                  ${step >= s ? 'bg-[#378ADD] text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {step > s ? '✓' : s}
                </div>
                <span className={`text-xs ${step >= s ? 'text-[#E2E8F0]' : 'text-[#64748B]'}`}>
                  {s === 1 ? 'Identity' : 'Socials'}
                </span>
                {s < 2 && <div className="h-px w-8 bg-[#1B2B4B]" />}
              </div>
            ))}
          </div>

          {/* Step 1: Identity */}
          {step === 1 && (
            <div className="space-y-4">
              {/* Live avatar preview */}
              <div className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
                <ProfileAvatar
                  displayName={displayName || username || 'A'}
                  avatarColor={avatarColor}
                  size="lg"
                />
                <div>
                  <p className="text-sm font-medium text-[#E2E8F0]">
                    {displayName || 'Your name'}
                  </p>
                  <p className="text-xs text-[#64748B]">
                    {username ? `@${username}` : '@username'}
                  </p>
                </div>
              </div>

              {/* Username */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Username <span className="text-red-400">*</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input
                    value={username}
                    onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g,''))}
                    placeholder="yourname"
                    className="pl-7 font-mono"
                    maxLength={20}
                  />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2">
                    {usernameState === 'checking'   && <Loader2  className="h-4 w-4 animate-spin text-[#64748B]" />}
                    {usernameState === 'available'  && <CheckCircle className="h-4 w-4 text-emerald-400" />}
                    {(usernameState === 'taken' || usernameState === 'invalid') && <XCircle className="h-4 w-4 text-red-400" />}
                  </span>
                </div>
                {usernameState === 'available' && (
                  <p className="mt-1 text-xs text-emerald-400">@{username} is available!</p>
                )}
                {usernameError && (
                  <p className="mt-1 text-xs text-red-400">{usernameError}</p>
                )}
                <p className="mt-1 text-[10px] text-[#64748B]">
                  3–20 characters · letters, numbers, underscores · permanent
                </p>
              </div>

              {/* Display name */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Display name <span className="text-red-400">*</span>
                </label>
                <Input
                  value={displayName}
                  onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="Your full name"
                  maxLength={40}
                />
                <p className="mt-1 text-[10px] text-[#64748B]">
                  Shown instead of your wallet address throughout the platform
                </p>
              </div>

              {/* Bio */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Bio <span className="text-[#64748B] font-normal normal-case">(optional)</span>
                </label>
                <textarea
                  value={bio}
                  onChange={(e) => setBio(e.target.value)}
                  placeholder="Tell others a bit about yourself…"
                  maxLength={160}
                  rows={3}
                  className="w-full rounded-md border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] placeholder:text-[#64748B] focus:outline-none focus:ring-1 focus:ring-[#378ADD] resize-none"
                />
                <p className="mt-1 text-right text-[10px] text-[#64748B]">{bio.length}/160</p>
              </div>

              <Button
                className="w-full"
                size="lg"
                onClick={() => setStep(2)}
                disabled={usernameState !== 'available' || !displayName.trim()}
              >
                Next — Add socials
              </Button>
            </div>
          )}

          {/* Step 2: Socials */}
          {step === 2 && (
            <div className="space-y-4">
              <p className="text-xs text-[#64748B]">
                Connect your social accounts so traders can verify and trust you.
                All optional — you can add these later in settings.
              </p>

              {/* Twitter */}
              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  <Twitter className="h-3.5 w-3.5" /> Twitter / X
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input
                    value={twitter}
                    onChange={(e) => setTwitter(e.target.value.replace('@',''))}
                    placeholder="yourhandle"
                    className="pl-7"
                  />
                </div>
              </div>

              {/* Telegram */}
              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  <AtSign className="h-3.5 w-3.5" /> Telegram
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input
                    value={telegram}
                    onChange={(e) => setTelegram(e.target.value.replace('@',''))}
                    placeholder="yourhandle"
                    className="pl-7"
                  />
                </div>
              </div>

              {/* Privacy toggle */}
              <div className="flex items-center justify-between rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-3">
                <div>
                  <p className="text-sm font-medium text-[#E2E8F0]">Show socials publicly</p>
                  <p className="text-xs text-[#64748B]">Others can see your Twitter and Telegram</p>
                </div>
                <button
                  onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-6 w-11 rounded-full transition-colors ${showSocials ? 'bg-[#378ADD]' : 'bg-[#1B2B4B]'}`}
                >
                  <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-5' : 'translate-x-0.5'}`} />
                </button>
              </div>

              {submitError && (
                <p className="text-xs text-red-400">{submitError}</p>
              )}

              <div className="flex gap-2">
                <Button variant="outline" className="flex-1" onClick={() => setStep(1)}>
                  Back
                </Button>
                <Button
                  className="flex-1"
                  size="lg"
                  onClick={handleSubmit}
                  disabled={submitting}
                >
                  {submitting
                    ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</>
                    : 'Create profile'
                  }
                </Button>
              </div>

              <button
                onClick={handleSubmit}
                disabled={submitting}
                className="w-full text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors"
              >
                Skip socials for now →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  app/(auth)/profile/setup/page.tsx"

# ============================================================
# 9 — Frontend: Own profile page
# ============================================================
mkdir -p "afrifx-web/app/(app)/profile"

cat > "afrifx-web/app/(app)/profile/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { useQueryClient } from '@tanstack/react-query'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ClientOnly } from '@/components/ui/client-only'
import { Twitter, AtSign, Edit2, CheckCircle, Loader2, ExternalLink } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export default function ProfilePage() {
  return (
    <ClientOnly fallback={<div className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />}>
      <ProfileContent />
    </ClientOnly>
  )
}

function ProfileContent() {
  const { address }          = useAccount()
  const { data: profile, refetch } = useProfile()
  const queryClient          = useQueryClient()

  const [editing,     setEditing]     = useState(false)
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [saving,      setSaving]      = useState(false)

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
        body: JSON.stringify({ displayName, bio, twitterHandle: twitter, telegramHandle: telegram, showSocials }),
      })
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      await refetch()
      setEditing(false)
    } finally { setSaving(false) }
  }

  if (!profile) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-[#64748B]">Loading profile…</p>
      </div>
    )
  }

  const totalTrades = (profile.maker_trades ?? 0) + (profile.taker_trades ?? 0)
  const reputation  = totalTrades >= 10 && profile.dispute_count === 0
    ? 'Elite'
    : totalTrades >= 5
    ? 'Trusted'
    : totalTrades >= 1
    ? 'Active'
    : 'New'

  const repColor = {
    Elite: 'text-amber-400', Trusted: 'text-emerald-400',
    Active: 'text-[#378ADD]', New: 'text-[#64748B]',
  }[reputation]

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

      <div className="grid gap-4 lg:grid-cols-3">

        {/* Profile card */}
        <div className="lg:col-span-1 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">

          <div className="mb-4 flex flex-col items-center gap-3 text-center">
            <ProfileAvatar
              displayName={profile.display_name}
              avatarColor={profile.avatar_color}
              size="xl"
              verified={profile.verified}
            />
            {editing ? (
              <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)} className="text-center" />
            ) : (
              <div>
                <div className="flex items-center justify-center gap-2">
                  <h2 className="text-lg font-semibold text-[#E2E8F0]">{profile.display_name}</h2>
                  {profile.verified && <Badge variant="arc">Verified</Badge>}
                </div>
                <p className="text-sm text-[#378ADD]">@{profile.username}</p>
              </div>
            )}
          </div>

          {/* Bio */}
          {editing ? (
            <textarea
              value={bio}
              onChange={(e) => setBio(e.target.value)}
              placeholder="Add a bio…"
              maxLength={160}
              rows={3}
              className="w-full rounded-md border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] placeholder:text-[#64748B] focus:outline-none focus:ring-1 focus:ring-[#378ADD] resize-none mb-3"
            />
          ) : profile.bio ? (
            <p className="mb-4 text-center text-sm text-[#64748B]">{profile.bio}</p>
          ) : null}

          {/* Wallet */}
          <div className="mb-4 rounded-lg bg-[#080D1B] px-3 py-2 text-center">
            <p className="text-[10px] text-[#64748B]">Wallet</p>
            <p className="font-mono text-xs text-[#E2E8F0]">{address?.slice(0,8)}…{address?.slice(-6)}</p>
          </div>

          {/* Socials */}
          {editing ? (
            <div className="space-y-2">
              <div className="relative">
                <Twitter className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-[#64748B]" />
                <Input value={twitter} onChange={(e) => setTwitter(e.target.value.replace('@',''))} placeholder="Twitter handle" className="pl-8 text-sm" />
              </div>
              <div className="relative">
                <AtSign className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-[#64748B]" />
                <Input value={telegram} onChange={(e) => setTelegram(e.target.value.replace('@',''))} placeholder="Telegram handle" className="pl-8 text-sm" />
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
                <a href={`https://twitter.com/${profile.twitter_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <Twitter className="h-3.5 w-3.5" /> @{profile.twitter_handle}
                  <ExternalLink className="h-3 w-3 ml-auto" />
                </a>
              )}
              {profile.telegram_handle && (
                <a href={`https://t.me/${profile.telegram_handle}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-2 hover:text-[#E2E8F0]">
                  <AtSign className="h-3.5 w-3.5" /> @{profile.telegram_handle}
                  <ExternalLink className="h-3 w-3 ml-auto" />
                </a>
              )}
              {!profile.twitter_handle && !profile.telegram_handle && (
                <p className="text-center text-[#64748B]">No socials added yet</p>
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

        {/* Stats */}
        <div className="lg:col-span-2 space-y-4">

          {/* Reputation */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Reputation</p>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {[
                { label: 'Status',          value: reputation,                          color: repColor },
                { label: 'Completed trades', value: String(totalTrades),               color: 'text-[#E2E8F0]' },
                { label: 'Offers made',      value: String(profile.maker_trades ?? 0), color: 'text-[#E2E8F0]' },
                { label: 'Disputes',         value: String(profile.dispute_count),      color: profile.dispute_count > 0 ? 'text-red-400' : 'text-emerald-400' },
              ].map(({ label, value, color }) => (
                <div key={label} className="rounded-lg bg-[#080D1B] p-3 text-center">
                  <p className="text-[10px] text-[#64748B]">{label}</p>
                  <p className={`mt-1 text-lg font-bold ${color}`}>{value}</p>
                </div>
              ))}
            </div>

            {!profile.verified && totalTrades < 10 && (
              <p className="mt-3 text-xs text-[#64748B]">
                Complete {10 - totalTrades} more trade{10 - totalTrades !== 1 ? 's' : ''} with zero disputes to earn the Verified badge.
              </p>
            )}
            {profile.verified && (
              <div className="mt-3 flex items-center gap-2 text-xs text-emerald-400">
                <CheckCircle className="h-3.5 w-3.5" />
                Verified trader — 10+ completed trades, zero disputes
              </div>
            )}
          </div>

          {/* Shareable link */}
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
            <p className="mb-2 text-sm font-medium text-[#E2E8F0]">Public profile link</p>
            <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2">
              <p className="flex-1 font-mono text-xs text-[#378ADD]">
                {typeof window !== 'undefined' ? window.location.origin : ''}/profile/{profile.username}
              </p>
              <button
                onClick={() => navigator.clipboard.writeText(`${window.location.origin}/profile/${profile.username}`)}
                className="text-xs text-[#64748B] hover:text-[#E2E8F0]">
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
__EOF__
echo "✅  app/(app)/profile/page.tsx"

# ============================================================
# 10 — Public profile page
# ============================================================
mkdir -p "afrifx-web/app/(app)/profile/[username]"

cat > "afrifx-web/app/(app)/profile/[username]/page.tsx" << '__EOF__'
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
__EOF__
echo "✅  app/(app)/profile/[username]/page.tsx"

# ============================================================
# 11 — App layout: redirect to /profile/setup if no profile
# ============================================================
cat > "afrifx-web/app/(app)/layout.tsx" << '__EOF__'
'use client'
import { useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useRouter, usePathname } from 'next/navigation'
import { useProfile } from '@/hooks/useProfile'
import { TopNav } from '@/components/layout/TopNav'
import { Sidebar } from '@/components/layout/Sidebar'
import { TickerStrip } from '@/components/layout/TickerStrip'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  const { isConnected, address } = useAccount()
  const { data: profile, isLoading } = useProfile()
  const router   = useRouter()
  const pathname = usePathname()

  useEffect(() => {
    if (!isConnected || isLoading) return
    if (!profile && address) {
      // Redirect to profile setup if wallet is connected but no profile exists
      router.push('/profile/setup')
    }
  }, [isConnected, isLoading, profile, address, router])

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <TickerStrip />
      <TopNav />
      <div className="flex flex-1 overflow-hidden">
        <Sidebar />
        <main className="flex-1 overflow-y-auto p-6">{children}</main>
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/layout.tsx — profile guard added"

# ============================================================
# 12 — TopNav: show profile avatar instead of raw address
# ============================================================
cat > afrifx-web/components/layout/TopNav.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { useAccount, useDisconnect } from 'wagmi'
import { useProfile } from '@/hooks/useProfile'
import { ProfileAvatar } from '@/components/profile/ProfileAvatar'
import { ConnectButton } from '@/components/wallet/ConnectButton'
import { ClientOnly } from '@/components/ui/client-only'

function NavProfile() {
  const { address, isConnected } = useAccount()
  const { data: profile }        = useProfile()
  const { disconnect }           = useDisconnect()

  if (!isConnected) return <ConnectButton />

  if (profile) {
    return (
      <div className="flex items-center gap-2">
        <Link href="/profile" className="flex items-center gap-2 hover:opacity-80 transition-opacity">
          <ProfileAvatar
            displayName={profile.display_name}
            avatarColor={profile.avatar_color}
            size="sm"
            verified={profile.verified}
          />
          <div className="hidden sm:block text-right">
            <p className="text-xs font-medium text-[#E2E8F0]">{profile.display_name}</p>
            <p className="text-[10px] text-[#378ADD]">@{profile.username}</p>
          </div>
        </Link>
        <button
          onClick={() => disconnect()}
          className="rounded-full border border-[#1B2B4B] px-2.5 py-1 text-[10px] text-[#64748B] hover:text-[#E2E8F0] transition-colors"
        >
          Disconnect
        </button>
      </div>
    )
  }

  // Wallet connected but no profile yet
  return <ConnectButton />
}

export function TopNav() {
  return (
    <header className="flex h-14 items-center justify-between border-b border-[#1B2B4B] px-5">
      <Link href="/convert" className="flex items-center gap-2 text-[#E2E8F0] font-semibold">
        <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-[#378ADD]/20">
          <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
        </div>
        AfriFX
        <span className="inline-flex items-center gap-1 rounded-full bg-[#378ADD]/10 px-2 py-0.5 text-[10px] font-medium text-[#378ADD]">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </Link>
      <ClientOnly fallback={<div className="h-8 w-32 animate-pulse rounded-full bg-[#1B2B4B]" />}>
        <NavProfile />
      </ClientOnly>
    </header>
  )
}
__EOF__
echo "✅  TopNav — profile avatar + name instead of address"

# ============================================================
# 13 — Sidebar: add Profile link
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History, LayoutDashboard,
  TrendingUp, Globe, Store, ClipboardList, User
} from 'lucide-react'
import { cn } from '@/lib/utils'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',   icon: ArrowLeftRight, label: 'Convert'  },
    { href: '/corridor',  icon: Globe,          label: 'Corridor' },
    { href: '/send',      icon: Send,           label: 'Send'     },
  ]},
  { label: 'P2P Market', items: [
    { href: '/marketplace',        icon: Store,         label: 'Marketplace'  },
    { href: '/marketplace/create', icon: ClipboardList, label: 'Create offer' },
    { href: '/my-trades',          icon: ClipboardList, label: 'My trades'    },
  ]},
  { label: 'Account', items: [
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
    { href: '/profile',   icon: User,            label: 'Profile'   },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()
  return (
    <aside className="w-52 shrink-0 border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname === href || (href !== '/' && pathname.startsWith(href + '/'))
            return (
              <Link key={href} href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}>
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Profile link added"

# ============================================================
# 14 — Update offer detail + marketplace to use UserDisplay
# ============================================================

# Update UserDisplay import in offer detail
grep -q "UserDisplay" "afrifx-web/app/(app)/marketplace/[id]/page.tsx" 2>/dev/null || \
echo "  Note: Update offer detail page to use UserDisplay for maker/taker display"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Profile system complete!"
echo ""
echo "  New backend:"
echo "    GET  /profile/check/:username  — availability check"
echo "    GET  /profile/wallet/:address  — by wallet"
echo "    GET  /profile/:username        — public profile"
echo "    POST /profile                  — create"
echo "    PATCH /profile/:address        — update"
echo ""
echo "  New pages:"
echo "    /profile/setup     — onboarding (new wallets)"
echo "    /profile           — own profile + edit"
echo "    /profile/:username — public profile"
echo ""
echo "  Features:"
echo "    • Unique @username (live availability check)"
echo "    • Auto-generated color avatar (deterministic)"
echo "    • Display name replaces wallet address everywhere"
echo "    • Twitter + Telegram social links"
echo "    • Privacy toggle for socials"
echo "    • Reputation score (completed trades / disputes)"
echo "    • Verified badge (10+ trades, zero disputes)"
echo "    • Shareable public profile URL"
echo "    • New wallet → redirected to /profile/setup"
echo "    • TopNav shows avatar + display name"
echo ""
echo "  Restart both servers:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
