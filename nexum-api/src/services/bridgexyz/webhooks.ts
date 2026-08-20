// ============================================================
// Bridge.xyz webhook signature verification + event parsing.
//
// Bridge signs every webhook with RSA-SHA256 using a PER-ENDPOINT public key
// (returned when you create/enable the webhook). There is NO HMAC shared
// secret. Verification steps, taken verbatim from Bridge's official docs and
// their TypeScript sample (apidocs.bridge.xyz/.../webhooks/signature and
// /setting-up-webhooks):
//
//   1. Header: X-Webhook-Signature: t=<ms_timestamp>,v0=<base64_signature>
//   2. signedPayload = `${timestamp}.${rawBody}`
//   3. digest = SHA256(signedPayload)                       ← first hash
//   4. verify: RSA-SHA256 over `digest` with the public key ← hashes digest AGAIN
//
// ⚠ The digest is effectively DOUBLE-HASHED: we compute a SHA256 digest, then
// hand THAT 32-byte digest to an RSA-SHA256 verifier (which hashes its input a
// second time). This matches Bridge's own TS/Python/Java/Go samples — they all
// pass the pre-computed digest to the verifier. Passing the raw signedPayload
// instead would hash only once and every signature would fail.
//
// ⚠ MUST verify against the RAW request bytes, not a re-serialized object —
// key order / spacing / unicode escaping would differ. index.ts already
// captures req.rawBody via the express.json({ verify }) hook.
// ============================================================

import crypto from 'crypto'

/** The env-configured per-endpoint public key (PEM). Empty until set. */
export function bridgeWebhookPublicKey(): string {
  const raw = process.env.BRIDGE_WEBHOOK_PUBLIC_KEY ?? ''
  // Allow the single-line form with literal "\n" (how it's stored in env UIs).
  return raw.includes('-----BEGIN')
    ? raw.replace(/\\n/g, '\n').trim()
    : ''
}

export function bridgeWebhookConfigured(): boolean {
  return bridgeWebhookPublicKey().length > 0
}

export interface BridgeWebhookEvent {
  api_version:          string
  event_id:             string
  event_category:       string
  event_type:           string
  event_object:         Record<string, unknown>
  event_object_changes?: Record<string, unknown>
  event_created_at:     string
}

export class WebhookSignatureError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'WebhookSignatureError'
  }
}

const REPLAY_TOLERANCE_MS = 10 * 60 * 1000 // 10 minutes, per Bridge's guidance

interface ParsedHeader { timestamp: string; signature: string }

function parseSignatureHeader(header: string): ParsedHeader | null {
  let timestamp = ''
  let signature = ''
  for (const part of header.split(',')) {
    const eq = part.indexOf('=')
    if (eq === -1) continue
    const key = part.slice(0, eq).trim()
    const val = part.slice(eq + 1).trim() // split on FIRST '=' — base64 '=' padding is safe
    if (key === 't') timestamp = val
    else if (key === 'v0') signature = val
  }
  if (!timestamp || !signature) return null
  return { timestamp, signature }
}

/**
 * Verify a Bridge webhook signature against the raw body. Throws
 * WebhookSignatureError on any failure (missing/old/invalid). Returns the
 * parsed timestamp on success.
 *
 * `now` is injectable for testing the replay window.
 */
export function verifyWebhookSignature(
  rawBody:         string,
  signatureHeader: string | undefined,
  publicKeyPem:    string,
  now:             number = Date.now(),
): { timestamp: number } {
  if (!signatureHeader) throw new WebhookSignatureError('Missing signature header')
  if (!publicKeyPem)     throw new WebhookSignatureError('Webhook public key not configured')

  const parsed = parseSignatureHeader(signatureHeader)
  if (!parsed) throw new WebhookSignatureError('Malformed signature header')

  const ts = Number(parsed.timestamp)
  if (!Number.isFinite(ts)) throw new WebhookSignatureError('Invalid timestamp')
  if (now - ts > REPLAY_TOLERANCE_MS) throw new WebhookSignatureError('Timestamp too old')

  // Step 2 + 3: signed payload → SHA256 digest (first hash).
  const signedPayload = `${parsed.timestamp}.${rawBody}`
  const digest = crypto.createHash('sha256').update(signedPayload).digest()

  // Step 4: RSA-SHA256 verify over the digest (verifier hashes it a 2nd time).
  let ok = false
  try {
    const verifier = crypto.createVerify('RSA-SHA256')
    verifier.update(digest)
    verifier.end()
    ok = verifier.verify(publicKeyPem, parsed.signature, 'base64')
  } catch (err: any) {
    throw new WebhookSignatureError(`Signature verification error: ${err?.message ?? 'unknown'}`)
  }
  if (!ok) throw new WebhookSignatureError('Invalid signature')

  return { timestamp: ts }
}

/** Parse the JSON body into a typed event. Throws on malformed JSON/shape. */
export function parseWebhookEvent(rawBody: string): BridgeWebhookEvent {
  let obj: any
  try {
    obj = JSON.parse(rawBody)
  } catch {
    throw new Error('Invalid webhook JSON')
  }
  if (!obj || typeof obj !== 'object' || !obj.event_id || !obj.event_type) {
    throw new Error('Webhook payload missing required fields')
  }
  return obj as BridgeWebhookEvent
}

/**
 * For a virtual_account.activity event, dig out the fields we mirror locally.
 * The event_object mirrors the /history VirtualAccountEvent shape. Returns null
 * for events we don't track (non-activity categories).
 */
export interface ActivityDetail {
  virtualAccountId: string | null
  eventType:        string | null   // funds_received | payment_submitted | payment_processed | …
  depositId:        string | null
  amount:           string | null
  currency:         string | null
  destinationTxHash: string | null
  receiptUrl:       string | null
}

export function extractActivityDetail(event: BridgeWebhookEvent): ActivityDetail | null {
  if (!/virtual_account/i.test(event.event_category)) return null
  const o = (event.event_object ?? {}) as Record<string, any>
  const receipt = (o.receipt ?? {}) as Record<string, any>
  return {
    virtualAccountId:  o.virtual_account_id ?? o.virtualAccountId ?? null,
    eventType:         o.type ?? event.event_type ?? null,
    depositId:         o.deposit_id ?? null,
    amount:            o.amount ?? null,
    currency:          o.currency ?? null,
    destinationTxHash: o.destination_tx_hash ?? receipt.destination_tx_hash ?? null,
    receiptUrl:        receipt.url ?? null,
  }
}
