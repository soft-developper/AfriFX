#!/usr/bin/env bash
# ============================================================================
# Phase 6c - HOTFIX: hold Gateway cross-chain send (ERC-1271 not yet accepted)
#
# WHY
#   Gateway's /transfer attestation API rejects the SCA's ERC-1271 signature
#   ("Invalid signature: recovered signer does not match sourceSigner") - it
#   still statically ECDSA-recovers an EOA at that step, despite the ERC-1271
#   announcement. So cross-chain Gateway SEND fails for every user. (Deposit,
#   CCTP Bridge, P2P, Send/Convert all still work.)
#
# WHAT IT DOES
#   Gates useGatewaySend behind NEXT_PUBLIC_GATEWAY_SEND_ENABLED. While unset
#   (default), a cross-chain send returns a clear "temporarily unavailable"
#   message instead of a raw signature error. Deposits are untouched. When
#   Circle confirms ERC-1271 is live on the transfer API, set the env var to
#   'true' to re-enable - no code change needed.
#
# CHANGES (1 file)
#   afrifx-web/hooks/useGatewaySend.ts
#
# REQUIRES: Phase 6b.
#
# USAGE
#   bash phase6c-hold-gateway-send.sh
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
grep -q "signTypedData" "$WEB/hooks/useGatewaySend.ts" || die "Phase 6b not detected."
BK="$ROOT/.phase6c-backup"; rm -rf "$BK"; mkdir -p "$BK/$(dirname afrifx-web/hooks/useGatewaySend.ts)"
cp "$ROOT/afrifx-web/hooks/useGatewaySend.ts" "$BK/afrifx-web/hooks/useGatewaySend.ts" 2>/dev/null || true
ok "snapshot saved"
say "Writing file"
cat > "$ROOT/afrifx-web/hooks/useGatewaySend.ts" <<'AFX_6C_EOF'
'use client'
// ============================================================
// useGatewaySend - spend the unified Gateway balance, signed by the user's
// CIRCLE wallet.
//
// THE FLOW (per Circle's technical guide):
//   1. Build a TransferSpec + BurnIntent describing the transfer
//   2. Sign it as EIP-712 typed data  <-- now via the Circle wallet (ERC-1271)
//   3. POST to /v1/transfer -> Circle returns an attestation + signature
//   4. gatewayMint() on the destination chain <-- now via executeContractCall
//
// CIRCLE MIGRATION
//   Gateway added ERC-1271 support (Aug 2026), so an SCA can authorize
//   transfers directly - no EOA, no delegate. Step 2 uses signTypedData (a
//   SIGN_TYPEDDATA challenge) and step 4 uses executeContractCall. There is no
//   network switch: Circle runs the mint on the chain we name.
//
// *** CONSTRAINTS THAT STILL SHAPE THIS CODE ***
//   * ATTESTATIONS EXPIRE AFTER 10 MINUTES, so the mint must follow promptly.
//   * maxBlockHeight must exceed the wallet's withdrawalDelay; we read the head
//     and add a buffer, then let Circle's own error correct us if short.
//   * Arc->Arc doesn't use Gateway (a plain wallet transfer is instant); that
//     routing lives in the caller (useSmartSend), not here.
// ============================================================

import { useState, useCallback } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import {
  signTypedData, executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import { gatewayApi, gatewayContracts, gatewayChains, usdcToUnits } from '@/lib/gateway'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

export type SendStep =
  | 'idle' | 'signing' | 'requesting' | 'minting' | 'done' | 'error'

export interface GatewaySendState {
  step:    SendStep
  mintTx:  string | null
  error:   string | null
  /** Retained for API compatibility; always false now that SCAs can sign. */
  needsEoa: boolean
  /** Human step note while the user approves on their device. */
  note:    string | null
}

const INITIAL: GatewaySendState = {
  step: 'idle', mintTx: null, error: null, needsEoa: false, note: null,
}

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
  const config = useConfig()
  const [state, setState] = useState<GatewaySendState>(INITIAL)

  const reset = useCallback(() => setState(INITIAL), [])

  const send = useCallback(async (params: {
    fromKey: string       // which chain's Gateway balance to spend
    toKey:   string       // destination chain
    amount:  number
    recipient: string
  }) => {
    // TEMPORARY HOLD. Gateway's /transfer attestation step currently rejects
    // the SCA's ERC-1271 signature ("recovered signer does not match
    // sourceSigner") - it still statically ECDSA-recovers an EOA. Until Circle
    // confirms ERC-1271 is live on the transfer API (and the required format),
    // cross-chain Gateway send is disabled so users get an honest message
    // instead of a signature error. Deposits are unaffected. Flip
    // NEXT_PUBLIC_GATEWAY_SEND_ENABLED=true to re-enable without a code change.
    if (process.env.NEXT_PUBLIC_GATEWAY_SEND_ENABLED !== 'true') {
      const msg =
        'Cross-chain send is temporarily unavailable while we finish enabling ' +
        'it for your account type. Your balance is safe, and same-chain sends ' +
        'and deposits work as normal.'
      setState({ ...INITIAL, step: 'error', error: msg })
      return { ok: false as const, error: msg, needsEoa: false }
    }

    if (!address) {
      setState({ ...INITIAL, step: 'error', error: 'Sign in first' })
      return { ok: false as const, error: 'Sign in first', needsEoa: false }
    }

    const src = gatewayChains().find(c => c.key === params.fromKey)
    const dst = gatewayChains().find(c => c.key === params.toKey)
    const srcCctp = chainByKey(params.fromKey)
    const dstCctp = chainByKey(params.toKey)
    const dstChainId = evmChainId(params.toKey)

    if (!src || !dst || !srcCctp || !dstCctp || !dstChainId) {
      setState({ ...INITIAL, step: 'error', error: 'Unsupported route' })
      return { ok: false as const, error: 'Unsupported route', needsEoa: false }
    }

    const contracts = gatewayContracts()
    const value = usdcToUnits(params.amount)
    const note = (m: string) => setState(s => ({ ...s, note: m }))

    try {
      setState({ ...INITIAL, step: 'signing' })

      // maxBlockHeight must clear the wallet's withdrawalDelay, measured in
      // source-chain blocks. Read the head and add a generous buffer; if it's
      // short, Circle's error states the exact minimum and we retry with it.
      const srcChainId = evmChainId(params.fromKey)
      const srcClient  = srcChainId ? getPublicClient(config, { chainId: srcChainId }) : null
      const head = srcClient ? await srcClient.getBlockNumber() : BigInt(0)
      let maxBlockHeight = head + BigInt(2_000_000)

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

      // Build + sign + request, self-correcting maxBlockHeight once. The
      // signature covers maxBlockHeight, so a correction means RE-SIGN, not
      // just resend - hence sign and request live together.
      const signAndRequest = async (mbh: bigint) => {
        const intent = {
          maxBlockHeight: mbh,
          // A generous ceiling avoids rejection; the fee actually charged is
          // far lower. maxFee is what the USER authorises, so it stays
          // proportional to the amount.
          maxFee: usdcToUnits(Math.max(0.01, params.amount * 0.001)),
          spec,
        }

        // Circle wants the EIP-712 message with all bigints as strings.
        const typedData = {
          types: {
            EIP712Domain: [
              { name: 'name',    type: 'string' },
              { name: 'version', type: 'string' },
            ],
            ...EIP712_TYPES,
          },
          domain: { name: 'GatewayWallet', version: '1' },
          primaryType: 'BurnIntent',
          message: {
            maxBlockHeight: mbh.toString(),
            maxFee:         intent.maxFee.toString(),
            spec: { ...spec, value: value.toString() },
          },
        }

        let signature: string
        try {
          signature = await signTypedData(
            { chainKey: params.fromKey, typedData, memo: 'Gateway transfer' }, note)
        } catch (sigErr: any) {
          // With ERC-1271 an SCA can sign, so the old "needs EOA" path is gone.
          // Re-throw reauth/chain signals so the UI can handle them precisely.
          throw sigErr
        }

        setState(s => ({ ...s, step: 'requesting', note: null }))
        const res = await fetch(`${gatewayApi()}/transfer`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify([{
            burnIntent: {
              maxBlockHeight: mbh.toString(),
              maxFee: intent.maxFee.toString(),
              spec: { ...spec, value: value.toString() },
            },
            signature,
          }]),
        })

        const text = await res.text().catch(() => '')
        if (!res.ok) {
          const err: any = new Error(
            `Gateway transfer rejected (${res.status})${text ? `: ${text.slice(0, 200)}` : ''}`)
          const m = text.match(/expected at least (\d+)/i)
          if (m) err.__requiredHeight = BigInt(m[1])
          throw err
        }
        return JSON.parse(text || '{}')
      }

      let data: any
      try {
        data = await signAndRequest(maxBlockHeight)
      } catch (firstErr: any) {
        if (!firstErr?.__requiredHeight) throw firstErr
        maxBlockHeight = firstErr.__requiredHeight + BigInt(500_000)
        setState(s => ({ ...s, step: 'signing' }))
        data = await signAndRequest(maxBlockHeight)
      }

      const attestation = data?.attestation ?? data?.attestations?.[0]?.attestation
      const attSig      = data?.signature   ?? data?.attestations?.[0]?.signature
      if (!attestation || !attSig) {
        throw new Error('Gateway did not return an attestation. Please try again.')
      }

      // Mint on the destination chain via a Circle contract-execution challenge.
      setState(s => ({ ...s, step: 'minting' }))
      const mintResult = await executeContractCall({
        chainKey:             params.toKey,
        contractAddress:      contracts.minter,
        abiFunctionSignature: 'gatewayMint(bytes,bytes)',
        abiParameters:        [attestation, attSig],
      }, note)

      const mintTx = mintResult.txHash ?? 'pending'
      setState(s => ({ ...s, step: 'done', mintTx, note: null }))
      // Also RETURN the result. The Send page reads state; a caller running
      // many transfers in a loop (payroll) awaits this outcome instead, since
      // async state between iterations isn't reliable.
      return { ok: true as const, mintTx }
    } catch (err: any) {
      let message = err?.shortMessage ?? err?.message ?? 'Transfer failed'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/rpc request failed|fetch failed|failed to fetch/i.test(message)) {
        message = 'Could not reach the network. Nothing was transferred, please try again.'
      }
      setState(s => ({ ...s, step: 'error', error: message, needsEoa: false, note: null }))
      return { ok: false as const, error: message, needsEoa: false }
    }
  }, [address, config])

  return { ...state, send, reset }
}
AFX_6C_EOF
ok "wrote afrifx-web/hooks/useGatewaySend.ts"

say "Verifying"
grep -q "GATEWAY_SEND_ENABLED" "$WEB/hooks/useGatewaySend.ts" || die "guard missing"

say "WEB: install + tsc + build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && rm -rf .next && npx tsc --noEmit ) || { cp -rf "$BK"/. "$ROOT"/; die "web tsc failed - restored"; }
ok "web typechecks"
( cd "$WEB" && npm run build >/dev/null 2>&1 ) || { cp -rf "$BK"/. "$ROOT"/; die "web build failed - restored"; }
ok "web builds"
rm -rf "$BK"
say "Phase 6c applied and verified."
cat <<'NOTE'

  Gateway cross-chain SEND now shows a friendly "temporarily unavailable"
  message instead of failing on the signature. Deposits still work.

  Commit & push:
    git add afrifx-web/hooks/useGatewaySend.ts
    git commit -m "phase 6c: hold Gateway cross-chain send pending ERC-1271 confirmation"
    git push origin main

  WHEN CIRCLE CONFIRMS ERC-1271 IS LIVE ON /transfer:
    - If it just needs enabling: set NEXT_PUBLIC_GATEWAY_SEND_ENABLED=true in
      the web env (Vercel) and redeploy. No code change.
    - If it needs a signature-FORMAT change: tell me exactly what Circle says
      and I'll apply it, then flip the flag.

  QUESTION TO ASK CIRCLE:
    "Is ERC-1271 burn-intent signing live on the TESTNET /v1/transfer API for
     user-controlled SCA wallets? If so, what signature format does the
     transfer request expect (raw 65-byte, or an ERC-6492/wrapped form), and
     does the SCA need any on-chain registration first?"
NOTE
