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
