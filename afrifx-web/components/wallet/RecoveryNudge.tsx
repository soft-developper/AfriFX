'use client'
import { useState, useEffect } from 'react'
import { useWalletReady } from '@/hooks/useWalletReady'
import { ShieldAlert, X, ExternalLink } from 'lucide-react'

/*
  Embedded (social-login) wallets store a device key share in the browser.
  Without recovery set up, a user who switches devices or clears storage loses
  access to that wallet. For a payments app this is critical, so we nudge
  embedded-wallet users to add a recovery method. Dismissible per browser.
*/
const DISMISS_KEY = 'afrifx_recovery_nudge_dismissed'

export function RecoveryNudge() {
  const { ready, isEmbedded } = useWalletReady()
  const [dismissed, setDismissed] = useState(true)

  useEffect(() => {
    try { setDismissed(localStorage.getItem(DISMISS_KEY) === '1') } catch {}
  }, [])

  if (!ready || !isEmbedded || dismissed) return null

  function dismiss() {
    setDismissed(true)
    try { localStorage.setItem(DISMISS_KEY, '1') } catch {}
  }

  return (
    <div className="mb-4 flex items-start gap-3 rounded-xl border border-app-accent/40 bg-app-accent/10 px-4 py-3">
      <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0 text-app-accent-text" />
      <div className="flex-1 text-sm">
        <p className="font-medium text-app-text">Secure your wallet</p>
        <p className="mt-0.5 text-app-muted">
          You signed in with a social account, which creates a wallet stored on this device.
          Set up account recovery so you can still access your funds from another device or if
          you clear your browser.
        </p>
        <a
          href="https://app.openlogin.com/wallet/recovery"
          target="_blank" rel="noopener noreferrer"
          className="mt-2 inline-flex items-center gap-1.5 text-xs font-medium text-app-accent-text hover:underline"
        >
          Set up recovery <ExternalLink className="h-3 w-3" />
        </a>
      </div>
      <button onClick={dismiss} className="shrink-0 rounded p-1 text-app-muted hover:text-app-text" aria-label="Dismiss">
        <X className="h-4 w-4" />
      </button>
    </div>
  )
}
