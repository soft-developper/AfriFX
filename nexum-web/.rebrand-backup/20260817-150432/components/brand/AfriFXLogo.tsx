import Link from 'next/link'

/*
  Nexum brand lockup: the hexagon "A×" mark + a colorful gradient wordmark.
  Used in the app header and the landing page. The gradient gives the name the
  "colorful" treatment while staying on-brand (warm gold -> amber -> bronze).

  Sizes: sm (header), lg (landing hero).
*/
export function AfriFXLogo({
  size = 'sm',
  href = '/',
  showMark = true, // NEXUM: flow-N mark (indigo+cyan)
}: { size?: 'sm' | 'md' | 'lg'; href?: string; showMark?: boolean }) {
  const dims = {
    sm: { mark: 30, text: 'text-xl',  sub: 'text-[9px]' },
    md: { mark: 40, text: 'text-2xl', sub: 'text-[10px]' },
    lg: { mark: 64, text: 'text-5xl sm:text-6xl', sub: 'text-xs' },
  }[size]

  const inner = (
    <span className="inline-flex items-center gap-2.5">
      {showMark && (
        <svg width={dims.mark} height={dims.mark} viewBox="0 0 120 120" fill="none" className="shrink-0">
          <defs>
            <linearGradient id="nx-mark-g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stopColor="#5FE3EC" />
              <stop offset="1" stopColor="#2E8CE0" />
            </linearGradient>
          </defs>
          <path d="M34 92 L34 30 L86 92 L86 30" fill="none" stroke="url(#nx-mark-g)" strokeWidth="11" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      )}
      <span className="flex flex-col leading-none">
        <span className={`font-extrabold tracking-tight ${dims.text}`}>
          <span className="nx-gradient-text">Nex</span><span className="nx-gradient-text-bright">um</span>
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
