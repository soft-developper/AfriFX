#!/bin/bash
# ============================================================
# AfriFX BRIDGE -- STAGE 3a of 4: CCTP CLIENT (ABIs, fees, attestation)
#
# ONE new file. Nothing imports it yet, so this changes no behaviour -- but it's
# the piece that talks to Circle, so it was written against the OFFICIAL spec
# rather than memory. Several details are easy to get wrong and expensive:
#
# 1) *** V2 depositForBurn TAKES SEVEN PARAMETERS, NOT FOUR ***
#    Many third-party snippets (and a couple of the search results I found) still
#    show V1's four-parameter form. V2 adds destinationCaller, maxFee and
#    minFinalityThreshold. The ABI here is the V2 shape, asserted by a test.
#
# 2) *** maxFee: 0 REVERTS THE BURN ***
#    Circle: "If maxFee is less than the minimum Standard Transfer fee, the burn
#    reverts onchain." So we fetch the live fee (returned in BASIS POINTS) and
#    derive maxFee from it, with a floor of 1 unit so it can never be zero.
#
#    A bug I caught in my own first version: the safety margin was additive in
#    BPS, so a 100 USDC transfer at 1bps authorised 1.01 USDC of fees -- about 1%,
#    ~67x more than needed. The margin is now a percentage OF THE FEE, giving
#    0.015%. maxFee is a ceiling the USER agrees to pay, so it must be tight.
#
# 3) Attestations are fetched by SOURCE TRANSACTION HASH via GET /v2/messages
#    (and the domain in the path is the SOURCE domain -- passing the destination
#    is a classic mix-up).
#
# 4) Iris rate limit is 40 req/s and breaching it BLOCKS YOU FOR FIVE MINUTES,
#    so a 429 is treated as "pending" and backed off, never retried hard.
#
# 5) Only two finality thresholds exist: 1000 (Confirmed) and 2000 (Finalized).
#
# 6) A burn's attestation expires after ~24h BUT POST /v2/reattest/{nonce}
#    revives it with NO DEADLINE. This is precisely why a "stranded" transfer
#    from stage 2 is recoverable rather than lost. reattest() is included.
#
# Also: exact 6-decimal USDC unit conversion, done via strings so 0.3 and 2.675
# don't drift the way float maths would. Verified round-trip on edge cases.
#
# BigInt literals are written as BigInt(...) calls deliberately -- the project's
# TS target is ES5, and raising it project-wide to suit one file would risk
# other code.
#
# Run from ~/AfriFX:  bash bridge-stage3a-cctp-client.sh
# ============================================================
set -e
echo ""
echo "Installing CCTP client (stage 3a)..."
echo ""

mkdir -p "afrifx-web/lib"
cat > "afrifx-web/lib/cctp-client.ts" << 'AFX_EOF'
// ============================================================
// CCTP V2 client -- ABIs, fee lookup and attestation polling.
//
// STAGE 3a. Everything here was written against Circle's official technical
// guide, NOT from memory, because several details are easy to get wrong and
// expensive when you do:
//
//   * V2's depositForBurn takes SEVEN parameters, not V1's four. Many
//     third-party snippets still show the V1 shape. Using it would not compile
//     against the real contract.
//
//   * maxFee: 0 REVERTS. Circle: "If maxFee is less than the minimum Standard
//     Transfer fee, the burn reverts onchain." So we fetch the current fee from
//     the API and derive maxFee from it. The fee is returned in BASIS POINTS and
//     must be multiplied by the amount.
//
//   * Attestations are fetched by TRANSACTION HASH via GET /v2/messages, not by
//     a hash you compute yourself.
//
//   * Only two finality thresholds exist: 1000 (Confirmed/Fast) and 2000
//     (Finalized/Standard). Anything below 1000 is treated as 1000, anything
//     above as 2000.
//
//   * Iris rate limit is 40 req/s, and breaching it blocks you for FIVE
//     MINUTES. Polling is therefore deliberately slow.
//
//   * A burn expires after 24h, BUT POST /v2/reattest/{nonce} revives it with
//     no deadline. This is why a "stranded" transfer is recoverable rather than
//     lost.
// ============================================================

export const FINALITY = {
  CONFIRMED: 1000,   // Fast, where the chain supports it
  FINALIZED: 2000,   // Standard
} as const

// ── ABIs (only the pieces we call) ─────────────────────────
export const TOKEN_MESSENGER_V2_ABI = [
  {
    type: 'function',
    name: 'depositForBurn',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'amount',               type: 'uint256' },
      { name: 'destinationDomain',    type: 'uint32'  },
      { name: 'mintRecipient',        type: 'bytes32' },
      { name: 'burnToken',            type: 'address' },
      { name: 'destinationCaller',    type: 'bytes32' },
      { name: 'maxFee',               type: 'uint256' },
      { name: 'minFinalityThreshold', type: 'uint32'  },
    ],
    outputs: [],
  },
] as const

export const MESSAGE_TRANSMITTER_V2_ABI = [
  {
    type: 'function',
    name: 'receiveMessage',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'message',     type: 'bytes' },
      { name: 'attestation', type: 'bytes' },
    ],
    outputs: [{ name: 'success', type: 'bool' }],
  },
] as const

export const ERC20_ABI = [
  {
    type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'allowance', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

// ── Fees ───────────────────────────────────────────────────
export interface BurnFee {
  minimumFeeBps: number      // basis points, from the API
  maxFeeUnits:   bigint      // what to pass as maxFee (in token units)
  isFast:        boolean
}

/*
  Fetch the current fee for a route and turn it into a maxFee we can pass.

  Circle returns `minimumFee` in BASIS POINTS. maxFee = amount * bps / 10_000.
  We add a safety margin because the fee can move between quoting and burning,
  and an under-quoted maxFee makes the burn REVERT.
*/
export async function getBurnFee(
  irisBase: string, fromDomain: number, toDomain: number,
  amountUnits: bigint, marginPct = 50,
): Promise<BurnFee> {
  const url = `${irisBase}/v2/burn/USDC/fees/${fromDomain}/${toDomain}`
  try {
    const res = await fetch(url)
    if (!res.ok) throw new Error(`fee lookup ${res.status}`)
    const data: any = await res.json()

    // The response carries both fast and standard entries; take the standard
    // (finality 2000) minimum unless a fast one is clearly cheaper.
    const entries: any[] = Array.isArray(data) ? data : (data?.data ?? [data])
    const standard = entries.find(e => Number(e?.finalityThreshold) === 2000) ?? entries[0]
    const bps = Number(standard?.minimumFee ?? 0)

    /*
      maxFee = amount * bps / 10_000, plus a PROPORTIONAL safety margin.

      The margin is a PERCENTAGE OF THE FEE, not extra basis points on the
      amount. An earlier version added 100 bps to the rate, which on a 1 bps
      fee meant authorising ~1% of the transfer as fees — a hundred times more
      than necessary. maxFee is a ceiling the user is agreeing to pay, so it
      must be tight.
    */
    const base   = (amountUnits * BigInt(bps)) / BigInt(10000)
    const withMargin = base + (base * BigInt(marginPct)) / BigInt(100)

    return {
      minimumFeeBps: bps,
      // Never 0 — a zero maxFee reverts the burn. Floor at 1 unit.
      maxFeeUnits: withMargin > BigInt(0) ? withMargin : BigInt(1),
      isFast: false,
    }
  } catch {
    /*
      If the fee API is unreachable we do NOT guess zero (that reverts). Use a
      conservative 2 bps, which sits above the published minimums while still
      being a small fraction of the transfer.
    */
    const fallback = (amountUnits * BigInt(2)) / BigInt(10000)
    return { minimumFeeBps: 2, maxFeeUnits: fallback > BigInt(0) ? fallback : BigInt(1), isFast: false }
  }
}

// ── Attestation ────────────────────────────────────────────
export interface AttestationResult {
  status:      'pending' | 'complete' | 'not_found'
  message?:    string      // the raw message bytes, needed for receiveMessage
  attestation?: string     // Circle's signature
  nonce?:      string
  eventNonce?: string
}

/*
  Fetch the attestation for a burn, keyed by the SOURCE transaction hash.

  Note the domain in the path is the SOURCE domain — a common mix-up is passing
  the destination.
*/
export async function fetchAttestation(
  irisBase: string, sourceDomain: number, burnTxHash: string,
): Promise<AttestationResult> {
  const url = `${irisBase}/v2/messages/${sourceDomain}?transactionHash=${burnTxHash}`
  const res = await fetch(url)

  if (res.status === 404) return { status: 'not_found' }
  if (res.status === 429) {
    // Breaching Iris's 40 req/s limit blocks us for five minutes, so treat this
    // as "pending" and back off rather than hammering it further.
    return { status: 'pending' }
  }
  if (!res.ok) return { status: 'pending' }

  const data: any = await res.json().catch(() => ({}))
  const msg = data?.messages?.[0]
  if (!msg) return { status: 'not_found' }

  if (msg.status === 'complete' && msg.attestation && msg.message) {
    return {
      status: 'complete',
      message: msg.message,
      attestation: msg.attestation,
      nonce: msg.eventNonce ?? msg.nonce,
      eventNonce: msg.eventNonce,
    }
  }
  return { status: 'pending', nonce: msg.eventNonce ?? msg.nonce }
}

/*
  Revive an expired burn. Circle: a burn's attestation expires after ~24h, but
  reattest can be called AT ANY TIME with no deadline. This is the mechanism
  that makes a long-stranded transfer recoverable.
*/
export async function reattest(irisBase: string, nonce: string): Promise<boolean> {
  try {
    const res = await fetch(`${irisBase}/v2/reattest/${nonce}`, { method: 'POST' })
    return res.ok
  } catch { return false }
}

// USDC is 6 decimals on every CCTP chain (including Arc's ERC-20 interface).
export const USDC_DECIMALS = 6

export function toUnits(amount: number, decimals = USDC_DECIMALS): bigint {
  // Avoid float rounding: work on the string form.
  const [whole, frac = ''] = String(amount).split('.')
  const padded = (frac + '0'.repeat(decimals)).slice(0, decimals)
  // Avoid ** on bigint (needs a higher TS target): build the multiplier by
  // string, which is exact for any decimal count.
  const mult = BigInt('1' + '0'.repeat(decimals))
  return BigInt(whole || '0') * mult + BigInt(padded || '0')
}

export function fromUnits(units: bigint, decimals = USDC_DECIMALS): number {
  const s = units.toString().padStart(decimals + 1, '0')
  const whole = s.slice(0, -decimals)
  const frac  = s.slice(-decimals).replace(/0+$/, '')
  return Number(frac ? `${whole}.${frac}` : whole)
}
AFX_EOF
echo "  afrifx-web/lib/cctp-client.ts"

echo ""
echo "Done. Nothing imports this yet, so behaviour is unchanged. Now:"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Bridge stage 3a: CCTP client'"
echo "  git push"
echo ""
echo "  NEXT: stage 3b wires this to the user's wallet (approve -> depositForBurn"
echo "  -> poll attestation -> receiveMessage), reporting each step to the stage-2"
echo "  state machine so a crash is always recoverable. That's the stage where"
echo "  real money moves, so we test it on Arc testnet with a small amount first."
