#!/usr/bin/env bash
# ============================================================================
# TEMPORARY: Memo-on-SCA probe (decide keep-vs-drop Memo for P2P)
#
# WHY
#   The P2P migration needs to know if a Circle SCA (smart-contract) wallet can
#   call Arc's Memo.memo(). Arc's docs say memo() must come from an EOA - the
#   CallFrom precompile forwards the EOA as msg.sender - and a Circle wallet is
#   a contract, not an EOA. Convert (4b) dropped Memo for this reason. Rather
#   than assume, this ships a one-click probe you run once, signed in, to see
#   whether a real Memo-wrapped call confirms or reverts from your wallet.
#
#   The probe Memo-wraps USDC approve(vault, 0): approving zero moves no funds
#   and is safe to run repeatedly, but it genuinely exercises
#   SCA -> Memo.memo() -> inner call through the precompile.
#
# ADDS (2 temporary files, no existing code touched)
#   afrifx-web/lib/memo-sca-probe.ts
#   afrifx-web/app/(app)/memo-probe/page.tsx   -> route /memo-probe
#
# AFTER YOU DECIDE: delete both files (or run the cleanup at the bottom).
#
# USAGE
#   bash probe-memo-on-sca.sh
#   # then deploy, visit /memo-probe while signed in, click the button.
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$ROOT/afrifx-web"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
[ -f "$WEB/hooks/useCircleTx.ts" ] || die "run from repo root"
grep -q "executeContractCall" "$WEB/hooks/useCircleTx.ts" || die "needs Phase 5b (executeContractCall)."
say "Writing probe files"
mkdir -p "$ROOT/$(dirname "afrifx-web/lib/memo-sca-probe.ts")"
cat > "$ROOT/afrifx-web/lib/memo-sca-probe.ts" <<'AFX_PROBE_EOF'
'use client'
// ============================================================
// TEMPORARY PROBE - delete after the Memo-on-SCA question is settled.
//
// Question: can a Circle SCA wallet successfully call Arc's Memo.memo()?
// Arc's docs say memo() must be called from an EOA (the CallFrom precompile
// forwards the EOA as msg.sender). A Circle wallet is a smart contract, not an
// EOA, so this may revert. Convert (4b) dropped Memo for this reason. Before
// we keep or drop Memo across all six P2P actions, we test ONE real call.
//
// What it does: Memo-wraps a harmless USDC approve(vault, 0) - approving zero
// changes nothing and costs almost nothing, but it genuinely exercises
// SCA -> Memo.memo() -> inner call via the precompile. If this confirms on
// chain, real vault calls will too. If it reverts, Memo + SCA is unsupported.
// ============================================================

import { encodeFunctionData } from 'viem'
import { executeContractCall } from '@/hooks/useCircleTx'
import { CONTRACTS } from '@/lib/contracts'
import { buildMemoId, buildMemoCallArgs } from '@/lib/memo'

export interface ProbeResult {
  ok:      boolean
  txHash?: string
  state?:  string
  message: string
}

export async function probeMemoOnSca(
  onStep?: (m: string) => void,
): Promise<ProbeResult> {
  const vault = CONTRACTS.AFRIFX_VAULT
  const usdc  = CONTRACTS.USDC

  // Inner call: USDC.approve(vault, 0) - a real state-touching call that is
  // economically a no-op (zero allowance), so it's safe to fire repeatedly.
  const innerData = encodeFunctionData({
    abi: [{
      name: 'approve', type: 'function', stateMutability: 'nonpayable',
      inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
      outputs: [{ name: '', type: 'bool' }],
    }] as const,
    functionName: 'approve',
    args: [vault, BigInt(0)],
  })

  // Wrap it in Memo.memo(target=USDC, data=innerData, memoId, memoData)
  const memoArgs = buildMemoCallArgs(usdc, innerData, buildMemoId('sca-probe'), {
    app: 'afrifx', type: 'p2p-create', ref: 'PROBE',
  })

  try {
    const result = await executeContractCall({
      chainKey:             'arc',
      contractAddress:      memoArgs.address,           // the Memo contract
      abiFunctionSignature: 'memo(address,bytes,bytes32,bytes)',
      abiParameters:        memoArgs.args as unknown as string[],
    }, onStep)

    if (result.txHash) {
      return {
        ok: true, txHash: result.txHash, state: result.state,
        message: `Memo call CONFIRMED from the Circle SCA wallet (tx ${result.txHash.slice(0, 12)}...). Keep Memo for P2P.`,
      }
    }
    return {
      ok: false, state: result.state,
      message: `Memo call did not surface a tx hash (state: ${result.state ?? 'unknown'}). Likely still pending or blocked - check the explorer.`,
    }
  } catch (err: any) {
    return {
      ok: false,
      message: `Memo call FAILED from the SCA wallet: ${err?.message ?? String(err)}. This is the expected outcome if Memo needs an EOA - drop Memo for P2P (match Convert).`,
    }
  }
}
AFX_PROBE_EOF
ok "wrote afrifx-web/lib/memo-sca-probe.ts"
mkdir -p "$ROOT/$(dirname "afrifx-web/app/(app)/memo-probe/page.tsx")"
cat > "$ROOT/afrifx-web/app/(app)/memo-probe/page.tsx" <<'AFX_PROBE_EOF'
'use client'
// TEMPORARY probe page - delete after the Memo-on-SCA question is settled.
// Visit /memo-probe while signed in (needs a live Circle signing session),
// click the button, read the result. It tells us whether to keep or drop
// Memo for the P2P migration.

import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { probeMemoOnSca, type ProbeResult } from '@/lib/memo-sca-probe'

export default function MemoProbePage() {
  const { isConnected } = useAccount()
  const [busy, setBusy]     = useState(false)
  const [step, setStep]     = useState<string | null>(null)
  const [result, setResult] = useState<ProbeResult | null>(null)

  async function run() {
    setBusy(true); setResult(null); setStep(null)
    try {
      const r = await probeMemoOnSca(setStep)
      setResult(r)
    } catch (err: any) {
      setResult({ ok: false, message: err?.message ?? String(err) })
    } finally {
      setBusy(false); setStep(null)
    }
  }

  return (
    <div className="mx-auto max-w-lg p-6">
      <h1 className="text-lg font-semibold">Memo-on-SCA probe</h1>
      <p className="mt-2 text-sm text-app-muted">
        Fires one Memo-wrapped USDC approve(vault, 0) through your Circle
        wallet. Zero allowance, so it moves no funds. Tells us if Memo works
        from a smart-contract wallet on Arc.
      </p>

      <Button className="mt-4" disabled={!isConnected || busy} onClick={run}>
        {busy ? 'Running…' : 'Run Memo probe'}
      </Button>
      {!isConnected && (
        <p className="mt-2 text-xs text-amber-500">Sign in first.</p>
      )}
      {step && <p className="mt-3 text-xs text-app-muted">{step}</p>}

      {result && (
        <div className={`mt-4 rounded-lg border p-3 text-sm ${
          result.ok ? 'border-green-700/50 bg-green-900/20 text-green-300'
                    : 'border-red-700/50 bg-red-900/20 text-red-300'}`}>
          <p className="font-medium">{result.ok ? 'CONFIRMED' : 'FAILED / PENDING'}</p>
          <p className="mt-1 leading-relaxed">{result.message}</p>
          {result.txHash && (
            <a
              href={`https://explorer.testnet.arc.network/tx/${result.txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="mt-2 inline-block text-xs underline"
            >View on explorer</a>
          )}
        </div>
      )}
    </div>
  )
}
AFX_PROBE_EOF
ok "wrote afrifx-web/app/(app)/memo-probe/page.tsx"

say "WEB: tsc + build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) || die "web tsc failed"
ok "web typechecks"
( cd "$WEB" && rm -rf .next && npm run build >/dev/null 2>&1 ) || die "web build failed"
ok "web builds (route /memo-probe added)"
say "Probe ready."
cat <<'NOTE'

  Next:
    1. Commit & push (or just run locally):
         git add "afrifx-web/lib/memo-sca-probe.ts" \
                 "afrifx-web/app/(app)/memo-probe/page.tsx"
         git commit -m "temp: Memo-on-SCA probe"
         git push origin main
    2. Sign in, go to /memo-probe, click "Run Memo probe", approve on device.
    3. Read the result:
         CONFIRMED  -> Memo works from the SCA. We KEEP Memo for P2P.
         FAILED     -> Memo needs an EOA. We DROP Memo for P2P (like Convert).
    4. Tell me which, and I'll build the P2P migration accordingly.

  Cleanup when done (removes both files):
    rm -f "afrifx-web/lib/memo-sca-probe.ts"
    rm -rf "afrifx-web/app/(app)/memo-probe"
NOTE
