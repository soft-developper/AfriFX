#!/bin/bash
# Run from ~/AfriFX:  bash fix-hydration-create.sh
set -e
echo "🔧  Fixing hydration errors..."

# ============================================================
# FIX 1 — App layout: convert to server component
# The useAccount/useProfile hooks caused SSR mismatch.
# Move the profile guard into a separate client component.
# ============================================================
cat > "afrifx-web/app/(app)/layout.tsx" << '__EOF__'
import { TopNav }      from '@/components/layout/TopNav'
import { Sidebar }     from '@/components/layout/Sidebar'
import { TickerStrip } from '@/components/layout/TickerStrip'
import { ProfileGuard } from '@/components/profile/ProfileGuard'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <TickerStrip />
      <TopNav />
      <div className="flex flex-1 overflow-hidden">
        <Sidebar />
        <main className="flex-1 overflow-y-auto p-6">
          <ProfileGuard>{children}</ProfileGuard>
        </main>
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/layout.tsx — server component, guard extracted"

# ============================================================
# FIX 2 — ProfileGuard: client component that handles redirect
# ============================================================
cat > afrifx-web/components/profile/ProfileGuard.tsx << '__EOF__'
'use client'
import { useEffect } from 'react'
import { useAccount } from 'wagmi'
import { useRouter } from 'next/navigation'
import { useProfile } from '@/hooks/useProfile'

export function ProfileGuard({ children }: { children: React.ReactNode }) {
  const { isConnected, address } = useAccount()
  const { data: profile, isLoading } = useProfile()
  const router = useRouter()

  useEffect(() => {
    if (!isConnected || isLoading) return
    if (address && !profile) {
      router.push('/profile/setup')
    }
  }, [isConnected, isLoading, profile, address, router])

  return <>{children}</>
}
__EOF__
echo "✅  components/profile/ProfileGuard.tsx"

# ============================================================
# FIX 3 — Wrap all wallet-dependent pages in ClientOnly
# This stops Next.js from trying to SSR wallet state
# ============================================================

# Marketplace create page
cat > "afrifx-web/app/(app)/marketplace/create/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { CreateOfferClient } from './CreateOfferClient'

export default function CreateOfferPage() {
  return (
    <ClientOnly fallback={
      <div className="w-full max-w-md space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-10 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-40 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <CreateOfferClient />
    </ClientOnly>
  )
}
__EOF__
echo "✅  marketplace/create/page.tsx — server shell"

# Move the actual form to CreateOfferClient.tsx
cat > "afrifx-web/app/(app)/marketplace/create/CreateOfferClient.tsx" << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES      = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}
const TIMER_OPTIONS = [
  { label: '30 min',  value: 1800 },
  { label: '1 hour',  value: 3600 },
  { label: '2 hours', value: 7200 },
  { label: 'Custom',  value: 0    },
]

export function CreateOfferClient() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,     setOrderType]     = useState<OrderType>('market')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [limitOffset,   setLimitOffset]   = useState(0)
  const [timerOption,   setTimerOption]   = useState(1800)
  const [customTimer,   setCustomTimer]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
    } catch {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-[#64748B]">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Create P2P offer</h1>
          <p className="text-sm text-[#64748B]">Lock USDC in escrow — perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-1">
          <button onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market' ? 'bg-[#378ADD] text-white' : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit' ? 'bg-[#378ADD] text-white' : 'text-[#64748B] hover:text-[#E2E8F0]'}`}>
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Description */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-3 text-xs text-[#64748B]">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#378ADD]" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate.'}
          </div>
        </div>

        {/* USDC + currency */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-[#64748B]">
              Balance: <span className="text-[#E2E8F0]">{balance}</span>
            </span>
          </div>
          <div className="flex gap-2">
            <select value={localCurrency} onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] outline-none">
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input type="number" placeholder="0.00" value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className="flex-1 font-mono text-lg" />
          </div>
        </div>

        {/* Rate display + limit slider */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-[#64748B]">Live market rate</span>
              <span className="font-mono text-[#E2E8F0]">1 USDC = {marketRate.toLocaleString()} {localCurrency}</span>
            </div>
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-[#64748B]">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-[#E2E8F0]'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input type="range" min="-5" max="5" step="0.5" value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-[#378ADD]" />
                <div className="mt-1 flex justify-between text-[10px] text-[#64748B]">
                  <span>-5%</span><span>Market</span><span>+5%</span>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated receive */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-[#64748B]">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-[#E2E8F0]">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-[#64748B]">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Timer */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              Taker completion window
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            {TIMER_OPTIONS.map((opt) => (
              <button key={opt.value} onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-[#378ADD] text-white'
                    : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}>
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input type="number" placeholder="Minutes (min 5, max 1440)"
                value={customTimer} onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono" />
              <span className="text-xs text-[#64748B]">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-[#64748B]">
            If taker doesn't send {localCurrency} within this window, the offer automatically cancels and USDC returns to you.
          </p>
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs">
            <p className="mb-2 font-medium text-[#E2E8F0]">Order summary</p>
            <div className="space-y-1.5 text-[#64748B]">
              {[
                ['Order type', orderType],
                ['You lock',   `${usdcAmount} USDC`],
                ['You receive', `${localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${localCurrency}`],
                ['Taker window', timerSeconds >= 3600 ? `${timerSeconds/3600}h` : `${timerSeconds/60}min`],
                ['Duration',    'Perpetual until filled or cancelled'],
                ['Platform fee', `${(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)`],
              ].map(([label, val]) => (
                <div key={label} className="flex justify-between">
                  <span>{label}</span>
                  <span className="text-[#E2E8F0]">{val}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Trade flow reminder */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-3 text-xs text-[#64748B]">
          <p className="mb-1 font-medium text-[#E2E8F0]">Trade flow</p>
          <ol className="space-y-0.5">
            {[
              'You lock USDC in vault escrow',
              `Taker accepts + sends ${localCurrency} to you within the window`,
              'Taker confirms: "I sent the money"',
              'You confirm: "I received it"',
              'Platform releases USDC to taker',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-[#378ADD]">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button className="w-full" size="lg" onClick={handleCreate}
            disabled={
              isLoading || !usdcAmount || localAmount <= 0 || timerSeconds < 300 ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }>
            {isLoading
              ? 'Locking USDC in escrow…'
              : `Create ${orderType} order — ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  CreateOfferClient.tsx — client form extracted"

# Also wrap profile setup in ClientOnly
cat > "afrifx-web/app/(auth)/profile/setup/page.tsx" << '__EOF__'
import { ClientOnly } from '@/components/ui/client-only'
import { ProfileSetupClient } from './ProfileSetupClient'

export default function ProfileSetupPage() {
  return (
    <ClientOnly fallback={
      <div className="flex min-h-screen items-center justify-center">
        <div className="w-full max-w-sm space-y-4">
          <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        </div>
      </div>
    }>
      <ProfileSetupClient />
    </ClientOnly>
  )
}
__EOF__
echo "✅  profile/setup/page.tsx — server shell"

# Move setup form to ProfileSetupClient
# (reuse existing logic from the previous setup page)
cat > "afrifx-web/app/(auth)/profile/setup/ProfileSetupClient.tsx" << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
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
  Loader2, Sparkles, Twitter, AtSign,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ProfileSetupClient() {
  const { address, isConnected } = useAccount()
  const router      = useRouter()
  const queryClient = useQueryClient()

  const [username,    setUsername]    = useState('')
  const [displayName, setDisplayName] = useState('')
  const [bio,         setBio]         = useState('')
  const [twitter,     setTwitter]     = useState('')
  const [telegram,    setTelegram]    = useState('')
  const [showSocials, setShowSocials] = useState(true)
  const [step,        setStep]        = useState(1)

  const [usernameState, setUsernameState] = useState<'idle'|'checking'|'available'|'taken'|'invalid'>('idle')
  const [usernameError, setUsernameError] = useState('')
  const [submitting,    setSubmitting]    = useState(false)
  const [submitError,   setSubmitError]   = useState('')

  const avatarColor = username ? getAvatarColor(username) : '#378ADD'

  useEffect(() => {
    if (!username) { setUsernameState('idle'); return }
    if (username.length < 3)  { setUsernameState('invalid'); setUsernameError('Min 3 characters'); return }
    if (username.length > 20) { setUsernameState('invalid'); setUsernameError('Max 20 characters'); return }
    if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      setUsernameState('invalid'); setUsernameError('Letters, numbers, underscores only'); return
    }
    setUsernameState('checking')
    const t = setTimeout(async () => {
      const result = await checkUsername(username)
      if (result.error) { setUsernameState('invalid'); setUsernameError(result.error) }
      else if (result.available) { setUsernameState('available'); setUsernameError('') }
      else { setUsernameState('taken'); setUsernameError('This username is taken') }
    }, 500)
    return () => clearTimeout(t)
  }, [username])

  async function handleSubmit() {
    if (!address || usernameState !== 'available' || !displayName.trim()) return
    setSubmitting(true); setSubmitError('')
    try {
      const res = await fetch(`${API}/profile`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          walletAddress: address, username, displayName: displayName.trim(),
          bio: bio.trim() || null,
          twitterHandle: twitter.trim() || null,
          telegramHandle: telegram.trim() || null,
          showSocials,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setSubmitError(data.error ?? 'Failed'); return }
      await queryClient.invalidateQueries({ queryKey: ['profile', address] })
      setStep(3)
    } catch (e: any) { setSubmitError(e.message) }
    finally { setSubmitting(false) }
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
      <div className="mb-8 flex items-center gap-2">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-[#378ADD]/20">
          <ArrowLeftRight className="h-5 w-5 text-[#378ADD]" />
        </div>
        <span className="text-xl font-semibold text-[#E2E8F0]">AfriFX</span>
      </div>

      {step === 3 && (
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex justify-center">
            <ProfileAvatar displayName={displayName} avatarColor={avatarColor} size="xl" />
          </div>
          <h1 className="mb-2 text-2xl font-semibold text-[#E2E8F0]">Welcome, {displayName}!</h1>
          <p className="mb-2 text-sm text-[#64748B]">Your profile <span className="text-[#378ADD]">@{username}</span> is ready.</p>
          <p className="mb-8 text-xs text-[#64748B]">You can update your profile anytime from the sidebar.</p>
          <Button className="w-full" size="lg" onClick={() => router.push('/convert')}>
            <Sparkles className="h-4 w-4" /> Enter AfriFX
          </Button>
        </div>
      )}

      {step < 3 && (
        <div className="w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-2xl font-semibold text-[#E2E8F0]">Create your profile</h1>
            <p className="mt-1 text-sm text-[#64748B]">Your identity on AfriFX. Username is permanent.</p>
          </div>

          {/* Step indicators */}
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

          {step === 1 && (
            <div className="space-y-4">
              {/* Avatar preview */}
              <div className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
                <ProfileAvatar displayName={displayName || username || 'A'} avatarColor={avatarColor} size="lg" />
                <div>
                  <p className="text-sm font-medium text-[#E2E8F0]">{displayName || 'Your name'}</p>
                  <p className="text-xs text-[#64748B]">{username ? `@${username}` : '@username'}</p>
                </div>
              </div>

              {/* Username */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Username <span className="text-red-400">*</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input value={username}
                    onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g,''))}
                    placeholder="yourname" className="pl-7 font-mono" maxLength={20} />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2">
                    {usernameState === 'checking'  && <Loader2  className="h-4 w-4 animate-spin text-[#64748B]" />}
                    {usernameState === 'available' && <CheckCircle className="h-4 w-4 text-emerald-400" />}
                    {(usernameState === 'taken' || usernameState === 'invalid') && <XCircle className="h-4 w-4 text-red-400" />}
                  </span>
                </div>
                {usernameState === 'available' && <p className="mt-1 text-xs text-emerald-400">@{username} is available!</p>}
                {usernameError && <p className="mt-1 text-xs text-red-400">{usernameError}</p>}
                <p className="mt-1 text-[10px] text-[#64748B]">3–20 chars · letters, numbers, underscores · permanent</p>
              </div>

              {/* Display name */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Display name <span className="text-red-400">*</span>
                </label>
                <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="Your full name" maxLength={40} />
                <p className="mt-1 text-[10px] text-[#64748B]">Shown instead of your wallet address everywhere</p>
              </div>

              {/* Bio */}
              <div>
                <label className="mb-1.5 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  Bio <span className="font-normal normal-case text-[#64748B]">(optional)</span>
                </label>
                <textarea value={bio} onChange={(e) => setBio(e.target.value)}
                  placeholder="Tell others about yourself…" maxLength={160} rows={3}
                  className="w-full rounded-md border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] placeholder:text-[#64748B] focus:outline-none focus:ring-1 focus:ring-[#378ADD] resize-none" />
                <p className="mt-1 text-right text-[10px] text-[#64748B]">{bio.length}/160</p>
              </div>

              <Button className="w-full" size="lg" onClick={() => setStep(2)}
                disabled={usernameState !== 'available' || !displayName.trim()}>
                Next — Add socials
              </Button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <p className="text-xs text-[#64748B]">Connect your socials so traders can verify and trust you. All optional.</p>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  <Twitter className="h-3.5 w-3.5" /> Twitter / X
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input value={twitter} onChange={(e) => setTwitter(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div>
                <label className="mb-1.5 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-[#64748B]">
                  <AtSign className="h-3.5 w-3.5" /> Telegram
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-[#64748B]">@</span>
                  <Input value={telegram} onChange={(e) => setTelegram(e.target.value.replace('@',''))}
                    placeholder="yourhandle" className="pl-7" />
                </div>
              </div>

              <div className="flex items-center justify-between rounded-lg border border-[#1B2B4B] bg-[#0F1729] p-3">
                <div>
                  <p className="text-sm font-medium text-[#E2E8F0]">Show socials publicly</p>
                  <p className="text-xs text-[#64748B]">Others can see your Twitter and Telegram</p>
                </div>
                <button onClick={() => setShowSocials(!showSocials)}
                  className={`relative h-6 w-11 rounded-full transition-colors ${showSocials ? 'bg-[#378ADD]' : 'bg-[#1B2B4B]'}`}>
                  <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${showSocials ? 'translate-x-5' : 'translate-x-0.5'}`} />
                </button>
              </div>

              {submitError && <p className="text-xs text-red-400">{submitError}</p>}

              <div className="flex gap-2">
                <Button variant="outline" className="flex-1" onClick={() => setStep(1)}>Back</Button>
                <Button className="flex-1" size="lg" onClick={handleSubmit} disabled={submitting}>
                  {submitting ? <><Loader2 className="h-4 w-4 animate-spin" /> Creating…</> : 'Create profile'}
                </Button>
              </div>
              <button onClick={handleSubmit} disabled={submitting}
                className="w-full text-xs text-[#64748B] hover:text-[#E2E8F0] transition-colors">
                Skip socials →
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  ProfileSetupClient.tsx — client form extracted"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Hydration fixes applied!"
echo ""
echo "  What was fixed:"
echo "  • app/(app)/layout.tsx → server component"
echo "    Profile redirect moved to ProfileGuard client component"
echo "  • marketplace/create/page.tsx → server shell"
echo "    Form logic moved to CreateOfferClient.tsx"
echo "  • profile/setup/page.tsx → server shell"  
echo "    Form logic moved to ProfileSetupClient.tsx"
echo ""
echo "  Pattern: server shell (no wallet hooks) wraps"
echo "  ClientOnly → client component (can use wallet hooks)"
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
