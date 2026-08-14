'use client'
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

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider>
          <RainbowKitThemed>
            {children}
          </RainbowKitThemed>
        </ThemeProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
