#!/bin/bash
# ============================================================
# AfriFX -- README brought up to date
#
# The README described an earlier version of the product. For the first thing a
# developer, partner or investor reads, that matters.
#
# CORRECTED
#   * "five African currency corridors" -> the real 13 currencies, named.
#   * The whole "Multi-Corridor Swaps" phase retitled to "FX Trading", since
#     Corridor no longer exists as a feature. Explains instead that every pair
#     routes through USDC, which is what actually happens.
#   * taker/maker replaced with buyer/seller throughout the prose, matching the
#     UI rename. (The DATABASE fields are still taker_/maker_ and were not
#     touched; this is documentation only.)
#   * Intro now mentions that USDC bridges in and out of Arc, so funds aren't
#     trapped on one chain.
#   * Live Platform section lists the bridged chains.
#
# ADDED (shipped features that weren't documented at all)
#   * Phase 11, Cross-Chain Bridge. Explains burn-and-mint vs wrapped tokens,
#     and is HONEST about the risk: a burn is irreversible until the mint, so it
#     describes how state is persisted before signing and why an interrupted
#     transfer is recoverable rather than lost.
#   * Phase 12, Unified Balance via Circle Gateway, including why Arc's ~0.5s
#     finality makes it a natural home for the balance.
#   * Phase 13, AI Dispute Triage, stated plainly as ADVISORY ONLY, with the
#     prompt-injection handling described rather than glossed over.
#   * Feature bullets updated: 13 currencies, bridging, unified balance, PDF
#     payment proof, duty rosters.
#
# Also removed every em-dash, matching the convention we settled on for the
# codebase.
#
# Deliberately NOT claimed: fiat on/off-ramp, Flutterwave, or mainnet. Those
# aren't shipped, and a README that oversells is worse than one that's stale.
#
# Run from ~/AfriFX:  bash readme-update.sh
# ============================================================
set -e
echo ""
echo "Updating README..."
echo ""

cat > "README.md" << 'AFX_EOF'
# AfriFX, Stablecoin-Powered Cross-Border Payments on Arc

AfriFX is a decentralised foreign exchange and cross-border payments platform built on the Arc blockchain. It enables individuals and businesses across Africa to move money across borders using USDC stablecoins as the settlement layer, with real local currency amounts on both ends. USDC can be bridged in and out of Arc from Ethereum, Base, Arbitrum and Polygon, so funds are never trapped on a single chain. Every transaction is settled on-chain, transparent, and traceable on ArcScan.

---

## What Problem Does AfriFX Solve?

Cross-border payments in Africa are slow, expensive, and opaque. Traditional banks charge high fees, take days to settle, and require extensive documentation. Mobile money operators are fast but are siloed within country borders. AfriFX bridges this gap by using USDC as a neutral settlement currency between any two African currencies, with peer-to-peer trading at market rates and a built-in escrow system to protect both parties.

---

## How It Works, Phase by Phase

### Phase 1 & 2, FX Trading
The core of AfriFX is a direct USDC exchange supporting 13 African currencies: Nigerian Naira (NGN), Ghanaian Cedi (GHS), Kenyan Shilling (KES), South African Rand (ZAR), Egyptian Pound (EGP), Ugandan Shilling (UGX), Tanzanian Shilling (TZS), Rwandan Franc (RWF), West African CFA (XOF), Central African CFA (XAF), Zambian Kwacha (ZMW), Ethiopian Birr (ETB) and Mozambican Metical (MZN). Every pair routes through USDC, so any local currency can reach any other. Exchange rates are sourced live from multiple API providers with automatic fallback, database caching, and hardcoded last-resort values so a feed outage never blocks a trade.

### Phase 3, Peer-to-Peer Marketplace
The P2P marketplace lets users trade USDC directly with each other at agreed rates. A seller creates an offer specifying the amount, currency, and rate. A buyer accepts the offer on-chain, locking the USDC in escrow inside the AfriFXVault smart contract. The buyer then sends the local currency payment off-chain (bank transfer or mobile money) and confirms, attaching a PDF receipt as proof. The seller confirms receipt and the smart contract automatically releases the USDC to the buyer. Both parties can communicate through a built-in trade chat that is automatically deleted once the trade completes.

### Phase 4, User Profiles and Reputation
Every wallet can create a unique username and public profile. Reputation is built automatically from completed trades, with tiers ranging from New to Elite. Verified status is granted to accounts with more than ten completed trades and no disputes. Profiles are searchable by username and show trade history, reputation tier, and verified badge.

### Phase 5, Infrastructure and Rate Oracle
A multi-source rate oracle fetches live exchange rates from multiple providers with automatic failover. Rates are cached in the database and served instantly to the frontend. The backend runs background jobs every 30 minutes to refresh rates. All rate failures are handled gracefully with database fallback.

### Phase 6, Business Treasury
Business accounts get a dedicated treasury dashboard showing their portfolio in both crypto and local currency equivalents. The treasury supports automatic conversion rules, for example, automatically converting USDC to NGN when balances exceed a threshold. Payroll batches let businesses pay multiple recipients in a single operation, each receiving a unique Memo reference for reconciliation.

### Phase 7, Admin Dashboard
A secure two-factor admin panel accessible only to registered admin wallets. Super admins can create sub-admin accounts with granular permissions covering disputes, offers, users, analytics, treasury, and audit logs. Every admin action is logged for audit purposes. Sub-admins only see the sections they have been granted access to.

### Phase 8, Trade Settlement and Invoices
Businesses can generate invoices with unique Memo references (e.g. INV-20260627-A3X2) and share payment links with their clients. The payer visits the link, connects their wallet, and pays in USDC, with local currency invoices automatically converted at live rates before payment. A settlement reports page aggregates all payments, invoices, and FX conversions into a downloadable CSV for accounting.

### Phase 9, Dispute Resolution System
Three dispute flows are handled automatically:

**Flow 1, buyer does not send:** If the buyer accepts an offer but never confirms sending the local currency within the agreed window, the platform automatically cancels the trade and returns USDC to the seller. No human intervention needed.

**Flow 2, buyer claims to have sent but seller disputes:** After the seller's response window elapses, the seller can raise a dispute stating they did not receive payment. An admin reviews the evidence and resolves, either releasing USDC to the buyer or refunding the seller.

**Flow 3, buyer sends but seller goes silent:** After the seller's response window elapses without any action, the buyer can raise a dispute. If neither party raises a dispute and the seller remains silent for 24 hours, USDC is automatically released to the buyer. If a dispute is raised by either party, an admin must resolve it; there is no automatic release.

### Phase 10, Dispute Chat and Evidence Review
When a dispute is raised, it appears on the admin dashboard. An admin clicks "Accept dispute, become judge" to take ownership. The moment they accept, both the seller and buyer see the admin's name on their offer page along with a chat interface. The admin can message both parties from a single interface, request bank statements, and review uploaded PDF evidence. Bank statements uploaded by either party are visible only to the admin for privacy. Once the admin reaches a verdict, they click either "Release USDC to buyer" or "Refund USDC to seller" and the smart contract executes immediately. All messages are archived for super admin audit.

### Phase 11, Cross-Chain Bridge (Circle CCTP)
USDC can be moved between Arc and Ethereum, Base, Arbitrum and Polygon using Circle's Cross-Chain Transfer Protocol. This is a burn-and-mint bridge, not a wrapped-token bridge: USDC is burned on the source chain and native USDC is minted on the destination, so there is no third-party custody and no synthetic asset. The user signs both transactions from their own wallet.

Because a burn is irreversible until the matching mint completes, every bridge is recorded in the database *before* anything is signed, and each stage is persisted as it happens. A transfer interrupted between burn and mint is never lost: the burn transaction hash is stored, the mint remains claimable by anyone, and a reconciler tracks anything still outstanding. The UI distinguishes clearly between a transfer that failed before the burn (nothing moved, safe to retry) and one still in flight (funds burned, mint owed).

### Phase 12, Unified Balance (Circle Gateway)
Circle Gateway gives each user a single USDC balance that is spendable on any supported chain. Funds are deposited once, and after they reach finality on the deposit chain they can be spent instantly, in under a second, on any other chain without bridging first. Arc finalises in roughly half a second, which makes it a natural home for the balance.

This powers cross-chain sends: a same-chain transfer goes directly from the wallet, while a cross-chain transfer draws on the unified balance. The user picks a destination and the app chooses the route.

### Phase 13, AI Dispute Triage
Admins handling a dispute can generate a neutral, structured summary of the case: a timeline, each party's position, where their accounts diverge, what the on-chain record shows, what the uploaded evidence contains, and what is missing. It reads the trade data, the chat transcript and the PDF evidence.

It is strictly advisory. It never decides, never messages users and never touches escrow; the human admin still rules on every dispute. Because the chat and evidence are user-supplied, the assistant treats them as untrusted data and reports any embedded attempt to instruct it rather than following it, surfacing manipulation attempts to the admin instead of acting on them.

---

## Key Features Summary

**For individuals:**
- Trade between USDC and 13 African currencies at live rates
- Bridge native USDC between Arc, Ethereum, Base, Arbitrum and Polygon
- Hold one unified USDC balance spendable across chains
- Trade peer-to-peer with anyone at agreed rates
- Full escrow protection, funds locked on-chain until both parties confirm
- Built-in trade chat with PDF payment proof and automatic cleanup after completion
- Public profile with verified badge and reputation tier

**For businesses:**
- Portfolio dashboard showing holdings in local currency equivalents
- Treasury automation rules for currency conversion
- Batch payroll with unique Memo references per recipient
- Invoice generation with shareable payment links
- Settlement reports with CSV export for accounting

**For platform integrity:**
- Smart contract escrow, no counterparty risk
- Automatic dispute resolution for clear-cut cases
- Admin-mediated resolution with evidence chat for complex cases
- AI case summaries to speed up admin triage, advisory only
- Duty rosters so disputes are only routed to admins who are on shift
- Full on-chain transaction history on ArcScan
- Every admin action logged for audit

---

## Live Platform

- **Frontend:** [afrifx.xyz](https://afrifx.xyz)
- **API:** [afrifx-api.onrender.com](https://afrifx-api.onrender.com)
- **Home chain:** Arc Testnet (Chain ID 5042002)
- **Bridged chains:** Ethereum Sepolia, Base Sepolia, Arbitrum Sepolia, Polygon Amoy
- **Explorer:** [testnet.arcscan.app](https://testnet.arcscan.app)

---

## Getting Started

1. Visit [afrifx.xyz](https://afrifx.xyz) and connect your wallet (MetaMask, Coinbase Wallet, or any WalletConnect-compatible wallet)
2. Get testnet USDC from the Arc faucet if you need funds to trade
3. Create your profile with a unique username
4. Start trading, bridging USDC from another chain, or creating invoices

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

*Built on Arc Testnet · Powered by USDC · Bridged with Circle CCTP and Gateway · Settled on-chain*
AFX_EOF
echo "  README.md"

echo ""
echo "Done. Then:"
echo "  git add -A && git commit -m 'README: 13 currencies, bridge, unified balance, AI triage'"
echo "  git push"
echo ""
echo "  Worth reading it through on GitHub afterwards, since it renders there"
echo "  and it's the first thing anyone evaluating the project will see."
