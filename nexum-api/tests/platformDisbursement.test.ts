import { describe, it, expect, beforeEach, afterEach } from 'vitest'

// These tests verify the guard behavior only - that the service refuses to act
// without configuration - WITHOUT making any network calls to Circle. The
// happy path (real provisioning / payout) is exercised manually against the
// Circle sandbox, since it moves testnet funds.

describe('platformDisbursement config guards', () => {
  const saved = { key: process.env.CIRCLE_API_KEY, secret: process.env.CIRCLE_ENTITY_SECRET }

  beforeEach(() => {
    delete process.env.CIRCLE_API_KEY
    delete process.env.CIRCLE_ENTITY_SECRET
  })
  afterEach(() => {
    if (saved.key)    process.env.CIRCLE_API_KEY = saved.key
    else              delete process.env.CIRCLE_API_KEY
    if (saved.secret) process.env.CIRCLE_ENTITY_SECRET = saved.secret
    else              delete process.env.CIRCLE_ENTITY_SECRET
  })

  it('provisioning throws a clear error when the entity secret is missing', async () => {
    process.env.CIRCLE_API_KEY = 'test-key'
    const { provisionDisbursementWallet } = await import('../src/services/platformDisbursement')
    await expect(provisionDisbursementWallet()).rejects.toThrow(/CIRCLE_ENTITY_SECRET/)
  })

  it('a payout throws a clear error when the API key is missing', async () => {
    process.env.CIRCLE_ENTITY_SECRET = 'test-secret'
    const { sendUsdc } = await import('../src/services/platformDisbursement')
    await expect(sendUsdc({
      walletId: 'w', destinationAddress: '0xabc', amount: 1,
    })).rejects.toThrow(/CIRCLE_API_KEY/)
  })
})
