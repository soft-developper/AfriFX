'use client'
// ============================================================
// usePayrollFunding - top up the platform's reusable disbursement float.
//
// HYBRID CUSTODY (Phase 7b). The employer signs ONE USDC transfer from their
// Circle wallet into the platform's MPC disbursement wallet. The backend then
// pays batches out of that float (7c) with no per-payee signing. This hook is
// only the funding step: sign the transfer, then record it so the backend
// confirms it against the live wallet balance.
//
// The destination is fetched from the server (the live wallet address), never
// hardcoded or supplied by the client, so funds always go to the real wallet.
// ============================================================

import { useState, useCallback } from 'react'
import { parseUnits } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type FundStep = 'idle' | 'preparing' | 'signing' | 'confirming' | 'done' | 'error'

export interface FundState {
  step:    FundStep
  txHash:  string | null
  balance: number | null
  error:   string | null
  note:    string | null
}

const INITIAL: FundState = {
  step: 'idle', txHash: null, balance: null, error: null, note: null,
}

export function usePayrollFunding() {
  const { address } = useAccount()
  const [state, setState] = useState<FundState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const fund = useCallback(async (amount: number) => {
    if (!address) { setState({ ...INITIAL, step: 'error', error: 'Sign in first' }); return }
    if (!(amount > 0)) { setState({ ...INITIAL, step: 'error', error: 'Enter an amount greater than zero' }); return }

    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      setState({ ...INITIAL, step: 'preparing' })

      // Fetch the live disbursement address from the server - never hardcode
      // or let the client choose where the money goes.
      const addrRes = await fetch(`${API}/payroll/disbursement/address`)
      const addrData = await addrRes.json().catch(() => ({}))
      if (!addrRes.ok || !addrData.address) {
        throw new Error(addrData.error ?? 'Disbursement wallet is not set up yet.')
      }
      const to = addrData.address as string

      // Sign the USDC transfer employer -> disbursement wallet.
      setState(s => ({ ...s, step: 'signing' }))
      const result = await executeContractCall({
        chainKey:             'arc',
        contractAddress:      CONTRACTS.USDC,
        abiFunctionSignature: 'transfer(address,uint256)',
        abiParameters:        [to, parseUnits(amount.toFixed(6), USDC_DECIMALS).toString()],
      }, note)

      const txHash = result.txHash ?? null
      if (!txHash) {
        throw new Error(
          'The top-up was approved but is taking longer than usual to confirm. ' +
          'Check the float balance shortly - if it rose, it went through.')
      }

      // Record + confirm against the live wallet balance server-side.
      setState(s => ({ ...s, step: 'confirming', txHash, note: null }))
      const fundRes = await fetch(`${API}/payroll/disbursement/fund`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ funderAddress: address, amount, txHash }),
      })
      const fundData = await fundRes.json().catch(() => ({}))
      if (!fundRes.ok) throw new Error(fundData.error ?? 'Could not record the top-up')

      setState(s => ({
        ...s, step: 'done', balance: fundData.balance ?? null, note: null,
      }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Funding failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was sent, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, note: null }))
    }
  }, [address])

  return { ...state, fund, reset }
}
