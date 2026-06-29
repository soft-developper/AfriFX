'use client'
import { useState, useEffect } from 'react'

const API_RAW   = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
// Force HTTPS in production to avoid 307 redirects stripping Authorization header
const API       = typeof window !== 'undefined' && window.location.protocol === 'https:'
  ? API_RAW.replace('http://', 'https://')
  : API_RAW
const TOKEN_KEY = 'afrifx_admin_token'

// Module-level cache — persists across re-renders and component remounts
// Resets only when the page is fully refreshed
let sessionCache: { admin: any; loading: boolean } | null = null
let fetchPromise: Promise<void> | null = null

export interface AdminSession {
  id:          string
  username:    string
  email:       string
  role:        string
  permissions: string[]
}

export function useAdminAuth() {
  const [admin,   setAdmin]   = useState<AdminSession | null>(sessionCache?.admin ?? null)
  const [loading, setLoading] = useState(sessionCache ? false : true)

  const getToken = () =>
    typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  useEffect(() => {
    // Already fetched — use cache
    if (sessionCache !== null) {
      setAdmin(sessionCache.admin)
      setLoading(false)
      return
    }

    // Fetch in progress — wait for it
    if (fetchPromise !== null) {
      fetchPromise.then(() => {
        if (sessionCache) {
          setAdmin(sessionCache.admin)
          setLoading(false)
        }
      })
      return
    }

    const token = getToken()
    if (!token) {
      sessionCache = { admin: null, loading: false }
      setLoading(false)
      return
    }

    // Start fetch — store promise so concurrent mounts share it
    fetchPromise = fetch(`${API}/admin/auth/me`, {
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(res => {
        if (res.ok) return res.json()
        sessionStorage.removeItem(TOKEN_KEY)
        return null
      })
      .then(data => {
        const admin = data?.admin ?? null
        sessionCache = { admin, loading: false }
        setAdmin(admin)
      })
      .catch(() => {
        sessionStorage.removeItem(TOKEN_KEY)
        sessionCache = { admin: null, loading: false }
        setAdmin(null)
      })
      .finally(() => {
        setLoading(false)
        fetchPromise = null
      })
  }, []) // Runs once per mount — but module cache prevents duplicate fetches

  async function verifyWallet(wallet: string) {
    const res = await fetch(`${API}/admin/auth/verify-wallet`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ wallet }),
    })
    return res.json()
  }

  async function login(identifier: string, password: string, wallet?: string) {
    const res = await fetch(`${API}/admin/auth/login`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ identifier, password, wallet }),
    })
    const data = await res.json()
    if (res.ok && data.token) {
      sessionStorage.setItem(TOKEN_KEY, data.token)
      sessionCache = { admin: data.admin, loading: false }
      setAdmin(data.admin)
      return { success: true, admin: data.admin }
    }
    return { success: false, error: data.error ?? 'Login failed' }
  }

  async function logout() {
    const token = getToken()
    if (token) {
      await fetch(`${API}/admin/auth/logout`, {
        method:  'POST',
        headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    sessionStorage.removeItem(TOKEN_KEY)
    sessionCache  = null  // Clear cache on logout
    fetchPromise  = null
    setAdmin(null)
  }

  function hasPermission(perm: string): boolean {
    if (!admin) return false
    if (admin.role === 'super_admin') return true
    return admin.permissions.includes(perm)
  }

  return { admin, loading, verifyWallet, login, logout, hasPermission, getToken }
}

export function adminFetch(path: string, options: RequestInit = {}) {
  const token = typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null
  return fetch(`${API}${path}`, {
    ...options,
    headers: {
      ...options.headers,
      'Content-Type':  'application/json',
      Authorization:   `Bearer ${token}`,
    },
  })
}
