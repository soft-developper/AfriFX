'use client'

/**
 * Account session for the app.
 *
 * Mirrors useAdminAuth, with one deliberate difference: the token lives
 * in localStorage rather than sessionStorage. Admins sign in per tab;
 * a payments app that signs people out whenever they close a tab is
 * hostile, so this persists until the session expires or they sign out.
 */

import { useState, useEffect, useRef, useCallback } from 'react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export const ACCOUNT_TOKEN_KEY = 'nexum_token'
export const ACCOUNT_KEY       = 'nexum_account'

export interface Account {
  id:            string
  email:         string
  username:      string
  firstName:     string
  lastName:      string
  /** Null until Phase 2 provisions the Circle wallet. */
  walletAddress: string | null
  status:        string
  createdAt:     number
}

export const getToken = () =>
  typeof window === 'undefined' ? null : localStorage.getItem(ACCOUNT_TOKEN_KEY)

export function persistSession(token: string, account: Account) {
  localStorage.setItem(ACCOUNT_TOKEN_KEY, token)
  localStorage.setItem(ACCOUNT_KEY, JSON.stringify(account))
}

export function clearSession() {
  localStorage.removeItem(ACCOUNT_TOKEN_KEY)
  localStorage.removeItem(ACCOUNT_KEY)
}

/**
 * fetch() with the session attached.
 *
 * A 401 means the session is gone, so it clears local state rather than
 * leaving the UI in a signed-in-looking but broken condition.
 */
export async function apiFetch(path: string, init: RequestInit = {}) {
  const token = getToken()
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(init.headers ?? {}),
    },
  })
  if (res.status === 401) clearSession()
  return res
}

export function useAuth() {
  const [account, setAccount] = useState<Account | null>(null)
  const [loading, setLoading] = useState(true)
  const checked = useRef(false)

  useEffect(() => {
    if (checked.current) return
    checked.current = true

    // Show the cached account immediately so the UI doesn't flash signed-out,
    // then confirm with the server.
    const cached = localStorage.getItem(ACCOUNT_KEY)
    if (cached) { try { setAccount(JSON.parse(cached)) } catch { /* ignore */ } }

    if (!getToken()) { setAccount(null); setLoading(false); return }

    apiFetch('/auth/me')
      .then(res => (res.ok ? res.json() : null))
      .then(data => {
        if (data?.account) {
          setAccount(data.account)
          localStorage.setItem(ACCOUNT_KEY, JSON.stringify(data.account))
        } else {
          clearSession()
          setAccount(null)
        }
      })
      .catch(() => { /* offline: keep the cached account rather than signing out */ })
      .finally(() => setLoading(false))
  }, [])

  const signOut = useCallback(async () => {
    await apiFetch('/auth/logout', { method: 'POST' }).catch(() => {})
    clearSession()
    setAccount(null)
  }, [])

  return { account, loading, signOut, isSignedIn: Boolean(account) }
}
