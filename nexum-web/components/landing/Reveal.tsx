'use client'
import { useEffect, useRef, useState } from 'react'

/*
  Reveals children with a gentle fade + rise the first time they scroll into
  view. Uses IntersectionObserver (no library), and fully respects
  prefers-reduced-motion, in that case content is shown immediately with no
  transform. `delay` staggers siblings (ms).
*/
export function Reveal({
  children,
  delay = 0,
  className = '',
}: { children: React.ReactNode; delay?: number; className?: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const [shown, setShown] = useState(false)

  useEffect(() => {
    // Respect reduced motion: show at once.
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
    if (reduce) { setShown(true); return }

    const el = ref.current
    if (!el) return
    const obs = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            setShown(true)
            obs.unobserve(e.target)
          }
        })
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
    )
    obs.observe(el)
    return () => obs.disconnect()
  }, [])

  return (
    <div
      ref={ref}
      className={className}
      style={{
        opacity: shown ? 1 : 0,
        transform: shown ? 'none' : 'translateY(16px)',
        transition: 'opacity 0.6s ease, transform 0.6s ease',
        transitionDelay: `${delay}ms`,
      }}
    >
      {children}
    </div>
  )
}
