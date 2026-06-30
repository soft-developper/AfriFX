# AfriFX — Stablecoin-Powered Cross-Border Payments on Arc

AfriFX is a decentralised foreign exchange and cross-border payments platform built on the Arc blockchain. It enables individuals and businesses across Africa to move money across borders using USDC stablecoins as the settlement layer — with real local currency amounts on both ends. Every transaction is settled on-chain, transparent, and traceable on ArcScan.

---

## What Problem Does AfriFX Solve?

Cross-border payments in Africa are slow, expensive, and opaque. Traditional banks charge high fees, take days to settle, and require extensive documentation. Mobile money operators are fast but are siloed within country borders. AfriFX bridges this gap by using USDC as a neutral settlement currency between any two African currencies, with peer-to-peer trading at market rates and a built-in escrow system to protect both parties.

---

## How It Works — Phase by Phase

### Phase 1 & 2 — FX Conversion and Multi-Corridor Swaps
The core of AfriFX is a direct USDC exchange that supports five African currency corridors: Nigerian Naira (NGN), Ghanaian Cedi (GHS), Kenyan Shilling (KES), South African Rand (ZAR), and Egyptian Pound (EGP). Users can convert USDC to any of these currencies or swap between two local currencies through a two-step corridor (local → USDC → local). All exchange rates are sourced live from multiple API providers with automatic fallback and caching.

### Phase 3 — Peer-to-Peer Marketplace
The P2P marketplace lets users trade USDC directly with each other at agreed rates. A maker creates an offer specifying the amount, currency, and rate. A taker accepts the offer on-chain, locking the USDC in escrow inside the AfriFXVault smart contract. The taker then sends the local currency payment off-chain (bank transfer, mobile money) and confirms. The maker confirms receipt and the smart contract automatically releases the USDC to the taker. Both parties can communicate through a built-in trade chat that is automatically deleted once the trade completes.

### Phase 4 — User Profiles and Reputation
Every wallet can create a unique username and public profile. Reputation is built automatically from completed trades, with tiers ranging from New to Elite. Verified status is granted to accounts with more than ten completed trades and no disputes. Profiles are searchable by username and show trade history, reputation tier, and verified badge.

### Phase 5 — Infrastructure and Rate Oracle
A multi-source rate oracle fetches live exchange rates from multiple providers with automatic failover. Rates are cached in the database and served instantly to the frontend. The backend runs background jobs every 30 minutes to refresh rates. All rate failures are handled gracefully with database fallback.

### Phase 6 — Business Treasury
Business accounts get a dedicated treasury dashboard showing their portfolio in both crypto and local currency equivalents. The treasury supports automatic conversion rules — for example, automatically converting USDC to NGN when balances exceed a threshold. Payroll batches let businesses pay multiple recipients in a single operation, each receiving a unique Memo reference for reconciliation.

### Phase 7 — Admin Dashboard
A secure two-factor admin panel accessible only to registered admin wallets. Super admins can create sub-admin accounts with granular permissions covering disputes, offers, users, analytics, treasury, and audit logs. Every admin action is logged for audit purposes. Sub-admins only see the sections they have been granted access to.

### Phase 8 — Trade Settlement and Invoices
Businesses can generate invoices with unique Memo references (e.g. INV-20260627-A3X2) and share payment links with their clients. The payer visits the link, connects their wallet, and pays in USDC — with local currency invoices automatically converted at live rates before payment. A settlement reports page aggregates all payments, invoices, and FX conversions into a downloadable CSV for accounting.

### Phase 9 — Dispute Resolution System
Three dispute flows are handled automatically:

**Flow 1 — Taker does not send:** If the taker accepts an offer but never confirms sending the local currency within the agreed window, the platform automatically cancels the trade and returns USDC to the maker. No human intervention needed.

**Flow 2 — Taker claims to have sent, maker disputes:** After the maker's response window elapses, the maker can raise a dispute stating they did not receive payment. An admin reviews the evidence and resolves — either releasing USDC to the taker or refunding the maker.

**Flow 3 — Taker sends, maker goes silent:** After the maker's response window elapses without any action, the taker can raise a dispute. If neither party raises a dispute and the maker remains silent for 24 hours, USDC is automatically released to the taker. If a dispute is raised by either party, an admin must resolve it — there is no automatic release.

### Phase 10 — Dispute Chat and Evidence Review
When a dispute is raised, it appears on the admin dashboard. An admin clicks "Accept dispute — become judge" to take ownership. The moment they accept, both the maker and taker see the admin's name on their offer page along with a chat interface. The admin can message both parties from a single interface, request bank statements, and review uploaded PDF evidence. Bank statements uploaded by either party are visible only to the admin for privacy. Once the admin reaches a verdict, they click either "Release USDC to taker" or "Refund USDC to maker" and the smart contract executes immediately. All messages are archived for super admin audit.

---

## Key Features Summary

**For individuals:**
- Convert between USDC and 5 African currencies at live rates
- Trade peer-to-peer with anyone at agreed rates
- Full escrow protection — funds locked on-chain until both parties confirm
- Built-in trade chat with automatic cleanup after completion
- Public profile with verified badge and reputation tier

**For businesses:**
- Portfolio dashboard showing holdings in local currency equivalents
- Treasury automation rules for currency conversion
- Batch payroll with unique Memo references per recipient
- Invoice generation with shareable payment links
- Settlement reports with CSV export for accounting

**For platform integrity:**
- Smart contract escrow — no counterparty risk
- Automatic dispute resolution for clear-cut cases
- Admin-mediated resolution with evidence chat for complex cases
- Full on-chain transaction history on ArcScan
- Every admin action logged for audit

---

## Live Platform

- **Frontend:** [afrifx.xyz](https://afrifx.xyz)
- **API:** [afrifx-api.onrender.com](https://afrifx-api.onrender.com)
- **Blockchain:** Arc Testnet (Chain ID 5042002)
- **Explorer:** [testnet.arcscan.app](https://testnet.arcscan.app)

---

## Getting Started

1. Visit [afrifx.xyz](https://afrifx.xyz) and connect your wallet (MetaMask, Coinbase Wallet, or any WalletConnect-compatible wallet)
2. Get testnet USDC from the Arc faucet if you need funds to trade
3. Create your profile with a unique username
4. Start converting, trading, or creating invoices

For businesses, reach out to the platform admin to set up a treasury account with custom conversion rules and payroll access.

---

## Developer Setup

```bash
# Clone the repository
git clone https://github.com/soft-developper/AfriFX.git
cd AfriFX

# Backend
cd afrifx-api
npm install
cp .env.example .env        # fill in your credentials
npm run dev

# Frontend (new terminal)
cd afrifx-web
npm install
cp .env.local.example .env.local    # fill in your credentials
npm run dev
```

See `.env.example` and `.env.local.example` for the full list of required environment variables.

---

*Built on Arc Testnet · Powered by USDC · Settled on-chain*
