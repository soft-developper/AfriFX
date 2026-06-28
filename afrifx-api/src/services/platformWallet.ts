// Platform wallet — used to call releaseP2POffer() on-chain
// Private key stored in .env — never committed to git
// This wallet must be the contract owner (deployer wallet)

import { createWalletClient, createPublicClient, http, encodeFunctionData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arcTestnet, arcClient } from './arc'

const PRIVATE_KEY   = process.env.PLATFORM_WALLET_PRIVATE_KEY as `0x${string}`
const VAULT_ADDRESS = process.env.AFRIFX_VAULT_ADDRESS as `0x${string}`

// Minimal ABI for release + cancel
const VAULT_ABI = [
  {
    type: 'function',
    name: 'releaseP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelP2POffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'offerId', type: 'bytes32' },
      { name: 'reason',  type: 'string'  },
    ],
    outputs: [],
  },
] as const

function getWalletClient() {
  if (!PRIVATE_KEY) throw new Error('PLATFORM_WALLET_PRIVATE_KEY not set in .env')
  const account = privateKeyToAccount(PRIVATE_KEY)
  return createWalletClient({
    account,
    chain:     arcTestnet,
    transport: http(process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'),
  })
}

/**
 * Release USDC to taker — called automatically when both sides confirm.
 */
export async function releasePlatform(offerId: `0x${string}`): Promise<`0x${string}`> {
  if (!VAULT_ADDRESS) throw new Error('AFRIFX_VAULT_ADDRESS not set in .env')
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      VAULT_ADDRESS,
    abi:          VAULT_ABI,
    functionName: 'releaseP2POffer',
    args:         [offerId],
  })

  console.log(`[Platform] Released offer ${offerId} · tx: ${hash}`)
  return hash
}

/**
 * Cancel offer and return USDC to maker — used for disputes/timeouts.
 */
export async function cancelPlatform(
  offerId: `0x${string}`,
  reason:  string,
): Promise<`0x${string}`> {
  if (!VAULT_ADDRESS) throw new Error('AFRIFX_VAULT_ADDRESS not set in .env')
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      VAULT_ADDRESS,
    abi:          VAULT_ABI,
    functionName: 'cancelP2POffer',
    args:         [offerId, reason],
  })

  console.log(`[Platform] Cancelled offer ${offerId} · reason: ${reason} · tx: ${hash}`)
  return hash
}
