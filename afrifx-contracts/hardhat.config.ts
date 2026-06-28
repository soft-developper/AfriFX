import { HardhatUserConfig } from 'hardhat/config'
import '@nomicfoundation/hardhat-toolbox'
import * as dotenv from 'dotenv'
dotenv.config()

const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY ?? '0x' + '0'.repeat(64)

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    arc_testnet: {
      url:      process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network',
      chainId:  5042002,
      accounts: [PRIVATE_KEY],
      // Arc uses USDC as gas token — ensure deployer wallet has testnet USDC
      // Faucet: https://faucet.circle.com
    },
    hardhat: {
      chainId: 31337,
    },
  },
  etherscan: {
    apiKey: {
      arc_testnet: process.env.ARCSCAN_API_KEY ?? 'placeholder',
    },
    customChains: [
      {
        network: 'arc_testnet',
        chainId: 5042002,
        urls: {
          apiURL:     'https://testnet.arcscan.app/api',
          browserURL: 'https://testnet.arcscan.app',
        },
      },
    ],
  },
}

export default config
