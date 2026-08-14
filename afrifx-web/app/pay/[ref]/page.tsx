'use client'
// PUBLIC invoice pay page — no auth, no Sidebar, no ProfileGuard.
// Anyone with the link (or who scans the QR) can connect their own wallet and pay.
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { InvoicePayInner } from '@/components/invoice/InvoicePayInner'
import { InvoiceQR } from '@/components/invoice/InvoiceQR'

export default function PublicPayPage() {
  const { ref } = useParams()
  const memoRef = String(ref ?? '')

  return (
    <div className="min-h-screen bg-app-bg">
      {/* Minimal public header — no app navigation */}
      <header className="border-b border-app-border">
        <div className="mx-auto flex max-w-lg items-center justify-between px-4 py-3">
          <Link href="/" className="text-sm font-semibold text-app-text">AfriFX</Link>
          <span className="text-[11px] text-app-muted">Secure invoice payment</span>
        </div>
      </header>

      <main className="mx-auto max-w-lg px-4 py-6">
        <InvoicePayInner />

        {/* Scannable codes for sharing / wallet scanners */}
        <div className="mt-4">
          <InvoiceQR memoRef={memoRef} />
        </div>

        <p className="mt-6 text-center text-[11px] text-app-muted">
          You don’t need an AfriFX account. Connect any wallet holding USDC on Arc to pay.
        </p>
      </main>
    </div>
  )
}
