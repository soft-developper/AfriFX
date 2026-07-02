'use client'
import { useState, useEffect, useRef } from 'react'

const API        = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
export const TOKEN_KEY = 'afrifx_admin_token'
export const ADMIN_KEY = 'afrifx_admin'

export interface AdminSession {
  id:           string
  username:     string
  email:        string
  role:         string
  permissions:  string[]
  totpEnabled:  boolean
}

function persist(token: string, admin: AdminSession) {
  sessionStorage.setItem(TOKEN_KEY, token)
  sessionStorage.setItem(ADMIN_KEY, JSON.stringify(admin))
}

function clearPersisted() {
  sessionStorage.removeItem(TOKEN_KEY)
  sessionStorage.removeItem(ADMIN_KEY)
}

export function useAdminAuth() {
  const [admin,   setAdmin]   = useState<AdminSession | null>(null)
  const [loading, setLoading] = useState(true)
  const fetchedRef            = useRef(false)

  const getToken = () =>
    typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  useEffect(() => {
    if (fetchedRef.current) return
    fetchedRef.current = true
    const token = getToken()
    if (!token) { setLoading(false); return }

    fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(res => { if (res.ok) return res.json(); clearPersisted(); return null })
      .then(data => {
        if (data?.admin) {
          setAdmin(data.admin)
          sessionStorage.setItem(ADMIN_KEY, JSON.stringify(data.admin))
        }
      })
      .catch(() => { clearPersisted() })
      .finally(() => setLoading(false))
  }, [])

  // ── First-time setup ─────────────────────────────────────
  async function checkSetupStatus(): Promise<boolean> {
    const res  = await fetch(`${API}/admin-auth/setup-status`)
    const data = await res.json()
    return data.needsSetup === true
  }

  async function setup(email: string, password: string, username: string) {
    const res  = await fetch(`${API}/admin-auth/setup`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, username }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Setup failed' }

    // Setup doesn't return the admin object — fetch it via /verify
    const meRes = await fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${data.token}` },
    })
    const me = await meRes.json()
    if (meRes.ok && me.admin) {
      persist(data.token, me.admin)
      setAdmin(me.admin)
      return { success: true, admin: me.admin, needsTOTP: !!data.needsTOTP }
    }
    return { success: true, needsTOTP: !!data.needsTOTP }
  }

  // ── Login ─────────────────────────────────────────────────
  async function login(email: string, password: string, totpCode?: string) {
    const res  = await fetch(`${API}/admin-auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, totpCode }),
    })
    const data = await res.json()

    if (!res.ok) return { success: false, error: data.error ?? 'Login failed' }
    if (data.needs2FA) return { success: false, needs2FA: true }

    if (data.token && data.admin) {
      persist(data.token, data.admin)
      setAdmin(data.admin)
      return { success: true, admin: data.admin as AdminSession }
    }
    return { success: false, error: 'Unexpected response from server' }
  }

  async function logout() {
    const token = getToken()
    if (token) {
      await fetch(`${API}/admin-auth/logout`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    clearPersisted()
    fetchedRef.current = false
    setAdmin(null)
  }

  // ── Password reset ───────────────────────────────────────
  async function forgotPassword(email: string) {
    const res  = await fetch(`${API}/admin-auth/forgot-password`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Request failed' }
  }

  async function resetPassword(token: string, password: string) {
    const res  = await fetch(`${API}/admin-auth/reset-password`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, password }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Reset failed' }
  }

  // ── Invitations ───────────────────────────────────────────
  async function invite(email: string, permissions: string[]) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/invite`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ email, permissions }),
    })
    const data = await res.json()
    return res.ok ? { success: true, message: data.message } : { success: false, error: data.error ?? 'Invite failed' }
  }

  async function acceptInvite(token: string, username: string, password: string) {
    const res  = await fetch(`${API}/admin-auth/accept-invite`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, username, password }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Invitation failed' }

    const meRes = await fetch(`${API}/admin-auth/verify`, {
      headers: { Authorization: `Bearer ${data.token}` },
    })
    const me = await meRes.json()
    if (meRes.ok && me.admin) {
      persist(data.token, me.admin)
      setAdmin(me.admin)
    }
    return { success: true }
  }

  // ── Password / 2FA management ────────────────────────────
  async function changePassword(currentPassword: string, newPassword: string) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/change-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ currentPassword, newPassword }),
    })
    const data = await res.json()
    return res.ok ? { success: true } : { success: false, error: data.error ?? 'Change failed' }
  }

  async function setup2FA() {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/2fa/setup`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}` },
    })
    const data = await res.json()
    return res.ok
      ? { success: true, secret: data.secret as string, qrCode: data.qrCode as string }
      : { success: false, error: data.error ?? '2FA setup failed' }
  }

  async function verify2FA(code: string) {
    const token = getToken()
    const res   = await fetch(`${API}/admin-auth/2fa/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ code }),
    })
    const data = await res.json()
    if (!res.ok) return { success: false, error: data.error ?? 'Verification failed' }
    // Reflect the now-enabled 2FA flag locally
    setAdmin(prev => {
      if (!prev) return prev
      const next = { ...prev, totpEnabled: true }
      sessionStorage.setItem(ADMIN_KEY, JSON.stringify(next))
      return next
    })
    return { success: true, recoveryCodes: data.recoveryCodes as string[] }
  }

  function hasPermission(perm: string): boolean {
    if (!admin) return false
    if (admin.role === 'super_admin') return true
    return admin.permissions.includes(perm)
  }

  return {
    admin, loading, getToken,
    checkSetupStatus, setup, login, logout,
    forgotPassword, resetPassword,
    invite, acceptInvite,
    changePassword, setup2FA, verify2FA,
    hasPermission,
  }
}

export function adminFetch(path: string, options: RequestInit = {}) {
  const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
  return fetch(`${API}${path}`, {
    ...options,
    headers: { ...options.headers, 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  })
}
