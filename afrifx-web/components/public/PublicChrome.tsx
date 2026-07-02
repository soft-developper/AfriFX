import Link from 'next/link'
import { ArrowLeftRight } from 'lucide-react'

export function PublicHeader({ active }: { active?: 'about' | 'contact' }) {
  return (
    <header className="border-b border-app-border bg-app-surface">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <Link href="/" className="flex items-center gap-2">
          <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-app-accent/20">
            <ArrowLeftRight className="h-4 w-4 text-app-accent-text" />
          </span>
          <span className="text-lg font-semibold text-app-text">AfriFX</span>
        </Link>
        <nav className="flex items-center gap-4 text-sm sm:gap-5">
          <Link href="/about"
            className={active === 'about' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            About
          </Link>
          <Link href="/contact"
            className={active === 'contact' ? 'text-app-text' : 'text-app-muted hover:text-app-accent-text'}>
            Contact
          </Link>
          <Link href="/convert"
            className="rounded-lg bg-app-accent px-3 py-1.5 font-medium text-app-on-accent hover:bg-app-accent-hover">
            Launch app
          </Link>
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
          <Link href="/about" className="hover:text-app-text">About</Link>
          <Link href="/contact" className="hover:text-app-text">Contact</Link>
        </div>
      </div>
    </footer>
  )
}
