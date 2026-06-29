'use client'
import { useState, useEffect, useCallback } from 'react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const TOKEN_KEY = 'afrifx_admin_token'

export interface AdminSession {
  id:          string
  username:    string
  email:       string
  role:        string
  permissions: string[]
}

export function useAdminAuth() {
  const [admin,   setAdmin]   = useState<AdminSession | null>(null)
  const [loading, setLoading] = useState(true)

  // Token stored in memory + sessionStorage (cleared on tab close)
  const getToken = () => typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  const verifySession = useCallback(async () => {
    const token = getToken()
    if (!token) { setLoading(false); return }
    try {
      const res = await fetch(`${API}/admin/auth/me`, {
        headers: { Authorization: `Bearer ${token}` },
      })
      if (res.ok) {
        const data = await res.json()
        setAdmin(data.admin)
      } else {
        sessionStorage.removeItem(TOKEN_KEY)
      }
    } catch {
      sessionStorage.removeItem(TOKEN_KEY)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { verifySession() }, [verifySession])

  // Step 1: verify wallet is admin
  async function verifyWallet(wallet: string) {
    const res = await fetch(`${API}/admin/auth/verify-wallet`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ wallet }),
    })
    return res.json()
  }

  // Step 2: login with credentials
  async function login(identifier: string, password: string, wallet?: string) {
    const res = await fetch(`${API}/admin/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier, password, wallet }),
    })
    const data = await res.json()
    if (res.ok && data.token) {
      sessionStorage.setItem(TOKEN_KEY, data.token)
      setAdmin(data.admin)
      return { success: true, admin: data.admin }
    }
    return { success: false, error: data.error ?? 'Login failed' }
  }

  async function logout() {
    const token = getToken()
    if (token) {
      await fetch(`${API}/admin/auth/logout`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    sessionStorage.removeItem(TOKEN_KEY)
    setAdmin(null)
  }

  function hasPermission(perm: string): boolean {
    if (!admin) return false
    if (admin.role === 'super_admin') return true
    return admin.permissions.includes(perm)
  }

  return { admin, loading, verifyWallet, login, logout, hasPermission, getToken }
}

// Authenticated fetch helper
export function adminFetch(path: string, options: RequestInit = {}) {
  const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
  return fetch(`${API}${path}`, {
    ...options,
    headers: {
      ...options.headers,
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
  })
}
