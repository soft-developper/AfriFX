import type { Metadata, Viewport } from 'next'
import { Providers } from './providers'
import '@/styles/globals.css'

export const metadata: Metadata = {
  title: 'AfriFX — Stablecoin FX on Arc',
  description: 'Instant stablecoin foreign exchange and cross-border payments for Africa, powered by Arc.',
  icons: {
    icon:     [{ url: '/favicon.svg', type: 'image/svg+xml' }],
    shortcut: '/favicon.svg',
    apple:    '/favicon.svg',
  },
  manifest: '/manifest.json',
}

export const viewport: Viewport = {
  themeColor: '#12100B',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className="min-h-screen bg-app-bg text-app-text"
        suppressHydrationWarning
      >
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
