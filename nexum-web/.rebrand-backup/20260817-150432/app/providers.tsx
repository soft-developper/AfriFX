'use client'
import { useEffect }           from 'react'
import { WagmiProvider }       from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RainbowKitProvider, darkTheme, lightTheme } from '@rainbow-me/rainbowkit'
import { wagmiConfig }         from '@/lib/wagmi'
import { ThemeProvider, useTheme } from '@/hooks/useTheme'
import '@rainbow-me/rainbowkit/styles.css'

const queryClient = new QueryClient()

function RainbowKitThemed({ children }: { children: React.ReactNode }) {
  const { theme } = useTheme()
  const rkTheme = theme === 'light'
    ? lightTheme({
        accentColor:           '#8A5E13',
        accentColorForeground: 'white',
        borderRadius:          'large',
        fontStack:             'system',
        overlayBlur:           'small',
      })
    : darkTheme({
        accentColor:           '#D9A441',
        accentColorForeground: '#12100B',
        borderRadius:          'large',
        fontStack:             'system',
        overlayBlur:           'small',
      })
  return (
    <RainbowKitProvider theme={rkTheme} coolMode>
      {children}
    </RainbowKitProvider>
  )
}

/**
 * Global guard: scrolling the mouse wheel over a focused number input
 * silently changes its value in every browser. Across the app that means
 * an amount you typed (e.g. 10 USDC on Send) drifts as you scroll the page.
 * We stop it everywhere at once: when a number input has focus and the
 * wheel fires on it, blur it so the wheel scrolls the page instead. This
 * covers raw <input type="number"> that don't use the shared Input component.
 */
function NumberInputWheelGuard() {
  useEffect(() => {
    const onWheel = (e: WheelEvent) => {
      const el = document.activeElement as HTMLElement | null
      if (
        el &&
        el.tagName === 'INPUT' &&
        (el as HTMLInputElement).type === 'number' &&
        el === e.target
      ) {
        (el as HTMLInputElement).blur()
      }
    }
    // passive:true — we only blur, never preventDefault, so page scroll is smooth.
    document.addEventListener('wheel', onWheel, { passive: true })
    return () => document.removeEventListener('wheel', onWheel)
  }, [])
  return null
}

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider>
          <RainbowKitThemed>
            <NumberInputWheelGuard />
            {children}
          </RainbowKitThemed>
        </ThemeProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
