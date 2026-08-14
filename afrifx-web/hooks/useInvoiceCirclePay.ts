'use client'
// Pay an invoice from the user's CIRCLE (user-controlled) wallet.
// Reuses sendUsdc (challenge → device approval → on-chain confirm) — the same
// primitive Send/P2P/Bridge use. Plain transfer, no memo (Circle SCA can't use
// Arc's Memo precompile). Ref metadata is persisted to the API by the caller.
import { useState } from 'react'
import { getSigningSession, sendUsdc, NeedsReauthError } from '@/hooks/useCircleTx'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface CirclePayResult { txHash?: string; state: string }

export function hasCircleSession(): boolean {
  return !!getSigningSession()
}

export function useInvoiceCirclePay() {
  const [step, setStep] = useState<string | null>(null)

  // Returns { needsSignin: true } when there is no live Circle session, so the
  // caller can redirect to /signin?returnTo=<invoice>. Otherwise runs the pay.
  async function payWithCircle(
    to: string,
    usdcAmount: number,
  ): Promise<{ needsSignin: true } | { needsSignin: false; result: CirclePayResult }> {
    if (!hasCircleSession()) return { needsSignin: true }
    try {
      const result = await sendUsdc(
        { to, amount: usdcAmount.toFixed(6) },
        (m) => setStep(m),
      )
      return { needsSignin: false, result }
    } catch (e) {
      if (e instanceof NeedsReauthError) return { needsSignin: true }
      throw e
    } finally {
      setStep(null)
    }
  }

  return { payWithCircle, step }
}
