// ============================================================
// Flutterwave v4 OAuth 2.0 token manager.
//
// v4 uses client-credentials OAuth, not a static secret key: you exchange
// CLIENT_ID + CLIENT_SECRET for a Bearer token that EXPIRES. Fetching a new
// token on every request would get us rate-limited, so we cache it and refresh
// shortly before it expires.
// ============================================================

const TOKEN_URL =
  'https://idp.flutterwave.com/realms/flutterwave/protocol/openid-connect/token'

// Sandbox by default. Set FLUTTERWAVE_ENV=production to go live.
export const FLW_BASE_URL =
  process.env.FLUTTERWAVE_ENV === 'production'
    ? 'https://api.flutterwave.cloud/f4b/production'
    : 'https://developersandbox-api.flutterwave.com'

export const FLW_IS_SANDBOX = process.env.FLUTTERWAVE_ENV !== 'production'

interface CachedToken { token: string; expiresAt: number }
let cached: CachedToken | null = null
let inFlight: Promise<string> | null = null

// Refresh this many seconds BEFORE the token actually expires.
const SKEW_SECONDS = 60

export function flutterwaveConfigured(): boolean {
  return !!(process.env.FLUTTERWAVE_CLIENT_ID && process.env.FLUTTERWAVE_CLIENT_SECRET)
}

export async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)

  if (cached && cached.expiresAt - SKEW_SECONDS > now) return cached.token
  // Collapse concurrent refreshes into one request.
  if (inFlight) return inFlight

  const clientId     = process.env.FLUTTERWAVE_CLIENT_ID
  const clientSecret = process.env.FLUTTERWAVE_CLIENT_SECRET
  if (!clientId || !clientSecret) {
    throw new Error('Flutterwave is not configured (FLUTTERWAVE_CLIENT_ID / FLUTTERWAVE_CLIENT_SECRET)')
  }

  inFlight = (async () => {
    try {
      const body = new URLSearchParams({
        client_id:     clientId,
        client_secret: clientSecret,
        grant_type:    'client_credentials',
      })

      const res = await fetch(TOKEN_URL, {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body:    body.toString(),
      })

      const data: any = await res.json().catch(() => ({}))
      if (!res.ok || !data?.access_token) {
        throw new Error(
          `Flutterwave auth failed: ${data?.error_description ?? data?.error ?? res.status}`)
      }

      const ttl = Number(data.expires_in ?? 600)
      cached = {
        token:     data.access_token,
        expiresAt: Math.floor(Date.now() / 1000) + ttl,
      }
      return cached.token
    } finally {
      inFlight = null
    }
  })()

  return inFlight
}

// For tests / forced refresh.
export function _clearTokenCache() { cached = null; inFlight = null }
