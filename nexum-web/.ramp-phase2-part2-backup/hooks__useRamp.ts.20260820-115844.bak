'use client'
import { useState, useCallback, useEffect } from 'react'
import { apiFetch } from '@/hooks/useAuth'

export type RampKycStatus =
  | 'not_started' | 'under_review' | 'incomplete'
  | 'awaiting_questionnaire' | 'awaiting_ubo'
  | 'approved' | 'rejected' | 'paused' | 'offboarded'

export type RampTosStatus = 'pending' | 'approved'
export type RampCustomerType = 'individual' | 'business'

export interface RampRejection {
  developer_reason?: string
  reason?: string
  created_at?: string
}

export interface RampCustomer {
  exists:       boolean
  customerType?: RampCustomerType
  kycStatus?:   RampKycStatus
  tosStatus?:   RampTosStatus
  kycLink?:     string | null
  tosLink?:     string | null
  customerId?:  string | null
  rejectionReasons?: RampRejection[]
  verified?:    boolean
}

/*
  Bridge.xyz onboarding state for the signed-in account. KYC is hosted (the
  user completes tos_link + kyc_link in a new tab), so this hook's job is to
  create the link, expose it, and poll status until approved/rejected.
*/
export function useRamp() {
  const [customer, setCustomer] = useState<RampCustomer | null>(null)
  const [loading,  setLoading]  = useState(true)
  const [busy,     setBusy]     = useState(false)
  const [error,    setError]    = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const res = await apiFetch('/ramp/customer')
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error ?? 'Could not load your ramp status')
      setCustomer(data)
    } catch (err: any) {
      setError(err?.message ?? 'Could not load your ramp status')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { load() }, [load])

  // Create the hosted KYC link (lazy onboarding).
  const startVerification = useCallback(async (fullName: string, type: RampCustomerType) => {
    setBusy(true); setError(null)
    try {
      const res = await apiFetch('/ramp/customer', {
        method: 'POST',
        body: JSON.stringify({ fullName, type }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error ?? 'Could not start verification')
      setCustomer(data)
      return data as RampCustomer
    } catch (err: any) {
      setError(err?.message ?? 'Could not start verification')
      return null
    } finally {
      setBusy(false)
    }
  }, [])

  // Poll Bridge for the latest status (called on tab-return / interval).
  const refresh = useCallback(async () => {
    try {
      const res = await apiFetch('/ramp/customer/refresh')
      const data = await res.json().catch(() => ({}))
      if (res.ok) setCustomer(data)
      return data as RampCustomer
    } catch { return null }
  }, [])

  // Sandbox-only helper the UI shows behind an env flag.
  const simulateApprove = useCallback(async () => {
    setBusy(true); setError(null)
    try {
      const res = await apiFetch('/ramp/customer/simulate-approve', { method: 'POST' })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error ?? 'Simulate approval failed')
      setCustomer(data)
      return data as RampCustomer
    } catch (err: any) {
      setError(err?.message ?? 'Simulate approval failed')
      return null
    } finally {
      setBusy(false)
    }
  }, [])

  const verified = !!customer?.verified

  return { customer, loading, busy, error, verified, load, startVerification, refresh, simulateApprove }
}
