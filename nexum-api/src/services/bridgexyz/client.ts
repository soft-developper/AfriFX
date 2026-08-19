// ============================================================
// Bridge.xyz API client (fiat on/off-ramp provider).
//
// Bridge is a DIFFERENT infrastructure from the HoneyCoin/Flutterwave payout
// model in services/ramp/, so it lives in its own module (services/bridgexyz/)
// and is NOT wired through the FiatRampProvider interface. It owns its own
// customer/KYC lifecycle and its persistent rails (virtual accounts for
// on-ramp, liquidation addresses for off-ramp).
//
// NOTE ON NAMING: the word "bridge" already means the CCTP cross-chain bridge
// in this codebase (routes/bridge.ts, services/bridge/, /bridge nav). This
// module is Bridge.xyz the FIAT RAMP. User-facing it is called "On/Off-ramp"
// and lives at /ramp — never "bridge" — to avoid confusion with CCTP.
//
// Phase 0 scope: config gate + a typed fetch helper + a read-only ping so we
// can prove the sandbox key works from Render. No customer creation, no DB,
// no UI. Everything here is inert unless BRIDGE_API_KEY is set.
// ============================================================

import { randomUUID } from 'crypto'

// Sandbox by default. Set BRIDGE_ENV=production to go live.
export const BRIDGE_IS_SANDBOX = process.env.BRIDGE_ENV !== 'production'

// Base host. BRIDGE_BASE_URL can override (e.g. a proxy); otherwise derived
// from BRIDGE_ENV. The /v0 API version segment is appended by bridgeFetch.
export const BRIDGE_BASE_URL =
  process.env.BRIDGE_BASE_URL ??
  (BRIDGE_IS_SANDBOX ? 'https://api.sandbox.bridge.xyz' : 'https://api.bridge.xyz')

export const BRIDGE_API_VERSION = 'v0'

/** True only when an API key is present, so the app is safe with no .env. */
export function bridgeXyzConfigured(): boolean {
  return !!process.env.BRIDGE_API_KEY
}

export class BridgeApiError extends Error {
  status: number
  body: unknown
  constructor(message: string, status: number, body?: unknown) {
    super(message)
    this.name = 'BridgeApiError'
    this.status = status
    this.body = body
  }
}

interface BridgeFetchOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE'
  /** JSON body for POST/PUT. */
  body?: unknown
  /**
   * Idempotency key for mutating calls. Bridge REQUIRES one on every POST.
   * Omit for GETs. If a mutating call is made without one, we generate a UUID
   * — but callers that need safe retries should pass their OWN stored key.
   */
  idempotencyKey?: string
  /** Extra query params. */
  query?: Record<string, string | number | undefined>
}

/**
 * Typed fetch against the Bridge API. Adds Api-Key + Idempotency-Key headers,
 * builds the /v0 URL, and throws BridgeApiError on non-2xx with the parsed
 * body so callers can inspect Bridge's error shape.
 */
export async function bridgeFetch<T = unknown>(
  path: string, opts: BridgeFetchOptions = {},
): Promise<T> {
  const apiKey = process.env.BRIDGE_API_KEY
  if (!apiKey) {
    throw new BridgeApiError('Bridge is not configured (BRIDGE_API_KEY missing)', 500)
  }

  const method = opts.method ?? 'GET'
  const cleanPath = path.startsWith('/') ? path.slice(1) : path

  const url = new URL(`${BRIDGE_BASE_URL}/${BRIDGE_API_VERSION}/${cleanPath}`)
  if (opts.query) {
    for (const [k, v] of Object.entries(opts.query)) {
      if (v !== undefined) url.searchParams.set(k, String(v))
    }
  }

  const headers: Record<string, string> = {
    'Api-Key': apiKey,
    'Accept': 'application/json',
  }
  let bodyStr: string | undefined
  if (method !== 'GET') {
    headers['Content-Type'] = 'application/json'
    headers['Idempotency-Key'] = opts.idempotencyKey ?? randomUUID()
    bodyStr = JSON.stringify(opts.body ?? {})
  }

  let res: Response
  try {
    res = await fetch(url.toString(), { method, headers, body: bodyStr })
  } catch (err: any) {
    throw new BridgeApiError(`Bridge request failed: ${err?.message ?? 'network error'}`, 502)
  }

  const text = await res.text()
  let parsed: unknown = undefined
  if (text) {
    try { parsed = JSON.parse(text) } catch { parsed = text }
  }

  if (!res.ok) {
    const msg =
      (parsed && typeof parsed === 'object' && 'message' in (parsed as any)
        ? String((parsed as any).message)
        : `Bridge API error ${res.status}`)
    throw new BridgeApiError(msg, res.status, parsed)
  }

  return parsed as T
}

/**
 * Read-only reachability check for the smoke test. Lists customers with a
 * page size of 1: proves the key authenticates and the host is reachable
 * without creating anything. Returns a small summary, never the customer data.
 */
export async function bridgePing(): Promise<{ ok: true; reachable: true }> {
  // The customers list is the simplest authenticated read. We ignore the
  // payload entirely — a 2xx is all we need to confirm the key works.
  await bridgeFetch('customers', { method: 'GET', query: { limit: 1 } })
  return { ok: true, reachable: true }
}
