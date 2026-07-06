import Link from 'next/link'

/*
  AfriFX brand lockup: the hexagon "A×" mark + a colorful gradient wordmark.
  Used in the app header and the landing page. The gradient gives the name the
  "colorful" treatment while staying on-brand (warm gold -> amber -> bronze).

  Sizes: sm (header), lg (landing hero).
*/
export function AfriFXLogo({
  size = 'sm',
  href = '/',
  showMark = true,
}: { size?: 'sm' | 'md' | 'lg'; href?: string; showMark?: boolean }) {
  const dims = {
    sm: { mark: 30, text: 'text-xl',  sub: 'text-[9px]' },
    md: { mark: 40, text: 'text-2xl', sub: 'text-[10px]' },
    lg: { mark: 64, text: 'text-5xl sm:text-6xl', sub: 'text-xs' },
  }[size]

  const inner = (
    <span className="inline-flex items-center gap-2.5">
      {showMark && (
        <svg width={dims.mark} height={dims.mark} viewBox="0 0 120 124" fill="none" className="shrink-0">
          <defs>
            <linearGradient id="afx-mark-g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stopColor="#EAC15C" />
              <stop offset="1" stopColor="#B9822A" />
            </linearGradient>
          </defs>
          <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="url(#afx-mark-g)" strokeWidth="7" strokeLinejoin="round" />
          <g fill="none" stroke="currentColor" strokeWidth="8" strokeLinecap="round" strokeLinejoin="round" className="text-app-text">
            <path d="M36 88 L52 40 L68 88" /><path d="M43 70 L61 70" />
          </g>
          <g fill="none" stroke="url(#afx-mark-g)" strokeWidth="8" strokeLinecap="round">
            <path d="M74 52 L96 84" /><path d="M96 52 L74 84" />
          </g>
        </svg>
      )}
      <span className="flex flex-col leading-none">
        <span className={`font-extrabold tracking-tight ${dims.text}`}>
          <span className="afx-gradient-text">Afri</span>
          <span className="afx-gradient-text-bright">FX</span>
        </span>
        {size === 'lg' && (
          <span className={`mt-1 font-medium uppercase tracking-[0.2em] text-app-muted ${dims.sub}`}>
            Stablecoin FX on Arc
          </span>
        )}
      </span>
    </span>
  )

  if (href) return <Link href={href} className="inline-flex">{inner}</Link>
  return inner
}
