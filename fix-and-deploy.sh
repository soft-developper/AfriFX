#!/bin/bash
# ============================================================
# AfriFX — Fix errors + add MockUSDC for tests
# Run from ~/AfriFX:  bash fix-and-deploy.sh
# ============================================================
set -e
echo ""
echo "🔧  Applying fixes..."
echo ""

# ============================================================
# FIX 1 — Backend: replace ts-node --esm with tsx
# tsx handles CommonJS + ESM automatically, no flags needed
# ============================================================

cat > afrifx-api/package.json << '__EOF__'
{
  "name": "afrifx-api",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev":      "tsx src/index.ts",
    "build":    "tsc",
    "start":    "node dist/index.js",
    "db:push":  "drizzle-kit push"
  },
  "dependencies": {
    "express":        "^4.19.2",
    "cors":           "^2.8.5",
    "dotenv":         "^16.4.5",
    "viem":           "^2.17.7",
    "@libsql/client": "^0.10.0",
    "drizzle-orm":    "^0.33.0",
    "node-cron":      "^3.0.3"
  },
  "devDependencies": {
    "@types/express":   "^4.17.21",
    "@types/cors":      "^2.8.17",
    "@types/node":      "^20",
    "@types/node-cron": "^3.0.11",
    "drizzle-kit":      "^0.24.0",
    "typescript":       "^5",
    "tsx":              "^4.19.1"
  }
}
__EOF__

echo "✅  Backend package.json updated (tsx replaces ts-node --esm)"

# ============================================================
# FIX 2 — Frontend: remove metaMask() connector
# metaMask() pulls in MetaMask SDK which needs React Native deps.
# injected() works for MetaMask, Rabby, and all browser wallets.
# ============================================================

cat > afrifx-web/lib/wagmi.ts << '__EOF__'
import { createConfig, http } from 'wagmi'
import { injected, coinbaseWallet } from 'wagmi/connectors'
import { arcTestnet } from './arc-chain'

export const wagmiConfig = createConfig({
  chains: [arcTestnet],
  connectors: [
    injected(),                                      // MetaMask, Rabby, any injected wallet
    coinbaseWallet({ appName: 'AfriFX' }),
  ],
  transports: {
    [arcTestnet.id]: http('https://rpc.testnet.arc.network'),
  },
})
__EOF__

echo "✅  Frontend wagmi.ts fixed (removed metaMask() connector)"

# ============================================================
# FIX 3 — Add MockUSDC contract (needed by Vault test)
# ============================================================

cat > afrifx-contracts/contracts/MockUSDC.sol << '__EOF__'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Simple ERC-20 mock that mimics Arc USDC (6 decimals)
// Used ONLY in local Hardhat tests — never deployed to Arc Testnet

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
__EOF__

echo "✅  MockUSDC.sol added"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  All fixes applied"
echo ""
echo "📦  Now run:"
echo "    cd afrifx-api && npm install   (installs tsx)"
echo "══════════════════════════════════════════════════════"
