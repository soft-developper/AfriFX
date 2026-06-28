'use client'
import Link              from 'next/link'
import { ArrowLeftRight, Zap } from 'lucide-react'
import { ConnectButton }  from '@rainbow-me/rainbowkit'
import { useAccount }     from 'wagmi'
import { useProfile }     from '@/hooks/useProfile'
import { ProfileAvatar }  from '@/components/profile/ProfileAvatar'
import { ClientOnly }     from '@/components/ui/client-only'

// Custom ConnectButton that shows our profile avatar when connected
function NavProfile() {
  const { isConnected }   = useAccount()
  const { data: profile } = useProfile()

  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        mounted,
      }) => {
        const ready = mounted
        if (!ready) return (
          <div className="h-8 w-24 animate-pulse rounded-full bg-[#1B2B4B]" />
        )

        if (!account) {
          return (
            <button onClick={openConnectModal}
              className="rounded-xl bg-[#378ADD] px-4 py-2 text-sm font-medium text-white transition-opacity hover:opacity-90">
              Connect wallet
            </button>
          )
        }

        if (chain?.unsupported) {
          return (
            <button onClick={openChainModal}
              className="rounded-xl bg-red-500/20 px-4 py-2 text-sm font-medium text-red-400 transition-opacity hover:opacity-90">
              Wrong network
            </button>
          )
        }

        return (
          <div className="flex items-center gap-2">
            {/* Profile avatar → opens RainbowKit account modal (has copy address) */}
            <button onClick={openAccountModal}
              className="flex items-center gap-2 rounded-xl border border-[#1B2B4B] bg-[#0F1729] px-2.5 py-1.5 transition-colors hover:bg-[#1B2B4B]">
              {profile ? (
                <>
                  <ProfileAvatar
                    displayName={profile.display_name}
                    avatarColor={profile.avatar_color}
                    size="xs"
                    verified={profile.verified}
                  />
                  <div className="hidden sm:block text-left">
                    <p className="text-xs font-medium text-[#E2E8F0] leading-none">
                      {profile.display_name}
                    </p>
                    <p className="text-[10px] text-[#378ADD] leading-none mt-0.5">
                      @{profile.username}
                    </p>
                  </div>
                </>
              ) : (
                <>
                  {/* No profile yet — show shortened address */}
                  <div className="h-5 w-5 rounded-full bg-[#378ADD]/30 flex items-center justify-center">
                    <span className="text-[8px] font-bold text-[#378ADD]">
                      {account.address.slice(2,4).toUpperCase()}
                    </span>
                  </div>
                  <span className="hidden sm:block font-mono text-xs text-[#E2E8F0]">
                    {account.displayName}
                  </span>
                </>
              )}
              {/* Balance badge */}
              {account.displayBalance && (
                <span className="hidden md:block rounded-lg bg-[#1B2B4B] px-2 py-0.5 font-mono text-[10px] text-[#64748B]">
                  {account.displayBalance}
                </span>
              )}
            </button>
          </div>
        )
      }}
    </ConnectButton.Custom>
  )
}

export function TopNav() {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-[#1B2B4B] px-4 md:px-6">
      <Link href="/convert"
        className="flex items-center gap-2 text-[#E2E8F0] font-semibold">
        <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-[#378ADD]/20">
          <ArrowLeftRight className="h-4 w-4 text-[#378ADD]" />
        </div>
        <span className="text-sm md:text-base">AfriFX</span>
        <span className="hidden sm:inline-flex items-center gap-1 rounded-full bg-[#378ADD]/10 px-2 py-0.5 text-[10px] font-medium text-[#378ADD]">
          <Zap className="h-2.5 w-2.5" /> Arc Testnet
        </span>
      </Link>

      <ClientOnly fallback={
        <div className="h-8 w-28 animate-pulse rounded-xl bg-[#1B2B4B]" />
      }>
        <NavProfile />
      </ClientOnly>
    </header>
  )
}
