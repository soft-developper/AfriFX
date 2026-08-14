'use client'

/**
 * Provisioning the user's wallet.
 *
 * Three steps, because the user must consent on their own device:
 *   1. ask our API to start it, getting a challengeId from Circle
 *   2. run the challenge in the browser, where the user approves and
 *      their keyshare is generated locally
 *   3. ask our API to read the wallet back and store the address
 *
 * Step 3 can return "not ready": Circle indexes the new wallet
 * asynchronously, so a short poll is expected rather than exceptional.
 */

import { executeChallenge } from '@/lib/circle'
import { apiFetch, persistSession, getToken, type Account } from '@/hooks/useAuth'

/** How long to wait for Circle to index the new wallet before giving up. */
const SYNC_ATTEMPTS   = 6
const SYNC_DELAY_MS   = 1500

export interface ProvisionResult {
  account: Account
  blockchain: string
}

export async function provisionWallet(
  userToken: string,
  encryptionKey: string,
  onStep?: (message: string) => void,
): Promise<ProvisionResult> {
  onStep?.('Setting up your wallet')

  const initRes = await apiFetch('/auth/wallet/initialize', {
    method: 'POST',
    body:   JSON.stringify({ userToken }),
  })
  const init = await initRes.json().catch(() => ({}))
  if (!initRes.ok) throw new Error(init.error ?? 'Could not start wallet setup')

  // No challenge means the wallet already exists, e.g. the user refreshed
  // mid-flow or is signing up again on another device. Skip to reading it.
  if (init.challengeId) {
    onStep?.('Confirm in the window to finish')
    await executeChallenge(init.challengeId, userToken, encryptionKey)
  }

  onStep?.('Finishing up')

  for (let attempt = 0; attempt < SYNC_ATTEMPTS; attempt++) {
    const res  = await apiFetch('/auth/wallet/sync', {
      method: 'POST',
      body:   JSON.stringify({ userToken }),
    })
    const data = await res.json().catch(() => ({}))

    if (res.ok && data.ready) {
      const token = getToken()
      if (token) persistSession(token, data.account as Account)

      // Add the CCTP bridge chains so a future bridge can mint on the
      // destination. Best-effort: the Arc wallet is already live and the
      // account is active, so a hiccup here must NOT block sign-in. Bridging
      // can add any missing chain on demand later.
      await addBridgeChains(userToken, encryptionKey, onStep).catch(() => {})

      return { account: data.account as Account, blockchain: data.blockchain }
    }

    // 202 means "still being created"; anything else is a real failure.
    if (res.status !== 202) {
      throw new Error(data.error ?? 'Could not finish setting up your wallet')
    }
    await new Promise(r => setTimeout(r, SYNC_DELAY_MS))
  }

  throw new Error(
    'Your wallet is taking longer than usual to appear. It may still be created \u2014 sign in again in a moment to check.',
  )
}

/**
 * Add the CCTP bridge chains to the freshly created wallet.
 *
 * A bridge mints on the DESTINATION chain, which the user's wallet must
 * already exist on. Circle gives every EVM chain the same address, but each
 * one is added once - we do that here, at sign-up, so bridging is seamless
 * later instead of pausing mid-transfer to add a chain.
 *
 * One extra device approval: the server asks Circle to add the chains and
 * returns a challengeId, the user confirms it in the window, done. When every
 * chain already exists (a repeated sign-in) the server returns no challenge
 * and we return immediately.
 *
 * Deliberately allowed to throw - the caller treats any failure as non-fatal,
 * because the Arc wallet already works and missing chains can be added on
 * demand at bridge time.
 */
export async function addBridgeChains(
  userToken: string,
  encryptionKey: string,
  onStep?: (message: string) => void,
): Promise<void> {
  const res = await apiFetch('/auth/wallet/add-chains', {
    method: 'POST',
    body:   JSON.stringify({ userToken }),
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error ?? 'Could not add bridge chains')

  // No challenge means every chain already exists; nothing to approve.
  if (data.challengeId) {
    onStep?.('Confirm in the window to enable bridging')
    await executeChallenge(data.challengeId, userToken, encryptionKey)
  }
}
