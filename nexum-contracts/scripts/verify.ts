import { run } from 'hardhat'

// Fill these after deploying
const VAULT_ADDRESS    = process.env.VAULT_ADDRESS    ?? ''
const EXCHANGE_ADDRESS = process.env.EXCHANGE_ADDRESS ?? ''
const USDC_ADDRESS     = '0x3600000000000000000000000000000000000000'

async function main() {
  if (!VAULT_ADDRESS || !EXCHANGE_ADDRESS) {
    throw new Error('Set VAULT_ADDRESS and EXCHANGE_ADDRESS in env before verifying')
  }

  console.log('Verifying AfriFXVault…')
  await run('verify:verify', {
    address:              VAULT_ADDRESS,
    constructorArguments: [USDC_ADDRESS],
  })

  console.log('Verifying AfriFXExchange…')
  await run('verify:verify', {
    address:              EXCHANGE_ADDRESS,
    constructorArguments: [],
  })

  console.log('✅  Verification complete')
}

main().catch((err) => { console.error(err); process.exit(1) })
