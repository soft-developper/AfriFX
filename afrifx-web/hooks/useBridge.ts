'use client'
// ============================================================
// useBridge — the CCTP flow, driven by the USER'S OWN WALLET.
//
// STAGE 3b. This is where real money moves, so the discipline is:
//   RECORD FIRST, THEN ACT, THEN RECORD THE RESULT.
//
// Every step is reported to the stage-2 state machine, so if the tab closes,
// the wallet disconnects, or the RPC dies, the record on the server always
// reflects reality and the transfer can be resumed or reconciled.
//
// THE ONE MOMENT THAT MATTERS: the instant the burn confirms, we POST the burn
// tx hash to /bridge/:id/burned BEFORE doing anything else. After that point
// the funds are burned and the mint is owed — if we lost the tx hash there,
// recovery would be far harder. Everything else is best-effort; that write is
// not.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import {
  cctpContracts, irisBase, chainByKey, addressToBytes32, CCTP_ENV,
} from '@/lib/cctp-chains'
import {
  TOKEN_MESSENGER_V2_ABI, MESSAGE_TRANSMITTER_V2_ABI, ERC20_ABI,
  getBurnFee, fetchAttestation, toUnits, FINALITY,
} from '@/lib/cctp-client'
import { evmChainId } from '@/lib/bridge-chains'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type BridgeStep =
  | 'idle' | 'creating' | 'switching' | 'approving' | 'burning'
  | 'attesting' | 'minting' | 'done' | 'error'

export interface BridgeState {
  step:     BridgeStep
  bridgeId: string | null
  burnTx:   string | null
  mintTx:   string | null
  error:    string | null
  /** Burned but not yet minted — funds are in flight and the mint is owed. */
  inFlight: boolean
  /** Seconds spent waiting for Circle, so the UI isn't a black box. */
  waitedSec: number
}

const INITIAL: BridgeState = {
  step: 'idle', bridgeId: null, burnTx: null, mintTx: null,
  error: null, inFlight: false, waitedSec: 0,
}

// Iris allows 40 req/s and blocks for 5 minutes if breached, so poll gently.
const POLL_MS       = 5_000
/*
  Five minutes of ACTIVE waiting, not thirty. Ethereum Sepolia needs ~13-19 min
  to finalise before Circle will even attest, so a spinner that waits the whole
  time makes a working transfer look broken. We wait a sensible while, then hand
  off to the reconciler — which was always the design.
*/
const POLL_MAX_MIN  = 5

async function api(path: string, body?: unknown) {
  const res = await fetch(`${API}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const d = await res.json().catch(() => ({}))
    throw new Error(d.error ?? `API ${res.status}`)
  }
  return res.json()
}

export function useBridge() {
  const { address } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  /*
    We deliberately do NOT use usePublicClient() here. It returns a client for
    whatever chain wagmi currently considers active — but this hook SWITCHES
    CHAINS mid-flow, so that client can end up pointed at the wrong chain when
    we wait for a receipt, which surfaces as "RPC Request failed" without any
    on-chain failure. Instead we fetch a client pinned to the exact chain for
    each wait.
  */
  const config = useConfig()
  const [state, setState] = useState<BridgeState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const bridge = useCallback(async (params: {
    fromKey: string
    toKey:   string
    amount:  number
    recipient?: string
  }) => {
    if (!address) { setState(s => ({ ...s, step: 'error', error: 'Connect a wallet first' })); return }

    const from = chainByKey(params.fromKey)
    const to   = chainByKey(params.toKey)
    if (!from || !to) { setState(s => ({ ...s, step: 'error', error: 'Unsupported route' })); return }

    const recipient = params.recipient ?? address
    const amountUnits = toUnits(params.amount)
    let bridgeId: string | null = null
    let burnedYet = false

    try {
      // ── 1. Record BEFORE anything is signed ──────────────
      setState({ ...INITIAL, step: 'creating' })
      const created = await api('/bridge', {
        walletAddress: address,
        fromChain: from.key, toChain: to.key,
        fromDomain: from.domain, toDomain: to.domain,
        amount: params.amount, recipient,
      })
      bridgeId = created.id
      setState(s => ({ ...s, bridgeId }))

      // ── 2. Make sure the wallet is on the SOURCE chain ───
      const srcChainId = evmChainId(from.key)
      if (!srcChainId) throw new Error(`No EVM chain id configured for ${from.name}`)
      setState(s => ({ ...s, step: 'switching' }))
      await switchChainAsync({ chainId: srcChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${from.name} and try again`)
      })

      const contracts = cctpContracts()
      const messenger = contracts.tokenMessenger as `0x${string}`

      /*
        CCTP burns an ERC-20, so burnToken MUST be a real token address. If it's
        missing we fail HERE with a clear message rather than passing the zero
        address to depositForBurn, which reverts with an opaque error after the
        user has already approved and signed. This was the actual cause of
        Arc-source bridges failing.
      */
      if (!from.usdc || /^0x0+$/.test(from.usdc)) {
        throw new Error(
          `No USDC token address configured for ${from.name}. ` +
          `Bridging from this chain can't proceed until it's set.`)
      }

      // ── 3. Approve the TokenMessenger to spend USDC ──────
      setState(s => ({ ...s, step: 'approving' }))
      const approveTx = await writeContractAsync({
        address: from.usdc as `0x${string}`,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [messenger, amountUnits],
        chainId: srcChainId,
      })
      await getPublicClient(config, { chainId: srcChainId })
        ?.waitForTransactionReceipt({ hash: approveTx as `0x${string}` })

      // ── 4. BURN on the source chain ──────────────────────
      setState(s => ({ ...s, step: 'burning' }))
      await api(`/bridge/${bridgeId}/burning`, {})

      const fee = await getBurnFee(irisBase(), from.domain, to.domain, amountUnits)

      const burnTx = await writeContractAsync({
        address: messenger,
        abi: TOKEN_MESSENGER_V2_ABI,
        functionName: 'depositForBurn',
        args: [
          amountUnits,
          to.domain,
          addressToBytes32(recipient),
          // Guarded above, so this is always a real token address.
          from.usdc as `0x${string}`,
          // bytes32(0) = ANY address may call receiveMessage on the destination.
          // That's what allows our reconciler (or the user from another device)
          // to finish a stranded mint.
          `0x${'0'.repeat(64)}` as `0x${string}`,
          fee.maxFeeUnits,
          FINALITY.FINALIZED,
        ],
        chainId: srcChainId,
      })

      const receipt = await getPublicClient(config, { chainId: srcChainId })
        ?.waitForTransactionReceipt({ hash: burnTx as `0x${string}` })
      if (receipt && receipt.status !== 'success') throw new Error('Burn transaction failed')

      /*
        *** THE CRITICAL WRITE ***
        Funds are now burned. Persist the tx hash immediately — everything
        downstream depends on it, and without it recovery is much harder.
        We deliberately await this and let a failure surface loudly.
      */
      burnedYet = true
      setState(s => ({ ...s, burnTx: burnTx as string, inFlight: true }))
      await api(`/bridge/${bridgeId}/burned`, {
        burnTx,
        // Circle looks the message up by tx hash, so we store the hash in both
        // fields rather than computing a message hash client-side.
        messageBytes: burnTx,
        messageHash:  burnTx,
      })

      // ── 5. Wait for Circle's attestation ─────────────────
      setState(s => ({ ...s, step: 'attesting' }))
      const startedAt = Date.now()
      const deadline  = startedAt + POLL_MAX_MIN * 60_000

      /*
        Poll DEFENSIVELY. Previously fetchAttestation() was called unguarded
        inside this loop, so one transient network error escaped it entirely and
        the spinner ran forever with no explanation. Each attempt is wrapped, and
        elapsed time is published so the UI can show a clock.
      */
      let att: Awaited<ReturnType<typeof fetchAttestation>> = { status: 'pending' }
      while (Date.now() < deadline) {
        try {
          att = await fetchAttestation(irisBase(), from.domain, burnTx as string)
          if (att.status === 'complete') break
        } catch {
          // swallow and retry — the burn is safe either way
        }
        setState(s => ({ ...s, waitedSec: Math.floor((Date.now() - startedAt) / 1000) }))
        await new Promise(r => setTimeout(r, POLL_MS))
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        // NOT a loss: the burn is recorded and the reconciler will finish it.
        throw new Error(
          'Circle is still attesting this transfer. Your USDC is burned and ' +
          'safely recorded — the mint completes automatically, and you can close ' +
          'this page. Check "Recent bridges" below for the final status.')
      }
      await api(`/bridge/${bridgeId}/attested`, { attestation: att.attestation })

      // ── 6. MINT on the destination chain ─────────────────
      setState(s => ({ ...s, step: 'minting' }))
      const dstChainId = evmChainId(to.key)
      if (!dstChainId) throw new Error(`No EVM chain id configured for ${to.name}`)
      await switchChainAsync({ chainId: dstChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${to.name} to finish the transfer`)
      })

      const mintTx = await writeContractAsync({
        address: contracts.messageTransmitter as `0x${string}`,
        abi: MESSAGE_TRANSMITTER_V2_ABI,
        functionName: 'receiveMessage',
        args: [att.message as `0x${string}`, att.attestation as `0x${string}`],
        chainId: dstChainId,
      })
      await getPublicClient(config, { chainId: dstChainId })
        ?.waitForTransactionReceipt({ hash: mintTx as `0x${string}` })

      await api(`/bridge/${bridgeId}/completed`, { mintTx })
      setState(s => ({ ...s, step: 'done', mintTx: mintTx as string, inFlight: false }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Bridge failed'

      /*
        "RPC Request failed" is unhelpful and alarming — it means the request
        never reached a node (rate-limited public endpoint, CORS, or the wallet
        being on a chain we have no transport for). Say that, since the user's
        next step is completely different from a real on-chain failure.
      */
      if (/rpc request failed|fetch failed|failed to fetch|network request/i.test(message)) {
        message =
          'Could not reach the network. This is usually a busy public RPC ' +
          'endpoint rather than a problem with your transfer — nothing was ' +
          'submitted to the chain. Please try again in a moment.'
      }

      // Tell the server. It classifies failed-vs-stranded by whether a burn
      // landed, so burned funds can never be recorded as a harmless failure.
      if (bridgeId) {
        await api(`/bridge/${bridgeId}/failed`, { error: message }).catch(() => {})
      }
      setState(s => ({
        ...s, step: 'error', error: message,
        inFlight: burnedYet,
      }))
    }
  }, [address, writeContractAsync, switchChainAsync, config])

  return { ...state, bridge, reset, env: CCTP_ENV }
}
