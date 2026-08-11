/**
 * Choosing which wallet to record on an account.
 *
 * Circle can return wallets on several chains and makes no promise about
 * ordering, so `wallets[0]` is a real bug waiting to happen: it would
 * silently record a Base address as the user's Arc address, and every
 * balance and transfer after that would look at the wrong place.
 */

import { describe, it, expect } from 'vitest'
import { pickPrimaryWallet, cctpBlockchainFor, missingBridgeChains, type CircleWallet } from '../src/services/circleWallets'

const w = (blockchain: string, address = '0x' + blockchain.length.toString().repeat(4), state?: string): CircleWallet =>
  ({ id: `id-${blockchain}`, address, blockchain, state })

describe('pickPrimaryWallet', () => {
  it('returns null when there are no wallets yet', () => {
    // Normal shortly after the challenge: Circle indexes asynchronously.
    expect(pickPrimaryWallet([], 'ARC-TESTNET')).toBeNull()
    expect(pickPrimaryWallet(undefined as any, 'ARC-TESTNET')).toBeNull()
  })

  it('returns the only wallet when there is one', () => {
    const only = w('ARC-TESTNET')
    expect(pickPrimaryWallet([only], 'ARC-TESTNET')).toBe(only)
  })

  // The case that makes wallets[0] wrong.
  it('picks the configured chain even when it is not first', () => {
    const wallets = [w('BASE-SEPOLIA'), w('MATIC-AMOY'), w('ARC-TESTNET')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('ARC-TESTNET')
  })

  it('matches the chain case-insensitively', () => {
    const wallets = [w('arc-testnet')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')).not.toBeNull()
  })

  it('follows the configured chain, so switching home chains needs no code change', () => {
    const wallets = [w('ARC-TESTNET'), w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'BASE-SEPOLIA')!.blockchain).toBe('BASE-SEPOLIA')
  })

  // Better to record something usable than to leave the account with no
  // address at all, which would block the user entirely.
  it('falls back to another wallet when the configured chain is absent', () => {
    const wallets = [w('BASE-SEPOLIA')]
    expect(pickPrimaryWallet(wallets, 'ARC-TESTNET')!.blockchain).toBe('BASE-SEPOLIA')
  })

  it('skips wallets with no address', () => {
    const good = w('BASE-SEPOLIA')
    const bad  = { id: 'x', address: '', blockchain: 'ARC-TESTNET' } as CircleWallet
    expect(pickPrimaryWallet([bad, good], 'ARC-TESTNET')).toBe(good)
  })

  it('skips frozen wallets rather than recording an unusable address', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    const live   = w('BASE-SEPOLIA', '0xlive')
    expect(pickPrimaryWallet([frozen, live], 'ARC-TESTNET')).toBe(live)
  })

  it('returns null when every wallet is unusable', () => {
    const frozen = w('ARC-TESTNET', '0xfrozen', 'FROZEN')
    expect(pickPrimaryWallet([frozen], 'ARC-TESTNET')).toBeNull()
  })
})

/**
 * Mapping app chain keys to Circle's blockchain enum.
 *
 * The classic CCTP integration bug is confusing Polygon's key "polygon"
 * with Circle's code, which is MATIC-AMOY on testnet — not "POLYGON".
 * These lock the mapping so a rename can't silently break a bridge route.
 */
describe('cctpBlockchainFor', () => {
  it('maps every supported testnet chain key', () => {
    expect(cctpBlockchainFor('arc')).toBe('ARC-TESTNET')
    expect(cctpBlockchainFor('base')).toBe('BASE-SEPOLIA')
    expect(cctpBlockchainFor('ethereum')).toBe('ETH-SEPOLIA')
    expect(cctpBlockchainFor('arbitrum')).toBe('ARB-SEPOLIA')
    expect(cctpBlockchainFor('polygon')).toBe('MATIC-AMOY')
  })
  it('returns null for an unknown key', () => {
    expect(cctpBlockchainFor('solana')).toBeNull()
    expect(cctpBlockchainFor('')).toBeNull()
  })
})

/**
 * Which bridge chains still need adding for a given wallet set.
 * Only the missing ones, case-insensitive, so re-running provisioning
 * never asks Circle to recreate a chain that already exists.
 */
describe('missingBridgeChains', () => {
  it('returns the chains not present, case-insensitively', () => {
    const have = [w('ARC-TESTNET'), w('base-sepolia')]
    expect(missingBridgeChains(have, ['BASE-SEPOLIA', 'ETH-SEPOLIA']))
      .toEqual(['ETH-SEPOLIA'])
  })
  it('returns nothing when all chains already exist', () => {
    const have = [w('BASE-SEPOLIA'), w('ETH-SEPOLIA')]
    expect(missingBridgeChains(have, ['BASE-SEPOLIA', 'ETH-SEPOLIA'])).toEqual([])
  })
  it('returns all wanted chains when the set is empty', () => {
    expect(missingBridgeChains([], ['BASE-SEPOLIA', 'ETH-SEPOLIA']))
      .toEqual(['BASE-SEPOLIA', 'ETH-SEPOLIA'])
  })
})
