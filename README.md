# AfriFX
Stablecoin-powered foreign exchange and cross-border payment platform built on Arc.

## Arc Chain
- Chain ID: `5042002`
- RPC: `https://rpc.testnet.arc.network`
- USDC (gas): `0x3600000000000000000000000000000000000000`
- Explorer: `https://testnet.arcscan.app`

## Projects
| Folder | Stack |
|---|---|
| `afrifx-web/` | Next.js 14, wagmi v2, viem, Tailwind |
| `afrifx-api/` | Express, TypeScript, Drizzle, Turso |
| `afrifx-contracts/` | Solidity, Hardhat, Arc Testnet |

## Quick start
```bash
# Frontend
cd afrifx-web && npm install && npm run dev

# Backend
cd afrifx-api && npm install && npm run dev

# Contracts
cd afrifx-contracts && npm install && npx hardhat compile
```
