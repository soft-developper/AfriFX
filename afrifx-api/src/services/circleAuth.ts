/**
 * Verifying a Circle user session.
 *
 * Circle is our identity provider. The browser authenticates with
 * Google or an email OTP via the Web SDK and receives a `userToken`
 * (valid 60 minutes). The browser sends that token to us; we call
 * Circle with it to (a) prove it is genuine and unexpired and
 * (b) learn the stable Circle user id behind it.
 *
 * The token must never be trusted without this round trip: it arrives
 * from the client and is otherwise just an opaque string.
 */

import { randomUUID } from 'crypto'

const CIRCLE_BASE_URL = process.env.CIRCLE_BASE_URL ?? 'https://api.circle.com'

export interface CircleUser {
  /** Stable Circle user id. This is what we store on the account. */
  id: string
  /** ENABLED once the user exists and is usable. */
  status: string
  /** UNSET until the user has created a wallet. */
  pinStatus?: string
}

export class CircleAuthError extends Error {
  constructor(message: string, readonly status: number) {
    super(message)
    this.name = 'CircleAuthError'
  }
}

/**
 * Start a social-login session.
 *
 * The Web SDK generates a deviceId in the browser; we exchange it for
 * short-lived tokens the SDK needs to run the Google OAuth handshake.
 * This has to happen server-side because it needs the API key.
 */
export async function createSocialDeviceToken(deviceId: string) {
  return circlePost('/v1/w3s/users/social/token', { deviceId })
}

/** Ask Circle to email a one-time code, and get the tokens to verify it. */
export async function requestEmailOtp(deviceId: string, email: string) {
  return circlePost('/v1/w3s/users/email/token', { deviceId, email })
}

/** Shared POST helper for the endpoints above. */
async function circlePost(path: string, body: Record<string, unknown>) {
  const apiKey = process.env.CIRCLE_API_KEY
  if (!apiKey) throw new CircleAuthError('CIRCLE_API_KEY is not configured', 500)

  let res: Response
  try {
    res = await fetch(`${CIRCLE_BASE_URL}${path}`, {
      method:  'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization:  `Bearer ${apiKey}`,
      },
      // Circle requires a unique idempotency key per request.
      body: JSON.stringify({ idempotencyKey: randomUUID(), ...body }),
    })
  } catch {
    throw new CircleAuthError('Could not reach Circle. Please try again.', 503)
  }

  const payload: any = await res.json().catch(() => ({}))
  if (!res.ok) {
    throw new CircleAuthError(payload?.message ?? 'Circle rejected the request', 502)
  }
  return payload?.data ?? {}
}

/**
 * Exchange a client-supplied userToken for the Circle user it belongs to.
 * Throws CircleAuthError if the token is missing, expired or rejected.
 */
export async function verifyUserToken(userToken: string): Promise<CircleUser> {
  if (!userToken || typeof userToken !== 'string') {
    throw new CircleAuthError('Missing Circle user token', 400)
  }

  const apiKey = process.env.CIRCLE_API_KEY
  if (!apiKey) {
    // Fail loudly: silently treating this as "unauthenticated" would let
    // a misconfigured deploy reject every login with a confusing error.
    throw new CircleAuthError('CIRCLE_API_KEY is not configured', 500)
  }

  let res: Response
  try {
    res = await fetch(`${CIRCLE_BASE_URL}/v1/w3s/user`, {
      method: 'GET',
      headers: {
        Accept:          'application/json',
        Authorization:   `Bearer ${apiKey}`,
        'X-User-Token':  userToken,
      },
    })
  } catch {
    throw new CircleAuthError('Could not reach Circle. Please try again.', 503)
  }

  const body: any = await res.json().catch(() => ({}))

  if (!res.ok) {
    // 401/403 from Circle means the token is bad or expired, which is a
    // client problem; anything else is Circle's problem, not the user's.
    if (res.status === 401 || res.status === 403) {
      throw new CircleAuthError('Your sign-in session expired. Please sign in again.', 401)
    }
    throw new CircleAuthError(body?.message ?? 'Circle rejected the session', 502)
  }

  const user = body?.data
  if (!user?.id) {
    throw new CircleAuthError('Circle returned no user for this session', 502)
  }

  return { id: String(user.id), status: String(user.status ?? ''), pinStatus: user.pinStatus }
}
