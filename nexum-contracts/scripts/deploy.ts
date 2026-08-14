import { ethers } from 'hardhat'

// Arc Testnet USDC address 6 decimals ERC-20 interface
const USDC_ADDRESS = '0x3600000000000000000000000000000000000000'

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('\n🚀  Deploying AfriFX contracts to Arc Testnet')
  console.log('    Deployer:', deployer.address)
  console.log('    Chain ID: 5042002\n')

  // Deploy AfriFXVault
  const Vault = await ethers.getContractFactory('AfriFXVault')
  const vault = await Vault.deploy(USDC_ADDRESS)
  await vault.waitForDeployment()
  const vaultAddr = await vault.getAddress()
  console.log('✅  AfriFXVault deployed:', vaultAddr)

  // Deploy AfriFXExchange
  const Exchange = await ethers.getContractFactory('AfriFXExchange')
  const exchange = await Exchange.deploy()
  await exchange.waitForDeployment()
  const exchangeAddr = await exchange.getAddress()
  console.log('✅  AfriFXExchange deployed:', exchangeAddr)

  console.log('\n📋  Update these in afrifx-web/lib/contracts.ts:')
  console.log(`    AFRIFX_VAULT:    '${vaultAddr}'`)
  console.log(`    AFRIFX_EXCHANGE: '${exchangeAddr}'`)

  console.log('\n📋  Update in afrifx-api/.env:')
  console.log(`    AFRIFX_VAULT_ADDRESS=${vaultAddr}`)

  console.log('\n🔍  View on ArcScan:')
  console.log(`    https://testnet.arcscan.app/address/${vaultAddr}`)
  console.log(`    https://testnet.arcscan.app/address/${exchangeAddr}`)
}

main().catch((err) => { console.error(err); process.exit(1) })
