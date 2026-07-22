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
