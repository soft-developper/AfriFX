'use client'
// ============================================================
// useGatewaySend — spend the unified balance on any supported chain.
//
// THE FLOW (per Circle's technical guide):
//   1. Build a TransferSpec + BurnIntent describing the transfer
//   2. Sign it as EIP-712 typed data with the user's EOA (off-chain, no gas)
//   3. POST to /v1/transfer -> Circle returns an attestation + signature
//   4. Call gatewayMint() on the GatewayMinter on the DESTINATION chain
//
// Step 3 is the fast part (<500ms) because finality was already paid for at
// deposit time. That's the whole point of Gateway.
//
// *** CONSTRAINTS THAT SHAPE THIS CODE ***
//   * ONLY EOA SIGNATURES. Circle: "SCA signatures such as EIP-1271 signatures
//     can't be accepted. Burn intents must be signed by an EOA." If the user's
//     wallet is a smart account, this will fail at the signing step — we detect
//     that and say so plainly rather than showing a cryptic error.
//   * ATTESTATIONS EXPIRE AFTER 10 MINUTES, so the mint must follow promptly.
//   * maxBlockHeight must be far enough ahead to exceed the wallet's
//     withdrawalDelay, so we read the current block and add a generous buffer.
//   * Same-chain transfers ARE supported and still mint-and-burn — but for
//     Arc->Arc we don't use Gateway at all (see useSmartSend), because a plain
//     wallet transfer is instant and doesn't consume the unified balance.
// ============================================================

import { useState, useCallback } from 'react'
import { useAccount, useSignTypedData, useWriteContract, useSwitchChain, useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { gatewayApi, gatewayContracts, gatewayChains, usdcToUnits } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type SendStep =
  | 'idle' | 'signing' | 'requesting' | 'switching' | 'minting' | 'done' | 'error'

export interface GatewaySendState {
  step:    SendStep
  mintTx:  string | null
  error:   string | null
  /** True when the failure is "your wallet can't sign for Gateway". */
  needsEoa: boolean
}

const INITIAL: GatewaySendState = {
  step: 'idle', mintTx: null, error: null, needsEoa: false,
}

// GatewayMinter — only the method we call.
const GATEWAY_MINTER_ABI = [
  {
    type: 'function', name: 'gatewayMint', stateMutability: 'nonpayable',
    inputs: [
      { name: 'attestationPayload', type: 'bytes' },
      { name: 'signature',          type: 'bytes' },
    ],
    outputs: [],
  },
] as const

// EIP-712 types, mirroring Circle's TransferSpec / BurnIntent structs.
const EIP712_TYPES = {
  TransferSpec: [
    { name: 'version',              type: 'uint32'  },
    { name: 'sourceDomain',         type: 'uint32'  },
    { name: 'destinationDomain',    type: 'uint32'  },
    { name: 'sourceContract',       type: 'bytes32' },
    { name: 'destinationContract',  type: 'bytes32' },
    { name: 'sourceToken',          type: 'bytes32' },
    { name: 'destinationToken',     type: 'bytes32' },
    { name: 'sourceDepositor',      type: 'bytes32' },
    { name: 'destinationRecipient', type: 'bytes32' },
    { name: 'sourceSigner',         type: 'bytes32' },
    { name: 'destinationCaller',    type: 'bytes32' },
    { name: 'value',                type: 'uint256' },
    { name: 'salt',                 type: 'bytes32' },
    { name: 'hookData',             type: 'bytes'   },
  ],
  BurnIntent: [
    { name: 'maxBlockHeight', type: 'uint256' },
    { name: 'maxFee',         type: 'uint256' },
    { name: 'spec',           type: 'TransferSpec' },
  ],
} as const

const ZERO32 = `0x${'0'.repeat(64)}` as const

function toBytes32(addr: string): `0x${string}` {
  return `0x${'0'.repeat(24)}${addr.toLowerCase().replace(/^0x/, '')}` as `0x${string}`
}

function randomSalt(): `0x${string}` {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return `0x${Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')}` as `0x${string}`
}

export function useGatewaySend() {
  const { address } = useAccount()
  const { signTypedDataAsync } = useSignTypedData()
  const { writeContractAsync } = useWriteContract()
  const { switchChainAsync }   = useSwitchChain()
  const config = useConfig()
  const [state, setState] = useState<GatewaySendState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const send = useCallback(async (params: {
    fromKey: string       // which chain's Gateway balance to spend
    toKey:   string       // destination chain
    amount:  number
    recipient: string
  }) => {
    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Connect a wallet first' })
      return
    }

    const src = gatewayChains().find(c => c.key === params.fromKey)
    const dst = gatewayChains().find(c => c.key === params.toKey)
    const srcCctp = chainByKey(params.fromKey)
    const dstCctp = chainByKey(params.toKey)
    const dstChainId = evmChainId(params.toKey)

    if (!src || !dst || !srcCctp || !dstCctp || !dstChainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported route' })
      return
    }

    const contracts = gatewayContracts()
    const value = usdcToUnits(params.amount)

    try {
      // ── 1. Build the burn intent ───────────────────────
      setState({ ...INITIAL, step: 'signing' })

      // maxBlockHeight must clear the wallet's withdrawalDelay. We read the
      // source chain's current height and add a large buffer.
      const srcChainId = evmChainId(params.fromKey)
      const srcClient  = srcChainId ? getPublicClient(config, { chainId: srcChainId }) : null
      const head = srcClient ? await srcClient.getBlockNumber() : BigInt(0)
      const maxBlockHeight = head + BigInt(1_000_000)

      const spec = {
        version: 1,
        sourceDomain:         src.domain,
        destinationDomain:    dst.domain,
        sourceContract:       toBytes32(contracts.wallet),
        destinationContract:  toBytes32(contracts.minter),
        sourceToken:          toBytes32(srcCctp.usdc),
        destinationToken:     toBytes32(dstCctp.usdc),
        sourceDepositor:      toBytes32(address),
        destinationRecipient: toBytes32(params.recipient),
        sourceSigner:         toBytes32(address),
        // 0 = any caller may use the attestation, so the mint isn't locked to
        // one sender. We're not composing this with other on-chain actions.
        destinationCaller:    ZERO32,
        value,
        salt: randomSalt(),
        hookData: '0x' as `0x${string}`,
      }

      const intent = {
        maxBlockHeight,
        // Circle's fee must be covered; a generous ceiling avoids a rejected
        // request, and the actual fee charged is far lower.
        maxFee: usdcToUnits(Math.max(0.01, params.amount * 0.001)),
        spec,
      }

      // ── 2. Sign as EIP-712 (EOA only) ──────────────────
      let signature: string
      try {
        signature = await signTypedDataAsync({
          domain: { name: 'GatewayWallet', version: '1' },
          types: EIP712_TYPES as any,
          primaryType: 'BurnIntent',
          message: intent as any,
        })
      } catch (sigErr: any) {
        const m = String(sigErr?.message ?? '')
        // A smart contract account can't produce the ECDSA signature Gateway
        // requires. Say that clearly instead of surfacing a raw wallet error.
        if (/1271|smart account|not supported|unsupported/i.test(m)) {
          setState({
            ...INITIAL, step: 'error', needsEoa: true,
            error: 'This wallet can\'t sign Gateway transfers. Gateway requires a ' +
                   'standard wallet (EOA) — smart contract accounts aren\'t supported.',
          })
          return
        }
        throw sigErr
      }

      // ── 3. Request the attestation ─────────────────────
      setState(s => ({ ...s, step: 'requesting' }))
      const res = await fetch(`${gatewayApi()}/transfer`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify([{
          burnIntent: {
            maxBlockHeight: maxBlockHeight.toString(),
            maxFee: intent.maxFee.toString(),
            spec: { ...spec, value: value.toString() },
          },
          signature,
        }]),
      })

      if (!res.ok) {
        const detail = await res.text().catch(() => '')
        throw new Error(`Gateway transfer rejected (${res.status})${detail ? `: ${detail.slice(0, 200)}` : ''}`)
      }
      const data: any = await res.json()
      const attestation = data?.attestation ?? data?.attestations?.[0]?.attestation
      const attSig      = data?.signature   ?? data?.attestations?.[0]?.signature
      if (!attestation || !attSig) {
        throw new Error('Gateway did not return an attestation. Please try again.')
      }

      // ── 4. Mint on the destination chain ───────────────
      setState(s => ({ ...s, step: 'switching' }))
      await switchChainAsync({ chainId: dstChainId }).catch(() => {
        throw new Error(`Please switch your wallet to ${dst.name} to complete the transfer`)
      })

      setState(s => ({ ...s, step: 'minting' }))
      const mintTx = await writeContractAsync({
        address: contracts.minter as `0x${string}`,
        abi: GATEWAY_MINTER_ABI,
        functionName: 'gatewayMint',
        args: [attestation as `0x${string}`, attSig as `0x${string}`],
        chainId: dstChainId,
      })
      await getPublicClient(config, { chainId: dstChainId })
        ?.waitForTransactionReceipt({ hash: mintTx as `0x${string}` })

      setState(s => ({ ...s, step: 'done', mintTx: mintTx as string }))
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Transfer failed'
      if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was transferred — please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message }))
    }
  }, [address, signTypedDataAsync, writeContractAsync, switchChainAsync, config])

  return { ...state, send, reset }
}
