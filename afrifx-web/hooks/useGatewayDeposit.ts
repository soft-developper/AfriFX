'use client'
// ============================================================
// useGatewayDeposit - deposit USDC into Circle's Gateway Wallet, signed by the
// user's CIRCLE wallet.
//
// Two on-chain steps, exactly as Circle documents:
//   1. approve(GatewayWallet, amount)  on the USDC token
//   2. deposit(usdcAddress, amount)    on the GatewayWallet
//
// CIRCLE MIGRATION: both are contractExecution challenges the user approves on
// their device (executeContractCall). No network switch - Circle runs each
// call on the chain we name.
//
// *** WHY THERE IS A GUARD ***
// Circle: "Directly transferring USDC to the Gateway Wallet contract with a
// standard ERC-20 transfer will result in loss of that USDC." There is NO
// recovery, so assertNotPlainTransfer() makes it structurally impossible for
// this code to do it.
//
// AFTER DEPOSITING: funds are NOT instantly spendable. They must reach block
// finality first - ~0.5s on Arc, but ~13-19 MINUTES on Base or Ethereum. The
// UI must say so rather than leaving the user wondering.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import {
  gatewayContracts, gatewayChains, usdcToUnits, assertNotPlainTransfer,
} from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type DepositStep =
  | 'idle' | 'approving' | 'depositing' | 'done' | 'error'

export interface DepositState {
  step:      DepositStep
  approveTx: string | null
  depositTx: string | null
  error:     string | null
  /** How long deposits take to become spendable on the chosen chain. */
  finality:  string | null
  /** Human step note while the user approves on their device. */
  note:      string | null
}

const INITIAL: DepositState = {
  step: 'idle', approveTx: null, depositTx: null, error: null, finality: null, note: null,
}

export function useGatewayDeposit() {
  const { address } = useAccount()
  const [state, setState] = useState<DepositState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const deposit = useCallback(async (params: { chainKey: string; amount: number }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Sign in first' })
      return
    }

    const chain    = chainByKey(params.chainKey)
    const gwChain  = gatewayChains().find(c => c.key === params.chainKey)
    const chainId  = evmChainId(params.chainKey)
    const wallet   = gatewayContracts().wallet as `0x${string}`

    if (!chain || !gwChain || !chainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported chain for Gateway' })
      return
    }
    if (!chain.usdc) {
      setState({ ...INITIAL, step: 'error', error: `No USDC address configured for ${chain.name}` })
      return
    }
    if (!(params.amount > 0)) {
      setState({ ...INITIAL, step: 'error', error: 'Enter an amount greater than zero' })
      return
    }

    const units = usdcToUnits(params.amount)
    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      // ── 1. Approve the Gateway Wallet to pull USDC ─────
      setState({ ...INITIAL, step: 'approving', finality: gwChain.finality })
      await executeContractCall({
        chainKey:             params.chainKey,
        contractAddress:      chain.usdc,
        abiFunctionSignature: 'approve(address,uint256)',
        abiParameters:        [wallet, units.toString()],
      }, note)

      // ── 2. Deposit ─────────────────────────────────────
      // Guard: this must be deposit() on the wallet contract, never a plain
      // ERC-20 transfer to it (which would destroy the funds).
      assertNotPlainTransfer('deposit', wallet)

      setState(s => ({ ...s, step: 'depositing' }))
      const depositResult = await executeContractCall({
        chainKey:             params.chainKey,
        contractAddress:      wallet,
        abiFunctionSignature: 'deposit(address,uint256)',
        abiParameters:        [chain.usdc, units.toString()],
      }, note)

      if (!depositResult.txHash) {
        throw new Error(
          'The deposit was approved but is taking longer than usual to confirm. ' +
          'Check your balance shortly - if it landed, it went through.')
      }

      setState(s => ({ ...s, step: 'done', depositTx: depositResult.txHash!, note: null }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Deposit failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was submitted, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, note: null }))
    }
  }, [address])

  return { ...state, deposit, reset }
}
