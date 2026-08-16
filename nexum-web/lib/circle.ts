'use client'

/**
 * Circle Web SDK wrapper.
 *
 * The SDK is browser-only and pulls in Node built-ins, so it is always
 * loaded with a dynamic import inside a client component. Importing it
 * at module scope breaks the Next.js server build.
 *
 * Social login sends the browser away to Google and back, which wipes
 * React state. The tokens needed to finish the handshake are therefore
 * kept in cookies, not state, so they survive the round trip.
 */

import { setCookie, getCookie, deleteCookie } from 'cookies-next'

const API    = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const APP_ID = process.env.NEXT_PUBLIC_CIRCLE_APP_ID ?? ''
const GOOGLE = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ?? ''

const COOKIE = {
  deviceToken:   'circle_device_token',
  encryptionKey: 'circle_device_encryption_key',
  /** Set when the user came from the sign-up form, so we know where to send them back. */
  intent:        'circle_auth_intent',
} as const

/**
 * Where Google sends the browser back to.
 *
 * This must be the sign-in page, NOT the site root. The root is the
 * landing page, and the SDK callback that finishes the handshake only
 * exists on /signin - returning to '/' silently drops the login and
 * leaves the user looking at the marketing page.
 *
 * Whatever this returns must also be listed in Google Cloud Console
 * under Authorized redirect URIs, exactly.
 */
export function signInUrl(): string {
  if (typeof window === 'undefined') return ''
  return `${window.location.origin}/signin`
}

export type AuthIntent = 'signin' | 'signup'

export interface CircleLoginResult {
  userToken:     string
  encryptionKey: string
  /**
   * Email from the social provider, when it gives us one.
   *
   * Google returns this in oAuthInfo.socialUserInfo. Without it a
   * Google sign-in creates an account with no address, so welcome mail,
   * invoice reminders and trade alerts have nowhere to go.
   */
  email?:        string
  /** Display name from the provider, used to prefill the profile form. */
  name?:         string
}

/** Cached SDK instance. One per page load is enough. */
let sdk: any = null
let deviceIdCache: string | null = null

/**
 * Get (and cache) the SDK. `onLogin` fires after a social redirect
 * completes, which is why it must be supplied at construction time
 * rather than at the moment the button is clicked.
 */
export async function getSdk(
  onLogin?: (err: unknown, result: CircleLoginResult | null) => void,
): Promise<any> {
  if (sdk) return sdk

  const { W3SSdk } = await import('@circle-fin/w3s-pw-web-sdk')

  sdk = new W3SSdk(
    {
      appSettings:  { appId: APP_ID },
      loginConfigs: {
        deviceToken:         (getCookie(COOKIE.deviceToken) as string) ?? '',
        deviceEncryptionKey: (getCookie(COOKIE.encryptionKey) as string) ?? '',
        google: {
          clientId:            GOOGLE,
          redirectUri:         typeof window !== 'undefined' ? signInUrl() : '',
          selectAccountPrompt: true,
        },
      },
    },
    (err: unknown, result: any) => {
      if (!onLogin) return
      if (err || !result?.userToken) return onLogin(err ?? new Error('Sign-in failed'), null)
      const social = result?.oAuthInfo?.socialUserInfo
      onLogin(null, {
        userToken:     result.userToken,
        encryptionKey: result.encryptionKey,
        email:         social?.email,
        name:          social?.name,
      })
    },
  )

  return sdk
}

/**
 * The SDK's device id identifies this browser to Circle.
 *
 * Without calling getDeviceId() first, challenge execution silently does
 * nothing, so this is always fetched before anything else.
 */
export async function getDeviceId(): Promise<string> {
  if (deviceIdCache) return deviceIdCache

  const cached = localStorage.getItem('circle_device_id')
  if (cached) { deviceIdCache = cached; return cached }

  const instance = await getSdk()
  const id: string = await instance.getDeviceId()
  localStorage.setItem('circle_device_id', id)
  deviceIdCache = id
  return id
}

/** Start Google sign-in. The browser leaves the page and comes back. */
export async function startGoogleLogin(intent: AuthIntent): Promise<void> {
  const deviceId = await getDeviceId()

  const res = await fetch(`${API}/auth/circle/device-token`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ deviceId }),
  })
  if (!res.ok) {
    throw new Error((await res.json().catch(() => ({}))).error ?? 'Could not start Google sign-in')
  }
  const { deviceToken, deviceEncryptionKey } = await res.json()

  // Survive the OAuth redirect.
  setCookie(COOKIE.deviceToken, deviceToken)
  setCookie(COOKIE.encryptionKey, deviceEncryptionKey)
  setCookie(COOKIE.intent, intent)

  const instance = await getSdk()
  instance.updateConfigs({
    appSettings:  { appId: APP_ID },
    loginConfigs: {
      deviceToken,
      deviceEncryptionKey,
      google: {
        clientId:            GOOGLE,
        redirectUri:         signInUrl(),
        selectAccountPrompt: true,
      },
    },
  })

  const { SocialLoginProvider } = await import('@circle-fin/w3s-pw-web-sdk/dist/src/types')
  instance.performLogin(SocialLoginProvider.GOOGLE)
}

/** Ask Circle to email a code. Returns nothing; the code arrives by email. */
export async function sendEmailCode(email: string): Promise<void> {
  const deviceId = await getDeviceId()

  const res = await fetch(`${API}/auth/circle/email-otp`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ deviceId, email }),
  })
  if (!res.ok) {
    throw new Error((await res.json().catch(() => ({}))).error ?? 'Could not send the code')
  }
  const { deviceToken, deviceEncryptionKey, otpToken } = await res.json()

  const instance = await getSdk()
  instance.updateConfigs({
    appSettings:  { appId: APP_ID },
    loginConfigs: { deviceToken, deviceEncryptionKey, otpToken, email: { email } },
  })
}

/** Open Circle's hosted code-entry window. Result arrives via the getSdk callback. */
export async function openCodeEntry(): Promise<void> {
  const instance = await getSdk()
  instance.verifyOtp()
}

/** Which flow the user was in before a social redirect took them away. */
export function consumeIntent(): AuthIntent | null {
  const v = getCookie(COOKIE.intent) as AuthIntent | undefined
  return v === 'signin' || v === 'signup' ? v : null
}

/**
 * Run a Circle challenge and wait for the user to approve it.
 *
 * Wallet creation happens here, on the user's device. Their keyshare is
 * generated locally and never reaches our servers, which is what makes
 * the wallet user-controlled rather than custodial.
 *
 * setAuthentication must be called first or execute silently does nothing.
 */
export async function executeChallenge(
  challengeId: string, userToken: string, encryptionKey: string,
): Promise<void> {
  const instance = await getSdk()
  // Circle's SDK no-ops execute() until the device id is fetched.
  // Login primes it, but a user with a live session can reach a
  // signing screen without logging in this tab — prime it here so
  // the challenge callback actually fires.
  await getDeviceId()
  instance.setAuthentication({ userToken, encryptionKey })

  await new Promise<void>((resolve, reject) => {
    instance.execute(challengeId, (err: any) => {
      if (err) reject(new Error(err?.message ?? 'You cancelled the request'))
      else resolve()
    })
  })
}

/**
 * Like executeChallenge, but returns the SIGNATURE the challenge produced.
 *
 * SIGN_TYPEDDATA / SIGN_MESSAGE challenges yield a signature in the execute
 * result (result.data.signature). executeChallenge throws that away because
 * transfers/contract calls don't need it; Gateway burn intents do, so this
 * variant surfaces it. Same PIN/confirm UX, different return.
 */
export async function executeSigningChallenge(
  challengeId: string, userToken: string, encryptionKey: string,
): Promise<string> {
  const instance = await getSdk()
  // Circle's SDK no-ops execute() until the device id is fetched.
  // Login primes it, but a user with a live session can reach a
  // signing screen without logging in this tab — prime it here so
  // the challenge callback actually fires.
  await getDeviceId()
  instance.setAuthentication({ userToken, encryptionKey })

  return new Promise<string>((resolve, reject) => {
    instance.execute(challengeId, (err: any, result: any) => {
      if (err) { reject(new Error(err?.message ?? 'You cancelled the request')); return }
      const sig = result?.data?.signature ?? result?.signature
      if (!sig) { reject(new Error('No signature was returned by the wallet.')); return }
      resolve(String(sig))
    })
  })
}

/** Clear the handshake cookies once we no longer need them. */
export function clearAuthCookies(): void {
  deleteCookie(COOKIE.deviceToken)
  deleteCookie(COOKIE.encryptionKey)
  deleteCookie(COOKIE.intent)
}

/** True when the app has the config it needs to talk to Circle at all. */
export const circleConfigured = () => Boolean(APP_ID)
