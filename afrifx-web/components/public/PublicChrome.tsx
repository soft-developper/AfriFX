import Link from 'next/link'
import { ArrowUpRight } from 'lucide-react'
import { AfriFXLogo } from '@/components/brand/AfriFXLogo'

export function PublicHeader({ active }: { active?: 'about' | 'contact' }) {
  return (
    <header className="border-b border-app-border bg-app-surface">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <AfriFXLogo size="sm" href="/" />
        <nav className="flex items-center gap-4 text-sm sm:gap-5">
          <Link href="/about"
            className={active === 'about' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            About
          </Link>
          <Link href="/contact"
            className={active === 'contact' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            Contact
          </Link>
          <a href="/dashboard" target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 font-medium text-app-on-accent hover:bg-app-accent-hover">
            Launch app <ArrowUpRight className="h-3.5 w-3.5" />
          </a>
        </nav>
      </div>
    </header>
  )
}

export function PublicFooter() {
  return (
    <footer className="border-t border-app-border">
      <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-3 px-4 py-6 text-xs text-app-muted sm:flex-row">
        <span>© {new Date().getFullYear()} AfriFX. Stablecoin FX on Arc.</span>
        <div className="flex gap-4">
          <Link href="/" className="hover:text-app-text">Home</Link>
          <Link href="/about" className="hover:text-app-text">About</Link>
          <Link href="/contact" className="hover:text-app-text">Contact</Link>
        </div>
      </div>
    </footer>
  )
}
