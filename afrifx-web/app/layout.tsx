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
  themeColor: [
    { media: '(prefers-color-scheme: dark)',  color: '#12100B' },
    { media: '(prefers-color-scheme: light)', color: '#F7F1E6' },
  ],
}

// Runs before first paint to set the theme class, preventing a flash of the
// wrong theme. Mirrors the logic in hooks/useTheme.tsx (manual pref wins,
// otherwise clock-based: light 06:00–17:59, dark otherwise).
const themeInitScript = `
(function() {
  try {
    var stored = localStorage.getItem('afrifx_theme');
    var theme;
    if (stored === 'light' || stored === 'dark') {
      theme = stored;
    } else {
      var h = new Date().getHours();
      theme = (h >= 6 && h < 18) ? 'light' : 'dark';
    }
    if (theme === 'light') document.documentElement.classList.add('light');
  } catch (e) {}
})();
`

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body
        className="min-h-screen bg-app-bg text-app-text"
        suppressHydrationWarning
      >
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
