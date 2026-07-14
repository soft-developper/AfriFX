'use client'
import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ShieldOff, LogOut } from 'lucide-react'
import { TOKEN_KEY, ADMIN_KEY } from '@/hooks/useAdminAuth'

// IMPORTANT: This page does NOT use AdminShell
// to avoid infinite redirect loops for sub-admins with no permissions

export default function NoAccessPage() {
  const router             = useRouter()
  const [username, setUsername] = useState('')
  const [checked,  setChecked]  = useState(false)

  useEffect(() => {
    // One-time check do not loop
    const token    = sessionStorage.getItem(TOKEN_KEY)
    const adminRaw = sessionStorage.getItem(ADMIN_KEY)
    if (!token || !adminRaw) {
      router.replace('/admin')
      return
    }
    try {
      const admin = JSON.parse(adminRaw)
      setUsername(admin.username ?? '')
    } catch {}
    setChecked(true)
  }, []) // Empty deps, run once only, no loop

  function handleLogout() {
    sessionStorage.removeItem(TOKEN_KEY)
    sessionStorage.removeItem(ADMIN_KEY)
    router.replace('/admin')
  }

  if (!checked) return null

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-app-bg px-4">
      <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-8 text-center">
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-amber-900/20 border border-amber-900/40">
          <ShieldOff className="h-8 w-8 text-amber-400" />
        </div>
        <h1 className="mb-2 text-lg font-semibold text-app-text">
          No permissions assigned
        </h1>
        {username && (
          <p className="mb-1 text-sm text-app-accent-text">@{username}</p>
        )}
        <p className="mb-6 text-sm text-app-muted">
          Your admin account has been created but no permissions have been
          assigned yet. Please contact the super admin to grant you access
          to the relevant sections.
        </p>
        <div className="mb-6 rounded-xl border border-app-border bg-app-bg p-4 text-left text-xs text-app-muted space-y-1.5">
          <p className="font-medium text-app-text">What the super admin needs to do:</p>
          <p>1. Go to Admin panel → Sub-admins</p>
          <p>2. Find your account and click Edit</p>
          <p>3. Assign the required permissions</p>
          <p>4. You can then log back in</p>
        </div>
        <button onClick={handleLogout}
          className="flex w-full items-center justify-center gap-2 rounded-xl border border-app-border px-4 py-2.5 text-sm text-app-muted hover:bg-app-bg hover:text-red-400 transition-colors">
          <LogOut className="h-4 w-4" />
          Sign out
        </button>
      </div>
    </div>
  )
}
