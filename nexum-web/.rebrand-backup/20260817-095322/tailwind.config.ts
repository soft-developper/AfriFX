import type { Config } from 'tailwindcss'
import plugin from 'tailwindcss/plugin'

const config: Config = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        // Semantic tokens driven by CSS variables (see globals.css).
        // Support opacity modifiers via the <alpha-value> placeholder.
        app: {
          bg:            'rgb(var(--app-bg) / <alpha-value>)',
          surface:       'rgb(var(--app-surface) / <alpha-value>)',
          border:        'rgb(var(--app-border) / <alpha-value>)',
          accent:        'rgb(var(--app-accent) / <alpha-value>)',
          'accent-hover':'rgb(var(--app-accent-hover) / <alpha-value>)',
          'accent-text': 'rgb(var(--app-accent-text) / <alpha-value>)',
          'on-accent':   'rgb(var(--app-on-accent) / <alpha-value>)',
          text:          'rgb(var(--app-text) / <alpha-value>)',
          muted:         'rgb(var(--app-muted) / <alpha-value>)',
        },
        arc: {
          bg:      '#080D1B',
          card:    '#0F1729',
          border:  '#1B2B4B',
          accent:  '#378ADD',
          success: '#10B981',
          danger:  '#EF4444',
          muted:   '#64748B',
          text:    '#E2E8F0',
        },
      },
      keyframes: {
        ticker: {
          '0%':   { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(-50%)' },
        },
      },
      animation: {
        ticker: 'ticker 30s linear infinite',
      },
    },
  },
  plugins: [
    // Enables `light:` utilities that apply only when <html class="light">.
    // Mirrors how our theme system toggles the root class (see hooks/useTheme.tsx).
    plugin(({ addVariant }) => {
      addVariant('light', ':is(.light &)')
    }),
  ],
}
export default config
