'use client'
import { useState, useEffect, useRef } from 'react'

const API       = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
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
  const fetchedRef            = useRef(false)

  const getToken = () =>
    typeof window !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) : null

  useEffect(() => {
    if (fetchedRef.current) return
    fetchedRef.current = true
    const token = getToken()
    if (!token) { setLoading(false); return }
    fetch(`${API}/admin/auth/me`, {
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(res => { if (res.ok) return res.json(); sessionStorage.removeItem(TOKEN_KEY); return null })
      .then(data => { if (data?.admin) setAdmin(data.admin) })
      .catch(() => { sessionStorage.removeItem(TOKEN_KEY) })
      .finally(() => setLoading(false))
  }, [])

  async function verifyWallet(wallet: string) {
    const res = await fetch(`${API}/admin/auth/verify-wallet`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ wallet }),
    })
    return res.json()
  }

  async function login(identifier: string, password: string, wallet?: string) {
    const res = await fetch(`${API}/admin/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
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
        method: 'POST', headers: { Authorization: `Bearer ${token}` },
      }).catch(() => {})
    }
    sessionStorage.removeItem(TOKEN_KEY)
    fetchedRef.current = false
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
    headers: { ...options.headers, 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  })
}
