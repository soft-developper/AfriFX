'use client'
import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ShieldOff, LogOut } from 'lucide-react'

export default function NoAccessPage() {
  const router = useRouter()
  const [username, setUsername] = useState('')

  useEffect(() => {
    // Verify they are actually logged in as an admin
    const token     = sessionStorage.getItem('admin_token')
    const adminRaw  = sessionStorage.getItem('admin')
    if (!token || !adminRaw) {
      router.replace('/admin')
      return
    }
    try {
      const admin = JSON.parse(adminRaw)
      setUsername(admin.username ?? '')
    } catch {}
  }, [router])

  function handleLogout() {
    sessionStorage.removeItem('admin_token')
    sessionStorage.removeItem('admin')
    router.replace('/admin')
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-[#080D1B] px-4">
      <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-8 text-center">
        {/* Icon */}
        <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-amber-900/20 border border-amber-900/40">
          <ShieldOff className="h-8 w-8 text-amber-400" />
        </div>

        {/* Message */}
        <h1 className="mb-2 text-lg font-semibold text-[#E2E8F0]">
          No permissions assigned
        </h1>
        {username && (
          <p className="mb-1 text-sm text-[#378ADD]">@{username}</p>
        )}
        <p className="mb-6 text-sm text-[#64748B]">
          Your admin account has been created but no permissions have been
          assigned yet. Please contact the super admin to grant you access
          to the relevant sections.
        </p>

        {/* Info box */}
        <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#080D1B] p-4 text-left text-xs text-[#64748B] space-y-1.5">
          <p className="font-medium text-[#E2E8F0]">What the super admin needs to do:</p>
          <p>1. Go to Admin panel → Sub-admins</p>
          <p>2. Find your account</p>
          <p>3. Edit permissions and assign the required access</p>
          <p>4. You can then log in and access your permitted sections</p>
        </div>

        {/* Logout */}
        <button
          onClick={handleLogout}
          className="flex w-full items-center justify-center gap-2 rounded-xl border border-[#1B2B4B] px-4 py-2.5 text-sm text-[#64748B] hover:bg-[#080D1B] hover:text-red-400 transition-colors">
          <LogOut className="h-4 w-4" />
          Sign out
        </button>
      </div>
    </div>
  )
}
