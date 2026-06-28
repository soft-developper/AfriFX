#!/bin/bash
# ============================================================
# AfriFX — RainbowKit v2 Integration
# Run from ~/AfriFX:  bash rainbowkit-integration.sh
# ============================================================
set -e
echo ""
echo "🌈  Integrating RainbowKit v2..."
echo ""

cd afrifx-web

# ============================================================
# 1 — Install packages
# ============================================================
echo "  Installing RainbowKit..."
npm install @rainbow-me/rainbowkit --legacy-peer-deps
echo "✅  RainbowKit installed"

# ============================================================
# 2 — Update wagmi config to use RainbowKit's getDefaultConfig
# ============================================================
cat > lib/wagmi.ts << '__EOF__'
import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { arcTestnet } from './arc-chain'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo'

export const wagmiConfig = getDefaultConfig({
  appName:     'AfriFX',
  appIcon:     'https://afrifx.app/icon.png',
  projectId,
  chains:      [arcTestnet],
  transports:  { [arcTestnet.id]: http(arcTestnet.rpcUrls.default.http[0]) },
  ssr:         true,
})
__EOF__
echo "✅  lib/wagmi.ts — RainbowKit getDefaultConfig"

# ============================================================
# 3 — Update root providers to include RainbowKitProvider
# ============================================================
cat > app/providers.tsx << '__EOF__'
'use client'
import { WagmiProvider }       from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RainbowKitProvider, darkTheme }   from '@rainbow-me/rainbowkit'
import { wagmiConfig }         from '@/lib/wagmi'
import '@rainbow-me/rainbowkit/styles.css'

const queryClient = new QueryClient()

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={darkTheme({
            accentColor:          '#378ADD',
            accentColorForeground: 'white',
            borderRadius:         'large',
            fontStack:            'system',
            overlayBlur:          'small',
          })}
          coolMode
        >
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
__EOF__
echo "✅  app/providers.tsx — RainbowKitProvider added"

# ============================================================
# 4 — Update TopNav to use RainbowKit ConnectButton
# ============================================================
cat > components/layout/TopNav.tsx << '__EOF__'
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
__EOF__
echo "✅  TopNav — RainbowKit ConnectButton.Custom"

# ============================================================
# 5 — Remove old ConnectButton component (no longer needed)
#     Replace with a thin wrapper for any pages still using it
# ============================================================
cat > components/wallet/ConnectButton.tsx << '__EOF__'
'use client'
// Thin wrapper — kept for backwards compatibility
// TopNav now uses RainbowKit ConnectButton.Custom directly
import { useConnectModal } from '@rainbow-me/rainbowkit'

export function ConnectButton({ label = 'Connect wallet' }: { label?: string }) {
  const { openConnectModal } = useConnectModal()
  return (
    <button
      onClick={openConnectModal}
      className="rounded-xl bg-[#378ADD] px-4 py-2 text-sm font-medium text-white transition-opacity hover:opacity-90">
      {label}
    </button>
  )
}
__EOF__
echo "✅  components/wallet/ConnectButton.tsx — RainbowKit wrapper"

# ============================================================
# 6 — Add .env.local entry reminder
# ============================================================
if ! grep -q "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID" .env.local 2>/dev/null; then
  echo "" >> .env.local
  echo "# WalletConnect — get free projectId at cloud.walletconnect.com" >> .env.local
  echo "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=demo" >> .env.local
  echo "✅  .env.local — placeholder projectId added"
else
  echo "✅  .env.local — projectId already set"
fi

# ============================================================
# 7 — Add RainbowKit styles to global CSS if not present
# ============================================================
if ! grep -q "rainbowkit" app/globals.css 2>/dev/null; then
  sed -i "1s|^|/* RainbowKit styles imported in providers.tsx */\n|" app/globals.css 2>/dev/null || true
fi

# ============================================================
# 8 — Update admin auth — the wallet verify step reads from
#     useAccount which still works the same with RainbowKit
# ============================================================
echo "✅  Admin auth — useAccount unchanged, works with RainbowKit"

cd ..

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  RainbowKit v2 integration complete!"
echo ""
echo "  What you get now:"
echo "  • 'Connect wallet' button opens RainbowKit modal"
echo "  • Modal lists: MetaMask, Coinbase, Rainbow, Trust,"
echo "    Argent, Ledger + 100 more wallets"
echo "  • WalletConnect QR code for mobile wallet connection"
echo "  • Account modal (click your avatar) has:"
echo "    - Copy wallet address button"
echo "    - USDC balance display"
echo "    - Chain switcher"
echo "    - Disconnect button"
echo "    - Transaction history"
echo "  • Profile avatar + display name still shown in TopNav"
echo "  • Clicking avatar opens the RainbowKit account modal"
echo ""
echo "  ⚠️  IMPORTANT — get your free WalletConnect projectId:"
echo "  1. Go to cloud.walletconnect.com (or reown.com)"
echo "  2. Create a free account + new project"
echo "  3. Copy the projectId"
echo "  4. Open afrifx-web/.env.local"
echo "  5. Replace 'demo' with your actual projectId:"
echo "     NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your_id_here"
echo ""
echo "  Without a real projectId the modal still works for"
echo "  browser extension wallets (MetaMask etc.) but the"
echo "  WalletConnect QR code for mobile won't function."
echo ""
echo "  Restart frontend:  cd afrifx-web && npm run dev"
echo "══════════════════════════════════════════════════════"
