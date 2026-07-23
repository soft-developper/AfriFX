'use client'
// ============================================================
// useGatewayDeposit deposit USDC into Circle's Gateway Wallet.
//
// STAGE 3. The user signs in their OWN wallet; nothing is custodial and no key
// ever reaches a server.
//
// Two on-chain steps, exactly as Circle documents:
//   1. approve(GatewayWallet, amount)  on the USDC token
//   2. deposit(usdcAddress, amount)    on the GatewayWallet
//
// *** WHY THERE IS A GUARD ***
// Circle: "Directly transferring USDC to the Gateway Wallet contract with a
// standard ERC-20 transfer will result in loss of that USDC." There is NO
// recovery from that mistake, so assertNotPlainTransfer() makes it structurally
// impossible for this code to do it.
//
// AFTER DEPOSITING: funds are NOT instantly spendable. They must reach block
// finality first ~0.5s on Arc, but ~13-19 MINUTES on Base or Ethereum. The
// UI must say so rather than leaving the user wondering.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import {
  gatewayContracts, gatewayChains, usdcToUnits,
  GATEWAY_WALLET_ABI, GATEWAY_ERC20_ABI, assertNotPlainTransfer,
} from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type DepositStep =
  | 'idle' | 'switching' | 'approving' | 'depositing' | 'done' | 'error'

export interface DepositState {
  step:      DepositStep
  approveTx: string | null
  depositTx: string | null
  error:     string | null
  /** How long deposits take to become spendable on the chosen chain. */
  finality:  string | null
}

const INITIAL: DepositState = {
  step: 'idle', approveTx: null, depositTx: null, error: null, finality: null,
}

export function useGatewayDeposit() {
  const { address } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const config = useConfig()
  const [state, setState] = useState<DepositState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const deposit = useCallback(async (params: { chainKey: string; amount: number }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Connect a wallet first' })
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

    try {
      setState({ ...INITIAL, step: 'switching', finality: gwChain.finality })
      await switchChainAsync({ chainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${chain.name} and try again`)
      })

      // ── 1. Approve the Gateway Wallet to pull USDC ─────
      setState(s => ({ ...s, step: 'approving' }))
      const approveTx = await writeContractAsync({
        address: chain.usdc as `0x${string}`,
        abi: GATEWAY_ERC20_ABI,
        functionName: 'approve',
        args: [wallet, units],
        chainId,
      })
      await getPublicClient(config, { chainId })
        ?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })
      setState(s => ({ ...s, approveTx: approveTx as string }))

      // ── 2. Deposit ─────────────────────────────────────
      // Guard: this must be deposit() on the wallet contract, never a plain
      // ERC-20 transfer to it (which would destroy the funds).
      assertNotPlainTransfer('deposit', wallet)

      setState(s => ({ ...s, step: 'depositing' }))
      const depositTx = await writeContractAsync({
        address: wallet,
        abi: GATEWAY_WALLET_ABI,
        functionName: 'deposit',
        args: [chain.usdc as `0x${string}`, units],
        chainId,
      })
      const receipt = await getPublicClient(config, { chainId })
        ?.waitForTransactionReceipt({ hash: depositTx as `0x${string}` })
      if (receipt && receipt.status !== 'success') throw new Error('Deposit transaction failed')

      setState(s => ({ ...s, step: 'done', depositTx: depositTx as string }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Deposit failed'
      if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was submitted, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message }))
    }
  }, [address, writeContractAsync, switchChainAsync, config])

  return { ...state, deposit, reset }
}
